Require Import Coq.Lists.List.
Require Import SGA.Syntax SGA.TypedSyntax SGA.Primitives SGA.Interop.
Import ListNotations.

Section SyntaxMacros.
  Context {pos_t method_name_t var_t reg_t: Type}.

  Definition bits_of_ascii c : bits 8 :=
    match c with
    | Ascii.Ascii b0 b1 b2 b3 b4 b5 b6 b7 =>
      Ob~b7~b6~b5~b4~b3~b2~b1~b0
    end.

  Fixpoint bits_of_bytes s : bits (String.length s * 8) :=
    match s with
    | EmptyString => Ob
    | String c s =>
      Bits.app (bits_of_bytes s) (bits_of_ascii c) (* FIXME: reversed *)
    end.

  Section ConstBits.
    Context {fn_t: Type}.
    Notation uaction := (uaction pos_t method_name_t var_t reg_t fn_t).

    Definition UConstBits {sz} (bs: bits sz) : uaction :=
      UConst (tau := bits_t sz) bs.

    Definition USkip : uaction :=
      UConstBits Ob.
  End ConstBits.

  Section Interop.
    Context {custom_fn_t: Type}.
    Notation uaction := (uaction pos_t method_name_t var_t reg_t (interop_ufn_t custom_fn_t)).

    Definition if_eq a1 a2 (tbranch fbranch: uaction) :=
      UIf (UCall (UPrimFn (UConvFn UEq)) a1 a2)
          tbranch
          fbranch.

    Fixpoint USwitch
             (var: uaction)
             (default: uaction)
             (branches: list (uaction * uaction))
      : uaction :=
      match branches with
      | nil => default
      | (val, action) :: branches =>
        if_eq var val
              action (USwitch var default branches)
      end.

    Fixpoint gen_switch {tau}
             (var: var_t)
             {nb} (branches: vect (type_denote tau * uaction) (S nb)) : uaction :=
      let '(label, branch) := vect_hd branches in
      match nb return vect _ (S nb) -> uaction with
      | 0 => fun _ => branch
      | S nb => fun branches => if_eq (UVar var) (UConst label)
                                  branch (gen_switch var (vect_tl branches))
      end branches.

    Definition UCompleteSwitch
               sz bound
               (var: var_t)
               (branches: vect uaction (S bound)) :=
      gen_switch (tau := bits_t sz) var
                 (vect_map2 (fun n a => (Bits.of_nat sz (index_to_nat n), a))
                            (all_indices (S bound)) branches).

    Definition UStructInit
               (sig: struct_sig)
               (fields: list (string * uaction)) :=
      let uinit := UPrimFn (UConvFn (UInit (struct_t sig))) in
      let usubst f := UPrimFn (UStructFn (UDo SubstField f)) in
      List.fold_left (fun acc '(f, a) => UCall (usubst f) acc a)
                     fields (UCall uinit (UConstBits Ob) (UConstBits Ob)).
  End Interop.

  Section InlineCalls.
    Context {module_reg_t: Type}.
    Context {fn_t module_fn_t: Type}.
    Context (fR: module_reg_t -> reg_t).
    Context (fSigma: module_fn_t -> fn_t).

    Fixpoint UCallModule (ua: uaction pos_t method_name_t var_t module_reg_t module_fn_t)
      : uaction pos_t method_name_t var_t reg_t fn_t :=
      match ua with
      | UError => UError
      | UFail tau => UFail tau
      | UVar var => UVar var
      | UConst cst => UConst cst
      | UConstString s => UConstString s
      | UConstEnum sig cst => UConstEnum sig cst
      | UAssign v ex => UAssign v (UCallModule ex)
      | USeq r1 r2 => USeq (UCallModule r1) (UCallModule r2)
      | UBind v ex body => UBind v (UCallModule ex) (UCallModule body)
      | UIf cond tbranch fbranch => UIf (UCallModule cond) (UCallModule tbranch) (UCallModule fbranch)
      | URead port idx => URead port (fR idx)
      | UWrite port idx value => UWrite port (fR idx) (UCallModule value)
      | UCall fn arg1 arg2 => UCall (fSigma fn) (UCallModule arg1) (UCallModule arg2)
      | UInternalCall sig body args => UInternalCall sig (UCallModule body) (List.map UCallModule args)
      | UAPos p e => UAPos p (UCallModule e)
      end.
  End InlineCalls.
End SyntaxMacros.

Section TypedSyntaxMacros.
  Context {var_t reg_t fn_t: Type}.
  Context {R: reg_t -> type}
          {Sigma: fn_t -> ExternalSignature}.

  Notation action := (action var_t R Sigma).

  Fixpoint mshift {K} (prefix: list K) {sig: list K} {k} (m: member k sig)
    : member k (prefix ++ sig) :=
    match prefix return member k sig -> member k (prefix ++ sig) with
    | [] => fun m => m
    | k' :: prefix => fun m => MemberTl k k' (prefix ++ sig) (mshift prefix m)
    end m.

  Fixpoint mshift' {K} (infix: list K) {sig sig': list K} {k} (m: member k (sig ++ sig'))
    : member k (sig ++ infix ++ sig').
  Proof.
    destruct sig as [ | k' sig].
    - exact (mshift infix m).
    - destruct (mdestruct m) as [(-> & Heq) | (m' & Heq)]; cbn in *.
      + exact (MemberHd k' (sig ++ infix ++ sig')).
      + exact (MemberTl k k' (sig ++ infix ++ sig') (mshift' _ infix sig sig' k m')).
  Defined.

  Fixpoint infix_action (infix: tsig var_t) {sig sig': tsig var_t} {tau} (a: action (sig ++ sig') tau)
    : action (sig ++ infix ++ sig') tau.
  Proof.
    remember (sig ++ sig'); destruct a; subst.
    - exact (Fail tau).
    - exact (Var (mshift' infix m)).
    - exact (Const cst).
    - exact (Assign (mshift' infix m) (infix_action infix _ _ _ a)).
    - exact (Seq (infix_action infix _ _ _ a1) (infix_action infix _ _ _ a2)).
    - exact (Bind var (infix_action infix _ _ _ a1) (infix_action infix (_ :: sig) sig' _ a2)).
    - exact (If (infix_action infix _ _ _ a1) (infix_action infix _ _ _ a2) (infix_action infix _ _ _ a3)).
    - exact (Read port idx).
    - exact (Write port idx (infix_action infix _ _ _ a)).
    - exact (Call fn (infix_action infix _ _ _ a1) (infix_action infix _ _ _ a2)).
  Defined.

  Definition prefix_action (prefix: tsig var_t) {sig: tsig var_t} {tau} (a: action sig tau)
    : action (prefix ++ sig) tau :=
    infix_action prefix (sig := []) a.

  Fixpoint suffix_action_eqn {A} (l: list A) {struct l}:
    l ++ [] = l.
  Proof. destruct l; cbn; [ | f_equal ]; eauto. Defined.

  Definition suffix_action (suffix: tsig var_t) {sig: tsig var_t} {tau} (a: action sig tau)
    : action (sig ++ suffix) tau.
  Proof. rewrite <- (suffix_action_eqn suffix); apply infix_action; rewrite (suffix_action_eqn sig); exact a. Defined.

  Fixpoint InternalCall'
           {tau: type}
           (sig: tsig var_t)
           (fn_sig: tsig var_t)
           (fn_body: action (fn_sig ++ sig) tau)
           (args: context (fun '(_, tau) => action sig tau) fn_sig)
    : action sig tau :=
    match fn_sig return action (fn_sig ++ sig) tau ->
                        context (fun '(_, tau) => action sig tau) fn_sig ->
                        action sig tau with
    | [] =>
      fun fn_body _ =>
        fn_body
    | (k, tau) :: fn_sig =>
      fun fn_body args =>
        InternalCall' sig fn_sig
                      (Bind k (prefix_action fn_sig (chd args)) fn_body)
                      (ctl args)
    end fn_body args.

  Fixpoint InternalCall
             {tau: type}
             (sig: tsig var_t)
             (fn_sig: tsig var_t)
             (fn_body: action fn_sig tau)
             (args: context (fun '(_, tau) => action sig tau) fn_sig)
    : action sig tau :=
    InternalCall' sig fn_sig (suffix_action sig fn_body) args.
End TypedSyntaxMacros.

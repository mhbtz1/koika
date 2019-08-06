type __ = Obj.t
let __ = let rec f _ = Obj.repr f in Obj.repr f

open Common

type ('prim, 'reg_t, 'fn_t) dedup_input_t = {
    di_regs: 'reg_t list;
    di_reg_sigs: 'reg_t -> reg_signature;
    di_fn_sigs: 'fn_t -> 'prim ffi_signature;
    di_circuits : 'reg_t -> ('reg_t, 'fn_t) SGA.circuit
  }

module SGA = SGA

module Util = struct
  let type_to_string (tau: SGA.type0) =
    Printf.sprintf "bits %d" tau

  let string_eq_dec (s1: string) (s2: string) =
    s1 = s2

  let string_of_bits bs =
    let bitstring = String.concat "" (List.rev_map (fun b -> if b then "1" else "0") bs.bs_bits) in
    Printf.sprintf "%d'b%s" bs.bs_size bitstring

  let string_of_coq_string chars =
    String.concat "" (List.map (String.make 1) chars)

  let type_error_to_error (epos: 'f) (err: _ SGA.error_message) =
    let ekind, emsg = match err with
      | SGA.UnboundVariable var ->
         (`NameError, Printf.sprintf "Unbound variable `%s'" var)
      | SGA.TypeMismatch (_tsig, actual, _expr, expected) ->
         (`TypeError, Printf.sprintf "This term has type `%s', but `%s' was expected"
                        (type_to_string actual) (type_to_string expected))
    in { epos; ekind; emsg }

  let bits_const_of_bits sz bs =
    { bs_size = sz;
      bs_bits = SGA.vect_to_list sz bs }

  let bits_const_to_int bs =
    List.fold_right (fun b bs -> (if b then 1 else 0) + 2 * bs) bs.bs_bits 0

  let ffi_signature_of_interop_fn ffi_name (fsig: SGA.externalSignature) =
    { ffi_name;
      ffi_arg1size = fsig.arg1Type;
      ffi_arg2size = fsig.arg2Type;
      ffi_retsize = fsig.retType }

  let make_dedup_input registers circuits =
    { di_regs = registers;
      di_reg_sigs = (fun r -> r);
      di_fn_sigs = (fun fn ->
        let ffi_name, fsig = match fn with
          | SGA.PrimFn fn ->
             PrimFn fn,
             SGA.prim_Sigma fn
          | SGA.CustomFn _ ->
             failwith "No custom functions" in
        ffi_signature_of_interop_fn ffi_name fsig);
      di_circuits = circuits }

  let dedup_input_of_verilogPackage (pkg: SGA.verilogPackage) =
    let di_regs =
      pkg.vp_reg_finite.finite_elems in
    let di_reg_sigs r =
      let sz = pkg.vp_reg_types r in
      { reg_name = string_of_coq_string (pkg.vp_reg_names r);
        reg_size = sz;
        reg_init_val = bits_const_of_bits sz (pkg.vp_reg_init r) } in
    let di_fn_sigs fn =
      let ffi_name, fsig = match fn with
      | SGA.PrimFn fn ->
         PrimFn fn,
         SGA.prim_Sigma fn
      | SGA.CustomFn fn ->
         CustomFn (string_of_coq_string (pkg.vp_custom_fn_names fn)),
         pkg.vp_custom_fn_types fn in
      ffi_signature_of_interop_fn ffi_name fsig in
    let di_circuits r =
      SGA.getenv pkg.vp_reg_Env pkg.vp_circuit r in
    { di_regs; di_reg_sigs; di_fn_sigs; di_circuits }
end

module Compilation = struct
  module DebugPrinter = struct
    open SGA
    open Printf

    let pp_port = function
      | P0 -> "P0"
      | P1 -> "P1"

    let rec pp_expr = function
      | UVar v -> sprintf "var %s" v
      | UConst (n, bs) ->
         sprintf "%d'%s" n
           (String.concat "" (List.rev_map (fun x -> if x then "1" else "0") (SGA.vect_to_list n bs)))
      | URead (p, r) -> sprintf "%s.read#%s" r.reg_name (pp_port p)
      | UCall (_, e1, e2) -> (sprintf "UCall (__, %s, %s)" (pp_expr e1) (pp_expr e2))
      | UEPos (_, x) -> pp_expr x

    let rec pp_rule = function
      | USkip -> "Skip"
      | UFail -> "Fail"
      | USeq (r1, r2) -> sprintf "Seq (%s) (%s)" (pp_rule r1) (pp_rule r2)
      | UBind (v, e, r) -> sprintf "Bind (%s <- %s) (%s)" v (pp_expr e) (pp_rule r)
      | UIf (c, r1, r2) -> sprintf "If %s Then %s Else %s EndIf" (pp_expr c) (pp_rule r1) (pp_rule r2)
      | UWrite (p, r, v) -> sprintf "%s.write#%s(%s)" r.reg_name (pp_port p) (pp_expr v)
      | URPos (_, x) -> pp_rule x

    let rec pp_scheduler = function
      | UDone -> "Done"
      | UCons (r, s) -> sprintf "Cons (%s) (%s)" (pp_rule r) (pp_scheduler s)
      | UTry (r, s1, s2) -> sprintf "Try (%s) (%s) (%s)" (pp_rule r) (pp_scheduler s1) (pp_scheduler s2)
      | USPos (_, x) -> pp_scheduler x
  end

  let translate_port = function
    | 0 -> SGA.P0
    | 1 -> SGA.P1
    | _ -> assert false

  let rec translate_expr { lpos; lcnt } =
    SGA.UEPos
      (lpos,
       match lcnt with
       | Var v -> SGA.UVar v
       | Num _ -> assert false
       | Const bs -> SGA.UConst (List.length bs, SGA.vect_of_list bs)
       | Read (port, reg) -> SGA.URead (translate_port port, reg.lcnt)
       | Call (fn, a1 :: a2 :: []) -> SGA.UCall (fn.lcnt, translate_expr a1, translate_expr a2)
       | Call (_, _) -> assert false)

  let rec translate_rule { lpos; lcnt } =
    SGA.URPos
      (lpos,
       match lcnt with
       | Skip -> SGA.USkip
       | Fail -> SGA.UFail
       | Progn rs -> translate_seq rs
       | Let (bs, body) -> translate_bindings bs body
       | If (e, r, rs) -> SGA.UIf (translate_expr e, translate_rule r, translate_seq rs)
       | When (e, rs) -> SGA.UIf (translate_expr e, translate_seq rs, SGA.UFail)
       | Write (port, reg, v) ->
          SGA.UWrite (translate_port port, reg.lcnt, translate_expr v))
  and translate_bindings bs body =
    match bs with
    | [] -> translate_seq body
    | (v, e) :: bs -> SGA.UBind (v.lcnt, translate_expr e, translate_bindings bs body)
  and translate_seq rs =
    match rs with
    | [] -> SGA.USkip
    | [r] -> translate_rule r
    | r :: rs -> SGA.USeq (translate_rule r, translate_seq rs)

  let rec translate_scheduler { lpos; lcnt } =
    SGA.USPos
      (lpos,
       match lcnt with
       | Done -> SGA.UDone
       | Sequence [] -> SGA.UDone
       | Sequence (r :: rs) ->
          SGA.UCons (r.lcnt, translate_scheduler { lpos; lcnt = Sequence rs })
       | Try (r, s1, s2) ->
          SGA.UTry (r.lcnt, translate_scheduler s1, translate_scheduler s2))

  let r = fun rs ->
    rs.reg_size

  let sigma = fun fn ->
    SGA.interop_Sigma (fun _ -> failwith "No custom functions") fn

  let uSigma = fun fn ->
    SGA.interop_uSigma (fun _ -> failwith "No custom functions") fn

  let rEnv_of_register_list tc_registers =
    let eqdec r1 r2 = Util.string_eq_dec r1.reg_name r2.reg_name in
    SGA.contextEnv { SGA.finite_elems = tc_registers; (* TODO memoize call to mem *)
                     SGA.finite_index = fun rn -> match SGA.mem eqdec rn tc_registers with
                                                  | Inl m -> m
                                                  | Inr _ -> failwith "Unexpected register name" }

  type 'f raw_rule =
    ('f, ('f, reg_signature, string SGA.interop_ufn_t) rule) locd

  type typechecked_rule =
    (var_t, reg_signature, string SGA.interop_fn_t) SGA.rule

  type 'f raw_scheduler = ('f, 'f scheduler) locd

  type typechecked_scheduler = var_t SGA.scheduler

  (* FIXME hashmaps, not lists *)
  type compile_unit =
    { c_registers: reg_signature list;
      c_scheduler: string SGA.scheduler;
      c_rules: (name_t * typechecked_rule) list }

  type compiled_circuit =
    (reg_signature, string SGA.interop_fn_t) SGA.circuit

  let typecheck_scheduler (raw_ast: 'f raw_scheduler) : var_t SGA.scheduler =
    let ast = translate_scheduler raw_ast in
    SGA.type_scheduler raw_ast.lpos ast

  let result_of_type_result = function
    | SGA.WellTyped s -> Ok s
    | SGA.IllTyped { epos; emsg } ->
       Result.Error (Util.type_error_to_error epos emsg)

  let typecheck_rule (raw_ast: 'f raw_rule) : (typechecked_rule, 'f err_contents) result =
    let ast = translate_rule raw_ast in
    result_of_type_result (SGA.type_rule Util.string_eq_dec r sigma uSigma raw_ast.lpos [] ast)

  let compile (cu: compile_unit) : (reg_signature -> compiled_circuit) =
    let rEnv = rEnv_of_register_list cu.c_registers in
    let r0: _ SGA.env_t = SGA.create rEnv (fun r -> SGA.CReadRegister r) in
    let rules r = List.assoc r cu.c_rules in
    let env = SGA.compile_scheduler r sigma rEnv r0 rules cu.c_scheduler in
    (fun r -> SGA.getenv rEnv env r)
end

module Graphs = struct
  type 'prim circuit_graph = {
      graph_roots: 'prim circuit_root list;
      graph_nodes: 'prim circuit list
    }

  let dedup_circuit (type prim reg_t fn_t)
        (pkg: (prim, reg_t, fn_t) dedup_input_t) : prim circuit_graph =
    let module CircuitHash = struct
        type t = prim circuit'
        let equal (c: prim circuit') (c': prim circuit') =
          match c, c' with
          | CNot c1, CNot c1' ->
             c1 == c1'
          | CAnd (c1, c2), CAnd (c1', c2') ->
             c1 == c1' && c2 == c2'
          | COr (c1, c2), COr (c1', c2') ->
             c1 == c1' && c2 == c2'
          | CMux (_, c1, c2, c3), CMux (_, c1', c2', c3') ->
             c1 == c1' && c2 == c2' && c3 == c3'
          | CConst b, CConst b' ->
             b = b' (* Not hashconsed *)
          | CExternal (f, a1, a2), CExternal (f', a1', a2') ->
             f = f' (* Not hashconsed *) && a1 == a1' && a2 == a2'
          | CReadRegister r, CReadRegister r' ->
             r = r' (* Not hashconsed *)
          | CAnnot (_, s, c), CAnnot (_, s', c') ->
             s = s' (* Not hashconsed *) && c == c'
          | _, _ -> false
        let hash c =
          Hashtbl.hash c
      end in
    let module SGACircuitHash = struct
        type t = (reg_t, fn_t) SGA.circuit
        let equal o1 o2 = o1 == o2
        let hash o = Hashtbl.hash o
      end in
    let module HasconsedOrder = struct
        type t = prim circuit
        let compare x y = compare x.Hashcons.tag y.Hashcons.tag
      end in
    let module CircuitBag = Set.Make(HasconsedOrder) in
    let module CircuitHashcons = Hashcons.Make(CircuitHash) in
    let module SGACircuitHashtbl = Hashtbl.Make(SGACircuitHash) in

    let circuit_to_tagged = SGACircuitHashtbl.create 50 in
    let unique_tagged = CircuitHashcons.create 50 in
    let tagged_circuits = ref CircuitBag.empty in

    let rec aux (c: _ SGA.circuit) =
      match SGACircuitHashtbl.find_opt circuit_to_tagged c with
      | Some c' ->
         c'
      | None ->
         let circuit' =
           match c with
           | SGA.CNot c ->
              CNot (aux c)
           | SGA.CAnd (c1, c2) ->
              CAnd (aux c1, aux c2)
           | SGA.COr (c1, c2) ->
              COr (aux c1, aux c2)
           | SGA.CMux (sz, s, c1, c2) ->
              CMux (sz, aux s, aux c1, aux c2)
           | SGA.CConst (sz, bs) ->
              CConst (Util.bits_const_of_bits sz bs)
           | SGA.CExternal (fn, c1, c2) ->
              CExternal (pkg.di_fn_sigs fn, aux c1, aux c2)
           | SGA.CReadRegister r ->
              CReadRegister (pkg.di_reg_sigs r)
           | SGA.CAnnot (sz, annot, c) ->
              CAnnot (sz, Util.string_of_coq_string annot, aux c) in
         let circuit = CircuitHashcons.hashcons unique_tagged circuit' in
         tagged_circuits := CircuitBag.add circuit !tagged_circuits;
         SGACircuitHashtbl.add circuit_to_tagged c circuit;
         circuit in
    let graph_roots = List.map (fun reg ->
                          let c = pkg.di_circuits reg in
                          { root_reg = pkg.di_reg_sigs reg;
                            root_circuit = aux c })
                        pkg.di_regs in
    let graph_nodes = List.of_seq (CircuitBag.to_seq !tagged_circuits) in
    { graph_roots; graph_nodes }
end

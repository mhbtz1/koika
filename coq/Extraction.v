(*! Interop | Extraction to OCaml (compiler and utilities) !*)
Require Import Koika.ExtractionSetup.

Require Koika.Common
        Koika.Environments
        Koika.TypedSyntax
        Koika.TypeInference
        Koika.TypedSyntaxFunctions
        Koika.CircuitGeneration
        Koika.Interop.

Unset Extraction SafeImplicits.
Extraction "extracted.ml"
           EqDec.EqDec
           FiniteType.FiniteType Member.mem Member.mmap
           PeanoNat.Nat.log2_up
           IndexUtils.List_nth
           Environments.ContextEnv Environments.to_list
           Vect.vect_to_list Vect.vect_of_list Vect.Bits.to_nat Vect.index_to_nat Vect.vect_zip
           Syntax.scheduler
           Desugaring.desugar_action
           TypeInference.type_action TypeInference.type_rule
           TypedSyntaxFunctions.unannot
           TypedSyntaxFunctions.scheduler_rules
           TypedSyntaxFunctions.action_mentions_var
           TypedSyntaxFunctions.member_mentions_shadowed_binding
           TypedSyntaxFunctions.action_footprint
           TypedSyntaxFunctions.returns_zero
           TypedSyntaxFunctions.is_pure
           TypedSyntaxFunctions.is_tt
           TypedSyntaxFunctions.action_type
           TypedSyntaxFunctions.interp_arithmetic
           TypedSyntaxFunctions.classify_registers
           TypedSyntaxFunctions.compute_register_histories
           TypedSyntaxFunctions.may_fail_without_revert
           TypedSyntaxFunctions.rule_max_log_size
           CircuitOptimization.lco_opt_compose
           CircuitOptimization.opt_constprop
           CircuitOptimization.opt_muxelim
           Interop.koika_package_t
           Interop.circuit_package_t
           Interop.sim_package_t
           Interop.verilog_package_t
           Interop.interop_package_t
           Interop.struct_of_list
           Interop.struct_to_list
           Interop.compile_scheduler
           Interop.compile_koika_package.

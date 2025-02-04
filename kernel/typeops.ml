(************************************************************************)
(*         *   The Coq Proof Assistant / The Coq Development Team       *)
(*  v      *   INRIA, CNRS and contributors - Copyright 1999-2019       *)
(* <O___,, *       (see CREDITS file for the list of authors)           *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

open CErrors
open Util
open Names
open Univ
open Sorts
open Term
open Constr
open Stages
open SVars
open Annot
open State
open Constraints
open Staging
open Context
open Vars
open Declarations
open Environ
open Reduction
open Inductive
open Type_errors

module RelDecl = Context.Rel.Declaration
module NamedDecl = Context.Named.Declaration

exception NotConvertibleVect of int

let conv_leq l2r env x y = default_conv CUMUL ~l2r env x y

let conv_leq_vecti env v1 v2 =
  Array.fold_left2_i
    (fun i cstrnts t1 t2 ->
      try union cstrnts (conv_leq false env t1 t2)
      with NotConvertible -> raise (NotConvertibleVect i))
    (empty ())
    v1
    v2

let check_constraints cst env = 
  if Environ.check_constraints cst env then ()
  else error_unsatisfied_constraints env cst

(* This should be a type (a priori without intention to be an assumption) *)
let check_type env c t =
  match kind(whd_all env t) with
  | Sort s -> s
  | _ -> error_not_type env (make_judge c t)

(* This should be a type intended to be assumed. The error message is
   not as useful as for [type_judgment]. *)
let infer_assumption env t ty =
  try
    let s = check_type env t ty in
    (match s with Sorts.SProp -> Irrelevant | _ -> Relevant)
  with TypeError _ ->
    error_assumption env (make_judge t ty)

let warn_bad_relevance_name = "bad-relevance"
let warn_bad_relevance =
  CWarnings.create ~name:warn_bad_relevance_name ~category:"debug" ~default:CWarnings.Disabled
    Pp.(function
        | None ->  str "Bad relevance in case annotation."
        | Some x -> str "Bad relevance for binder " ++ Name.print x.binder_name ++ str ".")

let warn_bad_relevance_ci ?loc () = warn_bad_relevance ?loc None
let warn_bad_relevance ?loc x = warn_bad_relevance ?loc (Some x)

let check_assumption env x t ty =
  let r = x.binder_relevance in
  let r' = infer_assumption env t ty in
  let x = if Sorts.relevance_equal r r'
    then x
    else (warn_bad_relevance x; {x with binder_relevance = r'})
  in
  x

(************************************************)
(* Incremental typing rules: builds a typing judgment given the *)
(* judgments for the subterms. *)

(*s Type of sorts *)

(* Prop and Set *)

let type1 = mkSort Sorts.type1

(* Type of Type(i). *)

let type_of_type u =
  let uu = Universe.super u in
    mkType uu

let type_of_sort = function
  | SProp | Prop | Set -> type1
  | Type u -> type_of_type u

(*s Type of a de Bruijn index. *)

let type_of_relative env n =
  try
    env |> lookup_rel n |> RelDecl.get_type |> lift n
  with Not_found ->
    error_unbound_rel env n

let stage_vars_in_relative env n =
  try env |> lookup_rel n |> RelDecl.get_value |> Option.map count_annots
  with Not_found ->
    error_unbound_rel env n

(* Type of variables *)
let type_of_variable env id =
  try named_type id env
  with Not_found ->
    error_unbound_var env id

let stage_vars_in_variable env id =
  try env |> named_body id |> Option.map count_annots
  with Not_found ->
    error_unbound_var env id

(* Management of context of variables. *)

(* Checks if a context of variables can be instantiated by the
   variables of the current env.
   Order does not have to be checked assuming that all names are distinct *)
let check_hyps_inclusion env ?evars f c sign =
  let conv env a b = conv env ?evars a b in
  Context.Named.fold_outside
    (fun d1 cstrnts ->
      let open Context.Named.Declaration in
      let id = NamedDecl.get_id d1 in
      try
        let d2 = lookup_named id env in
        let cstrnts' = union cstrnts (conv env (get_type d2) (get_type d1)) in
        (match d2,d1 with
        | LocalAssum _, LocalAssum _ -> cstrnts'
        | LocalAssum _, LocalDef _ ->
            (* This is wrong, because we don't know if the body is
               needed or not for typechecking: *) cstrnts'
        | LocalDef _, LocalAssum _ -> raise NotConvertible
        | LocalDef (_,b2,_), LocalDef (_,b1,_) -> conv env b2 b1);
      with Not_found | NotConvertible | Option.Heterogeneous ->
        error_reference_variables env id (f c))
    sign
    ~init:(empty ())

(* Instantiation of terms on real arguments. *)

(* Make a type polymorphic if an arity *)

(* Type of constants *)


let type_of_constant env (kn,_u as cst) =
  let cb = lookup_constant kn env in
  let cstrnts = check_hyps_inclusion env mkConstU cst cb.const_hyps in
  let ty, cu = constant_type env cst in
  let () = check_constraints cu env in
    ty, cstrnts

let type_of_constant_in env (kn,_u as cst) =
  let cb = lookup_constant kn env in
  let cstrnts = check_hyps_inclusion env mkConstU cst cb.const_hyps in
  constant_type_in env cst, cstrnts

let stage_vars_in_constant env (kn, _) =
  let cb = lookup_constant kn env in
  match cb.const_body with
  | Def c -> Some (count_annots @@ Mod_subst.force_constr c)
  | _ -> None

(* Type of a lambda-abstraction. *)

(* [judge_of_abstraction env name var j] implements the rule

 env, name:typ |- j.uj_val:j.uj_type     env, |- (name:typ)j.uj_type : s
 -----------------------------------------------------------------------
          env |- [name:typ]j.uj_val : (name:typ)j.uj_type

  Since all products are defined in the Calculus of Inductive Constructions
  and no upper constraint exists on the sort $s$, we don't need to compute $s$
*)

let type_of_abstraction _env name var ty =
  mkProd (name, var, ty)

(* Type of an application. *)

let make_judgev c t = 
  Array.map2 make_judge c t

let rec check_empty_stack = function
| [] -> true
| CClosure.Zupdate _ :: s -> check_empty_stack s
| _ -> false

let type_of_apply env func funt argsv argstv =
  let open CClosure in
  let len = Array.length argsv in
  let infos = create_clos_infos all env in
  let tab = create_tab () in
  let rec apply_rec i typ =
    if Int.equal i len then term_of_fconstr typ, empty ()
    else
      let typ, stk = whd_stack infos tab typ [] in
      (** The return stack is known to be empty *)
      let () = assert (check_empty_stack stk) in
      match fterm_of typ with
      | FProd (_, c1, c2, e) ->
        let arg = argsv.(i) in
        let argt = argstv.(i) in
        let c1 = term_of_fconstr c1 in
        begin match conv_leq false env argt c1 with
        | cstrnts ->
          let ty, cstrnts' = apply_rec (i+1) (mk_clos (Esubst.subs_cons ([| inject arg |], e)) c2) in
          ty, union cstrnts cstrnts'
        | exception NotConvertible ->
          error_cant_apply_bad_type env
            (i+1,c1,argt)
            (make_judge func funt)
            (make_judgev argsv argstv),
          empty ()
        end
      | _ ->
        error_cant_apply_not_functional env
          (make_judge func funt)
          (make_judgev argsv argstv),
        empty ()
  in
  apply_rec 0 (inject funt)

(* Type of primitive constructs *)
let type_of_prim_type _env = function
  | CPrimitives.PT_int63 -> Constr.mkSet

let type_of_int env =
  match env.retroknowledge.Retroknowledge.retro_int63 with
  | Some c -> mkConst c
  | None -> CErrors.user_err Pp.(str"The type int must be registered before this construction can be typechecked.")

let type_of_prim env t =
  let int_ty = type_of_int env in
  let bool_ty () =
    match env.retroknowledge.Retroknowledge.retro_bool with
    | Some ((ind,_),_) -> Constr.mkInd ind
    | None -> CErrors.user_err Pp.(str"The type bool must be registered before this primitive.")
  in
  let compare_ty () =
    match env.retroknowledge.Retroknowledge.retro_cmp with
    | Some ((ind,_),_,_) -> Constr.mkInd ind
    | None -> CErrors.user_err Pp.(str"The type compare must be registered before this primitive.")
  in
  let pair_ty fst_ty snd_ty =
    match env.retroknowledge.Retroknowledge.retro_pair with
    | Some (ind,_) -> Constr.mkApp(Constr.mkInd ind, [|fst_ty;snd_ty|])
    | None -> CErrors.user_err Pp.(str"The type pair must be registered before this primitive.")
  in
  let carry_ty int_ty =
    match env.retroknowledge.Retroknowledge.retro_carry with
    | Some ((ind,_),_) -> Constr.mkApp(Constr.mkInd ind, [|int_ty|])
    | None -> CErrors.user_err Pp.(str"The type carry must be registered before this primitive.")
  in
  let rec nary_int63_op arity ty =
    if Int.equal arity 0 then ty
      else Constr.mkProd(Context.nameR (Id.of_string "x"), int_ty, nary_int63_op (arity-1) ty)
  in
  let return_ty =
    let open CPrimitives in
    match t with
    | Int63head0
    | Int63tail0
    | Int63add
    | Int63sub
    | Int63mul
    | Int63div
    | Int63mod
    | Int63lsr
    | Int63lsl
    | Int63land
    | Int63lor
    | Int63lxor
    | Int63addMulDiv -> int_ty
    | Int63eq
    | Int63lt
    | Int63le -> bool_ty ()
    | Int63mulc
    | Int63div21
    | Int63diveucl -> pair_ty int_ty int_ty
    | Int63addc
    | Int63subc
    | Int63addCarryC
    | Int63subCarryC -> carry_ty int_ty
    | Int63compare -> compare_ty ()
  in
  nary_int63_op (CPrimitives.arity t) return_ty

let type_of_prim_or_type env = let open CPrimitives in
  function
  | OT_type t -> type_of_prim_type env t
  | OT_op op -> type_of_prim env op

let judge_of_int env i =
  make_judge (Constr.mkInt i) (type_of_int env)

(* Type of product *)

let sort_of_product env domsort rangsort =
  match (domsort, rangsort) with
    | (_, SProp) | (SProp, _) -> rangsort
    (* Product rule (s,Prop,Prop) *)
    | (_,       Prop)  -> rangsort
    (* Product rule (Prop/Set,Set,Set) *)
    | ((Prop | Set),  Set) -> rangsort
    (* Product rule (Type,Set,?) *)
    | (Type u1, Set) ->
        if is_impredicative_set env then
          (* Rule is (Type,Set,Set) in the Set-impredicative calculus *)
          rangsort
        else
          (* Rule is (Type_i,Set,Type_i) in the Set-predicative calculus *)
          Sorts.sort_of_univ (Universe.sup Universe.type0 u1)
    (* Product rule (Prop,Type_i,Type_i) *)
    | (Set,  Type u2)  -> Sorts.sort_of_univ (Universe.sup Universe.type0 u2)
    (* Product rule (Prop,Type_i,Type_i) *)
    | (Prop, Type _)  -> rangsort
    (* Product rule (Type_i,Type_i,Type_i) *)
    | (Type u1, Type u2) -> Sorts.sort_of_univ (Universe.sup u1 u2)

(* [judge_of_product env name (typ1,s1) (typ2,s2)] implements the rule

    env |- typ1:s1       env, name:typ1 |- typ2 : s2
    -------------------------------------------------------------------------
         s' >= (s1,s2), env |- (name:typ)j.uj_val : s'

  where j.uj_type is convertible to a sort s2
*)
let type_of_product env _name s1 s2 =
  let s = sort_of_product env s1 s2 in
    mkSort s

(* Type of a type cast *)

(* [judge_of_cast env (c,typ1) (typ2,s)] implements the rule

    env |- c:typ1    env |- typ2:s    env |- typ1 <= typ2
    ---------------------------------------------------------------------
         env |- c:typ2
*)

let check_cast env c ct k expected_type =
  try
    match k with
    | VMcast ->
      Vconv.vm_conv CUMUL env ct expected_type
    | DEFAULTcast ->
      default_conv ~l2r:false CUMUL env ct expected_type
    | REVERTcast ->
      default_conv ~l2r:true CUMUL env ct expected_type
    | NATIVEcast ->
      let sigma = Nativelambda.empty_evars in
      Nativeconv.native_conv CUMUL sigma env ct expected_type
  with NotConvertible ->
    error_actual_type env (make_judge c ct) expected_type

(* Inductive types. *)

(* The type is parametric over the uniform parameters whose conclusion
   is in Type; to enforce the internal constraints between the
   parameters and the instances of Type occurring in the type of the
   constructors, we use the level variables _statically_ assigned to
   the conclusions of the parameters as mediators: e.g. if a parameter
   has conclusion Type(alpha), static constraints of the form alpha<=v
   exist between alpha and the Type's occurring in the constructor
   types; when the parameters is finally instantiated by a term of
   conclusion Type(u), then the constraints u<=alpha is computed in
   the App case of execute; from this constraints, the expected
   dynamic constraints of the form u<=v are enforced *)

let type_of_inductive_knowing_parameters env (ind,u as indu) args =
  let (mib,_mip) as spec = lookup_mind_specif env ind in
  let cstrnts = check_hyps_inclusion env mkIndU indu mib.mind_hyps in
  let t,cst = Inductive.constrained_type_of_inductive_knowing_parameters 
    env (spec,u) args
  in
  check_constraints cst env;
  t, cstrnts

let type_of_inductive env (ind,u as indu) =
  let (mib,mip) = lookup_mind_specif env ind in
  let cstrnts = check_hyps_inclusion env mkIndU indu mib.mind_hyps in
  let t,cst = Inductive.constrained_type_of_inductive env ((mib,mip),u) in
  check_constraints cst env;
  t, cstrnts

(* Constructors. *)

let type_of_constructor env ?s (c,_u as cu) =
  let cstrnts =
    let ((kn,_),_) = c in
    let mib = lookup_mind kn env in
    check_hyps_inclusion env mkConstructU cu mib.mind_hyps
  in
  let specif = lookup_mind_specif env (inductive_of_constructor c) in
  let t,cst = constrained_type_of_constructor ?s cu specif in
  let () = check_constraints cst env in
  t, cstrnts

(* Case. *)

let check_branch_types env (ind,u) c ct lft explft =
  try conv_leq_vecti env lft explft
  with
      NotConvertibleVect i ->
        error_ill_formed_branch env c ((ind,i+1),u) lft.(i) explft.(i)
    | Invalid_argument _ ->
        error_number_branches env (make_judge c ct) (Array.length explft)

let type_of_case env stg ci p pt c ct _lf lft =
  let pind, largs, r =
    try find_rectype env ct
    with Not_found -> error_case_not_inductive env (make_judge c ct) in
  let _, sp = try dest_arity env pt
    with NotArity -> error_elim_arity env pind c (make_judge p pt) None in
  let rp = Sorts.relevance_of_sort sp in
  let ci = if ci.ci_relevance == rp then ci
    else (warn_bad_relevance_ci (); {ci with ci_relevance=rp})
  in
  let () = check_case_info env pind rp ci in
  let s, stg = next stg in
  let bty, rslty, cstrnts_rsl =
    type_case_branches env (pind, largs) (make_judge p pt) c s in
  let cstrnts_branch = check_branch_types env pind c ct lft bty in
  let cstrnts = union cstrnts_rsl cstrnts_branch in
  stg, ci, rslty, add_constraint_from_ind env Variant cstrnts (fst pind) r (hat s)

let type_of_projection env p c ct =
  let pty = lookup_projection p env in
  let (ind,u), args, _ =
    try find_rectype env ct
    with Not_found -> error_case_not_inductive env (make_judge c ct)
  in
  assert(eq_ind (Projection.inductive p) ind);
  let ty = Vars.subst_instance_constr u pty in
  substl (c :: CList.rev args) ty
      

(* Fixpoints. *)

(* Gets the stage variables that must be set to the recursive stage and infinity, respectively *)
let get_vstar_vneq stg_old stg_new lar vdef =
  let vstar = get_pos_vars stg_new in
  let old_annots = get_vars stg_old in
  let lar_annots = List.map collect_annots (Array.to_list lar) in
  let vdef_annots = List.map collect_annots (Array.to_list vdef) in
  let all_annots = SVars.union_list ([old_annots] @ lar_annots @ vdef_annots) in
  let vneq = diff all_annots vstar in
  vstar, vneq

(* Letting lar'' := lar' with stage annotations at star positions shifted up,
  check Γ (names' : lar') ⊢ vdeft ≤ lar''. *)
let check_fixpoint env (names, lar', vdef, vdeft) lar'' =
  let env1 = push_rec_types (names, lar', vdef) env in (* vdef is ignored *)
  let lt = Array.length vdeft in
  assert (Int.equal (Array.length lar'') lt);
  try
    conv_leq_vecti env1 vdeft (Array.map (fun ty -> lift lt ty) lar'')
  with NotConvertibleVect i ->
    error_ill_typed_rec_body env1 i names (make_judgev vdef vdeft) lar''

(* Letting ΠΔ'.U' := lar', ΠΔ''.U'' := lar'',
  check Γ ⊢ Δ' ≤ Δ''; Γ ⊢ U' ≤ U'' for inductive, and
  check Γ ⊢ Δ'' ≤ Δ'; Γ ⊢ U'' ≤ U' for coinductive *)
let check_fixpoint_type env lar' lar'' recursivity =
  let unzip_prod_assums arr =
    let decls, body = List.split @@ Array.to_list @@
      Array.map Term.decompose_prod_assum arr in
    let tys = List.map Rel.Declaration.get_type @@ List.concat decls in
    Array.of_list tys, Array.of_list body in
  let delta', u' = unzip_prod_assums lar' in
  let delta'', u'' = unzip_prod_assums lar'' in
  let cstrnt_delta = match recursivity with
    | Finite -> conv_leq_vecti env delta' delta''
    | CoFinite -> conv_leq_vecti env delta'' delta'
    | _ -> assert false in
  let cstrnt_u = match recursivity with
    | Finite -> conv_leq_vecti env u' u''
    | CoFinite -> conv_leq_vecti env u'' u'
    | _ -> assert false in
  union cstrnt_delta cstrnt_u

(* Global references *)

let type_of_global_in_context env r =
  let open Names.GlobRef in
  match r with
  | VarRef id -> Environ.named_type id env, Univ.AUContext.empty
  | ConstRef c ->
    let cb = Environ.lookup_constant c env in
    let univs = Declareops.constant_polymorphic_context cb in
    cb.Declarations.const_type, univs
  | IndRef ind ->
    let (mib,_ as specif) = Inductive.lookup_mind_specif env ind in
    let univs = Declareops.inductive_polymorphic_context mib in
    let inst = Univ.make_abstract_instance univs in
    let env = Environ.push_context ~strict:false (Univ.AUContext.repr univs) env in
    Inductive.type_of_inductive env (specif, inst), univs
  | ConstructRef cstr ->
    let (mib,_ as specif) =
      Inductive.lookup_mind_specif env (inductive_of_constructor cstr)
    in
    let univs = Declareops.inductive_polymorphic_context mib in
    let inst = Univ.make_abstract_instance univs in
    Inductive.type_of_constructor (cstr,inst) specif, univs

(************************************************************************)
(************************************************************************)

let check_binder_annot s x =
  let r = x.binder_relevance in
  let r' = Sorts.relevance_of_sort s in
  if r' == r
  then x
  else (warn_bad_relevance x; {x with binder_relevance = r'})

exception Found of State.t * Constraints.t * constr * types

(* The typing machine. *)
    (* ATTENTION : faudra faire le typage du contexte des Const,
    Ind et Constructsi un jour cela devient des constructions
    arbitraires et non plus des variables *)
let rec execute env stg cstr =
  let open Context.Rel.Declaration in
  match kind cstr with
    (* Atomic terms *)
    | Sort s ->
      (match s with
       | SProp -> if not (Environ.sprop_allowed env) then error_disallowed_sprop env
       | _ -> ());
      stg, empty (), cstr, type_of_sort s

    | Rel (n, _) ->
      let numvars = stage_vars_in_relative env n in
      let annots, stg = next_annots numvars stg in
      stg, empty (), mkRelA n annots, type_of_relative env n

    | Var (id, _) ->
      let numvars = stage_vars_in_variable env id in
      let s, stg = next stg in
      let t = annotate_glob s (type_of_variable env id) in
      let annots, stg = next_annots numvars stg in
      stg, empty (), mkVarA id annots, t

    | Const (c, _ans) ->
      let numvars = stage_vars_in_constant env c in
      let s, stg = next stg in
      let t, cstrnt = type_of_constant env c in
      let t = annotate_glob s t in
      let annots, stg = next_annots numvars stg in
      stg, cstrnt, mkConstUA c annots, t
	
    | Proj (p, c) ->
      let stg, cstrnt, c', ct = execute env stg c in
      let cstr = if c == c' then cstr else mkProj (p,c') in
      stg, cstrnt, cstr, type_of_projection env p c' ct

    (* Lambda calculus operators *)
    | App (f,args) ->
      let stga, cstrnta, args', argst = execute_array env stg args in
      let stgf, cstrntf, f', ft = match kind f with
      | Ind (ind, s) when Environ.template_polymorphic_pind ind env ->
        let args = Array.map (fun t -> lazy t) argst in
        let s', stg' = next ~s stga in
        let t, cstrnt = type_of_inductive_knowing_parameters env ind args in
        stg', cstrnt, mkIndUS ind s', t
      | _ -> (* No template polymorphism *)
        execute env stga f
      in
      let t, cstrntapp = type_of_apply env f' ft args' argst in
      let cstrnt = union_list [cstrnta; cstrntf; cstrntapp] in
      let cstr = if f == f' && args == args' then cstr else mkApp (f',args') in
      stgf, cstrnt, cstr, t

    | Lambda (name,c1,c2) ->
      let stg1, cstrnt1, c1', s = execute_is_type env stg c1 in
      let name' = check_binder_annot s name in
      let env1 = push_rel (LocalAssum (name',c1')) env in
      let stg2, cstrnt2, c2', c2t = execute env1 stg1 c2 in
      let cstrnt = union_list [cstrnt1; cstrnt2] in
      let cstr = if name == name' && c1 == c1' && c2 == c2' then cstr else mkLambda(name', erase c1',c2') in
      stg2, cstrnt, cstr, type_of_abstraction env name' c1' c2t

    | Prod (name,c1,c2) ->
      let stg1, cstrnt1, c1', vars = execute_is_type env stg c1 in
      let name' = check_binder_annot vars name in
      let env1 = push_rel (LocalAssum (name',c1')) env in
      let stg2, cstrnt2, c2', vars' = execute_is_type env1 stg1 c2 in
      let cstrnt = union cstrnt1 cstrnt2 in
      let cstr = if name == name' && c1 == c1' && c2 == c2' then cstr else mkProd(name',c1',c2') in
      stg2, cstrnt, cstr, type_of_product env name' vars vars'

    | LetIn (name,c1,c2,c3) ->
      let stg1, cstrnt1, c1', c1t = execute env stg c1 in
      let stg2, cstrnt2, c2', c2s = execute_is_type env stg1 c2 in
      let name' = check_binder_annot c2s name in
      let cstrnt' = check_cast env c1' c1t DEFAULTcast c2' in
      let env1 = push_rel (LocalDef (name',c1',c2')) env in
      let stg3, cstrnt3, c3', c3t = execute env1 stg2 c3 in
      let cstrnt = union_list [cstrnt1; cstrnt2; cstrnt3; cstrnt'] in
      let cstr = if name == name' && c1 == c1' && c2 == c2' && c3 == c3' then cstr
        else mkLetIn(name',c1',erase c2',c3')
      in
      stg3, cstrnt, cstr, subst1 c1 c3t

    | Cast (c,k,t) ->
      let stgc, cstrntc, c', ct = execute env stg c in
      let stgt, cstrntt, t', _ts = execute_is_type env stgc t in
      let cstrnt' = check_cast env c' ct k t' in
      let cstrnt = union_list [cstrntc; cstrntt; cstrnt'] in
      let cstr = if c == c' && t == t' then cstr else mkCast(c',k,erase t') in
      stgt, cstrnt, cstr, t'

    (* Inductive types *)
    | Ind (ind, s) ->
      let s', stg' = next ~s stg in
      let t, cstrnt = type_of_inductive env ind in
      stg', cstrnt, mkIndUS ind s', t

    | Construct c ->
      let s, stg = next stg in
      let t, cstrnt = type_of_constructor env ~s c in
      stg, cstrnt, cstr, t

    | Case (ci,p,c,lf) ->
      let stgc, cstrntc, c', ct = execute env stg c in
      let stgp, cstrntp, p', pt = execute env stgc p in
      let stglf, cstrntlf, lf', lft = execute_array env stgp lf in
      let stg, ci', t, cstrntci = type_of_case env stglf ci p' pt c' ct lf' lft in
      let cstrnt = union_list [cstrntc; cstrntp; cstrntlf; cstrntci] in
      let cstr = if ci == ci' && c == c' && p == p' && lf == lf' then cstr
        else mkCase (ci', erase p', c', lf')
      in
      stg, cstrnt, cstr, t

    | Fix ((von, i), (_, lar, _ as recdef)) ->
      let possible_indices =
        List.map Array.of_list @@
        List.combinations @@
        Array.to_list @@
        Array.map2
        (fun on ar -> match on with
          | Some n -> [n]
          | None ->
            List.map_i (fun i _ -> i) 0 @@
            List.filter Context.Rel.Declaration.is_local_assum @@
            Term.prod_assum ar)
        von lar in

      let try_vn vn =
        let stg, cstnt, cstr, ty = execute_fix env stg ((vn, i), recdef) in
        raise (Found (State.pop stg, cstnt, cstr, ty)) in

      begin try
        if Int.equal 1 @@ List.length possible_indices then
          try_vn @@ List.hd possible_indices
        else
          List.iter (fun vn -> try try_vn vn with TypeError _ -> ()) possible_indices;
          user_err ~hdr:"execute"
            (Pp.str "Cannot guess decreasing argument of fix.")
      with Found (stg, cstrnt, c, ty) ->
        stg, cstrnt, c, ty
      end
	  
    | CoFix cofix -> execute_cofix env stg cofix

    (* Primitive types *)
    | Int _ -> stg, empty (), cstr, type_of_int env

    (* Partial proofs: unsupported by the kernel *)
    | Meta _ ->
	anomaly (Pp.str "the kernel does not support metavariables.")

    | Evar _ ->
	anomaly (Pp.str "the kernel does not support existential variables.")

and execute_is_type env stg constr =
  let stg, cstrnt, c, t = execute env stg constr in
    stg, cstrnt, c, check_type env constr t

(* Usual inference: Γ ⊢ lar' : lart; Γ (names' : lar') ⊢ vdef : vdeft *)
and execute_recdef env stg (names, lar, vdef) =
  let stg_lar, cstrnt_lar, lar', lart = execute_array env stg lar in
  let names' = Array.Smart.map_i (fun i na -> check_assumption env na lar'.(i) lart.(i)) names in
  let env1 = push_rec_types (names', lar', vdef) env in (* vdef is ignored *)
  let stg_vdef, cstrnt_vdef, vdef', vdeft = execute_array env1 stg_lar vdef in
  stg_vdef, union cstrnt_lar cstrnt_vdef, (names', lar', vdef', vdeft)

(* Try RecCheck; if failure, try removing some stage variables from vstar *)
and execute_rec_check env stg cstrnt cstr (_, lar', _, _ as recdeft) vars recursivity =
  let rec try_rec_check stg (alphas, vstar, vneq) =
    let lar'' = Array.map (annotate_succ vstar) lar' in
    let cstrnt_fix = check_fixpoint env recdeft lar'' in
    let cstrnt_fix_ty = check_fixpoint_type env lar' lar'' recursivity in
    let cstrnt' = union_list [cstrnt; cstrnt_fix; cstrnt_fix_ty] in

    let rec_check_all alpha cstrnts = union cstrnts (rec_check alpha vstar vneq cstrnts) in
    let flags = Environ.typing_flags env in
    if flags.check_sized then
      try stg, SVars.fold rec_check_all alphas cstrnt'
      with RecCheckFailed (cstrnt'', si_inf, si) ->
        let rm = inter (inter si_inf si) (diff vstar alphas) in
        if is_empty rm then begin
          if flags.check_guarded then stg, cstrnt else
            error_unsatisfied_stage_constraints env cstrnt'' cstr si_inf si
        end else
          let vstar = diff vstar rm in
          let vneq = SVars.union vneq rm in
          let stg = remove_pos_vars rm stg in
          try_rec_check stg (alphas, vstar, vneq)
    else stg, cstrnt' in
  try_rec_check stg vars

and execute_fix env stg ((vn, i), (names, lar, vdef)) =
  let stg = State.push stg in
  let _ = execute_array env stg lar in (* check termination of lar so we can reduce *)

  let stg', cstrnt', (names', lar', vdef', _ as recdeft) =
    let inds = get_rec_inds env vn lar in
    let vninds = List.fold_left2 (fun acc n ind -> (n, ind) :: acc) [] (Array.to_list vn) inds in
    let lar_star = set_rec_stars env vninds lar in
    execute_recdef env stg (names, lar_star, vdef) in

  let stg_check, cstrnt_check =
    let alphas = get_rec_vars env vn lar' in
    let vstar, vneq = get_vstar_vneq stg stg' lar' vdef' in
    let cstr = mkFixOpt ((vn, i), (names', lar', vdef')) in
    execute_rec_check env stg' cstrnt' cstr recdeft (alphas, vstar, vneq) Finite in

  let fix =
    let lar_star = Array.Smart.map (erase_star (get_pos_vars stg_check)) lar' in
    let von = Array.map (fun n -> Some n) vn in
    ((von, i), (names', lar_star, vdef')) in

  check_fix env fix; State.pop stg_check, cstrnt_check, mkFix fix, lar'.(i)

and execute_cofix env stg (i, (names, lar, vdef)) =
  let stg = State.push stg in
  let _ = execute_array env stg lar in (* check termination of lar so we can reduce *)

  let stg', cstrnt', (names', lar', vdef', _ as recdeft) =
    let lar_star = set_corec_stars env (get_corec_inds env lar) lar in
    execute_recdef env stg (names, lar_star, vdef) in

  let stg_check, cstrnt_check =
    let alphas = get_corec_vars env lar' in
    let vstar, vneq = get_vstar_vneq stg stg' lar' vdef' in
    let cstr = mkCoFix (i, (names', lar', vdef')) in
    execute_rec_check env stg' cstrnt' cstr recdeft (alphas, vstar, vneq) CoFinite in

  let cofix =
    let lar_star = Array.Smart.map (erase_star (get_pos_vars stg_check)) lar' in
    (i, (names', lar_star, vdef')) in

  check_cofix env cofix; State.pop stg_check, cstrnt_check, mkCoFix cofix, lar'.(i)

and execute_array env stg cs =
  let tys = Array.make (Array.length cs) mkProp in
  let ((stg, cstrnt), cs) = Array.Smart.fold_left_map_i
    (fun i (stg, cstrnt1) c ->
      let stg', cstrnt2, c, ty = execute env stg c in
      tys.(i) <- ty;
      (stg', union cstrnt1 cstrnt2), c)
    (stg, empty ()) cs in
  stg, cstrnt, cs, tys

(* Derived functions *)

let check_wellformed_universes env c =
  let univs = universes_of_constr c in
  try UGraph.check_declared_universes (universes env) univs
  with UGraph.UndeclaredLevel u ->
    error_undeclared_universe env u

let infer env constr =
  let () = check_wellformed_universes env constr in
  let stg, _, constr_sized, t_sized = execute env State.init constr in
  let constr = erase_infty constr_sized in
  let t = erase_glob (get_pos_vars stg) t_sized in
  make_judge constr t

let infer = 
  if Flags.profile then
    let infer_key = CProfile.declare_profile "Fast_infer" in
      CProfile.profile2 infer_key (fun b c -> infer b c)
  else (fun b c -> infer b c)

let assumption_of_judgment env {uj_val=c; uj_type=t} =
  infer_assumption env c t

let type_judgment env {uj_val=c; uj_type=t} =
  let s = check_type env c t in
  {utj_val = c; utj_type = s }

let infer_type env constr =
  let () = check_wellformed_universes env constr in
  let stg, _, constr_sized, t = execute env State.init constr in
  let constr = erase_glob (get_pos_vars stg) constr_sized in
  let s = check_type env constr t in
  {utj_val = constr; utj_type = s}

(* Typing of several terms. *)

let check_context env rels =
  let open Context.Rel.Declaration in
  Context.Rel.fold_outside (fun d (env,rels) ->
    match d with
      | LocalAssum (x,ty) ->
        let jty = infer_type env ty in
        let x = check_binder_annot jty.utj_type x in
        push_rel d env, LocalAssum (x,jty.utj_val) :: rels
      | LocalDef (x,bd,ty) ->
        let j1 = infer env bd in
        let jty = infer_type env ty in
        let _ = conv_leq false env j1.uj_type ty in
        let x = check_binder_annot jty.utj_type x in
        push_rel d env, LocalDef (x,j1.uj_val,jty.utj_val) :: rels)
    rels ~init:(env,[])

let judge_of_prop = make_judge mkProp type1
let judge_of_set = make_judge mkSet type1
let judge_of_type u = make_judge (mkType u) (type_of_type u)

let judge_of_relative env k = make_judge (mkRel k) (type_of_relative env k)

let judge_of_variable env x = make_judge (mkVar x) (type_of_variable env x)

let judge_of_constant env cst =
  let t, _ = type_of_constant env cst in
  make_judge (mkConstU cst) t

let judge_of_projection env p cj =
  make_judge (mkProj (p,cj.uj_val)) (type_of_projection env p cj.uj_val cj.uj_type)

let dest_judgev v =
  Array.map j_val v, Array.map j_type v

let judge_of_apply env funj argjv =
  let args, argtys = dest_judgev argjv in
  let t, _ = type_of_apply env funj.uj_val funj.uj_type args argtys in
  make_judge (mkApp (funj.uj_val, args)) t

(* let judge_of_abstraction env x varj bodyj = *)
(*   make_judge (mkLambda (x, varj.utj_val, bodyj.uj_val)) *)
(*              (type_of_abstraction env x varj.utj_val bodyj.uj_type) *)

(* let judge_of_product env x varj outj = *)
(*   make_judge (mkProd (x, varj.utj_val, outj.utj_val)) *)
(*              (mkSort (sort_of_product env varj.utj_type outj.utj_type)) *)

(* let judge_of_letin env name defj typj j = *)
(*   make_judge (mkLetIn (name, defj.uj_val, typj.utj_val, j.uj_val)) *)
(*              (subst1 defj.uj_val j.uj_type) *)

let judge_of_cast env cj k tj =
  let _ = check_cast env cj.uj_val cj.uj_type k tj.utj_val in
  let c = match k with | REVERTcast -> cj.uj_val | _ -> mkCast (cj.uj_val, k, tj.utj_val) in
  make_judge c tj.utj_val

let judge_of_inductive env indu =
  let t, _ = type_of_inductive env indu in
  make_judge (mkIndU indu) t

let judge_of_constructor env cu =
  let t, _ = type_of_constructor env cu in
  make_judge (mkConstructU cu) t

let judge_of_case env ci pj cj lfj =
  let lf, lft = dest_judgev lfj in
  let _, ci, t, _ = type_of_case env init ci pj.uj_val pj.uj_type cj.uj_val cj.uj_type lf lft in
  make_judge (mkCase (ci, (*nf_betaiota*) pj.uj_val, cj.uj_val, lft)) t

(* Building type of primitive operators and type *)

let check_primitive_type env op_t t =
  let inft = type_of_prim_or_type env op_t in
  try default_conv ~l2r:false CUMUL env inft t
  with NotConvertible -> error_incorrect_primitive env (make_judge op_t inft) t

(************************************************************************)
(*         *      The Rocq Prover / The Rocq Development Team           *)
(*  v      *         Copyright INRIA, CNRS and contributors             *)
(* <O___,, * (see version control and CREDITS file for authors & dates) *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

open Constrintern
open Patternops
open Pp
open CAst
open Namegen
open Glob_term
open Glob_ops
open Tacred
open CErrors
open Util
open Names
open Nameops
open Libnames
open Tacmach
open Tactic_debug
open Constrexpr
open Termops
open Tacexpr
open Genarg
open Geninterp
open Stdarg
open Tacarg
open Printer
open Pretyping
open Tactypes
open Tactics
open Locus
open Tacintern
open Taccoerce
open Proofview.Notations
open Context.Named.Declaration
open Ltac_pretype

let do_profile trace ?count_call tac =
  Profile_tactic.do_profile_gen (function
      | (_, c) :: _ -> Some (Pptactic.pp_ltac_call_kind c)
      | [] -> None)
    trace ?count_call tac

let ltac_trace_info = Tactic_debug.ltac_trace_info

let has_type : type a. Val.t -> a typed_abstract_argument_type -> bool = fun v wit ->
  let Val.Dyn (t, _) = v in
  let t' = match val_tag wit with
  | Val.Base t' -> t'
  | _ -> assert false (* not used in this module *)
  in
  match Val.eq t t' with
  | None -> false
  | Some Refl -> true

let prj : type a. a Val.typ -> Val.t -> a option = fun t v ->
  let Val.Dyn (t', x) = v in
  match Val.eq t t' with
  | None -> None
  | Some Refl -> Some x

let in_list tag v =
  let tag = match tag with Val.Base tag -> tag | _ -> assert false in
  Val.Dyn (Val.typ_list, List.map (fun x -> Val.Dyn (tag, x)) v)
let in_gen wit v =
  let t = match val_tag wit with
  | Val.Base t -> t
  | _ -> assert false (* not used in this module *)
  in
  Val.Dyn (t, v)
let out_gen wit v =
  let t = match val_tag wit with
  | Val.Base t -> t
  | _ -> assert false (* not used in this module *)
  in
  match prj t v with None -> assert false | Some x -> x

let val_tag wit = val_tag (topwit wit)

let pr_argument_type arg =
  let Val.Dyn (tag, _) = arg in
  Val.pr tag

type value = Val.t

let push_appl appl args =
  match appl with
  | UnnamedAppl -> UnnamedAppl
  | GlbAppl l -> GlbAppl (List.map (fun (h,vs) -> (h,vs@args)) l)
let pr_generic arg =
    let Val.Dyn (tag, _) = arg in
    str"<" ++ Val.pr tag ++ str ":(" ++ Pptactic.pr_value Pptactic.ltop arg ++ str ")>"
let pr_appl h vs =
  Pptactic.pr_ltac_constant  h ++ spc () ++
  Pp.prlist_with_sep spc pr_generic vs
let rec name_with_list appl t =
  match appl with
  | [] -> t
  | (h,vs)::l -> Proofview.Trace.name_tactic (fun () -> pr_appl h vs) (name_with_list l t)
let name_if_glob appl t =
  match appl with
  | UnnamedAppl -> t
  | GlbAppl l -> name_with_list l t
let combine_appl appl1 appl2 =
  match appl1,appl2 with
  | UnnamedAppl,a | a,UnnamedAppl -> a
  | GlbAppl l1 , GlbAppl l2 -> GlbAppl (l2@l1)

let of_tacvalue = Value.of_tacvalue
let to_tacvalue = Value.to_tacvalue

(* Debug reference *)
let debug = ref DebugOff

(* Sets the debugger on or off *)
let set_debug pos = debug := pos

(* Gives the state of debug; disabled in worker processes *)
let get_debug () = if Flags.async_proofs_is_worker () then DebugOff else !debug

let log_trace = ref false

let is_traced () =
  !log_trace || !debug <> DebugOff || Profile_tactic.get_profiling()

(** More naming applications *)
let name_vfun appl vle =
  if is_traced () then
    match to_tacvalue vle with
    | Some (VFun (appl0,trace,loc,lfun,vars,t)) ->
      of_tacvalue (VFun (combine_appl appl0 appl,trace,loc,lfun,vars,t))
    | Some (VRec _) | None -> vle
  else vle

module TacStore = Geninterp.TacStore

let f_avoid_ids : Id.Set.t TacStore.field = TacStore.field "f_avoid_ids"
(* ids inherited from the call context (needed to get fresh ids) *)
let f_debug : debug_info TacStore.field = TacStore.field "f_debug"
let f_trace : ltac_trace TacStore.field = TacStore.field "f_trace"
let f_loc : Loc.t TacStore.field = TacStore.field "f_loc"

(* Signature for interpretation: val_interp and interpretation functions *)
type interp_sign = Geninterp.interp_sign =
  { lfun : value Id.Map.t
  ; poly : bool
  ; extra : TacStore.t }

let add_extra_trace trace extra = TacStore.set extra f_trace trace
let extract_trace ist =
  if is_traced () then match TacStore.get ist.extra f_trace with
  | None -> [],[]
  | Some trace -> trace
  else [],[]

let add_extra_loc loc extra =
  match loc with
  | None -> extra
  | Some loc -> TacStore.set extra f_loc loc
let extract_loc ist = TacStore.get ist.extra f_loc

let ensure_loc loc ist =
  match loc with
  | None -> ist
  | Some loc ->
    match extract_loc ist with
    | None -> { ist with extra = TacStore.set ist.extra f_loc loc }
    | Some _ -> ist

let print_top_val env v = Pptactic.pr_value Pptactic.ltop v

let catching_error call_trace fail (e, info) =
  let inner_trace =
    Option.default [] (Exninfo.get info ltac_trace_info)
  in
  if List.is_empty call_trace && List.is_empty inner_trace then fail (e, info)
  else begin
    assert (CErrors.noncritical e); (* preserved invariant *)
    let inner_trace = List.filter (fun i -> not (List.memq i call_trace)) inner_trace in
    let new_trace = inner_trace @ call_trace in
    let located_exc = (e, Exninfo.add info ltac_trace_info new_trace) in
    fail located_exc
  end

let update_loc loc (e, info as e') =
  let eloc = Loc.get_loc info in
  if Loc.finer eloc (Some loc) then e'
  else (* eloc missing or refers to inside of Ltac function *)
    (e, Loc.add_loc info loc)

let catch_error_with_trace_loc loc call_trace f x =
  try f x
  with e when CErrors.noncritical e ->
    let e = Exninfo.capture e in
    let e = Option.cata (fun loc -> update_loc loc e) e loc in
    catching_error call_trace Exninfo.iraise e

let catch_error_loc loc tac =
  match loc with
  | None -> tac
  | Some loc ->
    Proofview.tclORELSE tac (fun exn ->
        let (e, info) = update_loc loc exn in
        Proofview.tclZERO ~info e)

let wrap_error tac k =
  if is_traced () then Proofview.tclORELSE tac k else tac

let wrap_error_loc loc tac k =
  if is_traced () then
    let k = match loc with
      | None -> k
      | Some loc -> fun e -> k (update_loc loc e)
    in
    Proofview.tclORELSE tac k
  else catch_error_loc loc tac

let catch_error_tac call_trace tac =
  wrap_error
    tac
    (catching_error call_trace (fun (e, info) -> Proofview.tclZERO ~info e))

let catch_error_tac_loc loc call_trace tac =
  wrap_error_loc loc
    tac
    (catching_error call_trace (fun (e, info) -> Proofview.tclZERO ~info e))

let curr_debug ist = match TacStore.get ist.extra f_debug with
| None -> DebugOff
| Some level -> level

let pr_closure env ist body =
  let pp_body = Pptactic.pr_glob_tactic env body in
  let pr_sep () = fnl () in
  let pr_iarg (id, arg) =
    let arg = pr_argument_type arg in
    hov 0 (Id.print id ++ spc () ++ str ":" ++ spc () ++ arg)
  in
  let pp_iargs = v 0 (prlist_with_sep pr_sep pr_iarg (Id.Map.bindings ist)) in
  pp_body ++ fnl() ++ str "in environment " ++ fnl() ++ pp_iargs

let pr_inspect env expr result =
  let pp_expr = Pptactic.pr_glob_tactic env expr in
  let pp_result =
    match to_tacvalue result with
    | Some (VFun (_, _, _, ist, ul, b)) ->
      let body = if List.is_empty ul then b else CAst.make (TacFun (ul, b)) in
      str "a closure with body " ++ fnl() ++ pr_closure env ist body
    | Some (VRec (ist, body)) ->
      str "a recursive closure" ++ fnl () ++ pr_closure env !ist body
    | None ->
      let pp_type = pr_argument_type result in
      str "an object of type" ++ spc () ++ pp_type
  in
  pp_expr ++ fnl() ++ str "this is " ++ pp_result

(* Transforms an id into a constr if possible, or fails with Not_found *)
let constr_of_id env id =
  EConstr.mkVar (let _ = Environ.lookup_named id env in id)

(** Generic arguments : table of interpretation functions *)

let push_trace call ist =
  if is_traced () then match TacStore.get ist.extra f_trace with
  | None -> [call], [ist.lfun]
  | Some (trace, varmaps) -> call :: trace, ist.lfun :: varmaps
  else [],[]

let propagate_trace ist loc id v =
  match to_tacvalue v with
  | None ->  Proofview.tclUNIT v
  | Some tacv ->
    match tacv with
    | VFun (appl,_,_,lfun,it,b) ->
      let kn =
        match appl with
        | GlbAppl ((kn, _) :: _) -> Some kn
        | _ -> None
      in
      let t = if List.is_empty it then b else CAst.make (TacFun (it,b)) in
      let trace = push_trace(loc,LtacVarCall (kn,id,t)) ist in
      let ans = VFun (appl,trace,loc,lfun,it,b) in
      Proofview.tclUNIT (of_tacvalue ans)
    | VRec _ ->  Proofview.tclUNIT v

let append_trace trace v =
  match to_tacvalue v with
  | Some (VFun (appl,trace',loc,lfun,it,b)) -> of_tacvalue (VFun (appl,trace',loc,lfun,it,b))
  | _ -> v

(* Dynamically check that an argument is a tactic *)
let coerce_to_tactic loc id v =
  let fail () = user_err ?loc
    (str "Variable " ++ Id.print id ++ str " should be bound to a tactic.")
  in
  match to_tacvalue v with
  | Some (VFun (appl,trace,_,lfun,it,b)) -> of_tacvalue (VFun (appl,trace,loc,lfun,it,b))
  | _ -> fail ()

let intro_pattern_of_ident id = CAst.make @@ IntroNaming (IntroIdentifier id)
let value_of_ident id =
  in_gen (topwit wit_intro_pattern) (intro_pattern_of_ident id)

let (+++) lfun1 lfun2 = Id.Map.fold Id.Map.add lfun1 lfun2

let extend_values_with_bindings (ln,lm) lfun =
  let of_cub c = match c with
  | [], c -> Value.of_constr c
  | _ -> Value.of_constr_under_binders c
  in
  (* For compatibility, bound variables are visible only if no other
     binding of the same name exists *)
  let accu = Id.Map.map value_of_ident ln in
  let accu = lfun +++ accu in
  Id.Map.fold (fun id c accu -> Id.Map.add id (of_cub c) accu) lm accu

(***************************************************************************)
(* Evaluation/interpretation *)

let is_variable env id =
  Id.List.mem id (ids_of_named_context (Environ.named_context env))

let debugging_step ist pp =
  match curr_debug ist with
  | DebugOn lev -> Tactic_debug.defer_output
      (fun _ -> (str "Level " ++ int lev ++ str": " ++ pp () ++ fnl()))
  | _ -> Proofview.NonLogical.return ()

let debugging_exception_step ist signal_anomaly e pp =
  let explain_exc =
    if signal_anomaly then explain_logic_error
    else explain_logic_error_no_anomaly in
  debugging_step ist (fun () ->
    pp() ++ spc() ++ str "raised the exception" ++ fnl() ++ explain_exc e)

let ensure_freshness env =
  (* We anonymize declarations which we know will not be used *)
  (* This assumes that the original context had no rels *)
  process_rel_context
    (fun d e -> EConstr.push_rel (Context.Rel.Declaration.set_name Anonymous d) e) env

(* Raise Not_found if not in interpretation sign *)
let try_interp_ltac_var coerce ist env {loc;v=id} =
  let v = Id.Map.find id ist.lfun in
  try coerce v with CannotCoerceTo s ->
    Taccoerce.error_ltac_variable ?loc id env v s

let interp_ltac_var coerce ist env locid =
  try try_interp_ltac_var coerce ist env locid
  with Not_found -> anomaly (str "Detected '" ++ Id.print locid.v ++ str "' as ltac var at interning time.")

let interp_ident ist env sigma id =
  try try_interp_ltac_var (coerce_var_to_ident false env sigma) ist (Some (env,sigma)) (CAst.make id)
  with Not_found -> id

(* Interprets an optional identifier, bound or fresh *)
let interp_name ist env sigma = function
  | Anonymous -> Anonymous
  | Name id -> Name (interp_ident ist env sigma id)

let interp_intro_pattern_var loc ist env sigma id =
  try try_interp_ltac_var (coerce_to_intro_pattern sigma) ist (Some (env,sigma)) (CAst.make ?loc id)
  with Not_found -> IntroNaming (IntroIdentifier id)

let interp_intro_pattern_naming_var loc ist env sigma id =
  try try_interp_ltac_var (coerce_to_intro_pattern_naming sigma) ist (Some (env,sigma)) (CAst.make ?loc id)
  with Not_found -> IntroIdentifier id

let interp_int ist ({loc;v=id} as locid) =
  try try_interp_ltac_var coerce_to_int ist None locid
  with Not_found ->
    user_err ?loc
     (str "Unbound variable "  ++ Id.print id ++ str".")

let interp_int_or_var ist = function
  | ArgVar locid -> interp_int ist locid
  | ArgArg n -> n

let interp_int_as_list ist = function
  | ArgVar ({v=id} as locid) ->
      (try coerce_to_int_list (Id.Map.find id ist.lfun)
       with Not_found | CannotCoerceTo _ -> [interp_int ist locid])
  | ArgArg n -> [n]

let interp_int_list ist l =
  List.flatten (List.map (interp_int_as_list ist) l)

(* Interprets a bound variable (especially an existing hypothesis) *)
let interp_hyp ist env sigma ({loc;v=id} as locid) =
  (* Look first in lfun for a value coercible to a variable *)
  try try_interp_ltac_var (coerce_to_hyp env sigma) ist (Some (env,sigma)) locid
  with Not_found ->
  (* Then look if bound in the proof context at calling time *)
  if is_variable env id then id
  else Loc.raise ?loc (Logic.RefinerError (env, sigma, Logic.NoSuchHyp id))

let interp_hyp_list_as_list ist env sigma ({loc;v=id} as x) =
  try coerce_to_hyp_list env sigma (Id.Map.find id ist.lfun)
  with Not_found | CannotCoerceTo _ -> [interp_hyp ist env sigma x]

let interp_hyp_list ist env sigma l =
  List.flatten (List.map (interp_hyp_list_as_list ist env sigma) l)

let interp_reference ist env sigma = function
  | ArgArg (_,r) -> r
  | ArgVar {loc;v=id} ->
    try try_interp_ltac_var (coerce_to_reference sigma) ist (Some (env,sigma)) (CAst.make ?loc id)
    with Not_found ->
      try
        GlobRef.VarRef (get_id (Environ.lookup_named id env))
      with Not_found as exn ->
        let _, info = Exninfo.capture exn in
        Nametab.error_global_not_found ~info (qualid_of_ident ?loc id)

let try_interp_evaluable env (loc, id) =
  let v = Environ.lookup_named id env in
  match v with
  | LocalDef _ -> Evaluable.EvalVarRef id
  | _ -> error_not_evaluable (GlobRef.VarRef id)

let interp_evaluable ist env sigma = function
  | ArgArg (r,Some {loc;v=id}) ->
    (* Maybe [id] has been introduced by Intro-like tactics *)
    begin
      try try_interp_evaluable env (loc, id)
      with Not_found as exn ->
        match r with
        | Evaluable.EvalConstRef _ -> r
        | Evaluable.EvalProjectionRef _ -> r
        | _ ->
          let _, info = Exninfo.capture exn in
          Nametab.error_global_not_found ~info (qualid_of_ident ?loc id)
    end
  | ArgArg (r,None) -> r
  | ArgVar {loc;v=id} ->
    try try_interp_ltac_var (coerce_to_evaluable_ref env sigma) ist (Some (env,sigma)) (CAst.make ?loc id)
    with Not_found ->
      try try_interp_evaluable env (loc, id)
      with Not_found as exn ->
        let _, info = Exninfo.capture exn in
        Nametab.error_global_not_found ~info (qualid_of_ident ?loc id)

(* Interprets an hypothesis name *)
let interp_occurrences ist occs =
  Locusops.occurrences_map (interp_int_list ist) occs

let interp_occurrences_expr ist occs =
  (* XXX we should be able to delete this function
     but hyp clauses still use occurrences_expr *)
  let occs = interp_occurrences ist occs in
  Locusops.occurrences_map (List.map (fun x -> ArgArg x)) occs

let interp_hyp_location ist env sigma ((occs,id),hl) =
  ((interp_occurrences_expr ist occs,interp_hyp ist env sigma id),hl)

let interp_hyp_location_list_as_list ist env sigma ((occs,id),hl as x) =
  match occs,hl with
  | AllOccurrences,InHyp ->
      List.map (fun id -> ((AllOccurrences,id),InHyp))
        (interp_hyp_list_as_list ist env sigma id)
  | _,_ -> [interp_hyp_location ist env sigma x]

let interp_hyp_location_list ist env sigma l =
  List.flatten (List.map (interp_hyp_location_list_as_list ist env sigma) l)

let interp_clause ist env sigma { onhyps=ol; concl_occs=occs } : clause =
  { onhyps=Option.map (interp_hyp_location_list ist env sigma) ol;
    concl_occs=interp_occurrences_expr ist occs }

(* Interpretation of constructions *)

(* Extract the constr list from lfun *)
let extract_ltac_constr_values ist env =
  let fold id v accu =
    try
      let c = coerce_to_constr env v in
      Id.Map.add id c accu
    with CannotCoerceTo _ -> accu
  in
  Id.Map.fold fold ist.lfun Id.Map.empty
(** ppedrot: I have changed the semantics here. Before this patch, closure was
    implemented as a list and a variable could be bound several times with
    different types, resulting in its possible appearance on both sides. This
    could barely be defined as a feature... *)

(* Extract the identifier list from lfun: join all branches (what to do else?)*)
let rec intropattern_ids accu {loc;v=pat} = match pat with
  | IntroNaming (IntroIdentifier id) -> Id.Set.add id accu
  | IntroAction (IntroOrAndPattern (IntroAndPattern l)) ->
      List.fold_left intropattern_ids accu l
  | IntroAction (IntroOrAndPattern (IntroOrPattern ll)) ->
      List.fold_left intropattern_ids accu (List.flatten ll)
  | IntroAction (IntroInjection l) ->
      List.fold_left intropattern_ids accu l
  | IntroAction (IntroApplyOn ({v=c},pat)) -> intropattern_ids accu pat
  | IntroNaming (IntroAnonymous | IntroFresh _)
  | IntroAction (IntroWildcard | IntroRewrite _)
  | IntroForthcoming _ -> accu

let extract_ids ids lfun accu =
  let fold id v accu =
    if has_type v (topwit wit_intro_pattern) then
      let {v=ipat} = out_gen (topwit wit_intro_pattern) v in
      if Id.List.mem id ids then accu
      else intropattern_ids accu (CAst.make ipat)
    else accu
  in
  Id.Map.fold fold lfun accu

let default_fresh_id = Id.of_string "H"

let interp_fresh_id ist env sigma l =
  let extract_ident ist env sigma id =
    try try_interp_ltac_var (coerce_to_ident_not_fresh sigma)
                            ist (Some (env,sigma)) (CAst.make id)
    with Not_found -> id in
  let ids = List.map_filter (function ArgVar {v=id} -> Some id | _ -> None) l in
  let avoid = match TacStore.get ist.extra f_avoid_ids with
  | None -> Id.Set.empty
  | Some l -> l
  in
  let avoid = extract_ids ids ist.lfun avoid in
  let id =
    if List.is_empty l then default_fresh_id
    else
      let s =
        String.concat "" (List.map (function
          | ArgArg s -> s
          | ArgVar {v=id} -> Id.to_string (extract_ident ist env sigma id)) l) in
      let s = if CLexer.is_keyword (Procq.get_keyword_state()) s then s^"0" else s in
      Id.of_string s in
  Tactics.fresh_id_in_env avoid id env

(* Extract the uconstr list from lfun *)
let extract_ltac_constr_context ist env sigma =
  let add_uconstr id v map =
    try Id.Map.add id (coerce_to_uconstr v) map
    with CannotCoerceTo _ -> map
  in
  let add_constr id v map =
    try Id.Map.add id (coerce_to_constr env v) map
    with CannotCoerceTo _ -> map
  in
  let add_ident id v map =
    try Id.Map.add id (coerce_var_to_ident false env sigma v) map
    with CannotCoerceTo _ -> map
  in
  let fold id v {idents;typed;untyped;genargs} =
    let idents = add_ident id v idents in
    let typed = add_constr id v typed in
    let untyped = add_uconstr id v untyped in
    { idents ; typed ; untyped; genargs }
  in
  let empty = { idents = Id.Map.empty ;typed = Id.Map.empty ; untyped = Id.Map.empty; genargs = ist.lfun } in
  Id.Map.fold fold ist.lfun empty

(** Significantly simpler than [interp_constr], to interpret an
    untyped constr, it suffices to adjoin a closure environment. *)
let interp_glob_closure ist env sigma ?(kind=WithoutTypeConstraint) ?(pattern_mode=false) (term,term_expr_opt) =
  let closure = extract_ltac_constr_context ist env sigma in
  match term_expr_opt with
  | None -> { closure ; term }
  | Some term_expr ->
     (* If at toplevel (term_expr_opt<>None), the error can be due to
       an incorrect context at globalization time: we retype with the
       now known intros/lettac/inversion hypothesis names *)
      let constr_context =
        Id.Set.union
          (Id.Map.domain closure.typed)
          (Id.Map.domain closure.untyped)
      in
      let ltacvars = {
        ltac_vars = constr_context;
        ltac_bound = Id.Map.domain ist.lfun;
        ltac_extra = Genintern.Store.empty;
      } in
      { closure ; term = intern_gen kind ~strict_check:false ~pattern_mode ~ltacvars env sigma term_expr }

let interp_uconstr ist env sigma c = interp_glob_closure ist env sigma c

let interp_gen kind ist pattern_mode flags env sigma c =
  let kind_for_intern = match kind with OfType _ -> WithoutTypeConstraint | _ -> kind in
  let { closure = constrvars ; term } =
    interp_glob_closure ist env sigma ~kind:kind_for_intern ~pattern_mode c in
  let vars = {
    ltac_constrs = constrvars.typed;
    ltac_uconstrs = constrvars.untyped;
    ltac_idents = constrvars.idents;
    ltac_genargs = ist.lfun;
  } in
  let loc = loc_of_glob_constr term in
  let trace = push_trace (loc,LtacConstrInterp (env,sigma,term,vars)) ist in
  let (stack, _) = trace in
  (* save and restore the current trace info because the called routine later starts
     with an empty trace *)
  Tactic_debug.push_chunk trace;
  try
    let (evd,c) =
      catch_error_with_trace_loc loc stack (understand_ltac flags env sigma vars kind) term
    in
    (* spiwack: to avoid unnecessary modifications of tacinterp, as this
       function already use effect, I call [run] hoping it doesn't mess
       up with any assumption. *)
    Proofview.NonLogical.run (db_constr (curr_debug ist) env evd c);
    Tactic_debug.pop_chunk ();
    (evd,c)
  with reraise ->
    let reraise = Exninfo.capture reraise in
    Tactic_debug.pop_chunk ();
    Exninfo.iraise reraise

let constr_flags () = {
  use_coercions = true;
  use_typeclasses = UseTC;
  solve_unification_constraints = true;
  fail_evar = true;
  expand_evars = true;
  program_mode = false;
  polymorphic = false;
  undeclared_evars_rr = false;
  unconstrained_sorts = false;
}

(* Interprets a constr; expects evars to be solved *)
let interp_constr_gen kind ist env sigma c =
  let flags = { (constr_flags ()) with polymorphic = ist.Geninterp.poly } in
  interp_gen kind ist false flags env sigma c

let interp_constr = interp_constr_gen WithoutTypeConstraint

let interp_type = interp_constr_gen IsType

let open_constr_use_classes_flags () = {
  use_coercions = true;
  use_typeclasses = UseTC;
  solve_unification_constraints = true;
  fail_evar = false;
  expand_evars = false;
  program_mode = false;
  polymorphic = false;
  undeclared_evars_rr = false;
  unconstrained_sorts = false;
}

let open_constr_no_classes_flags () = {
  use_coercions = true;
  use_typeclasses = NoUseTC;
  solve_unification_constraints = true;
  fail_evar = false;
  expand_evars = false;
  program_mode = false;
  polymorphic = false;
  undeclared_evars_rr = false;
  unconstrained_sorts = false;
}

let pure_open_constr_flags = {
  use_coercions = true;
  use_typeclasses = NoUseTC;
  solve_unification_constraints = true;
  fail_evar = false;
  expand_evars = false;
  program_mode = false;
  polymorphic = false;
  undeclared_evars_rr = false;
  unconstrained_sorts = false;
}

(* Interprets an open constr *)
let interp_open_constr ?(expected_type=WithoutTypeConstraint) ?(flags=open_constr_no_classes_flags ()) ist env sigma c =
  interp_gen expected_type ist false flags env sigma c

let interp_open_constr_with_classes ?(expected_type=WithoutTypeConstraint) ist env sigma c =
  interp_gen expected_type ist false (open_constr_use_classes_flags ()) env sigma c

let interp_pure_open_constr ist =
  interp_gen WithoutTypeConstraint ist false pure_open_constr_flags

let interp_typed_pattern ist env sigma c =
  let sigma, c =
    interp_gen WithoutTypeConstraint ist true pure_open_constr_flags env sigma c in
  (* FIXME: it is necessary to be unsafe here because of the way we handle
     evars in the pretyper. Sometimes they get solved eagerly. *)
  legacy_bad_pattern_of_constr env sigma c

(* Interprets a constr expression *)
let interp_constr_in_compound_list inj_fun dest_fun interp_fun ist env sigma l =
  let try_expand_ltac_var sigma x =
    try match DAst.get (fst (dest_fun x)) with
    | GVar id ->
      let v = Id.Map.find id ist.lfun in
      sigma, List.map inj_fun (coerce_to_constr_list env v)
    | _ ->
        raise Not_found
    with CannotCoerceTo _ | Not_found ->
      (* dest_fun, List.assoc may raise Not_found *)
      let sigma, c = interp_fun ist env sigma x in
      sigma, [c] in
  let sigma, l = List.fold_left_map try_expand_ltac_var sigma l in
  sigma, List.flatten l

let interp_constr_list ist env sigma c =
  interp_constr_in_compound_list (fun x -> x) (fun x -> x) interp_constr ist env sigma c

let interp_open_constr_list =
  interp_constr_in_compound_list (fun x -> x) (fun x -> x) interp_open_constr

let interp_constr_with_occurrences ist env sigma (occs,c) =
  let (sigma,c_interp) = interp_constr ist env sigma c in
  sigma , (interp_occurrences ist occs, c_interp)

let interp_evaluable_or_pattern ist env sigma = function
  | ArgVar {loc;v=id} ->
      (* This is the encoding of an ltac var supposed to be bound
         prioritary to an evaluable reference and otherwise to a constr
         (it is an encoding to satisfy the "union" type given to Simpl) *)
    let coerce_eval_ref_or_constr x =
      try Inl (coerce_to_evaluable_ref env sigma x)
      with CannotCoerceTo _ ->
        let c = coerce_to_closed_constr env x in
        Inr (pattern_of_constr env sigma c) in
    (try try_interp_ltac_var coerce_eval_ref_or_constr ist (Some (env,sigma)) (CAst.make ?loc id)
     with Not_found as exn ->
       let _, info = Exninfo.capture exn in
       Nametab.error_global_not_found ~info (qualid_of_ident ?loc id))
  | ArgArg _ as b -> Inl (interp_evaluable ist env sigma b)

let interp_constr_with_occurrences_and_name_as_list =
  interp_constr_in_compound_list
    (fun c -> ((AllOccurrences,c),Anonymous))
    (function ((occs,c),Anonymous) when occs == AllOccurrences -> c
      | _ -> raise Not_found)
    (fun ist env sigma (occ_c,na) ->
      let (sigma,c_interp) = interp_constr_with_occurrences ist env sigma occ_c in
      sigma, (c_interp,
       interp_name ist env sigma na))

let interp_red_expr ist env sigma r =
  let ist = {
    Redexpr.Interp.interp_occurrence_var = (fun x -> interp_int_list ist [ArgVar x]);
    interp_constr = interp_constr ist;
    interp_constr_list = (fun env sigma c -> interp_constr_list ist env sigma [c]);
    interp_evaluable = interp_evaluable ist;
    interp_pattern = interp_typed_pattern ist;
    interp_evaluable_or_pattern = interp_evaluable_or_pattern ist;
  }
  in
  Redexpr.Interp.interp_red_expr ist env sigma r

let interp_strategy ist _env _sigma s =
  let interp_redexpr r = fun env sigma -> interp_red_expr ist env sigma r in
  let interp_constr c = (fst c, fun env sigma -> interp_open_constr ist env sigma c) in
  let s = Rewrite.map_strategy interp_constr interp_redexpr (fun x -> x) s in
  Rewrite.strategy_of_ast s

let interp_may_eval f ist env sigma = function
  | ConstrEval (r,c) ->
      let (sigma,redexp) = interp_red_expr ist env sigma r in
      let (sigma,c_interp) = f ist env sigma c in
      let (redfun, _) = Redexpr.reduction_of_red_expr env redexp in
      redfun env sigma c_interp
  | ConstrContext ({loc;v=s},c) ->
    let (sigma,ic) = f ist env sigma c in
    let ctxt =
      try try_interp_ltac_var coerce_to_constr_context ist (Some (env, sigma)) (CAst.make ?loc s)
      with Not_found ->
        user_err ?loc (str "Unbound context identifier" ++ Id.print s ++ str".")
    in
    let c = Constr_matching.instantiate_context ctxt ic in
    Typing.solve_evars env sigma c
  | ConstrTypeOf c ->
      let (sigma,c_interp) = f ist env sigma c in
      let (sigma, t) = Typing.type_of ~refresh:true env sigma c_interp in
      (sigma, t)
  | ConstrTerm c ->
     try
        f ist env sigma c
     with reraise ->
       let reraise = Exninfo.capture reraise in
       (* spiwack: to avoid unnecessary modifications of tacinterp, as this
          function already use effect, I call [run] hoping it doesn't mess
          up with any assumption. *)
       Proofview.NonLogical.run (debugging_exception_step ist false (fst reraise) (fun () ->
         str"interpretation of term " ++ pr_glob_constr_env env sigma (fst c)));
       Exninfo.iraise reraise

(* Interprets a constr expression possibly to first evaluate *)
let interp_constr_may_eval ist env sigma c =
  let (sigma,csr) =
    try
      interp_may_eval interp_constr ist env sigma c
    with reraise ->
      let reraise = Exninfo.capture reraise in
      (* spiwack: to avoid unnecessary modifications of tacinterp, as this
          function already use effect, I call [run] hoping it doesn't mess
          up with any assumption. *)
       Proofview.NonLogical.run (debugging_exception_step ist false (fst reraise) (fun () -> str"evaluation of term"));
      Exninfo.iraise reraise
  in
  begin
    (* spiwack: to avoid unnecessary modifications of tacinterp, as this
       function already use effect, I call [run] hoping it doesn't mess
       up with any assumption. *)
    Proofview.NonLogical.run (db_constr (curr_debug ist) env sigma csr);
    sigma , csr
  end

(** TODO: should use dedicated printers *)
let message_of_value v =
  let pr_with_env pr =
    Ftactic.enter begin fun gl -> Ftactic.return (pr (pf_env gl) (project gl)) end in
  let open Genprint in
  match generic_val_print v with
  | TopPrinterBasic pr -> Ftactic.return (pr ())
  | TopPrinterNeedsContext pr -> pr_with_env pr
  | TopPrinterNeedsContextAndLevel { default_ensure_surrounded; printer } ->
     pr_with_env (fun env sigma -> printer env sigma default_ensure_surrounded)

let interp_message_token ist = function
  | MsgString s -> Ftactic.return (str s)
  | MsgInt n -> Ftactic.return (int n)
  | MsgIdent {loc;v=id} ->
    let v = try Some (Id.Map.find id ist.lfun) with Not_found -> None in
    match v with
    | None -> Ftactic.lift (
        let info = Exninfo.reify () in
        Tacticals.tclZEROMSG ~info (Id.print id ++ str" not found."))
    | Some v -> message_of_value v

let interp_message ist l =
  let open Ftactic in
  Ftactic.List.map (interp_message_token ist) l >>= fun l ->
  Ftactic.return (prlist_with_sep spc (fun x -> x) l)

let rec interp_intro_pattern ist env sigma = with_loc_val (fun ?loc -> function
  | IntroAction pat ->
    let pat = interp_intro_pattern_action ist env sigma pat in
    CAst.make ?loc @@ IntroAction pat
  | IntroNaming (IntroIdentifier id) ->
    CAst.make ?loc @@ interp_intro_pattern_var loc ist env sigma id
  | IntroNaming pat ->
    CAst.make ?loc @@ IntroNaming (interp_intro_pattern_naming loc ist env sigma pat)
  | IntroForthcoming _  as x -> CAst.make ?loc x)

and interp_intro_pattern_naming loc ist env sigma = function
  | IntroFresh id -> IntroFresh (interp_ident ist env sigma id)
  | IntroIdentifier id -> interp_intro_pattern_naming_var loc ist env sigma id
  | IntroAnonymous as x -> x

and interp_intro_pattern_action ist env sigma = function
  | IntroOrAndPattern l ->
      let l = interp_or_and_intro_pattern ist env sigma l in
      IntroOrAndPattern l
  | IntroInjection l ->
      let l = interp_intro_pattern_list_as_list ist env sigma l in
      IntroInjection l
  | IntroApplyOn ({loc;v=c},ipat) ->
      let c env sigma = interp_open_constr ist env sigma c in
      let ipat = interp_intro_pattern ist env sigma ipat in
      IntroApplyOn (CAst.make ?loc c,ipat)
  | IntroWildcard | IntroRewrite _ as x -> x

and interp_or_and_intro_pattern ist env sigma = function
  | IntroAndPattern l ->
      let l = List.map (interp_intro_pattern ist env sigma) l in
      IntroAndPattern l
  | IntroOrPattern ll ->
      let ll = List.map (interp_intro_pattern_list_as_list ist env sigma) ll in
      IntroOrPattern ll

and interp_intro_pattern_list_as_list ist env sigma = function
  | [{loc;v=IntroNaming (IntroIdentifier id)}] as l ->
      (try coerce_to_intro_pattern_list ?loc sigma (Id.Map.find id ist.lfun)
       with Not_found | CannotCoerceTo _ ->
         List.map (interp_intro_pattern ist env sigma) l)
  | l -> List.map (interp_intro_pattern ist env sigma) l

let interp_intro_pattern_naming_option ist env sigma = function
  | None -> None
  | Some lpat -> Some (map_with_loc (fun ?loc pat -> interp_intro_pattern_naming loc ist env sigma pat) lpat)

let interp_or_and_intro_pattern_option ist env sigma = function
  | None -> None
  | Some (ArgVar {loc;v=id}) ->
      (match interp_intro_pattern_var loc ist env sigma id with
      | IntroAction (IntroOrAndPattern l) -> Some (CAst.make ?loc l)
      | _ ->
        user_err ?loc (str "Cannot coerce to a disjunctive/conjunctive pattern."))
  | Some (ArgArg {loc;v=l}) ->
      let l = interp_or_and_intro_pattern ist env sigma l in
      Some (CAst.make ?loc l)

let interp_intro_pattern_option ist env sigma = function
  | None -> None
  | Some ipat ->
      let ipat = interp_intro_pattern ist env sigma ipat in
      Some ipat

let interp_in_hyp_as ist env sigma (id,ipat) =
  let ipat = interp_intro_pattern_option ist env sigma ipat in
  (interp_hyp ist env sigma id,ipat)

let interp_binding_name ist env sigma = function
  | AnonHyp n -> AnonHyp n
  | NamedHyp id ->
      (* If a name is bound, it has to be a quantified hypothesis *)
      (* user has to use other names for variables if these ones clash with *)
      (* a name intended to be used as a (non-variable) identifier *)
      try try_interp_ltac_var (coerce_to_quantified_hypothesis sigma) ist (Some (env,sigma)) id
      with Not_found -> NamedHyp id

let interp_declared_or_quantified_hypothesis ist env sigma = function
  | AnonHyp n -> AnonHyp n
  | NamedHyp id ->
      try try_interp_ltac_var
            (coerce_to_decl_or_quant_hyp sigma) ist (Some (env,sigma)) id
      with Not_found -> NamedHyp id

let interp_binding ist env sigma {loc;v=(b,c)} =
  let sigma, c = interp_open_constr ist env sigma c in
  sigma, (CAst.make ?loc (interp_binding_name ist env sigma b,c))

let interp_bindings ist env sigma = function
| NoBindings ->
    sigma, NoBindings
| ImplicitBindings l ->
    let sigma, l = interp_open_constr_list ist env sigma l in
    sigma, ImplicitBindings l
| ExplicitBindings l ->
    let sigma, l = List.fold_left_map (interp_binding ist env) sigma l in
    sigma, ExplicitBindings l

let interp_constr_with_bindings ist env sigma (c,bl) =
  let sigma, bl = interp_bindings ist env sigma bl in
  let sigma, c = interp_constr ist env sigma c in
  sigma, (c,bl)

let interp_open_constr_with_bindings ist env sigma (c,bl) =
  let sigma, bl = interp_bindings ist env sigma bl in
  let sigma, c = interp_open_constr ist env sigma c in
  sigma, (c, bl)

let loc_of_bindings = function
| NoBindings         -> None
| ImplicitBindings l -> loc_of_glob_constr (fst (List.last l))
| ExplicitBindings l -> (List.last l).loc

let interp_open_constr_with_bindings_loc ist ((c,_),bl as cb) =
  let loc1 = loc_of_glob_constr c in
  let loc2 = loc_of_bindings bl in
  let loc  = Loc.merge_opt loc1 loc2 in
  let f env sigma = interp_open_constr_with_bindings ist env sigma cb in
  (loc,f)

let interp_destruction_arg ist gl arg =
  match arg with
  | keep,ElimOnConstr c ->
      keep,ElimOnConstr begin fun env sigma ->
        interp_open_constr_with_bindings ist env sigma c
      end
  | keep,ElimOnAnonHyp n as x -> x
  | keep,ElimOnIdent {loc;v=id} ->
      let error () = user_err ?loc
       (strbrk "Cannot coerce " ++ Id.print id ++
        strbrk " neither to a quantified hypothesis nor to a term.")
      in
      let try_cast_id id' =
        if Tactics.is_quantified_hypothesis id' gl
        then keep,ElimOnIdent (CAst.make ?loc id')
        else
          (keep, ElimOnConstr begin fun env sigma ->
          try (sigma, (constr_of_id env id', NoBindings))
          with Not_found ->
            user_err ?loc  (
            Id.print id ++ strbrk " binds to " ++ Id.print id' ++ strbrk " which is neither a declared nor a quantified hypothesis.")
          end)
      in
      try
        (* FIXME: should be moved to taccoerce *)
        let v = Id.Map.find id ist.lfun in
        if has_type v (topwit wit_intro_pattern) then
          let v = out_gen (topwit wit_intro_pattern) v in
          match v with
          | {v=IntroNaming (IntroIdentifier id)} -> try_cast_id id
          | _ -> error ()
        else if has_type v (topwit wit_hyp) then
          let id = out_gen (topwit wit_hyp) v in
          try_cast_id id
        else if has_type v (topwit wit_int) then
          keep,ElimOnAnonHyp (out_gen (topwit wit_int) v)
        else match Value.to_constr v with
        | None -> error ()
        | Some c -> keep,ElimOnConstr (fun env sigma -> (sigma, (c,NoBindings)))
      with Not_found ->
        (* We were in non strict (interactive) mode *)
        if Tactics.is_quantified_hypothesis id gl then
          keep,ElimOnIdent (CAst.make ?loc id)
        else
          let c = (DAst.make ?loc @@ GVar id,Some (CAst.make @@ CRef (qualid_of_ident ?loc id,None))) in
          let f env sigma =
            let (sigma,c) = interp_open_constr ist env sigma c in
            (sigma, (c,NoBindings))
          in
          keep,ElimOnConstr f

(* Associates variables with values and gives the remaining variables and
   values *)
let head_with_value (lvar,lval) =
  let rec head_with_value_rec lacc = function
    | ([],[]) -> (lacc,[],[])
    | (vr::tvr,ve::tve) ->
      (match vr with
      |	Anonymous -> head_with_value_rec lacc (tvr,tve)
      | Name v -> head_with_value_rec ((v,ve)::lacc) (tvr,tve))
    | (vr,[]) -> (lacc,vr,[])
    | ([],ve) -> (lacc,[],ve)
  in
  head_with_value_rec [] (lvar,lval)

let eval_pattern ist env sigma (bvars, _, pat) =
  let closure = extract_ltac_constr_context ist env sigma in
  let lvars = {
    ltac_constrs = closure.typed;
    ltac_uconstrs = closure.untyped;
    ltac_idents = closure.idents;
    ltac_genargs = closure.genargs;
  }
  in
  (bvars, Patternops.interp_pattern env sigma lvars pat)

let read_pattern ist env sigma = function
  | Subterm (ido,c) -> Subterm (ido,eval_pattern ist env sigma c)
  | Term c -> Term (eval_pattern ist env sigma c)

(* Reads the hypotheses of a Match Context rule *)
let cons_and_check_name id l =
  if Id.List.mem id l then
    user_err (
      str "Hypothesis pattern-matching variable " ++ Id.print id ++
      str " used twice in the same pattern.")
  else id::l

let rec read_match_goal_hyps ist env sigma lidh = function
  | (Hyp ({loc;v=na} as locna,mp))::tl ->
      let lidh' = Name.fold_right cons_and_check_name na lidh in
      Hyp (locna,read_pattern ist env sigma mp)::
        (read_match_goal_hyps ist env sigma lidh' tl)
  | (Def ({loc;v=na} as locna,mv,mp))::tl ->
      let lidh' = Name.fold_right cons_and_check_name na lidh in
      Def (locna,read_pattern ist env sigma mv, read_pattern ist env sigma mp)::
        (read_match_goal_hyps ist env sigma lidh' tl)
  | [] -> []

(* Reads the rules of a Match Context or a Match *)
let rec read_match_rule ist env sigma = function
  | (All tc)::tl -> (All tc)::(read_match_rule ist env sigma tl)
  | (Pat (rl,mp,tc))::tl ->
      Pat (read_match_goal_hyps ist env sigma [] rl, read_pattern ist env sigma mp,tc)
      :: read_match_rule ist env sigma tl
  | [] -> []

(* Fully evaluate an untyped constr *)
let type_uconstr ?(flags = (constr_flags ()))
  ?(expected_type = WithoutTypeConstraint) ist c =
  let flags = { flags with polymorphic = ist.Geninterp.poly } in
  begin fun env sigma ->
    Pretyping.understand_uconstr ~flags ~expected_type env sigma c
  end

(* Interprets an l-tac expression into a value *)
let rec val_interp ist ?(appl=UnnamedAppl) (tac:glob_tactic_expr) : Val.t Ftactic.t =
  (* The name [appl] of applied top-level Ltac names is ignored in
     [value_interp]. It is installed in the second step by a call to
     [name_vfun], because it gives more opportunities to detect a
     [VFun]. Otherwise a [Ltac t := let x := .. in tac] would never
     register its name since it is syntactically a let, not a
     function.  *)
  let (loc,tac2) = CAst.(tac.loc, tac.v) in
  let value_interp ist =
  match tac2 with
  | TacFun (it, body) ->
    Ftactic.return (of_tacvalue (VFun (UnnamedAppl, extract_trace ist, extract_loc ist, ist.lfun, it, body)))
  | TacLetIn (true,l,u) -> interp_letrec ist l u
  | TacLetIn (false,l,u) -> interp_letin ist l u
  | TacMatchGoal (lz,lr,lmr) -> interp_match_goal ist lz lr lmr
  | TacMatch (lz,c,lmr) -> interp_match ist lz c lmr
  | TacArg v -> interp_tacarg ist v
  | _ ->
    (* Delayed evaluation *)
    Ftactic.return (of_tacvalue (VFun (UnnamedAppl, extract_trace ist, extract_loc ist, ist.lfun, [], tac)))
  in
  let open Ftactic in
  Control.check_for_interrupt ();
  match curr_debug ist with
  | DebugOn lev ->
        let eval v =
          let ist = { ist with extra = TacStore.set ist.extra f_debug v } in
          value_interp ist >>= fun v -> return (name_vfun appl v)
        in
        Tactic_debug.debug_prompt lev tac eval ist.lfun (TacStore.get ist.extra f_trace)
  | _ -> value_interp ist >>= fun v -> return (name_vfun appl v)


and eval_tactic_ist ist tac : unit Proofview.tactic =
  let (loc, tac2) = CAst.(tac.loc, tac.v) in
  match tac2 with
  | TacAtom t ->
      let call = LtacAtomCall t in
      let (stack, _) = push_trace(loc,call) ist in
      do_profile stack
        (catch_error_tac_loc loc stack (interp_atomic ist t))
  | TacFun _ | TacLetIn _ | TacMatchGoal _ | TacMatch _ -> interp_tactic ist tac
  | TacId [] -> Proofview.tclLIFT (db_breakpoint (curr_debug ist) [])
  | TacId s ->
      let msgnl =
        let open Ftactic in
        interp_message ist s >>= fun msg ->
        return (hov 0 msg , hov 0 msg)
      in
      let print (_,msgnl) = Proofview.(tclLIFT (NonLogical.print_info msgnl)) in
      let log (msg,_) = Proofview.Trace.log (fun () -> msg) in
      let break = Proofview.tclLIFT (db_breakpoint (curr_debug ist) s) in
      Ftactic.run msgnl begin fun msgnl ->
        print msgnl <*> log msgnl <*> break
      end
  | TacFail (g,n,s) ->
      let msg = interp_message ist s in
      let tac ~info l = Tacticals.tclFAILn ~info (interp_int_or_var ist n) l in
      let tac =
        match g with
        | TacLocal ->
          let info = Exninfo.reify () in
          fun l -> Proofview.tclINDEPENDENT (tac ~info l)
        | TacGlobal ->
          let info = Exninfo.reify () in
          tac ~info
      in
      Ftactic.run msg tac
  | TacProgress tac -> Tacticals.tclPROGRESS (interp_tactic ist tac)
  | TacAbstract (t,ido) ->
      let call = LtacMLCall tac in
      let (stack,_) = push_trace(None,call) ist in
      do_profile stack
        (catch_error_tac stack begin
      Proofview.Goal.enter begin fun gl -> Abstract.tclABSTRACT
        (Option.map (interp_ident ist (pf_env gl) (project gl)) ido) (interp_tactic ist t)
      end end)
  | TacThen (t1,t) ->
      Tacticals.tclTHEN (interp_tactic ist t1) (interp_tactic ist t)
  | TacDispatch tl ->
      Proofview.tclDISPATCH (List.map (interp_tactic ist) tl)
  | TacExtendTac (tf,t,tl) ->
      Proofview.tclEXTEND (Array.map_to_list (interp_tactic ist) tf)
                          (interp_tactic ist t)
                          (Array.map_to_list (interp_tactic ist) tl)
  | TacThens (t1,tl) -> Tacticals.tclTHENS (interp_tactic ist t1) (List.map (interp_tactic ist) tl)
  | TacThens3parts (t1,tf,t,tl) ->
      Tacticals.tclTHENS3PARTS (interp_tactic ist t1)
        (Array.map (interp_tactic ist) tf) (interp_tactic ist t) (Array.map (interp_tactic ist) tl)
  | TacDo (n,tac) -> Tacticals.tclDO (interp_int_or_var ist n) (interp_tactic ist tac)
  | TacTimeout (n,tac) -> Tacticals.tclTIMEOUT (interp_int_or_var ist n) (interp_tactic ist tac)
  | TacTime (s,tac) -> Tacticals.tclTIME s (interp_tactic ist tac)
  | TacTry tac -> Tacticals.tclTRY (interp_tactic ist tac)
  | TacRepeat tac -> Tacticals.tclREPEAT (interp_tactic ist tac)
  | TacOr (tac1,tac2) ->
      Tacticals.tclOR (interp_tactic ist tac1) (interp_tactic ist tac2)
  | TacOnce tac ->
      Tacticals.tclONCE (interp_tactic ist tac)
  | TacExactlyOnce tac ->
      Tacticals.tclEXACTLY_ONCE (interp_tactic ist tac)
  | TacIfThenCatch (t,tt,te) ->
      Tacticals.tclIFCATCH
        (interp_tactic ist t)
        (fun () -> interp_tactic ist tt)
        (fun () -> interp_tactic ist te)
  | TacOrelse (tac1,tac2) ->
      Tacticals.tclORELSE (interp_tactic ist tac1) (interp_tactic ist tac2)
  | TacFirst l -> Tacticals.tclFIRST (List.map (interp_tactic ist) l)
  | TacSolve l -> Tacticals.tclSOLVE (List.map (interp_tactic ist) l)
  | TacArg _ -> Ftactic.run (val_interp (ensure_loc loc ist) tac) (fun v -> tactic_of_value ist v)
  | TacSelect (sel, tac) -> Goal_select.tclSELECT sel (interp_tactic ist tac)

  (* For extensions *)
  | TacAlias (s,l) ->
      let alias = Tacenv.interp_alias s in
      Proofview.tclProofInfo [@ocaml.warning "-3"] >>= fun (_name, poly) ->
      let (>>=) = Ftactic.bind in
      let interp_vars = Ftactic.List.map (fun v -> interp_tacarg ist v) l in
      let tac l =
        let addvar x v accu = Id.Map.add x v accu in
        let lfun = List.fold_right2 addvar alias.Tacenv.alias_args l ist.lfun in
        let trace = push_trace (loc,LtacNotationCall s) ist in
        let ist = {
          lfun
        ; poly
        ; extra = add_extra_loc loc (add_extra_trace trace ist.extra) } in
        val_interp ist alias.Tacenv.alias_body >>= fun v ->
        Ftactic.lift (tactic_of_value ist v)
      in
      let tac =
        Ftactic.with_env interp_vars >>= fun (env, lr) ->
        let name () = Pptactic.pr_alias (fun v -> print_top_val env v) 0 s lr in
        Proofview.Trace.name_tactic name (tac lr)
      (* spiwack: this use of name_tactic is not robust to a
         change of implementation of [Ftactic]. In such a situation,
         some more elaborate solution will have to be used. *)
      in
      let tac =
        let len1 = List.length alias.Tacenv.alias_args in
        let len2 = List.length l in
        if len1 = len2 then tac
        else
          let info = Exninfo.reify () in
          Tacticals.tclZEROMSG ~info
            (str "Arguments length mismatch: \
                  expected " ++ int len1 ++ str ", found " ++ int len2)
      in
      Ftactic.run tac (fun () -> Proofview.tclUNIT ())

  | TacML (opn,l) ->
      let trace = push_trace (Loc.tag ?loc @@ LtacMLCall tac) ist in
      let ist = { ist with extra = TacStore.set ist.extra f_trace trace; } in
      let tac = Tacenv.interp_ml_tactic opn in
      let args = Ftactic.List.map_right (fun a -> interp_tacarg ist a) l in
      let tac args =
        let name () = Pptactic.pr_extend (fun v -> print_top_val () v) 0 opn args in
        let (stack, _) = trace in
        Proofview.Trace.name_tactic name (catch_error_tac_loc loc stack (tac args ist))
      in
      Ftactic.run args tac

and force_vrec ist v : Val.t Ftactic.t =
  match to_tacvalue v with
  | Some (VRec (lfun,body)) -> val_interp {ist with lfun = !lfun} body
  | _ -> Ftactic.return v

and interp_ltac_reference ?loc' mustbetac ist r : Val.t Ftactic.t =
  match r with
  | ArgVar {loc;v=id} ->
      let v =
        try Id.Map.find id ist.lfun
        with Not_found -> in_gen (topwit wit_hyp) id
      in
      let open Ftactic in
      force_vrec ist v >>= begin fun v ->
      Ftactic.lift (propagate_trace ist loc id v) >>= fun v ->
      if mustbetac then Ftactic.return (coerce_to_tactic loc id v) else Ftactic.return v
      end
  | ArgArg (loc,r) ->
      Proofview.tclProofInfo [@ocaml.warning "-3"] >>= fun (_name, poly) ->
      let ids = extract_ids [] ist.lfun Id.Set.empty in
      let loc_info = (Option.default loc loc',LtacNameCall r) in
      let extra = TacStore.set ist.extra f_avoid_ids ids in
      let trace = push_trace loc_info ist in
      let extra = TacStore.set extra f_trace trace in
      let ist = { lfun = Id.Map.empty; poly; extra } in
      let appl = GlbAppl[r,[]] in
      (* We call a global ltac reference: add a loc on its executation only if not
         already in another global reference *)
      let ist = ensure_loc loc ist in
      let (stack, _) = trace in
      do_profile stack ~count_call:false
        (catch_error_tac_loc (* loc for interpretation *) loc stack
           (val_interp ~appl ist (Tacenv.interp_ltac r)))

and interp_tacarg ist arg : Val.t Ftactic.t =
  match arg with
  | TacGeneric (_,arg) -> interp_genarg ist arg
  | Reference r -> interp_ltac_reference false ist r
  | ConstrMayEval c ->
      Ftactic.enter begin fun gl ->
        let sigma = project gl in
        let env = Proofview.Goal.env gl in
        let (sigma,c_interp) = interp_constr_may_eval ist env sigma c in
        Proofview.tclTHEN (Proofview.Unsafe.tclEVARS sigma)
        (Ftactic.return (Value.of_constr c_interp))
      end
  | TacCall { v=(r,[]) } ->
      interp_ltac_reference true ist r
  | TacCall { loc; v=(f,l) } ->
      let (>>=) = Ftactic.bind in
      interp_ltac_reference true ist f >>= fun fv ->
      Ftactic.List.map (fun a -> interp_tacarg ist a) l >>= fun largs ->
      interp_app loc ist fv largs
  | TacFreshId l ->
      Ftactic.enter begin fun gl ->
        let id = interp_fresh_id ist (pf_env gl) (project gl) l in
        Ftactic.return (in_gen (topwit wit_intro_pattern) (CAst.make @@ IntroNaming (IntroIdentifier id)))
      end
  | TacPretype c ->
      Ftactic.enter begin fun gl ->
        let sigma = Proofview.Goal.sigma gl in
        let env = Proofview.Goal.env gl in
        let c = interp_uconstr ist env sigma c in
        let (sigma, c) = type_uconstr ist c env sigma in
        Proofview.tclTHEN (Proofview.Unsafe.tclEVARS sigma)
        (Ftactic.return (Value.of_constr c))
      end
  | TacNumgoals ->
      Ftactic.lift begin
        let open Proofview.Notations in
        Proofview.numgoals >>= fun i ->
        Proofview.tclUNIT (Value.of_int i)
      end
  | Tacexp t -> val_interp ist t

(* Interprets an application node *)
and interp_app loc ist fv largs : Val.t Ftactic.t =
  Proofview.tclProofInfo [@ocaml.warning "-3"] >>= fun (_name, poly) ->
  let (>>=) = Ftactic.bind in
  match to_tacvalue fv with
  | None | Some (VRec _) -> Tacticals.tclZEROMSG (str "Illegal tactic application.")
  (* if var=[] and body has been delayed by val_interp, then body
      is not a tactic that expects arguments.
      Otherwise Ltac goes into an infinite loop (val_interp puts
      a VFun back on body, and then interp_app is called again...) *)
  | Some (VFun(appl,trace,_,olfun,(_::_ as var),body)
         |VFun(appl,trace,_,olfun,([] as var),
               ( {CAst.v=(TacFun _)}
               | {CAst.v=(TacLetIn _)}
               | {CAst.v=(TacMatchGoal _)}
               | {CAst.v=(TacMatch _)}
               | {CAst.v=(TacArg _)} as body))) ->
    let (extfun,lvar,lval)=head_with_value (var,largs) in
    let fold accu (id, v) = Id.Map.add id v accu in
    let newlfun = List.fold_left fold olfun extfun in
    if List.is_empty lvar then
      begin wrap_error
          begin
            let ist =
              { lfun = newlfun
              ; poly
              ; extra = TacStore.set ist.extra f_trace trace
              } in
            let (stack, _) = trace in
            do_profile stack ~count_call:false
              (catch_error_tac_loc loc stack (val_interp (ensure_loc loc ist) body)) >>= fun v ->
            Ftactic.return (name_vfun (push_appl appl largs) v)
          end
          begin fun (e, info) ->
            Proofview.tclLIFT (debugging_exception_step ist false e (fun () -> str "evaluation")) <*>
            Proofview.tclZERO ~info e
          end
      end >>= fun v ->
      (* No errors happened, we propagate the trace *)
      let v = append_trace trace v in
      let call_debug env =
        Proofview.tclLIFT (debugging_step ist (fun () -> str"evaluation returns"++fnl()++pr_value env v)) in
      begin
        let open Genprint in
        match generic_val_print v with
        | TopPrinterBasic _ -> call_debug None
        | TopPrinterNeedsContext _ | TopPrinterNeedsContextAndLevel _ ->
          Proofview.Goal.enter (fun gl -> call_debug (Some (pf_env gl,project gl)))
      end <*>
      if List.is_empty lval then Ftactic.return v else interp_app loc ist v lval
    else
      Ftactic.return (of_tacvalue (VFun(push_appl appl largs,trace,loc,newlfun,lvar,body)))
  | Some (VFun(appl,trace,_,olfun,[],body)) ->
    let extra_args = List.length largs in
    let info = Exninfo.reify () in
    Tacticals.tclZEROMSG ~info
      (str "Illegal tactic application: got " ++
       str (string_of_int extra_args) ++
       str " extra " ++ str (String.plural extra_args "argument") ++
       str ".")

(* Gives the tactic corresponding to the tactic value *)
and tactic_of_value ist vle =
  match to_tacvalue vle with
  | Some vle ->
  begin match vle with
  | VFun (appl,trace,loc,lfun,[],t) ->
    Proofview.tclProofInfo [@ocaml.warning "-3"] >>= fun (_name, poly) ->
      let ist = {
        lfun = lfun;
        poly;
        (* todo: debug stack needs "trace" but that gives incorrect results for profiling
           Couldn't figure out how to make them play together.  Currently no way both can
           be enabled. Perhaps profiling should be redesigned as suggested in profile_ltac.mli *)
        extra = TacStore.set ist.extra f_trace (if Profile_tactic.get_profiling() then ([],[]) else trace); } in
      let tac = name_if_glob appl (eval_tactic_ist ist t) in
      let (stack, _) = trace in
      do_profile stack (catch_error_tac_loc loc stack tac)
  | VFun (appl,(stack,_),loc,vmap,vars,_) ->
     let tactic_nm =
       match appl with
         UnnamedAppl -> "An unnamed user-defined tactic"
       | GlbAppl apps ->
          let nms = List.map (fun (kn,_) -> string_of_qualid (Tacenv.shortest_qualid_of_tactic kn)) apps in
          match nms with
            []    -> assert false
          | kn::_ -> "The user-defined tactic \"" ^ kn ^ "\"" (* TODO: when do we not have a singleton? *)
     in
     let numargs = List.length vars in
     let givenargs =
       List.map (fun (arg,_) -> Names.Id.to_string arg) (Names.Id.Map.bindings vmap) in
     let numgiven = List.length givenargs in
     let info = Exninfo.reify () in
     catch_error_tac stack @@
     Tacticals.tclZEROMSG ~info
       Pp.(str tactic_nm ++ str " was not fully applied:" ++ spc() ++
           str "There is a missing argument for variable" ++ spc() ++ Name.print (List.hd vars) ++
           (if numargs > 1 then
              spc() ++ str "and " ++ int (numargs - 1) ++
              str " more"
            else mt()) ++ pr_comma() ++
           (match numgiven with
            | 0 ->
              str "no arguments at all were provided."
            | 1 ->
              str "1 argument was provided."
            | _ ->
              int numgiven ++ str " arguments were provided."))
  | VRec _ ->
    let info = Exninfo.reify () in
    Tacticals.tclZEROMSG ~info (str "A fully applied tactic is expected.")
  end
  | None ->
  if has_type vle (topwit wit_tactic) then
    let tac = out_gen (topwit wit_tactic) vle in
    tactic_of_value ist tac
  else
    let name =
      let Dyn (t, _) = vle in
      Val.repr t
    in
    let info = Exninfo.reify () in
    Tacticals.tclZEROMSG ~info (str "Expression does not evaluate to a tactic (got a " ++ str name ++ str ").")

(* Interprets the clauses of a recursive LetIn *)
and interp_letrec ist llc u =
  Proofview.tclUNIT () >>= fun () -> (* delay for the effects of [lref], just in case. *)
  let lref = ref ist.lfun in
  let fold accu ({v=na}, b) =
    let v = of_tacvalue (VRec (lref, CAst.make (TacArg b))) in
    Name.fold_right (fun id -> Id.Map.add id v) na accu
  in
  let lfun = List.fold_left fold ist.lfun llc in
  let () = lref := lfun in
  let ist = { ist with lfun } in
  val_interp ist u

(* Interprets the clauses of a LetIn *)
and interp_letin ist llc u =
  let rec fold lfun = function
  | [] ->
    let ist = { ist with lfun } in
    val_interp ist u
  | ({v=na}, body) :: defs ->
    Ftactic.bind (interp_tacarg ist body) (fun v ->
    fold (Name.fold_right (fun id -> Id.Map.add id v) na lfun) defs)
  in
  fold ist.lfun llc

(** [interp_match_success lz ist succ] interprets a single matching success
    (of type {!Tactic_matching.t}). *)
and interp_match_success ist { Tactic_matching.subst ; context ; terms ; lhs } =
  Proofview.tclProofInfo [@ocaml.warning "-3"] >>= fun (_name, poly) ->
  let (>>=) = Ftactic.bind in
  let lctxt = Id.Map.map Value.of_constr_context context in
  let hyp_subst = Id.Map.map Value.of_constr terms in
  let lfun = extend_values_with_bindings subst (lctxt +++ hyp_subst +++ ist.lfun) in
  let ist = { ist with lfun } in
  val_interp ist lhs >>= fun v ->
  match to_tacvalue v with
  | Some (VFun (appl,trace,loc,lfun,[],t)) ->
      let ist =
        { lfun = lfun
        ; poly
        ; extra = TacStore.set ist.extra f_trace trace
        } in
      let tac = eval_tactic_ist ist t in
      let dummy = VFun (appl, extract_trace ist, loc, Id.Map.empty, [],
        CAst.make (TacId [])) in
      let (stack, _) = trace in
      catch_error_tac stack (tac <*> Ftactic.return (of_tacvalue dummy))
  | _ -> Ftactic.return v


(** [interp_match_successes lz ist s] interprets the stream of
    matching of successes [s]. If [lz] is set to true, then only the
    first success is considered, otherwise further successes are tried
    if the left-hand side fails. *)
and interp_match_successes lz ist s =
   let general =
     let open Tacticals in
     let break (e, info) = match e with
       | FailError (0, _) -> None
       | FailError (n, s) -> Some (FailError (pred n, s), info)
       | _ -> None
     in
     Proofview.tclBREAK break s >>= fun ans -> interp_match_success ist ans
   in
    match lz with
    | General ->
        general
    | Select ->
      begin
        (* Only keep the first matching result, we don't backtrack on it *)
        let s = Proofview.tclONCE s in
        s >>= fun ans -> interp_match_success ist ans
      end
    | Once ->
        (* Once a tactic has succeeded, do not backtrack anymore *)
        Proofview.tclONCE general

(* Interprets the Match expressions *)
and interp_match ist lz constr lmr =
  let (>>=) = Ftactic.bind in
  begin wrap_error
    (interp_ltac_constr ist constr)
    begin function
      | (e, info) ->
          Proofview.tclLIFT (debugging_exception_step ist true e
          (fun () -> str "evaluation of the matched expression")) <*>
          Proofview.tclZERO ~info e
    end
  end >>= fun constr ->
  Ftactic.enter begin fun gl ->
    let sigma = project gl in
    let env = Proofview.Goal.env gl in
    let ilr = read_match_rule ist env sigma lmr in
    interp_match_successes lz ist (Tactic_matching.match_term env sigma constr ilr)
  end

(* Interprets the Match Context expressions *)
and interp_match_goal ist lz lr lmr =
    Ftactic.enter begin fun gl ->
      let sigma = project gl in
      let env = Proofview.Goal.env gl in
      let hyps = Proofview.Goal.hyps gl in
      let hyps = if lr then List.rev hyps else hyps in
      let concl = Proofview.Goal.concl gl in
      let ilr = read_match_rule ist env sigma lmr in
      interp_match_successes lz ist (Tactic_matching.match_goal env sigma hyps concl ilr)
    end

(* Interprets extended tactic generic arguments *)
and interp_genarg ist x : Val.t Ftactic.t =
    let open Ftactic.Notations in
    (* Ad-hoc handling of some types. *)
    let tag = genarg_tag x in
    if argument_type_eq tag (unquote (topwit (wit_list wit_hyp))) then
      interp_genarg_var_list ist x
    else if argument_type_eq tag (unquote (topwit (wit_list wit_constr))) then
      interp_genarg_constr_list ist x
    else
    let GenArg (Glbwit wit, x) as x0 = x in
    match wit with
    | ListArg wit ->
      let map x = interp_genarg ist (Genarg.in_gen (glbwit wit) x) in
      Ftactic.List.map map x >>= fun l ->
      Ftactic.return (Val.Dyn (Val.typ_list, l))
    | OptArg wit ->
      begin match x with
      | None -> Ftactic.return (Val.Dyn (Val.typ_opt, None))
      | Some x ->
        interp_genarg ist (Genarg.in_gen (glbwit wit) x) >>= fun x ->
        Ftactic.return (Val.Dyn (Val.typ_opt, Some x))
      end
    | PairArg (wit1, wit2) ->
      let (p, q) = x in
      interp_genarg ist (Genarg.in_gen (glbwit wit1) p) >>= fun p ->
      interp_genarg ist (Genarg.in_gen (glbwit wit2) q) >>= fun q ->
      Ftactic.return (Val.Dyn (Val.typ_pair, (p, q)))
    | ExtraArg s ->
      Geninterp.generic_interp ist x0

(** returns [true] for genargs which have the same meaning
    independently of goals. *)

and interp_genarg_constr_list ist x =
  Ftactic.enter begin fun gl ->
  let env = Proofview.Goal.env gl in
  let sigma = Proofview.Goal.sigma gl in
  let lc = Genarg.out_gen (glbwit (wit_list wit_constr)) x in
  let (sigma,lc) = interp_constr_list ist env sigma lc in
  let lc = in_list (val_tag wit_constr) lc in
  Proofview.tclTHEN (Proofview.Unsafe.tclEVARS sigma)
  (Ftactic.return lc)
  end

and interp_genarg_var_list ist x =
  Ftactic.enter begin fun gl ->
  let env = Proofview.Goal.env gl in
  let sigma = Proofview.Goal.sigma gl in
  let lc = Genarg.out_gen (glbwit (wit_list wit_hyp)) x in
  let lc = interp_hyp_list ist env sigma lc in
  let lc = in_list (val_tag wit_hyp) lc in
  Ftactic.return lc
  end

(* Interprets tactic expressions : returns a "constr" *)
and interp_ltac_constr ist e : EConstr.t Ftactic.t =
  let (>>=) = Ftactic.bind in
  begin wrap_error
      (val_interp ist e)
      begin function (err, info) -> match err with
        | Not_found ->
            Ftactic.enter begin fun gl ->
              let env = Proofview.Goal.env gl in
              Proofview.tclLIFT begin
                debugging_step ist (fun () ->
                  str "evaluation failed for" ++ fnl() ++
                    Pptactic.pr_glob_tactic env e)
              end
            <*> Proofview.tclZERO Not_found
            end
        | err -> Proofview.tclZERO ~info err
      end
  end >>= fun result ->
  Ftactic.enter begin fun gl ->
  let env = Proofview.Goal.env gl in
  let sigma = project gl in
  try
    let cresult = coerce_to_closed_constr env result in
    Proofview.tclLIFT begin
      debugging_step ist (fun () ->
        Pptactic.pr_glob_tactic env e ++ fnl() ++
          str " has value " ++ fnl() ++
          pr_econstr_env env sigma cresult)
    end <*>
    Ftactic.return cresult
  with CannotCoerceTo _ as exn ->
    let _, info = Exninfo.capture exn in
    let env = Proofview.Goal.env gl in
    Tacticals.tclZEROMSG ~info
      (str "Must evaluate to a closed term" ++ fnl() ++
       str "offending expression: " ++ fnl() ++ pr_inspect env e result)
  end


(* Interprets tactic expressions : returns a "tactic" *)
and interp_tactic ist tac : unit Proofview.tactic =
  Ftactic.run (val_interp ist tac) (fun v -> tactic_of_value ist v)

(* Provides a "name" for the trace to atomic tactics *)
and name_atomic ?env tacexpr tac : unit Proofview.tactic =
  begin match env with
  | Some e -> Proofview.tclUNIT e
  | None -> Proofview.tclENV
  end >>= fun env ->
  Proofview.tclEVARMAP >>= fun sigma ->
  let name () = Pptactic.pr_atomic_tactic env sigma tacexpr in
  Proofview.Trace.name_tactic name tac

(* Interprets a primitive tactic *)
and interp_atomic ist tac : unit Proofview.tactic =
  match tac with
  (* Basic tactics *)
  | TacIntroPattern (ev,l) ->
      Proofview.Goal.enter begin fun gl ->
        let env = Proofview.Goal.env gl in
        let sigma = project gl in
        let l' = interp_intro_pattern_list_as_list ist env sigma l in
        name_atomic ~env
          (TacIntroPattern (ev,l))
          (* spiwack: print uninterpreted, not sure if it is the
             expected behaviour. *)
          (Tactics.intro_patterns ev l')
      end
  | TacApply (a,ev,cb,cl) ->
      (* spiwack: until the tactic is in the monad *)
      Proofview.Trace.name_tactic (fun () -> Pp.str"<apply>") begin
      Proofview.Goal.enter begin fun gl ->
        let env = Proofview.Goal.env gl in
        let sigma = project gl in
        let l = List.map (fun (k,c) ->
            let loc, f = interp_open_constr_with_bindings_loc ist c in
            let f = Tacticals.tactic_of_delayed f in
            (k,(CAst.make ?loc f))) cb
        in
        let tac = match cl with
          | [] -> Tactics.apply_with_delayed_bindings_gen a ev l
          | cl ->
              let cl = List.map (interp_in_hyp_as ist env sigma) cl in
              List.fold_right (fun (id,ipat) -> Tactics.apply_delayed_in a ev id l ipat) cl Tacticals.tclIDTAC in
        tac
      end
      end
  | TacElim (ev,(keep,cb),cbo) ->
      Proofview.Goal.enter begin fun gl ->
        let env = Proofview.Goal.env gl in
        let sigma = project gl in
        let sigma, cb = interp_open_constr_with_bindings ist env sigma cb in
        let sigma, cbo = Option.fold_left_map (interp_open_constr_with_bindings ist env) sigma cbo in
        let named_tac =
          let tac = Tactics.elim ev keep cb cbo in
          name_atomic ~env (TacElim (ev,(keep,cb),cbo)) tac
        in
        Tacticals.tclWITHHOLES ev named_tac sigma
      end
  | TacCase (ev,(keep,cb)) ->
      Proofview.Goal.enter begin fun gl ->
        let sigma = project gl in
        let env = Proofview.Goal.env gl in
        let sigma, cb = interp_open_constr_with_bindings ist env sigma cb in
        let named_tac =
          let tac = Tactics.general_case_analysis ev keep cb in
          name_atomic ~env (TacCase(ev,(keep,cb))) tac
        in
        Tacticals.tclWITHHOLES ev named_tac sigma
      end
  | TacMutualFix (id,n,l) ->
      (* spiwack: until the tactic is in the monad *)
      Proofview.Trace.name_tactic (fun () -> Pp.str"<mutual fix>") begin
      Proofview.Goal.enter begin fun gl ->
        let env = pf_env gl in
        let f sigma (id,n,c) =
          let (sigma,c_interp) = interp_type ist env sigma c in
          sigma , (interp_ident ist env sigma id,n,c_interp) in
        let (sigma,l_interp) =
          Evd.MonadR.List.map_right (fun c sigma -> f sigma c) l (project gl)
        in
        Tacticals.tclTHEN (Proofview.Unsafe.tclEVARS sigma)
        (Tactics.mutual_fix (interp_ident ist env sigma id) n l_interp)
      end
      end
  | TacMutualCofix (id,l) ->
      (* spiwack: until the tactic is in the monad *)
      Proofview.Trace.name_tactic (fun () -> Pp.str"<mutual cofix>") begin
      Proofview.Goal.enter begin fun gl ->
        let env = pf_env gl in
        let f sigma (id,c) =
          let (sigma,c_interp) = interp_type ist env sigma c in
          sigma , (interp_ident ist env sigma id,c_interp) in
        let (sigma,l_interp) =
          Evd.MonadR.List.map_right (fun c sigma -> f sigma c) l (project gl)
        in
        Tacticals.tclTHEN (Proofview.Unsafe.tclEVARS sigma)
        (Tactics.mutual_cofix (interp_ident ist env sigma id) l_interp)
      end
      end
  | TacAssert (ev,b,t,ipat,c) ->
      Proofview.Goal.enter begin fun gl ->
        let env = Proofview.Goal.env gl in
        let sigma = project gl in
        let (sigma,c) =
          let expected_type =
            if Option.is_empty t then WithoutTypeConstraint else IsType in
          let flags = open_constr_use_classes_flags () in
          interp_open_constr ~expected_type ~flags ist env sigma c
        in
        let ipat' = interp_intro_pattern_option ist env sigma ipat in
        let tac = Option.map (Option.map (interp_tactic ist)) t in
        Tacticals.tclWITHHOLES ev
        (name_atomic ~env
          (TacAssert(ev,b,Option.map (Option.map ignore) t,ipat,c))
          (Tactics.forward b tac ipat' c)) sigma
      end
  | TacGeneralize cl ->
      Proofview.Goal.enter begin fun gl ->
        let sigma = project gl in
        let env = Proofview.Goal.env gl in
        let sigma, cl = interp_constr_with_occurrences_and_name_as_list ist env sigma cl in
        Tacticals.tclWITHHOLES false
        (name_atomic ~env
          (TacGeneralize cl)
          (Generalize.generalize_gen cl)) sigma
      end
  | TacLetTac (ev,na,c,clp,b,eqpat) ->
      Proofview.Goal.enter begin fun gl ->
        let env = Proofview.Goal.env gl in
        let sigma = project gl in
        let clp = interp_clause ist env sigma clp in
        let eqpat = interp_intro_pattern_naming_option ist env sigma eqpat in
        if Locusops.is_nowhere clp (* typically "pose" *) then
        (* We try to fully-typecheck the term *)
          let flags = open_constr_use_classes_flags () in
          let (sigma,c_interp) = interp_open_constr ~flags ist env sigma c in
          let na = interp_name ist env sigma na in
          let let_tac =
            if b then Tactics.pose_tac na c_interp
            else
              let id = Option.default (CAst.make IntroAnonymous) eqpat in
              let with_eq = Some (true, id) in
              Tactics.letin_tac with_eq na c_interp None Locusops.nowhere
          in
          Tacticals.tclWITHHOLES ev
          (name_atomic ~env
            (TacLetTac(ev,na,c_interp,clp,b,eqpat))
            let_tac) sigma
        else
        (* We try to keep the pattern structure as much as possible *)
          let let_pat_tac b na c cl eqpat =
            let id = Option.default (CAst.make IntroAnonymous) eqpat in
            let with_eq = if b then None else Some (true,id) in
            Tactics.letin_pat_tac ev with_eq na c cl
          in
          let (sigma',c) = interp_pure_open_constr ist env sigma c in
          name_atomic ~env
            (TacLetTac(ev,na,c,clp,b,eqpat))
            (Tacticals.tclWITHHOLES ev
               (let_pat_tac b (interp_name ist env sigma na)
                  (Some sigma,c) clp eqpat) sigma')
      end

  (* Derived basic tactics *)
  | TacInductionDestruct (isrec,ev,(l,el)) ->
      (* spiwack: some unknown part of destruct needs the goal to be
         prenormalised. *)
      Proofview.Goal.enter begin fun gl ->
        let env = Proofview.Goal.env gl in
        let sigma = project gl in
        let l =
          List.map begin fun (c,(ipato,ipats),cls) ->
            (* TODO: move sigma as a side-effect *)
             (* spiwack: the [*p] variants are for printing *)
            let cp = c in
            let c = interp_destruction_arg ist gl c in
            let ipato = interp_intro_pattern_naming_option ist env sigma ipato in
            let ipatsp = ipats in
            let ipats = interp_or_and_intro_pattern_option ist env sigma ipats in
            let cls = Option.map (interp_clause ist env sigma) cls in
            ((c,(ipato,ipats),cls),(cp,(ipato,ipatsp),cls))
          end l
        in
        let l,lp = List.split l in
        let sigma,el =
          Option.fold_left_map (interp_open_constr_with_bindings ist env) sigma el in
        Tacticals.tclTHEN (Proofview.Unsafe.tclEVARS sigma)
        (name_atomic ~env
          (TacInductionDestruct(isrec,ev,(lp,el)))
            (Induction.induction_destruct isrec ev (l,el)))
      end

  (* Conversion *)
  | TacReduce (r,cl) ->
      Proofview.Goal.enter begin fun gl ->
        let (sigma,r_interp) = interp_red_expr ist (pf_env gl) (project gl) r in
        Tacticals.tclTHEN (Proofview.Unsafe.tclEVARS sigma)
        (Tactics.reduce r_interp (interp_clause ist (pf_env gl) (project gl) cl))
      end
  | TacChange (check,None,c,cl) ->
      (* spiwack: until the tactic is in the monad *)
      Proofview.Trace.name_tactic (fun () -> Pp.str"<change>") begin
      Proofview.Goal.enter begin fun gl ->
        let is_onhyps = match cl.onhyps with
          | None | Some [] -> true
          | _ -> false
        in
        let is_onconcl = match cl.concl_occs with
          | AtLeastOneOccurrence | AllOccurrences | NoOccurrences -> true
          | _ -> false
        in
        let c_interp patvars env sigma =
          let lfun' = Id.Map.fold (fun id c lfun ->
            Id.Map.add id (Value.of_constr c) lfun)
            patvars ist.lfun
          in
          let ist = { ist with lfun = lfun' } in
            if is_onhyps && is_onconcl
            then Changed (interp_type ist env sigma c)
            else Changed (interp_constr ist env sigma c)
        in
        Tactics.change ~check None c_interp (interp_clause ist (pf_env gl) (project gl) cl)
      end
      end
  | TacChange (check,Some op,c,cl) ->
      (* spiwack: until the tactic is in the monad *)
      Proofview.Trace.name_tactic (fun () -> Pp.str"<change>") begin
      Proofview.Goal.enter begin fun gl ->
        let env = Proofview.Goal.env gl in
        let sigma = project gl in
        let op = interp_typed_pattern ist env sigma op in
        let to_catch = function Not_found -> true | e -> CErrors.is_anomaly e in
        let c_interp patvars env sigma =
          let lfun' = Id.Map.fold (fun id c lfun ->
            Id.Map.add id (Value.of_constr c) lfun)
            patvars ist.lfun
          in
          let env = ensure_freshness env in
          let ist = { ist with lfun = lfun' } in
            try
              Changed (interp_constr ist env sigma c)
            with e when to_catch e (* Hack *) ->
              user_err  (strbrk "Failed to get enough information from the left-hand side to type the right-hand side.")
        in
        Tactics.change ~check (Some op) c_interp (interp_clause ist env sigma cl)
      end
      end


  (* Equality and inversion *)
  | TacRewrite (ev,l,cl,by) ->
      Proofview.Goal.enter begin fun gl ->
        let l' = List.map (fun (b,m,(keep,c)) ->
          let f env sigma =
            interp_open_constr_with_bindings ist env sigma c
          in
          (b,m,keep,f)) l in
        let env = Proofview.Goal.env gl in
        let sigma = project gl in
        let cl = interp_clause ist env sigma cl in
        name_atomic ~env
          (TacRewrite (ev,l,cl,Option.map ignore by))
          (Equality.general_multi_rewrite ev l' cl
             (Option.map (fun by -> Tacticals.tclCOMPLETE (interp_tactic ist by),
               Equality.Naive)
                by))
      end
  | TacInversion (DepInversion (k,c,ids),hyp) ->
      Proofview.Goal.enter begin fun gl ->
        let env = Proofview.Goal.env gl in
        let sigma = project gl in
        let (sigma,c_interp) =
          match c with
          | None -> sigma , None
          | Some c ->
              let (sigma,c_interp) = interp_constr ist env sigma c in
              sigma , Some c_interp
        in
        let dqhyps = interp_declared_or_quantified_hypothesis ist env sigma hyp in
        let ids_interp = interp_or_and_intro_pattern_option ist env sigma ids in
        Tacticals.tclWITHHOLES false
        (name_atomic ~env
          (TacInversion(DepInversion(k,c_interp,ids),dqhyps))
          (Inv.dinv k c_interp ids_interp dqhyps)) sigma
      end
  | TacInversion (NonDepInversion (k,idl,ids),hyp) ->
      Proofview.Goal.enter begin fun gl ->
        let env = Proofview.Goal.env gl in
        let sigma = project gl in
        let hyps = interp_hyp_list ist env sigma idl in
        let dqhyps = interp_declared_or_quantified_hypothesis ist env sigma hyp in
        let ids_interp = interp_or_and_intro_pattern_option ist env sigma ids in
        name_atomic ~env
          (TacInversion (NonDepInversion (k,hyps,ids),dqhyps))
          (Inv.inv_clause k ids_interp hyps dqhyps)
      end
  | TacInversion (InversionUsing (c,idl),hyp) ->
      Proofview.Goal.enter begin fun gl ->
        let env = Proofview.Goal.env gl in
        let sigma = project gl in
        let (sigma,c_interp) = interp_constr ist env sigma c in
        let dqhyps = interp_declared_or_quantified_hypothesis ist env sigma hyp in
        let hyps = interp_hyp_list ist env sigma idl in
        Tacticals.tclTHEN (Proofview.Unsafe.tclEVARS sigma)
        (name_atomic ~env
          (TacInversion (InversionUsing (c_interp,hyps),dqhyps))
          (Leminv.lemInv_clause dqhyps c_interp hyps))
      end

(* Initial call for interpretation *)

let default_ist () =
  let extra = TacStore.set TacStore.empty f_debug (get_debug ()) in
  { lfun = Id.Map.empty; poly = false; extra = extra }

let eval_tactic t =
  if get_debug () <> DebugOff then
    Proofview.tclUNIT () >>= fun () -> (* delay for [default_ist] *)
    Proofview.tclLIFT (db_initialize true) <*>
    eval_tactic_ist (default_ist ()) t
  else
    Proofview.tclUNIT () >>= fun () -> (* delay for [default_ist] *)
    eval_tactic_ist (default_ist ()) t

let eval_tactic_ist ist t =
  Proofview.tclLIFT (db_initialize false) <*>
  eval_tactic_ist ist t

(** FFI *)

module Value = struct

  include Taccoerce.Value

  let of_closure ist tac =
    let closure = VFun (UnnamedAppl, extract_trace ist, None, ist.lfun, [], tac) in
    of_tacvalue closure

  let apply_expr f args =
    let fold arg (i, vars, lfun) =
      let id = Id.of_string ("x" ^ string_of_int i) in
      let x = Reference (ArgVar CAst.(make id)) in
      (succ i, x :: vars, Id.Map.add id arg lfun)
    in
    let (_, args, lfun) = List.fold_right fold args (0, [], Id.Map.empty) in
    let lfun = Id.Map.add (Id.of_string "F") f lfun in
    let ist = { (default_ist ()) with lfun = lfun; } in
    ist, CAst.make @@ TacArg (TacCall (CAst.make (ArgVar CAst.(make @@ Id.of_string "F"),args)))


  (** Apply toplevel tactic values *)
  let apply (f : value) (args: value list) =
    let ist, tac = apply_expr f args in
    eval_tactic_ist ist tac

  let apply_val (f : value) (args: value list) =
    let ist, tac = apply_expr f args in
    val_interp ist tac

end

(* globalization + interpretation *)


let interp_tac_gen lfun avoid_ids debug t =
  Proofview.tclProofInfo [@ocaml.warning "-3"] >>= fun (_name, poly) ->
  Proofview.Goal.enter begin fun gl ->
  let env = Proofview.Goal.env gl in
  let extra = TacStore.set TacStore.empty f_debug debug in
  let extra = TacStore.set extra f_avoid_ids avoid_ids in
  let ist = { lfun; poly; extra } in
  let ltacvars = Id.Map.domain lfun in
  eval_tactic_ist ist
    (intern_pure_tactic { (Genintern.empty_glob_sign ~strict:false env) with ltacvars } t)
  end

let interp t = interp_tac_gen Id.Map.empty Id.Set.empty (get_debug()) t

(* MUST be marshallable! *)
type ltac_expr = {
  global: bool;
  ast:  Tacexpr.raw_tactic_expr;
}

(* Used to hide interpretation for pretty-print, now just launch tactics *)
(* [global] means that [t] should be internalized outside of goals. *)
let hide_interp {global;ast} =
  let hide_interp env =
    let ist = Genintern.empty_glob_sign ~strict:false env in
    let te = intern_pure_tactic ist ast in
    let t = eval_tactic te in
    t
  in
  if global then
    Proofview.tclENV >>= fun env ->
    hide_interp env
  else
    Proofview.Goal.enter begin fun gl ->
      hide_interp (Proofview.Goal.env gl)
    end

let ComTactic.Interpreter hide_interp = ComTactic.register_tactic_interpreter "ltac1" hide_interp

(***************************************************************************)
(** Register standard arguments *)

let register_interp0 wit f =
  let open Ftactic.Notations in
  let interp ist v =
    f ist v >>= fun v -> Ftactic.return (Val.inject (val_tag wit) v)
  in
  Geninterp.register_interp0 wit interp

let def_intern ist x = (ist, x)
let def_subst _ x = x
let def_interp ist x = Ftactic.return x

let declare_uniform t =
  Genintern.register_intern0 t def_intern;
  Gensubst.register_subst0 t def_subst;
  register_interp0 t def_interp

let () =
  declare_uniform wit_unit

let () =
  declare_uniform wit_int

let () =
  declare_uniform wit_nat

let () =
  declare_uniform wit_bool

let () =
  declare_uniform wit_string

let lift f = (); fun ist x -> Ftactic.enter begin fun gl ->
  let env = Proofview.Goal.env gl in
  let sigma = Proofview.Goal.sigma gl in
  Ftactic.return (f ist env sigma x)
end

let lifts f = (); fun ist x -> Ftactic.enter begin fun gl ->
  let env = Proofview.Goal.env gl in
  let sigma = Proofview.Goal.sigma gl in
  let (sigma, v) = f ist env sigma x in
  Proofview.tclTHEN (Proofview.Unsafe.tclEVARS sigma)
    (* FIXME once we don't need to catch side effects *)
    (Proofview.tclTHEN (Proofview.Unsafe.tclSETENV (Global.env()))
       (Ftactic.return v))
end

let interp_bindings' ist bl = Ftactic.return begin fun env sigma ->
  interp_bindings ist env sigma bl
  end

let interp_constr_with_bindings' ist c = Ftactic.return begin fun env sigma ->
  interp_constr_with_bindings ist env sigma c
  end

let interp_open_constr_with_bindings' ist c = Ftactic.return begin fun env sigma ->
  interp_open_constr_with_bindings ist env sigma c
  end

let interp_destruction_arg' ist c = Ftactic.enter begin fun gl ->
  Ftactic.return (interp_destruction_arg ist gl c)
end

let interp_pre_ident ist env sigma s =
  s |> Id.of_string |> interp_ident ist env sigma |> Id.to_string

let () =
  register_interp0 wit_int_or_var (fun ist n -> Ftactic.return (interp_int_or_var ist n));
  register_interp0 wit_nat_or_var (fun ist n -> Ftactic.return (interp_int_or_var ist n));
  register_interp0 wit_smart_global (lift interp_reference);
  register_interp0 wit_ref (lift interp_reference);
  register_interp0 wit_pre_ident (lift interp_pre_ident);
  register_interp0 wit_ident (lift interp_ident);
  register_interp0 wit_hyp (lift interp_hyp);
  register_interp0 wit_intropattern (lift interp_intro_pattern) [@warning "-3"];
  register_interp0 wit_simple_intropattern (lift interp_intro_pattern);
  register_interp0 wit_clause_dft_concl (lift interp_clause);
  register_interp0 wit_constr (lifts interp_constr);
  register_interp0 Redexpr.wit_red_expr (lifts interp_red_expr);
  register_interp0 wit_quant_hyp (lift interp_declared_or_quantified_hypothesis);
  register_interp0 wit_open_constr (lifts interp_open_constr);
  register_interp0 wit_bindings interp_bindings';
  register_interp0 wit_constr_with_bindings interp_constr_with_bindings';
  register_interp0 wit_open_constr_with_bindings interp_open_constr_with_bindings';
  register_interp0 wit_destruction_arg interp_destruction_arg';
  ()

let () =
  let interp ist tac = Ftactic.return (Value.of_closure ist tac) in
  register_interp0 wit_tactic interp

let () =
  let interp ist tac = eval_tactic_ist ist tac >>= fun () -> Ftactic.return () in
  register_interp0 wit_ltac interp

let () =
  register_interp0 wit_uconstr (fun ist c -> Ftactic.enter begin fun gl ->
    Ftactic.return (interp_uconstr ist (Proofview.Goal.env gl) (Tacmach.project gl) c)
  end)

(***************************************************************************)
(* Other entry points *)

let val_interp ist tac k = Ftactic.run (val_interp ist tac) k

let interp_ltac_constr ist c k = Ftactic.run (interp_ltac_constr ist c) k

(***************************************************************************)
(* Backwarding recursive needs of tactic glob/interp/eval functions *)

let () =
  let eval ?loc ~poly env sigma tycon (used_ntnvars,tac) =
    let lfun = GlobEnv.lfun env in
    let () = assert (Id.Set.subset used_ntnvars (Id.Map.domain lfun)) in
    let extra = TacStore.set TacStore.empty f_debug (get_debug ()) in
    let ist = { lfun; poly; extra; } in
    let tac = eval_tactic_ist ist tac in
    (* EJGA: We should also pass the proof name if desired, for now
       poly seems like enough to get reasonable behavior in practice
     *)
    let name = Id.of_string "ltac_gen" in
    let sigma, ty = match tycon with
    | Some ty -> sigma, ty
    | None -> GlobEnv.new_type_evar env sigma ~src:(loc,Evar_kinds.InternalHole)
    in
    let (c, sigma) = Proof.refine_by_tactic ~name ~poly (GlobEnv.renamed_env env) sigma ty tac in
    let j = { Environ.uj_val = c; uj_type = ty } in
    (j, sigma)
  in
  GlobEnv.register_constr_interp0 wit_ltac_in_term eval

let vernac_debug b =
  set_debug (if b then Tactic_debug.DebugOn 0 else Tactic_debug.DebugOff)

let () =
  let open Goptions in
  declare_bool_option
    { optstage = Summary.Stage.Interp;
      optdepr  = None;
      optkey   = ["Ltac";"Debug"];
      optread  = (fun () -> get_debug () != Tactic_debug.DebugOff);
      optwrite = vernac_debug }

let () =
  let open Goptions in
  declare_bool_option
    { optstage = Summary.Stage.Interp;
      optdepr  = None;
      optkey   = ["Ltac"; "Backtrace"];
      optread  = (fun () -> !log_trace);
      optwrite = (fun b -> log_trace := b) }

open Basic
open Term
open Rule
open Signature

module T = Typing.Default
module R = Reduction.Default

exception DebugFlagNotRecognized of char

let set_debug_mode =
  String.iter (function
      | 'q' -> Debug.disable_flag Debug.D_warn
      | 'n' -> Debug.enable_flag  Debug.D_notice
      | 'o' -> Debug.enable_flag  Signature.D_module
      | 'c' -> Debug.enable_flag  Confluence.D_confluence
      | 'u' -> Debug.enable_flag  Typing.D_rule
      | 't' -> Debug.enable_flag  Typing.D_typeChecking
      | 'r' -> Debug.enable_flag  Reduction.D_reduce
      | 'm' -> Debug.enable_flag  Dtree.D_matching
      | c -> raise (DebugFlagNotRecognized c)
    )

type env_error =
  | EnvErrorType        of Typing.typing_error
  | EnvErrorSignature   of signature_error
  | EnvErrorRule        of rule_error
  | EnvErrorDep         of Dep.dep_error
  | NonLinearRule       of name
  | NotEnoughArguments  of ident * int * int * int
  | KindLevelDefinition of ident
  | ParseError          of string
  | BracketScopingError
  | AssertError

exception EnvError of loc * env_error

let raise_as_env lc = function
  | SignatureError        e -> raise (EnvError (lc, (EnvErrorSignature e)))
  | Typing.TypingError    e -> raise (EnvError (lc, (EnvErrorType      e)))
  | RuleError             e -> raise (EnvError (lc, (EnvErrorRule      e)))
  | ex -> raise ex

let check_arity = ref true

module type S =
sig
  val init        : string -> mident

  val get_signature : unit -> Signature.t
  val get_name    : unit -> mident
  val get_type    : loc -> name -> term
  val is_static   : loc -> name -> bool
  val get_dtree   : loc -> name -> Dtree.t
  val export      : unit -> unit
  val import      : loc -> mident -> unit
  val declare     : loc -> ident -> Signature.staticity -> term -> unit
  val define      : loc -> ident -> bool -> term -> term option -> unit
  val add_rules   : Rule.untyped_rule list -> (Subst.Subst.t * Rule.typed_rule) list
  val mk_entry    : Basic.mident -> Entry.entry -> unit

  val infer            : ?ctx:typed_context -> term         -> term
  val check            : ?ctx:typed_context -> term -> term -> unit
  val reduction        : ?ctx:typed_context -> ?red:(Reduction.red_cfg) -> term -> term
  val are_convertible  : ?ctx:typed_context -> term -> term -> bool
  val unsafe_reduction : ?red:(Reduction.red_cfg) -> term -> term

end

module Make(R:Reduction.S) =
struct

  module T = Typing.Make(R)

  (* Wrapper around Signature *)

  let sg = ref (Signature.make "noname")



  let init file =
    sg := Signature.make file;
    Signature.get_name !sg

  let get_name () = Signature.get_name !sg

  let get_signature () = !sg

  let get_type lc cst =
    try Signature.get_type !sg lc cst
    with e -> raise_as_env lc e

  let get_dtree lc cst =
    try Signature.get_dtree !sg lc cst
    with e -> raise_as_env lc e

  let export () =
    try Signature.export !sg
    with e -> raise_as_env dloc e

  let import lc md =
    try Signature.import !sg lc md
    with e -> raise_as_env lc e

  let _declare lc (id:ident) st ty : unit =
    match T.inference !sg ty with
    | Kind | Type _ -> Signature.add_declaration !sg lc id st ty
    | s -> raise (Typing.TypingError (Typing.SortExpected (ty,[],s)))

  let is_static lc cst = Signature.is_static !sg lc cst


  (*         Rule checking       *)

  (** Checks that all Miller variables are applied to at least
      as many arguments on the rhs as they are on the lhs (their arity). *)
  let _check_arity (r:rule_infos) : unit =
    let check l id n k nargs =
      let expected_args = r.arity.(n-k) in
      if nargs < expected_args
      then raise (EnvError (l, NotEnoughArguments (id,n,nargs,expected_args))) in
    let rec aux k = function
      | Kind | Type _ | Const _ -> ()
      | DB (l,id,n) ->
        if n >= k then check l id n k 0
      | App(DB(l,id,n),a1,args) when n>=k ->
        check l id n k (List.length args + 1);
        List.iter (aux k) (a1::args)
      | App (f,a1,args) -> List.iter (aux k) (f::a1::args)
      | Lam (_,_,None,b) -> aux (k+1) b
      | Lam (_,_,Some a,b) | Pi (_,_,a,b) -> (aux k a;  aux (k+1) b)
    in
    aux 0 r.rhs

  let _add_rules rs =
    let ris = List.map Rule.to_rule_infos rs in
    if !check_arity then List.iter _check_arity ris;
    Signature.add_rules !sg ris

  let _define lc (id:ident) (opaque:bool) (te:term) (ty_opt:Typing.typ option) : unit =
    let ty = match ty_opt with
      | None -> T.inference !sg te
      | Some ty -> T.checking !sg te ty; ty
    in
    match ty with
    | Kind -> raise (EnvError (lc, KindLevelDefinition id))
    | _ ->
      if opaque then Signature.add_declaration !sg lc id Signature.Static ty
      else
        let _ = Signature.add_declaration !sg lc id Signature.Definable ty in
        let cst = mk_name (get_name ()) id in
        let rule =
          { name= Delta(cst) ;
            ctx = [] ;
            pat = Pattern(lc, cst, []);
            rhs = te ;
          }
        in
        _add_rules [rule]

  let declare lc id st ty : unit =
    try _declare lc id st ty
    with e -> raise_as_env lc e

  let define lc id op te ty_opt : unit =
    try _define lc id op te ty_opt
    with e -> raise_as_env lc e

  let add_rules (rules: untyped_rule list) : (Subst.Subst.t * typed_rule) list =
    try
      let rs2 = List.map (T.check_rule !sg) rules in
      _add_rules rules;
      rs2
    with e -> raise_as_env (get_loc_rule (List.hd rules)) e

  let infer ?ctx:(ctx=[]) te =
    try
      let ty = T.infer !sg ctx te in
      (* We only verify that [ty] itself has a type (that we immediately
         throw away) if [ty] is not [Kind], because [Kind] does not have a
         type, but we still want [infer ctx Type] to produce [Kind] *)
      if ty <> mk_Kind then
        ignore(T.infer !sg ctx ty);
      ty
    with e -> raise_as_env (get_loc te) e

  let check ?ctx:(ctx=[]) te ty =
    try T.check !sg ctx te ty
    with e -> raise_as_env (get_loc te) e

  let _unsafe_reduction red te =
    R.reduction red !sg te

  let _reduction ctx red te =
    (* This is a safe reduction, so we check that [te] has a type
       before attempting to normalize it, but we only do so if [te]
       is not [Kind], because [Kind] does not have a type, but we
       still want to be able to reduce it *)
    if te <> mk_Kind then
      ignore(T.infer !sg ctx te);
    _unsafe_reduction red te

  let reduction ?ctx:(ctx=[]) ?red:(red=Reduction.default_cfg) te =
    try _reduction ctx red te
    with e -> raise_as_env (get_loc te) e

  let unsafe_reduction ?red:(red=Reduction.default_cfg) te =
    try _unsafe_reduction red te
    with e -> raise_as_env (get_loc te) e

  let are_convertible ?ctx:(ctx=[]) te1 te2 =
    try
      let ty1 = T.infer !sg ctx te1 in
      let ty2 = T.infer !sg ctx te2 in
      R.are_convertible !sg ty1 ty2 &&
      R.are_convertible !sg te1 te2
    with e -> raise_as_env (get_loc te1) e

  let mk_entry md e =
    let open Entry in
    let open Debug in
    match e with
    | Decl(lc,id,st,ty) ->
      debug D_notice "Declaration of constant '%a'." pp_ident id;
      declare lc id st ty
    | Def(lc,id,opaque,ty,te) ->
      let opaque_str = if opaque then " (opaque)" else "" in
      debug D_notice "Definition of symbol '%a'%s." pp_ident id opaque_str;
      define lc id opaque te ty
    | Rules(l,rs) ->
      let open Rule in
      List.iter (fun (r:untyped_rule) ->
          Debug.(debug D_notice "Adding rewrite rules: '%a'" Pp.print_rule_name r.name)) rs;
      let rs = add_rules rs in
      List.iter (fun (s,r) ->
          Debug.debug Debug.D_notice "%a@.with the following constraints: %a"
            pp_typed_rule r (Subst.Subst.pp (fun n -> let _,n,_ = List.nth r.ctx n in n)) s) rs
    | Eval(_,red,te) ->
      let te = reduction ~red te in
      Format.printf "%a@." Pp.print_term te
    | Infer(_,red,te) ->
      let  ty = infer te in
      let rty = reduction ~red ty in
      Format.printf "%a@." Pp.print_term rty
    | Check(l, assrt, neg, Convert(t1,t2)) ->
      let succ = (are_convertible t1 t2) <> neg in
      ( match succ, assrt with
        | true , false -> Format.printf "YES@."
        | true , true  -> ()
        | false, false -> Format.printf "NO@."
        | false, true  -> raise (EnvError (l,AssertError)) )
    | Check(l, assrt, neg, HasType(te,ty)) ->
      let succ = try check te ty; not neg with _ -> neg in
      ( match succ, assrt with
        | true , false -> Format.printf "YES@."
        | true , true  -> ()
        | false, false -> Format.printf "NO@."
        | false, true  -> raise (EnvError (l, AssertError)) )
    | DTree(lc,m,v) ->
      let m = match m with None -> get_name () | Some m -> m in
      let cst = mk_name m v in
      let forest = get_dtree lc cst in
      Format.printf "GDTs for symbol %a:@.%a" pp_name cst Dtree.pp_dforest forest
    | Print(_,s) -> Format.printf "%s@." s
    | Name(_,n) ->
      if not (mident_eq n md)
      then Debug.(debug D_warn "Invalid #NAME directive ignored.@.")
    | Require(lc,md) -> import lc md
end

module Default = Make(Reduction.Default)

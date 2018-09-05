open Basic
open Format
open Rule
open Term
open Dtree

type red_target   = Snf | Whnf
type red_strategy = ByName | ByValue | ByStrongValue

type red_cfg = {
  select   : (Rule.rule_name -> bool) option;
  nb_steps : int option; (* [Some 0] for no evaluation, [None] for no bound *)
  target   : red_target;
  strat    : red_strategy;
  beta     : bool;
  logger   : position -> Rule.rule_name -> term Lazy.t -> unit
}

let pp_red_cfg fmt cfg =
  let args =
    (match cfg.target   with Snf     -> ["SNF"]                             | _ -> []) @
    (match cfg.strat    with ByValue -> ["CBV"] | ByStrongValue -> ["CBSV"] | _ -> []) @
    (match cfg.nb_steps with Some i  -> [string_of_int i]                   | _ -> []) in
  Format.fprintf fmt "[%a]" (pp_list "," Format.pp_print_string) args

let default_cfg =
  {select=None; nb_steps=None; target=Snf; strat=ByName; beta=true; logger=fun _ _ _  -> () }

let selection  = ref None

let beta = ref true

let select f b =
  selection := f;
  beta := b

exception NotConvertible

let rev_mapi f l =
  let rec rmap_f i accu = function
    | [] -> accu
    | a::l -> rmap_f (i+1) (f i a :: accu) l
  in
  rmap_f 0 [] l

let rec zip_lists l1 l2 lst =
  match l1, l2 with
  | [], [] -> lst
  | s1::l1, s2::l2 -> zip_lists l1 l2 ((s1,s2)::lst)
  | _,_ -> raise NotConvertible

(* State *)

type env = term Lazy.t LList.t

(* A state {ctx; term; stack} is the state of an abstract machine that
represents a term where [ctx] is a ctx that contains the free variables
of [term] and [stack] represents the terms that [term] is applied to. *)
type state = {
  ctx:env;        (*context*)
  term : term;    (*term to reduce*)
  stack : stack;  (*stack*)
}
and stack = state list

let rec term_of_state {ctx;term;stack} : term =
  let t = ( if LList.is_empty ctx then term else Subst.psubst_l ctx term ) in
  match stack with
  | [] -> t
  | a::lst -> mk_App t (term_of_state a) (List.map term_of_state lst)

(* Pretty Printing *)

let pp_state fmt st =
  fprintf fmt "{ctx} {%a} {stack[%i]}\n" pp_term st.term (List.length st.stack)

let pp_stack fmt stck =
  fprintf fmt "[\n";
  List.iter (pp_state fmt) stck;
  fprintf fmt "]\n"

let pp_env fmt (ctx:env) =
  let pp_lazy_term out lt = pp_term fmt (Lazy.force lt) in
    pp_list ", " pp_lazy_term fmt (LList.lst ctx)

let pp_stack fmt (st:stack) =
  let aux fmt state =
    pp_term fmt (term_of_state state)
  in
    fprintf fmt "[ %a ]\n" (pp_list "\n | " aux) st

let pp_state ?(if_ctx=true) ?(if_stack=true) fmt { ctx; term; stack } =
  if if_ctx
  then fprintf fmt "{ctx=[%a];@." pp_env ctx
  else fprintf fmt "{ctx=[...](%i);@." (LList.len ctx);
  fprintf fmt "term=%a;@." pp_term term;
  if if_stack
  then fprintf fmt "stack=%a}@." pp_stack stack
  else fprintf fmt "stack=[...]}@.";
  fprintf fmt "@.%a@." pp_term (term_of_state {ctx; term; stack})

(* ********************* *)

type rw_strategy = Signature.t -> term -> term

type rw_state_strategy = Signature.t -> state -> state

type convertibility_test = Signature.t -> term -> term -> bool

let solve (sg:Signature.t) (reduce:rw_strategy) (depth:int) (pbs:int LList.t) (te:term) : term =
  try Matching.solve depth pbs te
  with Matching.NotUnifiable ->
    Matching.solve depth pbs (reduce sg te)

let unshift (sg:Signature.t) (reduce:rw_strategy) (q:int) (te:term) =
  try Subst.unshift q te
  with Subst.UnshiftExn ->
    Subst.unshift q (reduce sg te)

let get_context_syn (sg:Signature.t) (forcing:rw_strategy) (stack:stack) (ord:arg_pos LList.t) : env option =
  try Some (LList.map (
      fun p ->
        if ( p.depth = 0 )
        then lazy (term_of_state (List.nth stack p.position) )
        else
          Lazy.from_val
            (unshift sg forcing p.depth (term_of_state (List.nth stack p.position) ))
    ) ord )
  with Subst.UnshiftExn -> ( None )

let get_context_mp (sg:Signature.t) (forcing:rw_strategy) (stack:stack)
                   (pb_lst:abstract_problem LList.t) : env option =
  let aux ((pos,dbs):abstract_problem) : term Lazy.t =
    let res = solve sg forcing pos.depth dbs (term_of_state (List.nth stack pos.position)) in
    Lazy.from_val (Subst.unshift pos.depth res)
  in
  try Some (LList.map aux pb_lst)
  with Matching.NotUnifiable -> None
     | Subst.UnshiftExn -> assert false

let rec test (sg:Signature.t) (convertible:convertibility_test)
             (ctx:env) (constrs: constr list) : bool  =
  match constrs with
  | [] -> true
  | (Linearity (i,j))::tl ->
    let t1 = mk_DB dloc dmark i in
    let t2 = mk_DB dloc dmark j in
    if convertible sg (term_of_state { ctx; term=t1; stack=[] })
                      (term_of_state { ctx; term=t2; stack=[] })
    then test sg convertible ctx tl
    else false
  | (Bracket (i,t))::tl ->
    let t1 = Lazy.force (LList.nth ctx i) in
    let t2 = term_of_state { ctx; term=t; stack=[] } in
    if convertible sg t1 t2
    then test sg convertible ctx tl
    else
      (*FIXME: if a guard is not satisfied should we fail or only warn the user? *)
      raise (Signature.SignatureError( Signature.GuardNotSatisfied(get_loc t1, t1, t2) ))

let rec find_case (st:state) (cases:(case * dtree) list)
                  (default:dtree option) : (dtree*state list) option =
  match st, cases with
  | _, [] -> map_opt (fun g -> (g,[])) default
  | { term=Const (_,cst); stack } , (CConst (nargs,cst'),tr)::tl ->
     (* The case doesn't match if the identifiers differ or the stack is not
      * of the expected size. *)
     if name_eq cst cst' && List.length stack == nargs
     then Some (tr,stack)
     else find_case st tl default
  | { ctx; term=DB (l,x,n); stack } , (CDB (nargs,n'),tr)::tl ->
    begin
      assert ( ctx = LList.nil ); (* no beta in patterns *)
     (* The case doesn't match if the DB indices differ or the stack is not
      * of the expected size. *)
      if n == n' && List.length stack == nargs
      then Some (tr,stack)
      else find_case st tl default
    end
  | { ctx; term=Lam _; stack } , ( CLam , tr )::tl ->
    begin
      match term_of_state st with (*TODO could be optimized*)
      | Lam (_,_,_,te) ->
        Some ( tr , [{ ctx=LList.nil; term=te; stack=[] }] )
      | _ -> assert false
    end
  | _, _::tl -> find_case st tl default


(*TODO implement the stack as an array ? (the size is known in advance).*)
let gamma_rw (sg:Signature.t)
             (convertible:convertibility_test)
             (forcing:rw_strategy)
             (strategy:rw_state_strategy) : stack -> dtree -> (rule_name*env*term) option =
  let rec rw stack = function
    | Switch (i,cases,def) ->
       begin
         let arg_i = strategy sg (List.nth stack i) in
         match find_case arg_i cases def with
         | Some (g,[]) -> rw stack g
         | Some (g,s ) -> rw (stack@s) g
         (* This line highly depends on how the module dtree works.
         When a column is specialized, new columns are added at the end
         This is the reason why s is added at the end. *)
         | None -> None
       end
    | Test (rn,Syntactic ord, eqs, right, def) ->
      begin
        match get_context_syn sg forcing stack ord with
        | None -> bind_opt (rw stack) def
        | Some ctx ->
          if test sg convertible ctx eqs then Some (rn, ctx, right)
          else bind_opt (rw stack) def
      end
    | Test (rn,MillerPattern lst, eqs, right, def) ->
      begin
        match get_context_mp sg forcing stack lst with
        | None -> bind_opt (rw stack) def
        | Some ctx ->
          if test sg convertible ctx eqs then Some (rn, ctx, right)
          else bind_opt (rw stack) def
      end
  in
  rw

(* ********************* *)

(* Definition: a term is in weak-head-normal form if all its reducts
 * (including itself) have same 'shape' at the root.
 * The shape of a term could be computed like this:
 *
 * let rec shape = function
 *  | Type -> Type
 *  | Kind -> Kind
 *  | Pi _ -> Pi
 *  | Lam _ -> Lam
 *  | DB (_,_,n) -> DB n
 *  | Const (_,m,v) -> Const m v
 *  | App(f,a0,args) -> App (shape f,List.lenght (a0::args))

 * Property:
 * A (strongly normalizing) non weak-head-normal term can only have the form:
 * - (x:A => b) a c_1..c_n, this is a beta-redex potentially with extra arguments.
 * - or c a_1 .. a_n b_1 ..b_n with c a constant and c a'_1 .. a'_n is a gamma-redex
 *   where the (a'_i)s are reducts of (a_i)s.
 *)

(* This function reduces a state to a weak-head-normal form.
 * This means that the term [term_of_state (state_whnf sg state)] is a
 * weak-head-normal reduct of [term_of_state state].
 *
 * Moreover the returned state verifies the following properties:
 * - state.term is not an application
 * - state.term can only be a variable if term.ctx is empty
 *    (and therefore this variable is free in the corresponding term)
 * *)
let rec state_whnf (sg:Signature.t) (st:state) : state =
  match st with
  (* Weak heah beta normal terms *)
  | { term=Type _ }
  | { term=Kind }
  | { term=Pi _ }
  | { term=Lam _; stack=[] } -> st
  (* DeBruijn index: environment lookup *)
  | { ctx; term=DB (l,x,n); stack } ->
    if n < LList.len ctx
    then state_whnf sg { ctx=LList.nil; term=Lazy.force (LList.nth ctx n); stack }
    else { ctx=LList.nil; term=(mk_DB l x (n-LList.len ctx)); stack }
  (* Beta redex *)
  | { ctx; term=Lam (_,_,_,t); stack=p::s } ->
    if not !beta then st
    else state_whnf sg { ctx=LList.cons (lazy (term_of_state p)) ctx; term=t; stack=s }
  (* Application: arguments go on the stack *)
  | { ctx; term=App (f,a,lst); stack=s } ->
    (* rev_map + rev_append to avoid map + append*)
    let tl' = List.rev_map ( fun t -> {ctx;term=t;stack=[]} ) (a::lst) in
    state_whnf sg { ctx; term=f; stack=List.rev_append tl' s }
  (* Potential Gamma redex *)
  | { ctx; term=Const (l,n); stack } ->
    let trees = Signature.get_dtree sg !selection l n in
    match find_dtree (List.length stack) trees with
    | None -> st
    | Some (ar, tree) ->
      let s1, s2 = split_list ar stack in
      match gamma_rw sg are_convertible snf state_whnf s1 tree with
      | None -> st
      | Some (_,ctx,term) -> state_whnf sg { ctx; term; stack=s2 }

(* ********************* *)

(* Weak Head Normal Form *)
and whnf sg term = term_of_state ( state_whnf sg { ctx=LList.nil; term; stack=[] } )

(* Strong Normal Form *)
and snf sg (t:term) : term =
  match whnf sg t with
  | Kind | Const _ | DB _ | Type _ as t' -> t'
  | App (f,a,lst) -> mk_App (snf sg f) (snf sg a) (List.map (snf sg) lst)
  | Pi  (_,x,a,b) -> mk_Pi dloc x (snf sg a) (snf sg b)
  | Lam (_,x,a,b) -> mk_Lam dloc x (map_opt (snf sg) a) (snf sg b)

and are_convertible_lst sg : (term*term) list -> bool = function
  | [] -> true
  | (t1,t2)::lst ->
    are_convertible_lst sg
      ( if term_eq t1 t2 then lst
        else
          match whnf sg t1, whnf sg t2 with
          | Kind, Kind | Type _, Type _                 -> lst
          | Const (_,n), Const (_,n') when name_eq n n' -> lst
          | DB (_,_,n) , DB (_,_,n')  when n == n'      -> lst
          | App (f,a,args), App (f',a',args') ->
            (f,f') :: (a,a') :: (zip_lists args args' lst)
          | Lam (_,_,_,b), Lam (_,_,_ ,b') -> (b,b') :: lst
          | Pi  (_,_,a,b), Pi  (_,_,a',b') -> (a,a') :: (b,b') :: lst
          | _ -> raise NotConvertible)

(* Convertibility Test *)
and are_convertible sg t1 t2 =
  try are_convertible_lst sg [(t1,t2)]
  with NotConvertible -> false

let quick_reduction = function
  | Snf -> snf
  | Whnf -> whnf


let default_logger = fun _ _ _ -> ()
let default_stop   = fun ()  -> false

let logged_state_whnf ?log:(log=default_logger) ?stop:(stop=default_stop)
    (strat:red_strategy) (sg:Signature.t) =
  let rec aux (pos:Term.position) (st:state) : state =
    if stop () then st else
      match st, strat with
      (* Weak heah beta normal terms *)
      | { term=Type _ }, _
      | { term=Kind   }, _ -> st
        
      | { term=Pi _ }  , ByName
      | { term=Pi _ }  , ByValue -> st
      | { ctx=ctx; term=Pi(l,x,a,b) }, ByStrongValue ->
        let a' = term_of_state (aux (0::pos) {ctx=ctx; term=a; stack=[]}) in
        (** Should we also reduce b ? *)
        {st with term=mk_Pi l x a' b }

      (* Reducing type annotation *)
      | { ctx; term=Lam (l,x,Some ty,t); stack=[] }, ByStrongValue ->
        let ty' = term_of_state (aux (0::pos) {ctx=ctx; term=ty; stack=[]}) in
        {st with term=mk_Lam l x (Some ty') t}
      (* Empty stack *)
      | { term=Lam _; stack=[] }, _ -> st
      (* Beta redex with type annotation *)
      | { ctx; term=Lam (l,x,Some ty,t); stack=p::s }, ByStrongValue ->
        let ty' = term_of_state (aux (0::pos) {ctx=ctx; term=ty; stack=[]}) in
        if stop () || not !beta then {st with term=mk_Lam l x (Some ty') t}
        else
          let st' = { ctx=LList.cons (lazy (term_of_state p)) ctx; term=t; stack=s } in
          let _ = log pos Rule.Beta st' in
          aux pos st'
      (* Beta redex *)
      | { ctx; term=Lam (_,_,_,t); stack=p::s }, _ ->
        if not !beta then st
        else
          let st' = { ctx=LList.cons (lazy (term_of_state p)) ctx; term=t; stack=s } in
          let _ = log pos Rule.Beta st' in
          aux pos st'

      (* DeBruijn index: environment lookup *)
      | { ctx; term=DB (l,x,n); stack }, _ ->
        if n < LList.len ctx
        then aux pos { ctx=LList.nil; term=Lazy.force (LList.nth ctx n); stack }
        else { ctx=LList.nil; term=(mk_DB l x (n-LList.len ctx)); stack }

      (* Application: arguments go on the stack *)
      | { ctx; term=App (f,a,lst); stack=s }, ByName ->
        (* rev_map + rev_append to avoid map + append *)
        let tl' = List.rev_map ( fun t -> {ctx;term=t;stack=[]} ) (a::lst) in
        aux pos { ctx; term=f; stack=List.rev_append tl' s }

      (* Application: arguments are reduced to values then go on the stack *)
      | { ctx; term=App (f,a,lst); stack=s }, _ ->
        let tl' = rev_mapi ( fun i t -> aux (i::pos) {ctx;term=t;stack=[]} ) (a::lst) in
        aux pos { ctx; term=f; stack=List.rev_append tl' s }

      (* Potential Gamma redex *)
      | { ctx; term=Const (l,n); stack }, _ ->
        let trees = Signature.get_dtree sg !selection l n in
        match find_dtree (List.length stack) trees with
        | None -> st
        | Some (ar, tree) ->
          let s1, s2 = split_list ar stack in
          match gamma_rw sg are_convertible snf state_whnf s1 tree with
          | None -> st
          | Some (rn,ctx,term) ->
            let st' = { ctx; term; stack=s2 } in
            log pos rn st';
            aux pos st'
  in aux


let term_whnf st_whnf pos t = term_of_state (st_whnf pos { ctx=LList.nil; term=t; stack=[] } )

let term_snf st_whnf =
  let rec aux pos t =
    match term_whnf st_whnf pos t with
    | Kind | Const _ | DB _ | Type _ as t' -> t'
    | App (f,a,lst) ->
      mk_App (aux (0::pos) f) (aux (1::pos) a)
        (List.mapi (fun p arg -> aux (p::pos) arg) lst)
    | Pi  (_,x,a,b) -> mk_Pi dloc x (aux (0::pos) a) (aux (1::pos) b)
    | Lam (_,x,a,b) -> mk_Lam dloc x (map_opt (aux (0::pos)) a) (aux (1::pos) b)
  in aux

let reduction cfg sg te =
  select cfg.select cfg.beta;
  let log, stop =
    match cfg.nb_steps with
    | None   -> default_logger, default_stop
    | Some n ->
      let aux = ref n in
      (fun p rn st  -> cfg.logger p rn (lazy (term_of_state st)); decr aux),
      (fun () -> !aux <= 0)
  in
  let st_whnf = logged_state_whnf ~log:log ~stop:stop cfg.strat sg in
  let algo_red = match cfg.target with Snf -> term_snf | Whnf -> term_whnf in
  let te' = algo_red st_whnf [] te in
  select default_cfg.select default_cfg.beta;
  te'

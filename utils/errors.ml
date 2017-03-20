open Basic
open Format
open Rule
open Pp
open Term

let color = ref true
let errors_in_snf = ref false

let colored n s =
  if !color then "\027[3" ^ string_of_int n ^ "m" ^ s ^ "\027[m"
  else s

let green = colored 2
let orange = colored 3
let red = colored 1

let success fmt =
  eprintf "%s" (green "SUCCESS ");
  kfprintf (fun _ -> pp_print_newline err_formatter () ) err_formatter fmt


let prerr_loc lc =
  let (l,c) = of_loc lc in
    eprintf "line:%i column:%i " l c

let fail lc fmt =
  eprintf "%s" (red "ERROR ") ;
  prerr_loc lc;
  kfprintf (fun _ -> pp_print_newline err_formatter () ; raise Exit) err_formatter fmt

let pp_typed_context out = function
  | [] -> ()
  | (_::_) as ctx ->
    fprintf out " in context:\n%a" pp_typed_context ctx

let fail_typing_error err =
  let open Typing in
    match err with
      | KindIsNotTypable -> fail dloc "Kind is not typable."
      | ConvertibilityError (te,ctx,exp,inf) ->
          let exp = if !errors_in_snf then Env.unsafe_snf exp else exp in
          let inf = if !errors_in_snf then Env.unsafe_snf inf else inf in
            fail (get_loc te)
              "Error while typing '%a'%a.\nExpected: %a\nInferred: %a."
              pp_term te pp_typed_context ctx pp_term exp pp_term inf

      | VariableNotFound (lc,x,n,ctx) ->
          fail lc "The variable '%a' was not found in context:\n"
            pp_term (mk_DB lc x n) pp_typed_context ctx
      | SortExpected (te,ctx,inf) ->
          let inf = if !errors_in_snf then Env.unsafe_snf inf else inf in
            fail (Term.get_loc te)
              "Error while typing '%a'%a.\nExpected: a sort.\nInferred: %a."
              pp_term te pp_typed_context ctx pp_term inf
      | ProductExpected (te,ctx,inf) ->
          let inf = if !errors_in_snf then Env.unsafe_snf inf else inf in
            fail (get_loc te)
              "Error while typing '%a'%a.\nExpected: a product type.\nInferred: %a."
              pp_term te pp_typed_context ctx pp_term inf
      | InexpectedKind (te,ctx) ->
          fail (get_loc te)
            "Error while typing '%a'%a.\nExpected: anything but Kind.\nInferred: Kind."
            pp_term te pp_typed_context ctx
      | DomainFreeLambda lc ->
          fail lc "Cannot infer the type of domain-free lambda."
      | CannotInferTypeOfPattern (p,ctx) ->
          fail (get_loc_pat p)
            "Error while typing '%a'%a.\nThe type could not be infered."
            pp_pattern p pp_typed_context ctx
      | CannotSolveConstraints (r,cstr) ->
        fail (get_loc_pat r.pat)
          "Error while typing the rewrite rule\n%a\nCannot solve typing constraints:\n%a"
          print_untyped_rule (r, Preterm.RegularRule) (pp_list "\n" (fun out (_,t1,t2) -> fprintf out "%a ~~ %a" pp_term t1 pp_term t2)) cstr
      | BracketError1 (te,ctx) ->
        fail (get_loc te) "Error while typing the term { %a }%a.\n\
                           Brackets can only contain variables occuring \
                           on their left and cannot contain bound variables."
          pp_term te pp_typed_context ctx
     | BracketError2 (te,ctx,ty) ->
        fail (get_loc te) "Error while typing the term { %a }%a.\n\
                           The type of brackets can only contain variables occuring\
                           on their left and cannot contains bound variables."
          pp_term te pp_typed_context ctx
      | FreeVariableDependsOnBoundVariable (l,x,n,ctx,ty) ->
        fail l "Error while typing '%a[%i]'%a.\n\
                The type is not allowed to refer to bound variables.\n\
                Infered type:%a." pp_ident x n pp_typed_context ctx pp_term ty
      | NotImplementedFeature l -> fail l "Feature not implemented."

let fail_dtree_error err =
  let open Dtree in
    match err with
      | HeadSymbolMismatch (lc,hd1,hd2) ->
          fail lc "Unexpected head symbol '%a' \ (expected '%a')."
            print_ident hd1 print_ident hd2
      | ArityMismatch (lc,id) ->
          fail lc
            "All the rewrite rules for \ the symbol '%a' should have the same arity."
            pp_ident id


let fail_rule_error err =
  let open Rule in
  match err with
  | BoundVariableExpected pat ->
    fail (get_loc_pat pat)
      "The pattern of the rule is not a Miller pattern. The pattern '%a' is not a bound variable." pp_pattern pat
  | VariableBoundOutsideTheGuard te ->
    fail (get_loc te)
      "The term '%a' contains a variable bound outside the brackets."
      pp_term te
  | DistinctBoundVariablesExpected (lc,x) ->
    fail lc "The pattern of the rule is not a Miller pattern. The variable '%a' should be applied to distinct variables." pp_ident x
  | UnboundVariable (lc,x,pat) ->
    fail lc "The variables '%a' does not appear in the pattern '%a'."
      pp_ident x pp_pattern pat
  | AVariableIsNotAPattern (lc,id) ->
    fail lc "A variable is not a valid pattern."
  | NotEnoughArguments (lc,id,n,nb_args,exp_nb_args) ->
    fail lc "The variable '%a' is applied to %i argument(s) (expected: at least %i)."
      pp_ident id nb_args exp_nb_args
  | NonLinearRule r ->
    fail (Rule.get_loc_pat r.pat) "Non left-linear rewrite rule:\n%a.\n\
                               Maybe you forgot to pass the -nl option."
      pp_typed_rule r

let pp_cerr fmt err =
  let open Confluence in
  match  err with
  | NotConfluent cmd ->
    fprintf fmt "Checker's answer: NO.\nCommand: %s" cmd
  | MaybeConfluent cmd ->
    fprintf fmt "Checker's answer: MAYBE.\nCommand: %s" cmd
  | CCFailure cmd ->
    fprintf fmt "Checker's answer: ERROR.\nCommand: %s" cmd

let fail_signature_error err =
  let open Signature in
    match err with
      | FailToCompileModule (lc,md) ->
          fail lc "Fail to compile dependency '%a'." print_ident md
      | UnmarshalBadVersionNumber (lc,md) ->
          fail lc "Fail to open\ module '%s' (file generated by a different version?)." md
      | UnmarshalSysError (lc,md,msg) ->
          fail lc "Fail to open module '%s' (%s)." md msg
      | UnmarshalUnknown (lc,md) ->
          fail lc "Fail to open module '%s'." md
      | SymbolNotFound (lc,md,id) ->
          fail lc "Cannot find symbol '%a.%a'." print_ident md print_ident id
      | AlreadyDefinedSymbol (lc,id) ->
          fail lc "Already declared symbol '%a'." print_ident id
      | CannotBuildDtree err -> fail_dtree_error err
      | CannotMakeRuleInfos err -> fail_rule_error err
      | CannotAddRewriteRules (lc,id) ->
          fail lc
            "Cannot add rewrite\ rules for the static symbol '%a'.
Add the keyword 'def' to its declaration to make the symbol '%a' definable."
            print_ident id print_ident id
      | ConfluenceErrorRules (lc,rs,cerr) ->
        fail lc "Confluence checking failed when adding the rewrite rules below.\n%a\n%a"
          pp_cerr cerr (pp_list "\n" print_rule_infos) rs
      | ConfluenceErrorImport (lc,md,cerr) ->
        fail lc "Confluence checking failed when importing the module '%a'.\n%a"
          pp_ident md pp_cerr cerr

let fail_env_error = function
  | Env.EnvErrorSignature e -> fail_signature_error e
  | Env.EnvErrorType e -> fail_typing_error e
  | Env.KindLevelDefinition (lc,id) ->
    fail lc "Cannot add a rewrite rule for '%a' since it is a kind." print_ident id

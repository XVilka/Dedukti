open Basic
open Term
open Rule
open Cmd

let out = ref stdout
let deps = ref []
let md_to_file = ref []
let filename = ref ""
let verbose = ref false
let sorted = ref false

let print_out fmt = Printf.kfprintf (fun _ -> output_string !out "\n" ) !out fmt

(* This is similar to the function with the same name in
   kernel/signature.ml but this one answers wether the file exists and
   does not actually open the file *)
let rec find_dko_in_path name = function
  | [] -> false
  | dir :: path ->
      let filename = dir ^ "/" ^ name ^ ".dko" in
        if Sys.file_exists filename then
          true
        else
          find_dko_in_path name path

(* If the file for module m is not found in load path, add it to the
   list of dependencies *)
let add_dep m =
  let s = string_of_mident m in
  if not (find_dko_in_path s (get_path()))
  then begin
      let (name,m_deps) = List.hd !deps in
      if List.mem s (name :: m_deps) then ()
      else deps := (name, List.sort compare (s :: m_deps))::(List.tl !deps)
  end

let mk_prelude _ prelude_name =
  let name = string_of_mident prelude_name in
  deps := (name, [])::!deps


let rec mk_term = function
  | Kind | Type _ | DB _ -> ()
  | Const (_,cst) -> add_dep (md cst)
  | App (f,a,args) -> List.iter mk_term (f::a::args)
  | Lam (_,_,None,te) -> mk_term te
  | Lam (_,_,Some a,b)
  | Pi (_,_,a,b) -> ( mk_term a; mk_term b )


let rec mk_pattern = function
  | Var  (_,_,_,args) -> List.iter mk_pattern args
  | Pattern (_,cst,args) -> ( add_dep (md cst) ; List.iter mk_pattern args )
  | Lambda (_,_,te) -> mk_pattern te
  | Brackets t -> mk_term t

let mk_declaration _ _ _ t = mk_term t

let mk_definition _ _ = function
  | None -> mk_term
  | Some t -> mk_term t; mk_term

let mk_opaque = mk_definition

let mk_binding ( _,_, t) = mk_term t

let mk_ctx = List.iter mk_binding

let mk_prule (rule:untyped_rule) =
  mk_pattern rule.pat; mk_term rule.rhs

let mk_rules = List.iter mk_prule

let mk_command _ = function
  | Whnf t    | Hnf t          | Snf t
  | OneStep t | NSteps (_,t)
  | Infer t   | InferSnf t             -> mk_term t
  | Conv (t1,t2) | Check (t1,t2)       -> ( mk_term t1 ; mk_term t2 )
  | Gdt (_,_) | Print _                -> ()
  | Require md -> add_dep md
  | Other (_,lst)                      -> List.iter mk_term lst


let dfs graph visited start_node =
  let rec explore path visited node =
    if List.mem node path    then failwith "Circular dependencies"
    else
      if List.mem node visited then visited
      else
        let new_path = node :: path in
        let edges    = List.assoc node graph in
        let visited  = List.fold_left (explore new_path) visited edges in
        node :: visited
  in explore [] visited start_node

let topological_sort graph =
  List.fold_left (fun visited (node,_) -> dfs graph visited node) [] graph

let mk_ending () =
  let name, deps = List.hd !deps in
  md_to_file := (name, !filename)::!md_to_file;
  if not !sorted then
    print_out "%s.dko : %s %s" name !filename
              (String.concat " " (List.map (fun s -> s ^ ".dko") deps))
  else
    ()

let sort () = List.map (fun md -> List.assoc md !md_to_file) (List.rev (topological_sort !deps))

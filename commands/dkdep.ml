open Kernel
open Parsing
open Api

open Basic

module E            = Env.Make(Reduction.Default)
module ErrorHandler = Errors.Make(E)

let handle_file : string -> unit = fun file ->
    (* Initialisation. *)
    let md = E.init file in
    (* Actully parsing and gathering data. *)
    let input = open_in file in
    begin
      try Dep.handle md (fun f -> Parser.Parse_channel.handle md f input);
      with e -> ErrorHandler.graceful_fail (Some file) e
    end;
    close_in input

(** Output main program. *)

let output_deps : Format.formatter -> Dep.t -> unit = fun oc data ->
  let open Dep in
  let objfile src = Filename.chop_extension src ^ ".dko" in
  let output_line : mident -> deps -> unit =
    fun _ deps ->
       let file = deps.file in
       let deps = List.map (fun (_,src) -> objfile src) (MDepSet.elements deps.deps) in
       let deps = String.concat " " deps in
       try
         Format.fprintf oc "%s : %s %s@." (objfile file) file deps
       with _ -> () (* Dependency is missing *)
  in
  Hashtbl.iter output_line data

let output_sorted : Format.formatter -> Dep.t -> unit = fun _ data ->
  let deps = Dep.topological_sort data in
  Format.printf "%s@." (String.concat " " deps)

let _ =
  (* Parsing of command line arguments. *)
  let output  = ref stdout in
  let sorted  = ref false  in
  let args = Arg.align
    [ ( "-d"
      , Arg.String Env.set_debug_mode
      , "FLAGS enables debugging for all given flags:
      q : (quiet)    disables all warnings
      n : (notice)   notifies about which symbol or rule is currently treated
      o : (module)   notifies about loading of an external module (associated
                     to the command #REQUIRE)
      c : (confluence) notifies about information provided to the confluence
                     checker (when option -cc used)
      u : (rule)     provides information about type checking of rules
      t : (typing)   provides information about type-checking of terms
      r : (reduce)   provides information about reduction performed in terms
      m : (matching) provides information about pattern matching" )
    ; ( "-v"
      , Arg.Unit (fun () -> Env.set_debug_mode "montru")
      , " Verbose mode (equivalent to -d 'montru')" )
    ; ( "-q"
      , Arg.Unit (fun () -> Env.set_debug_mode "q")
      , " Quiet mode (equivalent to -d 'q')" )
    ; ( "-o"
      , Arg.String (fun n -> output := open_out n)
      , "FILE Outputs to file FILE" )
    ; ( "-s"
      , Arg.Set sorted
      , " Sort the source files according to their dependencies" )
    ; ( "--ignore"
      , Arg.Set Dep.ignore
      , " If some dependencies are not found, ignore them" )
    ; ( "-I"
      , Arg.String add_path
      , "DIR Add the directory DIR to the load path" ) ]
  in
  let usage = Format.sprintf "Usage: %s [OPTION]... [FILE]...
Compute the dependencies of the given Dedukti FILE(s).
For more information see https://github.com/Deducteam/Dedukti.
Available options:" Sys.argv.(0) in
  let files =
    let files = ref [] in
    Arg.parse args (fun f -> files := f :: !files) usage;
    List.rev !files
  in
  (* Actual work. *)
  List.iter handle_file files;
  let formatter = Format.formatter_of_out_channel !output in
  let output_fun = if !sorted then output_sorted else output_deps in
  output_fun formatter Dep.deps;
  Format.pp_print_flush formatter ();
  close_out !output

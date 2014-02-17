
open Types

module M =
struct

  let mk_prelude _ _ = assert false

  let mk_declaration lc id ty =
    let ty' = Inference.check_type [] ty in
      Env.add_decl lc id ty' ;
      Global.sprint (string_of_ident id ^ " is declared." )

  let mk_definition lc id ty_opt pte =
    let (te,ty) =
      match ty_opt with
        | None          -> Inference.infer [] pte
        | Some pty      ->
            let ty = Inference.check_type [] pty in
              ( Inference.check_term [] pte ty , ty )
    in
      Env.add_def lc id te ty ;
      Global.sprint (string_of_ident id ^ " is defined.")

  let mk_opaque lc id ty_opt pte =
    let (te,ty) =
      match ty_opt with
        | None          -> Inference.infer [] pte
        | Some pty      ->
            let ty = Inference.check_type [] pty in
             ( Inference.check_term [] pte ty , ty )
    in
      Env.add_decl lc id ty ;
      Global.sprint (string_of_ident id ^ " is defined.")

  let mk_rules (prs:prule list) =
    let (lc,hd) =
      match prs with
      | (_,(l,id,_),_)::_       -> (l,id)
      | _                       -> assert false
    in
    let rs = List.map Rule.check_rule prs in
      Env.add_rw lc hd rs ;
      Global.sprint ("Rules added.")

  let mk_command _ _ _ =
      failwith "Command not implemented." (*TODO*)

  let mk_ending _ = ()

end

module P = Parser.Make(M)

let rec parse lb =
  try
      while true do
        Global.sprint ">> ";
        P.line Lexer.token lb
      done
  with
    | LexerError (_,err)  | ParserError (_,err)
    | TypingError (_,err) | EnvError (_,err)
    | PatternError (_,err)                      ->  error lb err
    | P.Error                                   ->
        error lb ("Unexpected token '" ^ (Lexing.lexeme lb) ^ "'." )
    | EndOfFile                                 -> exit 0

and error lb err = Global.sprint err ; parse lb

let ascii_art =
"=============================================================================
 \\ \\    / /__| |__ ___ _ __  ___  | |_ ___  |   \\ ___ __| |_  _  _  _ | |_ _
  \\ \\/\\/ / -_) / _/ _ \\ '  \\/ -_) |  _/ _ \\ | |) / -_) _` | || || |/ /|  _(_)
   \\_/\\_/\\___|_\\__\\___/_|_|_\\___|  \\__\\___/ |___/\\___\\__,_|\\_,_||_|\\_\\ \\__|_|
=============================================================================
"

let  _ =
  Global.sprint ascii_art ;
  let v = hstring "toplevel" in
    Global.name := v ;
    Env.init v ;
    parse (Lexing.from_channel stdin)

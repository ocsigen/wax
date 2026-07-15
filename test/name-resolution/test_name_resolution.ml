(* Name resolution for go-to-definition: type-check a source with a
   [resolve_links] sink and print each resolved reference as
   "<use text>" @ use-span -> definition-span(s). Exercises module fields
   (functions, globals, types), locals (params, lets, shadowing) and labels. *)

open Wax_lang

module P =
  Wax_wasm.Parsing.Make
    (struct
      type t = Ast.location Ast.module_
    end)
    (Tokens)
    (Parser)
    (Parser_messages)
    (Lexer)

(* A location as line:col-line:col, 1-based line, 0-based byte column. *)
let span (l : Wax_utils.Ast.location) =
  let p (q : Lexing.position) =
    Printf.sprintf "%d:%d" q.pos_lnum (q.pos_cnum - q.pos_bol)
  in
  Printf.sprintf "%s-%s" (p l.loc_start) (p l.loc_end)

let slice src (l : Wax_utils.Ast.location) =
  String.sub src l.loc_start.pos_cnum (l.loc_end.pos_cnum - l.loc_start.pos_cnum)

let resolve name src =
  Printf.printf "=== %s ===\n" name;
  match P.parse_diagnostics ~filename:"t.wax" src with
  | Error e -> Printf.printf "parse error: %s\n\n" (String.trim e.message)
  | Ok (ast, _ctx) ->
      let d = Wax_utils.Diagnostic.collector ~source:src () in
      let links = ref [] in
      (try ignore (Typing.f_infer ~resolve_links:(Some links) d ast)
       with Wax_utils.Diagnostic.Aborted -> ());
      !links
      |> List.map (fun (r : Typing.reference) ->
          Printf.sprintf "%-8s @ %-9s -> %s"
            (Printf.sprintf "%S" (slice src r.use))
            (span r.use)
            (String.concat ", " (List.map span r.definitions)))
      (* The typer may resolve a name more than once; a use -> def link is the
         same each time, so present the distinct ones, ordered. *)
      |> List.sort_uniq compare
      |> List.iter print_endline;
      print_newline ()

let () =
  resolve "call, param, binop"
    "fn add(a: i32, b: i32) -> i32 { a + b; }\nfn use() -> i32 { add(1, 2); }\n";
  resolve "let shadowing"
    "fn f() -> i32 {\n  let x = 1;\n  let x = x + 1;\n  x;\n}\n";
  resolve "global and type"
    "type point = { x: i32, y: i32 };\n\
     const g: i32 = 0;\n\
     fn get_g(p: &point) -> i32 { g; }\n";
  resolve "label" "fn f() {\n  'outer: loop { br 'outer; }\n}\n"

(* Exercises the Wax panic-mode error recovery
   ([Wax_conversion.Driver.wax_parse_recover]): each source below has several
   independent syntax errors; recovery must report all of them (not just the
   first) and still return a best-effort AST. *)

let pos (p : Lexing.position) =
  Printf.sprintf "%d:%d" p.Lexing.pos_lnum (p.pos_cnum - p.pos_bol)

let first_line s =
  match String.index_opt s '\n' with Some i -> String.sub s 0 i | None -> s

let report name source =
  Printf.printf "=== %s ===\n" name;
  let ast, errors, _ctx =
    Wax_conversion.Driver.wax_parse_recover ~filename:"test.wax" source
  in
  Printf.printf "AST: %s\n"
    (match ast with Some _ -> "recovered" | None -> "none");
  Printf.printf "errors: %d\n" (List.length errors);
  List.iter
    (fun (e : Wax_wasm.Parsing.syntax_error) ->
      Printf.printf "  %s-%s: %s\n" (pos e.location.loc_start)
        (pos e.location.loc_end)
        (first_line (String.trim e.message)))
    errors;
  print_newline ()

let () =
  report "two broken statements, resync at ;"
    "fn f() -> i32 {\n    let x = ;\n    let y = * 2;\n    x + y;\n}\n";
  report "broken body, resync at } then clean re-entry"
    "fn a() -> i32 { let ; }\nfn b() -> i32 { 42; }\n";
  report "well-formed input has no errors"
    "fn g() -> i32 {\n    let a = 1;\n    a;\n}\n";
  report "error at end of input" "fn h() -> i32 { let =";
  (* No ';' or '}' survives before the next item; recovery resyncs on the 'fn'
     keyword and parses the following function cleanly. *)
  report "resync on leading 'fn' when no delimiter survives"
    "fn a( , ,\nfn b() -> i32 { 2; }\n";
  (* A closing ')' is a finer boundary than ';': recovery escapes the broken
     parenthesized sub-expression and salvages the rest of the statement. *)
  report "error inside parens, resync at )"
    "fn f() -> i32 { let x = (1 + ) + 7; let y = 3; x; }\n";
  report "error inside index, resync at ]"
    "fn f(a: i32) -> i32 { let x = a[@] + 1; x; }\n";
  (* A lexer error (bad character) is recorded as a diagnostic, then skipped:
     parsing resumes past it (here the ';' after the dropped '$' still errors),
     so recovery is not truncated by a stray character. *)
  report "lexer error is recorded and skipped"
    "fn f() -> i32 { let x = $; 1; }\n"

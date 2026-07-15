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
  (* The definition count matters for the end-of-input auto-close cases: a
     construct left open at EOF used to be unwound away, leaving [Some] but with
     the unclosed item dropped, so the count distinguishes a genuine partial AST
     from an empty shell. *)
  Printf.printf "AST: %s\n"
    (match ast with
    | Some m -> Printf.sprintf "recovered (%d defs)" (List.length m)
    | None -> "none");
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
    "fn f() -> i32 { let x = $; 1; }\n";
  (* A dropped statement separator is repaired by *inserting* a ';' (rather than
     skipping to a boundary): the state after a complete statement can shift ';'
     and the following statement then parses, so recovery reports a single
     precise "Missing ';'" and salvages the rest. *)
  report "missing ';' is repaired by insertion"
    "fn f() -> i32 {\n    let x = 1\n    let y = 2;\n    x + y;\n}\n";
  (* Insertion is validated before it is committed: here ';' is shiftable after
     the complete statement, but the offending '@' still cannot start the next
     one, so the repair is rejected and no spurious "Missing ';'" is added on top
     of the genuine error (only the standard diagnostic remains). *)
  report "unhelpful insertion is rejected, not reported"
    "fn f() -> i32 {\n    let x = 1 @\n    x;\n}\n";
  (* Nesting-aware skip: the ';' and '}' inside the 'do { 1; 2 }' group opened
     while skipping past the error do not resync the enclosing statement — the
     scan crosses the balanced group and resyncs at the *outer* ';', salvaging
     the rest as one error rather than cascading out to module level. *)
  report "skip crosses a nested group to the outer boundary"
    "fn f() -> i32 {\n    let x = @ do { 1; 2 };\n    let y = 3;\n    y;\n}\n";
  (* Auto-close at end of input: a construct still open at EOF is completed by
     inserting the closers (and a separator where a statement must be terminated
     first) the parser will accept, so it reduces into the AST instead of being
     unwound away. Without it the unclosed function would be dropped (0 defs). *)
  report "unclosed fn body is auto-closed at EOF"
    "fn f() -> i32 {\n    let x = 1;\n";
  report "complete fn kept, unclosed one recovered too"
    "fn a() -> i32 { 1; }\nfn b() -> i32 {\n    let y = 2;\n";
  report "auto-close inserts ')' then ';' then '}' at EOF"
    "fn f() -> i32 {\n    let x = (1 + 2\n"

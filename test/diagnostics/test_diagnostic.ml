open Wax_utils

let loc start_line start_col end_line end_col =
  let pos_start =
    {
      Lexing.pos_fname = "test.wax";
      pos_lnum = start_line;
      pos_bol = 0;
      pos_cnum = start_col;
    }
  in
  let pos_end =
    {
      Lexing.pos_fname = "test.wax";
      pos_lnum = end_line;
      pos_bol = 0;
      pos_cnum = end_col;
    }
  in
  { Ast.loc_start = pos_start; loc_end = pos_end }

let output = Diagnostic.channel_sink stdout

let test_case1 () =
  let source =
    "line 1\n\
     line 2\n\
     line 3\n\
     line 4\n\
     line 5 error here\n\
     line 6\n\
     line 7\n\
     line 8\n\
     line 9\n\
     line 10\n\
     line 11\n\
     line 12 related here\n\
     line 13\n\
     line 14\n"
  in
  Printf.printf "--- Case 1: Simple secondary label ---\n%!";
  Diagnostic.run ~output ~exit:false ~color:Never ~palette:Colors.wax_theme
    ~source:(Some source) (fun d ->
      let related =
        [
          {
            Diagnostic.location = loc 12 7 12 14;
            message = Message.text "defined here";
          };
        ]
      in
      Diagnostic.report d ~location:(loc 5 7 5 12) ~severity:Error ~related
        ~message:(Message.text "main error message")
        ())

let test_case2 () =
  let source =
    "line 1\nline 2 start here\nline 3 middle\nline 4 end here\nline 5\n"
  in
  Printf.printf "\n--- Case 2: Multi-line primary error ---\n%!";
  Diagnostic.run ~output ~exit:false ~color:Never ~palette:Colors.wax_theme
    ~source:(Some source) (fun d ->
      Diagnostic.report d ~location:(loc 2 7 4 15) ~severity:Error
        ~message:(Message.text "multi-line error")
        ())

let test_case3 () =
  let source =
    "line 1\n\
     line 2\n\
     line 3 secondary start\n\
     line 4 secondary middle\n\
     line 5 secondary end\n\
     line 6\n\
     line 7 main error\n\
     line 8\n"
  in
  Printf.printf "\n--- Case 3: Multi-line secondary label ---\n%!";
  Diagnostic.run ~output ~exit:false ~color:Never ~palette:Colors.wax_theme
    ~source:(Some source) (fun d ->
      let related =
        [
          {
            Diagnostic.location = loc 3 7 5 13;
            message = Message.text "multi-line secondary";
          };
        ]
      in
      Diagnostic.report d ~location:(loc 7 7 7 12) ~severity:Error ~related
        ~message:(Message.text "error with multi-line secondary")
        ())

let test_case4 () =
  let source =
    let rec gen i acc =
      if i > 100 then acc
      else gen (i + 1) (acc ^ "line " ^ string_of_int i ^ "\n")
    in
    gen 1 ""
  in
  Printf.printf "\n--- Case 4: Long multi-line span ---\n%!";
  Diagnostic.run ~output ~exit:false ~color:Never ~palette:Colors.wax_theme
    ~source:(Some source) (fun d ->
      Diagnostic.report d ~location:(loc 10 7 90 12) ~severity:Error
        ~message:(Message.text "long span error")
        ())

let test_case5 () =
  let source = "fn x {\nlet x = 10;\n" in
  Printf.printf "\n--- Case 5: Error at end of file (EOF) ---\n%!";
  Diagnostic.run ~output ~exit:false ~color:Never ~palette:Colors.wax_theme
    ~source:(Some source) (fun d ->
      let related =
        [
          {
            Diagnostic.location = loc 1 5 1 6;
            message = Message.text "This '{' might be unmatched.";
          };
        ]
      in
      Diagnostic.report d ~location:(loc 3 0 3 0) ~severity:Error ~related
        ~message:(Message.text "Expecting '}'.")
        ())

(* Regression guard for the latent ANSI-in-JSON bug: a message carrying styled
   atoms (an identifier, a type) must flatten to a plain, ANSI-free string —
   this is the path the JSON and short output formats take, so a type embedded
   there can never leak colour even on a colour terminal. Cram cannot simulate a
   TTY, so this is asserted here. *)
let test_case6 () =
  let msg =
    Message.(
      text "expected type" ++ styled Colors.Type "i32" ++ text "for"
      ++ ident "x")
  in
  let s = Message.to_plain_string msg in
  if String.contains s '\027' then (
    prerr_endline "to_plain_string leaked an ANSI escape";
    exit 1);
  Printf.printf "\n--- Case 6: plain render has no ANSI ---\n%s\n%!" s

let () =
  try
    test_case1 ();
    test_case2 ();
    test_case3 ();
    test_case4 ();
    test_case5 ();
    test_case6 ();
    flush stdout
  with
  | Unix.Unix_error (Unix.EPIPE, _, _) -> ()
  | e ->
      let s = Printexc.to_string e in
      if s <> "Exit" then (
        prerr_endline s;
        exit 1)

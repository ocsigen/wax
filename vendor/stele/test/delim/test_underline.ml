(* Unit checks of Parser_error_runtime.resolve, driven against a stub engine (the
   marker resolution is engine-agnostic, so no real lexer/parser is needed).

   A delimiter hint [<N>] underlines the FULL alias its label names — one column
   for a plain '[', two for a compound '[|' — reading the width from the label's
   quoted alias, so the marker itself carries no width; and it walks back from a
   cell that does not start at the delimiter, across line breaks if need be. A
   hedge subject [<^N>] underlines the whole construct, and is dropped when the
   construct is empty. The generator half — deriving the '[|'/'|]' pair and
   printing "This '[|' opens …" — is pinned by delim.expected. *)

(* A stub engine: a stack cell is just its source span; [get i] indexes from the
   top of a fixed array. *)
module Engine = struct
  type 'a env = (Lexing.position * Lexing.position) array
  type element = Lexing.position * Lexing.position

  let get i env = if i < Array.length env then Some env.(i) else None
  let positions el = el
end

module R = Parser_error_runtime.Make (Engine)

let pos ?(lnum = 1) ?(bol = 0) cnum =
  { Lexing.pos_fname = "t"; pos_lnum = lnum; pos_bol = bol; pos_cnum = cnum }

let cell a b = (pos a, pos b)

let check ~name ~source ~env ~message ~expect_text ~expect_start ~expect_len
    ?(expect_main = "") ?(expect_lnum = 1) ?(expect_bol = 0) () =
  let main, labels = R.resolve ~source ~env message in
  match labels with
  | [ l ] ->
      let start = l.R.loc_start.Lexing.pos_cnum in
      let len = l.R.loc_end.Lexing.pos_cnum - start in
      if main <> expect_main then
        failwith (Printf.sprintf "%s: unexpected residual message %S" name main);
      if l.R.text <> expect_text then
        failwith
          (Printf.sprintf "%s: label text %S <> %S" name l.R.text expect_text);
      if start <> expect_start then
        failwith (Printf.sprintf "%s: start %d <> %d" name start expect_start);
      if len <> expect_len then
        failwith (Printf.sprintf "%s: width %d <> %d" name len expect_len);
      if l.R.loc_start.Lexing.pos_lnum <> expect_lnum then
        failwith
          (Printf.sprintf "%s: line %d <> %d" name l.R.loc_start.Lexing.pos_lnum
             expect_lnum);
      if l.R.loc_start.Lexing.pos_bol <> expect_bol then
        failwith
          (Printf.sprintf "%s: line start %d <> %d" name
             l.R.loc_start.Lexing.pos_bol expect_bol);
      Printf.printf "%s: underline cols [%d,%d) width %d — ok\n" name start
        l.R.loc_end.Lexing.pos_cnum len
  | ls ->
      failwith
        (Printf.sprintf "%s: expected 1 label, got %d" name (List.length ls))

let () =
  (* A compound opener: "[|" at columns 0..2, so the hint underlines both. *)
  check ~name:"compound '[|'" ~source:"[| 1"
    ~env:[| cell 0 2 |]
    ~message:"<1>This '[|' opens the enclosing construct."
    ~expect_text:"This '[|' opens the enclosing construct." ~expect_start:0
    ~expect_len:2 ();
  (* A plain opener: "[" at column 0, so the hint underlines one column. *)
  check ~name:"plain '['" ~source:"[ 1"
    ~env:[| cell 0 1 |]
    ~message:"<1>This '[' opens the enclosing construct."
    ~expect_text:"This '[' opens the enclosing construct." ~expect_start:0
    ~expect_len:1 ();
  (* Walk-back: a spurious reduction surfaces a token just past the '['; the
     helper walks the source back over the blanks to the delimiter, then spans
     the named alias's width (one column for a plain '['). *)
  check ~name:"plain '[' walked back" ~source:"[  1"
    ~env:[| cell 3 4 |]
    ~message:"<1>This '[' opens the enclosing construct."
    ~expect_text:"This '[' opens the enclosing construct." ~expect_start:0
    ~expect_len:1 ();
  (* Walk-back across a line break: the '[' ends line 1 and the cell starts on
     line 2, so the underline moves back to line 1 with it. *)
  check ~name:"plain '[' walked back across lines" ~source:"x [\n  1"
    ~env:[| (pos ~lnum:2 ~bol:4 6, pos ~lnum:2 ~bol:4 7) |]
    ~message:"<1>This '[' opens the enclosing construct."
    ~expect_text:"This '[' opens the enclosing construct." ~expect_start:2
    ~expect_len:1 ~expect_lnum:1 ~expect_bol:0 ();
  (* A hedge subject underlines the cell's whole span. *)
  check ~name:"subject span" ~source:"{ 1; 2; )"
    ~env:[| cell 2 7 |]
    ~message:"Assuming that the statements are complete.\n<^1>these statements"
    ~expect_text:"these statements" ~expect_start:2 ~expect_len:5
    ~expect_main:"Assuming that the statements are complete." ();
  (* An empty construct leaves a zero-width span: the subject label is dropped
     and only the message remains. *)
  (match
     R.resolve ~source:"{ )"
       ~env:[| cell 2 2 |]
       "Assuming that the statements are complete.\n<^1>these statements"
   with
  | "Assuming that the statements are complete.", [] ->
      print_string "empty subject: dropped — ok\n"
  | main, ls ->
      failwith
        (Printf.sprintf "empty subject: got %S with %d label(s)" main
           (List.length ls)));
  (* A marker deeper than the live stack stays inline in the message. *)
  (match
     R.resolve ~source:"[ 1" ~env:[| cell 0 1 |] "Oops.\n<2>This '[' opens it."
   with
  | "Oops.\n<2>This '[' opens it.", [] ->
      print_string "marker past the stack: left inline — ok\n"
  | main, ls ->
      failwith
        (Printf.sprintf "marker past the stack: got %S with %d label(s)" main
           (List.length ls)));
  (* Only decimal digits make a depth: [<+1>] and [<0x1>] are prose. *)
  List.iter
    (fun m ->
      match R.resolve ~source:"[ 1" ~env:[| cell 0 1 |] m with
      | main, [] when main = m ->
          Printf.printf "%S: not a marker, left inline — ok\n" m
      | main, ls ->
          failwith
            (Printf.sprintf "%S: got %S with %d label(s)" m main
               (List.length ls)))
    [ "<+1>This '[' opens it."; "<0x1>This '[' opens it."; "<^+1>this" ];
  print_string "all underline checks passed\n"

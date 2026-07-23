(* Move 3 (runtime half): a delimiter hint underlines the FULL alias its label
   names — one column for a plain '[', two for a compound '[|'. The width is read
   from the label's quoted alias, so the [<N>] marker carries no width. This
   drives Parser_error_runtime.resolve directly against a stub engine (the width
   logic is engine-agnostic, so no real lexer/parser is needed); the generator
   half — deriving the '[|'/'|]' pair and printing "This '[|' opens …" — is
   pinned by delim.expected. *)

(* A stub engine: a stack cell is just its source span; [get i] indexes from the
   top of a fixed array. *)
module Engine = struct
  type 'a env = (Lexing.position * Lexing.position) array
  type element = Lexing.position * Lexing.position

  let get i env = if i < Array.length env then Some env.(i) else None
  let positions el = el
end

module R = Parser_error_runtime.Make (Engine)

let pos cnum =
  { Lexing.pos_fname = "t"; pos_lnum = 1; pos_bol = 0; pos_cnum = cnum }

let cell a b = (pos a, pos b)

let check ~name ~source ~env ~message ~expect_text ~expect_start ~expect_len =
  let main, labels = R.resolve ~source ~env message in
  match labels with
  | [ l ] ->
      let start = l.R.loc_start.Lexing.pos_cnum in
      let len = l.R.loc_end.Lexing.pos_cnum - start in
      if main <> "" then
        failwith (Printf.sprintf "%s: unexpected residual message %S" name main);
      if l.R.text <> expect_text then
        failwith
          (Printf.sprintf "%s: label text %S <> %S" name l.R.text expect_text);
      if start <> expect_start then
        failwith (Printf.sprintf "%s: start %d <> %d" name start expect_start);
      if len <> expect_len then
        failwith (Printf.sprintf "%s: width %d <> %d" name len expect_len);
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
    ~expect_len:2;
  (* A plain opener: "[" at column 0, so the hint underlines one column. *)
  check ~name:"plain '['" ~source:"[ 1"
    ~env:[| cell 0 1 |]
    ~message:"<1>This '[' opens the enclosing construct."
    ~expect_text:"This '[' opens the enclosing construct." ~expect_start:0
    ~expect_len:1;
  (* Walk-back: a spurious reduction surfaces a token just past the '['; the
     helper walks the source back over the blanks to the delimiter, then spans
     the named alias's width (one column for a plain '['). *)
  check ~name:"plain '[' walked back" ~source:"[  1"
    ~env:[| cell 3 4 |]
    ~message:"<1>This '[' opens the enclosing construct."
    ~expect_text:"This '[' opens the enclosing construct." ~expect_start:0
    ~expect_len:1;
  print_string "all underline checks passed\n"

(* The runnable end of the calc example: parse a file, evaluate it, and on a
   syntax error render a located diagnostic. This is the piece an adopter writes
   for their own tool — it drives Menhir's incremental engine, asks
   [Parser_messages] for the message at the error state, and hands it to
   [Parser_error_runtime] to resolve the [<N>] / [<^N>] markers against the live
   parser stack. The renderer below is deliberately tiny and self-contained (a
   real tool would use a diagnostics library such as Grace). *)

module I = Parser.MenhirInterpreter

(* The slice of the incremental engine [Parser_error_runtime] needs: reach a
   stack cell by depth, and read a cell's source span. *)
module R = Parser_error_runtime.Make (struct
  type 'a env = 'a I.env
  type element = I.element

  let get = I.get
  let positions (I.Element (_, _, p1, p2)) = (p1, p2)
end)

(* 0-based column of a position within its line. *)
let col (p : Lexing.position) = p.pos_cnum - p.pos_bol

(* Render a diagnostic in the rustc/ariadne style the tutorial shows: the
   message, a source arrow, the offending line, a caret under the error, then one
   caret-and-label per resolved marker. Single-line spans only — enough for the
   toy. *)
let render ~source ~primary main labels =
  let ps, pe = primary in
  let lnum = ps.Lexing.pos_lnum in
  let line_text =
    match List.nth_opt (String.split_on_char '\n' source) (lnum - 1) with
    | Some l -> l
    | None -> ""
  in
  let gutter = string_of_int lnum in
  let b = Buffer.create 128 in
  (* [resolve] keeps the message's trailing newline when it carries no labels
     (it only trims it when there are labels to append); trim it here so the
     header renders the same either way. *)
  Buffer.add_string b (Printf.sprintf "Error: %s\n" (String.trim main));
  Buffer.add_string b
    (Printf.sprintf " --> %s:%d:%d\n" ps.Lexing.pos_fname lnum (col ps + 1));
  Buffer.add_string b (Printf.sprintf "%s | %s\n" gutter line_text);
  (* Annotation lines put the '·' under the '|' so a caret lands under its source
     column. The source text starts one column past the '·', hence [col + 1]. *)
  let prefix = String.make (String.length gutter + 1) ' ' ^ "·" in
  let annotate (start : Lexing.position) (stop : Lexing.position) text =
    let width = max 1 (stop.pos_cnum - start.pos_cnum) in
    Buffer.add_string b
      (Printf.sprintf "%s%s%s%s\n" prefix
         (String.make (col start + 1) ' ')
         (String.make width '^')
         (if text = "" then "" else " " ^ text))
  in
  annotate ps pe "";
  List.iter (fun (l : R.label) -> annotate l.loc_start l.loc_end l.text) labels;
  prerr_string (Buffer.contents b)

let () =
  if Array.length Sys.argv < 2 then (
    prerr_endline "usage: calc FILE";
    exit 2);
  let path = Sys.argv.(1) in
  let source = In_channel.with_open_bin path In_channel.input_all in
  let lexbuf = Lexing.from_string source in
  Lexing.set_filename lexbuf (Filename.basename path);
  let fail_here main labels =
    render ~source
      ~primary:(Lexing.lexeme_start_p lexbuf, Lexing.lexeme_end_p lexbuf)
      main labels;
    exit 1
  in
  let rec loop checkpoint =
    match checkpoint with
    | I.InputNeeded _ ->
        let token =
          try Lexer.token lexbuf with Lexer.Lex_error msg -> fail_here msg []
        in
        let startp = Lexing.lexeme_start_p lexbuf in
        let endp = Lexing.lexeme_end_p lexbuf in
        loop (I.offer checkpoint (token, startp, endp))
    | I.Shifting _ | I.AboutToReduce _ -> loop (I.resume checkpoint)
    | I.HandlingError env ->
        let msg =
          try Parser_messages.message (I.current_state_number env)
          with Not_found -> "Syntax error."
        in
        let main, labels = R.resolve ~source ~env msg in
        fail_here main labels
    | I.Accepted results ->
        List.iter (fun v -> Printf.printf "=> %d\n" v) results
    | I.Rejected ->
        (* [HandlingError] reports and exits before the engine rejects, so this
           is unreachable; the branch just satisfies the match. *)
        prerr_endline "rejected";
        exit 1
  in
  loop (Parser.Incremental.prog lexbuf.Lexing.lex_curr_p)

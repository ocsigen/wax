(* Extract the Wax keyword list from the lexer into a JSON array, for the
   browser playground's lexical highlighter (see PLAYGROUND.md phase 2). The
   playground colours keywords itself (the toolchain's semantic tokens classify
   identifiers only), and rather than hardcode the list a third time it reads it
   from the one authoritative source — the lexer's keyword arms in
   src/lib-wax/lexer.ml, each of the form [| "word" -> TOKEN].

   Usage: [gen_keywords LEXER_ML], writing the JSON to stdout. LEXER_ML defaults
   to src/lib-wax/lexer.ml. *)

let read path = In_channel.with_open_bin path In_channel.input_all

let json_string buf s =
  Buffer.add_char buf '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | c -> Buffer.add_char buf c)
    s;
  Buffer.add_char buf '"'

let is_prefix ~prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

(* A lowercase-starting identifier of [a-z0-9_]. *)
let is_lower_ident s =
  s <> ""
  && s.[0] >= 'a'
  && s.[0] <= 'z'
  && String.for_all
       (fun c -> (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '_')
       s

(* Match a lexer arm [| "word" -> UPPERCASE], returning [word]. The arrow to an
   uppercase token constructor is what distinguishes a keyword arm from an
   operator arm (whose string is not a lowercase identifier anyway). *)
let extract_keyword line =
  let l = String.trim line in
  (* The arm prefix (bar, space, double-quote) is three characters. *)
  if not (is_prefix ~prefix:{|| "|} l) then None
  else
    let rest = String.sub l 3 (String.length l - 3) in
    match String.index_opt rest '"' with
    | None -> None
    | Some q ->
        let word = String.sub rest 0 q in
        let after =
          String.trim (String.sub rest (q + 1) (String.length rest - q - 1))
        in
        if
          is_lower_ident word
          && is_prefix ~prefix:"->" after
          &&
          let a = String.trim (String.sub after 2 (String.length after - 2)) in
          a <> "" && a.[0] >= 'A' && a.[0] <= 'Z'
        then Some word
        else None

let () =
  let path =
    if Array.length Sys.argv > 1 then Sys.argv.(1)
    else Filename.concat "src" (Filename.concat "lib-wax" "lexer.ml")
  in
  let lines = String.split_on_char '\n' (read path) in
  let kws = List.sort_uniq compare (List.filter_map extract_keyword lines) in
  if List.length kws < 20 then (
    (* A guard against silently emitting an empty/near-empty list if the lexer's
       shape ever changes: the playground would just lose keyword colouring, so
       fail the build loudly instead. *)
    prerr_endline
      "gen_keywords: too few keywords extracted; check lexer.ml shape";
    exit 1);
  let buf = Buffer.create 1024 in
  Buffer.add_char buf '[';
  List.iteri
    (fun i w ->
      if i > 0 then Buffer.add_string buf ", ";
      json_string buf w)
    kws;
  Buffer.add_string buf "]\n";
  print_string (Buffer.contents buf)

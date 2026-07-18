(* Extract the Wax snippets from docs/src/examples.md into a JSON array for the
   browser playground's "Examples" dropdown (see PLAYGROUND.md, Phase 1). Every
   `wax` fenced block in examples.md is compiled by test/cram-tests/docs-examples.t,
   so each extracted snippet is guaranteed to build — the playground reuses them
   rather than maintaining a second, unverified corpus.

   For each `## Title` section, the first ```wax fenced block becomes one entry
   `{ "title": ..., "code": ... }`. Sections without a Wax block are skipped.

   Usage: [gen_examples SRC_DIR], writing the JSON to stdout. SRC_DIR is the
   docs/src directory (holding examples.md). *)

let read path = In_channel.with_open_bin path In_channel.input_all

(* Minimal JSON string escaping — this build-time tool avoids a yojson
   dependency, so it hand-rolls the few escapes a code snippet can contain. *)
let json_string buf s =
  Buffer.add_char buf '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | c when Char.code c < 0x20 ->
          Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char buf c)
    s;
  Buffer.add_char buf '"'

let is_prefix ~prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

(* Extract [(title, code)] pairs: the first ```wax block under each `## ` H2. *)
let extract lines =
  let rec loop acc title have_block = function
    | [] -> List.rev acc
    | line :: rest when is_prefix ~prefix:"## " line ->
        let title = String.trim (String.sub line 3 (String.length line - 3)) in
        loop acc (Some title) false rest
    | line :: rest when (not have_block) && String.trim line = "```wax" -> (
        (* Gather the fenced block up to the closing ```. *)
        let rec gather body = function
          | [] -> (List.rev body, [])
          | l :: rest when String.trim l = "```" -> (List.rev body, rest)
          | l :: rest -> gather (l :: body) rest
        in
        let body, rest = gather [] rest in
        match title with
        | Some t ->
            let code = String.concat "\n" body in
            loop ((t, code) :: acc) title true rest
        | None -> loop acc title true rest)
    | _ :: rest -> loop acc title have_block rest
  in
  loop [] None false lines

let () =
  let dir = if Array.length Sys.argv > 1 then Sys.argv.(1) else "src" in
  let text = read (Filename.concat dir "examples.md") in
  let lines = String.split_on_char '\n' text in
  let examples = extract lines in
  let buf = Buffer.create 4096 in
  Buffer.add_string buf "[\n";
  List.iteri
    (fun i (title, code) ->
      if i > 0 then Buffer.add_string buf ",\n";
      Buffer.add_string buf "  {\"title\": ";
      json_string buf title;
      Buffer.add_string buf ", \"code\": ";
      json_string buf code;
      Buffer.add_string buf "}")
    examples;
  Buffer.add_string buf "\n]\n";
  print_string (Buffer.contents buf)

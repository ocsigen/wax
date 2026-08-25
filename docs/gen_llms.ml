(* Assemble the context-loadable Wax reference from the mdbook sources
   (docs/src), in reading order.

   See ADOPTION.md, Phase 6: Wax has almost no presence in any language model's
   training data, so an assistant writing Wax must be given the language in
   context. It will not crawl a multi-page mdbook, so the same content is
   assembled here into flat, self-contained files: one per-topic file per part
   below, committed under skills/wax/ so the `wax` agent skill can load each on
   demand, plus [reference], the whole book as a single file for embedding.

   Usage: [gen_llms SRC_DIR PART], writing the requested part to stdout.
   SRC_DIR is the docs/src directory; PART is a key of [parts] below (default
   [reference]). The page lists mirror docs/src/SUMMARY.md; keep them in sync
   when a page is added or removed. (Exceptions: playground.md is a raw-HTML UI
   page and editor.md is editor-setup documentation, not language reference, so
   both are deliberately excluded; introduction.md is human-facing installation
   and overview material, so it is kept out of the skill parts.) *)

let reference_preamble =
  {|# Wax language reference

Wax is a Rust-like surface syntax for WebAssembly. It converts bidirectionally
between Wax (source), WAT (WebAssembly text) and WASM (binary).

This file is the whole language reference assembled into one document, for use
as context by an AI coding assistant. Two things to lean on when writing Wax:

  1. Wax maps closely onto WAT and onto Rust. When unsure of a construct,
     derive it from "it is like this Rust, and it lowers to this WAT" — the
     Correspondence sections below give the mapping explicitly.
  2. The compiler is the source of truth. Check any Wax you produce with
     `wax check FILE.wax` (exit 0 = valid; 128 = rejected, with diagnostics on
     stderr) and iterate on the errors.

The sections below are the documentation pages concatenated in reading order.
|}

let correspondence_preamble =
  {|# Wax and WebAssembly correspondence

How each WebAssembly construct is written in Wax, assembled from the
correspondence chapter of the documentation: types, instructions, module
fields, and round-tripping guarantees.
|}

let correspondence_files =
  [
    "correspondence/intro.md";
    "correspondence/types.md";
    "correspondence/instructions.md";
    "correspondence/module_fields.md";
    "correspondence/round_trip.md";
  ]

(* PART -> (preamble, docs/src paths in docs/src/SUMMARY.md order). *)
let parts =
  [
    ( "reference",
      ( Some reference_preamble,
        [
          "introduction.md";
          "features.md";
          "language.md";
          "cheatsheet.md";
          "examples.md";
        ]
        @ correspondence_files @ [ "cli.md" ] ) );
    ("cheatsheet", (None, [ "cheatsheet.md" ]));
    ("language", (None, [ "language.md"; "features.md" ]));
    ("examples", (None, [ "examples.md" ]));
    ("correspondence", (Some correspondence_preamble, correspondence_files));
    ("cli", (None, [ "cli.md" ]));
  ]

let replace_all s ~sub ~by =
  let n = String.length sub in
  let buf = Buffer.create (String.length s) in
  let rec go i =
    if i + n > String.length s then
      Buffer.add_substring buf s i (String.length s - i)
    else if String.sub s i n = sub then (
      Buffer.add_string buf by;
      go (i + n))
    else (
      Buffer.add_char buf s.[i];
      go (i + 1))
  in
  go 0;
  Buffer.contents buf

(* The mdbook pages cross-link each other with relative links that assume the
   book layout. Rewrite them to the assembled file names so a link stays
   meaningful between the skill files: the correspondence pages become
   correspondence.md (fragments survive, as the pages are concatenated with
   their headings intact), features.md is folded into language.md, and the ./
   and ../ prefixes are dropped. Links to the excluded pages (editor.md,
   playground.md) are left alone. *)
let link_rewrites =
  [ ("](./", "]("); ("](../", "](") ]
  @ List.map
      (fun page -> ("](" ^ page, "](correspondence.md"))
      (correspondence_files
      @ [ "types.md"; "instructions.md"; "module_fields.md"; "round_trip.md" ])
  @ [ ("](features.md", "](language.md") ]

let rewrite_links s =
  List.fold_left (fun s (sub, by) -> replace_all s ~sub ~by) s link_rewrites

let read path = In_channel.with_open_bin path In_channel.input_all

let () =
  let dir = if Array.length Sys.argv > 1 then Sys.argv.(1) else "src" in
  let part = if Array.length Sys.argv > 2 then Sys.argv.(2) else "reference" in
  let preamble, files =
    match List.assoc_opt part parts with
    | Some p -> p
    | None ->
        Printf.eprintf "gen_llms: unknown part %S (one of: %s)\n" part
          (String.concat ", " (List.map fst parts));
        exit 2
  in
  Option.iter print_string preamble;
  List.iteri
    (fun i rel ->
      let path = Filename.concat dir rel in
      (* A comment marker keeps each page's provenance visible without adding a
         heading that would collide with the page's own H1. *)
      if i > 0 || preamble <> None then print_string "\n\n";
      Printf.printf "<!-- docs/src/%s -->\n\n" rel;
      print_string (rewrite_links (read path)))
    files

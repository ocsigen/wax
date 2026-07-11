(* Generate a single-file, context-loadable Wax reference ("llms.txt") by
   concatenating the mdbook sources in reading order.

   See ADOPTION.md, Phase 6: Wax has almost no presence in any language model's
   training data, so an assistant writing Wax must be given the language in
   context. It will not crawl a multi-page mdbook, so the same content is
   assembled here into one flat, self-contained file (no cross-links) that fits
   in a model's context window. The same payload is what `wax mcp`'s
   `wax_reference` tool should serve and what a docs site hosts at
   `/llms.txt`.

   Usage: [gen_llms SRC_DIR], writing the reference to stdout. SRC_DIR is the
   docs/src directory. The file list below mirrors docs/src/SUMMARY.md; keep the
   two in sync when a page is added or removed. *)

let preamble =
  {|# Wax language reference

Wax is a Rust-like surface syntax for WebAssembly. It converts bidirectionally
between Wax (source), WAT (WebAssembly text) and WASM (binary).

This file is the whole language reference assembled into one document, for use
as context by an AI coding assistant. Two things to lean on when writing Wax:

  1. Wax maps closely onto WAT and onto Rust. When unsure of a construct,
     derive it from "it is like this Rust, and lowers to this WAT" — the
     Correspondence sections below give the mapping explicitly.
  2. The compiler is the source of truth. Check any Wax you produce with
     `wax check FILE.wax` (exit 0 = valid; 128 = rejected, with diagnostics on
     stderr) and iterate on the errors.

The sections below are the documentation pages concatenated in reading order.
|}

(* docs/src paths, in docs/src/SUMMARY.md order. *)
let files =
  [
    "introduction.md";
    "features.md";
    "language.md";
    "cheatsheet.md";
    "examples.md";
    "correspondence/intro.md";
    "correspondence/types.md";
    "correspondence/instructions.md";
    "correspondence/module_fields.md";
    "cli.md";
  ]

let read path = In_channel.with_open_bin path In_channel.input_all

let () =
  let dir = if Array.length Sys.argv > 1 then Sys.argv.(1) else "src" in
  print_string preamble;
  List.iter
    (fun rel ->
      let path = Filename.concat dir rel in
      (* A comment marker keeps each page's provenance visible without adding a
         heading that would collide with the page's own H1. *)
      Printf.printf "\n\n<!-- docs/src/%s -->\n\n" rel;
      print_string (read path))
    files

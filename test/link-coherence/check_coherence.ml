(* Cross-checks that the three independent encodings of the WebAssembly binary
   format meeting in the linker agree with one another:

   - [Wax_wasm.Wasm_parser]      : bytes -> AST   (the decoder)
   - [Wax_wasm.Wasm_output]      : AST   -> bytes (the encoder)
   - [Wax_linker.Wasm_link.Scan] : an in-place byte rewriter that re-derives LEB
       decoding, section framing and instruction boundaries from scratch so it
       can renumber index immediates without materialising the AST.

   Two properties are checked over a corpus of real binary modules named on the
   command line (the dune rule produces them from the round-trip [.wat] fixtures
   with the [wax] CLI, the trusted producer):

   1. Identity-link idempotence. Merging a single input, keeping every export
      and resolving nothing, must be a fixed point of the linker: [link m] and
      [link (link m)] are byte-identical, and [link m] reparses. This drives the
      whole triangle -- Scan rewrites (with identity index maps), Wasm_output
      re-emits the sections it owns, Wasm_parser reads the result back -- and
      asserts they compose to the identity on the linker's own output. (Whether
      the index *remapping* is semantically right is the reference-interpreter
      suite's job; this is the structural/layout guarantee.)

   2. Instruction-offset agreement. [Wasm_link.get_instruction_offsets] (Scan's
      instruction-marking byte walk) must agree with an independent walk over
      the parsed AST's instruction locations: the two must agree on the function
      count, every instruction start the parser records must be one of Scan's
      marks, and every *extra* mark Scan makes must fall on a structural
      delimiter byte (the [end]/[else]/[catch] bytes the parser folds into its
      block nodes instead of emitting as instructions). A desynchronised
      immediate walk in Scan shifts its marks off the real boundaries and is
      caught here.

   Output is a golden report: a header per file only when that file shows a
   mismatch, empty when the three agree on every module. *)

module Ast = Wax_wasm.Ast
module Binary = Wax_wasm.Ast.Binary
module Wasm_parser = Wax_wasm.Wasm_parser
module Wasm_link = Wax_linker.Wasm_link
module IntSet = Set.Make (Int)

let read_file f = In_channel.with_open_bin f In_channel.input_all

(* Failures for the current file accumulate here and print under one header, so
   a clean run prints nothing at all. *)
let problems = ref []
let note fmt = Printf.ksprintf (fun s -> problems := s :: !problems) fmt

let parse bytes =
  match
    Wax_utils.Diagnostic.run ~color:Wax_utils.Colors.Never
      ~palette:Wax_utils.Colors.wat_theme ~source:None ~exit:false (fun d ->
        Wasm_parser.module_ d bytes)
  with
  | m -> Some m
  | exception Wax_utils.Diagnostic.Aborted -> None

(* --- Property 1: identity-link idempotence --- *)

let link bytes =
  let out = Filename.temp_file "coherence" ".wasm" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove out with Sys_error _ -> ())
    (fun () ->
      ignore
        (Wasm_link.f
           [
             {
               Wasm_link.module_name = "m";
               file = "input.wasm";
               code = Some bytes;
               opt_source_map = None;
             };
           ]
           ~output_file:out
          : Wax_linker.Source_map.t);
      read_file out)

let check_idempotence bytes =
  let o1 = link bytes in
  let o2 = link o1 in
  if not (String.equal o1 o2) then
    note
      "identity link is not idempotent: link m is %d bytes, link (link m) is \
       %d bytes"
      (String.length o1) (String.length o2);
  match parse o1 with
  | None -> note "linked output does not reparse"
  | Some _ -> ()

(* --- Property 2: instruction-offset agreement --- *)

(* The [end]/[else]/[catch]/[delegate]/[catch_all] bytes the parser stops at
   (wasm_parser.ml [instructions]); Scan's walk marks them because it tests
   [mark] before its match bottoms out, so they are the legitimate difference
   between the two mark sets. *)
let delimiter_bytes = [ 0x0B; 0x05; 0x07; 0x18; 0x19 ]

(* Byte offset ([loc_start.pos_cnum]) of every instruction the parser produced
   in the code section, recursing through the block-bearing forms. *)
let parser_instr_offsets (m : Ast.location Binary.module_) =
  let acc = ref [] in
  let rec instr (i : Ast.location Binary.instr) =
    match i.desc with
    | Binary.Hinted (_, inner) ->
        (* No bytecode of its own: the wrapped branch owns the offset. *)
        instr inner
    | desc ->
        acc := i.info.loc_start.pos_cnum :: !acc;
        block_children desc
  and block_children = function
    | Binary.Block { block; _ }
    | Binary.Loop { block; _ }
    | Binary.TryTable { block; _ } ->
        block_ block
    | Binary.If { if_block; else_block; _ } ->
        block_ if_block;
        block_ else_block
    | Binary.Try { block; catches; catch_all; _ } ->
        block_ block;
        List.iter (fun (_, b) -> block_ b) catches;
        Option.iter block_ catch_all
    | _ -> ()
  and block_ (b : (Ast.location Binary.instr list, Ast.location) Ast.annotated)
      =
    List.iter instr b.desc
  in
  List.iter
    (fun (c : Ast.location Binary.code) -> List.iter instr c.instrs)
    m.code;
  IntSet.of_list !acc

let check_offsets ~filename bytes (m : Ast.location Binary.module_) =
  let scan_offsets, scan_count =
    Wasm_link.get_instruction_offsets ~filename bytes
  in
  let scan_set = IntSet.of_list scan_offsets in
  let parser_set = parser_instr_offsets m in
  let parser_count = List.length m.code in
  if scan_count <> parser_count then
    note "function count disagreement: Scan sees %d, parser sees %d" scan_count
      parser_count;
  let missing = IntSet.diff parser_set scan_set in
  if not (IntSet.is_empty missing) then
    note "Scan missed %d instruction offset(s) the parser found (first at %d)"
      (IntSet.cardinal missing) (IntSet.min_elt missing);
  IntSet.iter
    (fun o ->
      let b =
        if o >= 0 && o < String.length bytes then Char.code bytes.[o] else -1
      in
      if not (List.mem b delimiter_bytes) then
        note
          "Scan marked offset %d (byte 0x%02x), neither an instruction start \
           nor a structural delimiter"
          o b)
    (IntSet.diff scan_set parser_set)

(* --- driver --- *)

let check_file filename =
  problems := [];
  (try
     let bytes = read_file filename in
     match parse bytes with
     | None -> note "input does not parse"
     | Some m ->
         check_offsets ~filename bytes m;
         check_idempotence bytes
   with e -> note "exception: %s" (Printexc.to_string e));
  match List.rev !problems with
  | [] -> ()
  | ps ->
      Printf.printf "==== %s ====\n" filename;
      List.iter (Printf.printf "  %s\n") ps

let () =
  for i = 1 to Array.length Sys.argv - 1 do
    check_file Sys.argv.(i)
  done

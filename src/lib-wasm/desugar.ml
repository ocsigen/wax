(* Expand the Wax-specific [@string]/[@char] annotations of a WAT module into
   core WebAssembly ([array.new_fixed] / [i32.const]), so the text other tools
   accept. Conditional-compilation annotations ([(@if ...)]) have no core-wasm
   form; they are expected to have been resolved already (by [Cond_specialize]
   through [-D]), and any that remain make desugaring fail. *)

open Ast.Text
module StringSet = Set.Make (String)
module IntSet = Set.Make (Int)

exception Conditional_remains of Ast.location
(** Raised when an [(@if ...)] annotation is still present: it could not be
    resolved (no matching [-D]), and there is nothing to desugar it to. *)

(* The array type a [@string] builds must be declared for [array.new_fixed] to
   name it. An untyped string uses the default [<string>] ([mut i8]); we
   synthesise that type once, under this name (freshened on the rare chance the
   module already declares it). *)
let default_string_type = "<string>"

let module_ ((name, fields) : Ast.location module_) : Ast.location module_ =
  (* Scan the type section: which array types are [i16] (their strings are
     UTF-16-encoded), tracked both by name and by index since a [@string] may
     name its type either way; plus every type name, to freshen the synthesised
     one. *)
  let wide_names = ref StringSet.empty in
  let wide_indices = ref IntSet.empty in
  let type_names = ref StringSet.empty in
  (* A type usable as the default [<string>] for an untyped string: as in
     [Text_to_binary], a singleton rec group that is a plain [(array (mut i8))]
     (final, no supertype). Referencing it avoids synthesising a redundant one;
     the last such type wins, matching [Text_to_binary]. *)
  let default_type = ref None in
  let next = ref 0 in
  List.iter
    (fun f ->
      match f.Ast.desc with
      | Types r ->
          let singleton = Array.length r = 1 in
          Array.iter
            (fun e ->
              let nameo, (st : subtype) = e.Ast.desc in
              let here = !next in
              Option.iter
                (fun n -> type_names := StringSet.add n.Ast.desc !type_names)
                nameo;
              (match st.typ with
              | Array { typ = Packed I16; _ } ->
                  wide_indices := IntSet.add here !wide_indices;
                  Option.iter
                    (fun n ->
                      wide_names := StringSet.add n.Ast.desc !wide_names)
                    nameo
              | _ -> ());
              (if singleton then
                 match st with
                 | {
                  final = true;
                  supertype = None;
                  typ = Array { mut = true; typ = Packed I8 };
                  _;
                 } ->
                     let idx =
                       match nameo with
                       | Some n ->
                           { Ast.desc = Id n.Ast.desc; info = n.Ast.info }
                       | None ->
                           {
                             Ast.desc = Num (Wax_utils.Uint32.of_int here);
                             info = f.Ast.info;
                           }
                     in
                     default_type := Some idx
                 | _ -> ());
              incr next)
            r
      | _ -> ())
    fields;

  let string_type_name =
    let rec fresh cand n =
      if StringSet.mem cand !type_names then
        fresh (Printf.sprintf "<string>%d" n) (n + 1)
      else cand
    in
    fresh default_string_type 1
  in
  let needs_string_type = ref false in

  let is_wide (i : idx) =
    match i.desc with
    | Id n -> StringSet.mem n !wide_names
    | Num k -> IntSet.mem (Wax_utils.Uint32.to_int k) !wide_indices
  in
  (* The type to build with, and whether it is UTF-16. An untyped string reuses
     an existing default [<string>] type when one exists, and otherwise pins a
     synthesised one. *)
  let resolve_type loc (idxo : idx option) =
    match idxo with
    | Some i -> (i, is_wide i)
    | None -> (
        match !default_type with
        | Some idx -> (idx, false)
        | None ->
            needs_string_type := true;
            ({ Ast.desc = Id string_type_name; info = loc }, false))
  in
  (* An operand of the folded [array.new_fixed] must itself be folded (an
     [(i32.const N)] sub-expression), not a bare stack instruction. *)
  let const loc v =
    {
      Ast.desc =
        Folded ({ Ast.desc = Const (I32 (string_of_int v)); info = loc }, []);
      info = loc;
    }
  in
  (* A string [array.new_fixed] over its encoded elements: UTF-16 code units for
     an [i16] array, raw UTF-8 bytes for an [i8] one. *)
  let string_expr loc (idxo : idx option) (s : datastring) =
    let content = Wax_utils.Ast.concat_desc s in
    let type_idx, wide = resolve_type loc idxo in
    let values =
      if wide then Wax_utils.Unicode.utf16_code_units content
      else List.init (String.length content) (fun j -> Char.code content.[j])
    in
    Folded
      ( {
          Ast.desc =
            ArrayNewFixed
              (type_idx, Wax_utils.Uint32.of_int (List.length values));
          info = loc;
        },
        List.map (const loc) values )
  in
  let char_expr c = Const (I32 (string_of_int (Uchar.to_int c))) in

  let rec map_instr (i : Ast.location instr) : Ast.location instr =
    match i.desc with
    | String (idxo, s) -> { i with desc = string_expr i.info idxo s }
    | Char c -> { i with desc = char_expr c }
    | If_annotation _ -> raise (Conditional_remains i.info)
    | desc -> { i with desc = map_structured desc }
  and map_structured (desc : Ast.location instr_desc) : Ast.location instr_desc
      =
    match desc with
    | Block b ->
        Block
          {
            b with
            block = { b.block with desc = List.map map_instr b.block.desc };
          }
    | Loop b ->
        Loop
          {
            b with
            block = { b.block with desc = List.map map_instr b.block.desc };
          }
    | If b ->
        If
          {
            b with
            if_block =
              { b.if_block with desc = List.map map_instr b.if_block.desc };
            else_block =
              { b.else_block with desc = List.map map_instr b.else_block.desc };
          }
    | TryTable b ->
        TryTable
          {
            b with
            block = { b.block with desc = List.map map_instr b.block.desc };
          }
    | Try b ->
        Try
          {
            b with
            block = { b.block with desc = List.map map_instr b.block.desc };
            catches =
              List.map
                (fun (t, l) ->
                  (t, { l with Ast.desc = List.map map_instr l.Ast.desc }))
                b.catches;
            catch_all =
              Option.map
                (fun b -> { b with Ast.desc = List.map map_instr b.Ast.desc })
                b.catch_all;
          }
    (* [@string]/[@char] print as a folded head with no operands; expand them at
       the folded level so no redundant parenthesis is left behind. *)
    | Folded ({ desc = String (idxo, s); info }, []) -> string_expr info idxo s
    | Folded ({ desc = Char c; _ }, []) -> char_expr c
    | Folded (h, l) -> Folded (map_instr h, List.map map_instr l)
    | Hinted (b, inner) -> Hinted (b, map_instr inner)
    | desc -> desc
  in

  let map_field (f : (Ast.location modulefield, Ast.location) Ast.annotated) =
    let desc =
      match f.Ast.desc with
      | Func r -> Func { r with instrs = List.map map_instr r.instrs }
      | Global r -> Global { r with init = List.map map_instr r.init }
      | Table r ->
          let init =
            match r.init with
            | Init_default -> Init_default
            | Init_expr e -> Init_expr (List.map map_instr e)
            | Init_segment segs ->
                Init_segment (List.map (List.map map_instr) segs)
          in
          Table { r with init }
      | Elem r -> Elem { r with init = List.map (List.map map_instr) r.init }
      | String_global { id; typ; init } ->
          let type_idx, _ = resolve_type f.info typ in
          let gtyp : globaltype =
            { mut = false; typ = Ref { nullable = false; typ = Type type_idx } }
          in
          let e = { Ast.desc = string_expr f.info typ init; info = f.info } in
          Global { id = Some id; typ = gtyp; init = [ e ]; exports = [] }
      | Module_if_annotation _ -> raise (Conditional_remains f.info)
      | desc -> desc
    in
    { f with desc }
  in

  (* A [(@feature "…")] declaration is pure metadata with no core equivalent:
     drop it, so no annotation remains in the output. Feature resolution has
     already run by this point (desugaring follows validation); re-ingesting
     the desugared text needs [-X] again, exactly as desugared strings do not
     come back as literals. *)
  let fields =
    List.filter
      (fun (f : (Ast.location modulefield, _) Ast.annotated) ->
        match f.desc with Feature_annotation _ -> false | _ -> true)
      fields
  in
  let fields = List.map map_field fields in
  let fields =
    if !needs_string_type then
      let st : subtype =
        {
          typ = Array { mut = true; typ = Packed I8 };
          supertype = None;
          final = true;
          descriptor = None;
          describes = None;
        }
      in
      (* Appended (not prepended) so it takes the highest type index, leaving any
         numeric type reference in the module unshifted. *)
      fields
      @ [
          Ast.no_loc
            (Types [| Ast.no_loc (Some (Ast.no_loc string_type_name), st) |]);
        ]
    else fields
  in
  (name, fields)

module IntHashtbl = Hashtbl.Make (struct
  type t = int

  let equal (x : int) y = x = y
  let hash (x : int) = x
end)

module StringHashtbl = Hashtbl.Make (struct
  type t = string

  let equal = String.equal
  let hash = Hashtbl.hash
end)

open Wax_wasm.Ast.Binary
module Uint64 = Wax_utils.Uint64
module Ast = Wax_utils.Ast

let dummy_loc = { Ast.loc_start = Lexing.dummy_pos; loc_end = Lexing.dummy_pos }

(* Linker diagnostics name three kinds of user-facing string: a file, an
   export, and an import (a "module"/"name" pair). Render each as a quoted
   string atom so every message displays them the same way (and colours them
   alike when colour is on). *)
let str s =
  Wax_utils.Message.styled Wax_utils.Colors.String (Printf.sprintf "%S" s)

let import_atom module_ name =
  Wax_utils.Message.(str module_ ++ text "/" ++ str name)

type link_subtyping_info = {
  wasm_info : Wax_wasm.Types.subtyping_info;
  (* Resolves a type index to its canonical identity. Keyed by canonical index,
     but under [--distinct-named-types] it *also* holds every appended
     name-variant's output index, mapped to the same canonical [ref_index] as
     the representative it copies. So a descriptor expressed in output space
     resolves straight to canonical identity here — no separate index map — and
     subtyping/exact-match are decided on that identity. *)
  types_map : (int, Wax_wasm.Types.ref_index) Hashtbl.t;
}

let get_id types_map idx =
  match Hashtbl.find types_map idx with
  | Wax_wasm.Types.Def id -> id
  | Rec _ -> assert false

(* Canonical-identity equality of two (possibly output-space) type indices. *)
let type_id_eq types_map i i' =
  Wax_wasm.Types.Id.equal (get_id types_map i) (get_id types_map i')

(* Resolve a Binary type to the internal (resolved) representation the store
   reasons about, mapping each output-space index to its identity via [get_id].
   Only the spine (heaptype/reftype/valtype) is needed, so [Map_types_spine]. *)
module To_internal =
  Wax_wasm.Ast.Map_types_spine (Wax_wasm.Ast.Binary) (Wax_wasm.Types.Internal)
    (struct
      type ctx = (int, Wax_wasm.Types.ref_index) Hashtbl.t

      let idx = get_id
    end)

let reftype_eq (info : link_subtyping_info) t1 t2 =
  let rt1 = To_internal.reftype info.types_map t1 in
  let rt2 = To_internal.reftype info.types_map t2 in
  Wax_wasm.Types.reftype_equal rt1 rt2

let valtype_eq (info : link_subtyping_info) t1 t2 =
  let vt1 = To_internal.valtype info.types_map t1 in
  let vt2 = To_internal.valtype info.types_map t2 in
  Wax_wasm.Types.valtype_equal vt1 vt2

(* Normalize a Binary rec group for the structural store. The context is
   [resolve], mapping a source type index (as it appears in the module being
   read) to its canonical reference: [Rec pos] for a member of the rec group
   currently being added, [Def id] for an already-canonicalised type. The array
   wrappers are plain [Array.map], as in [Remap] below.

   [Map_types.subtype] carries [descriptor]/[describes] (custom-descriptors)
   through [resolve] like any other index; that is essential, not incidental —
   they are part of a type's identity, and dropping them once made two structs
   differing only in their descriptor/describes clauses (e.g. [$a (descriptor $b)]
   and [$b (describes $a)]) canonicalise to the same type and be merged. *)
module To_normalized =
  Wax_wasm.Ast.Map_types (Wax_wasm.Ast.Binary) (Wax_wasm.Types.Normalized)
    (struct
      type ctx = idx -> Wax_wasm.Types.ref_index

      let idx f i = f i
      let params _ f a = Array.map f a
      let fields _ f a = Array.map f a
      let members _ f a = Array.map f a
    end)

(* Remap every type index in a Binary type (e.g. renumbering into output space).
   Instantiated from the shared type-family functor rather than hand-written; the
   context is the index-renaming function and every array wrapper is a plain
   [Array.map]. *)
module Remap =
  Wax_wasm.Ast.Map_types (Wax_wasm.Ast.Binary) (Wax_wasm.Ast.Binary)
    (struct
      type ctx = idx -> idx

      let idx f i = f i
      let params _ f a = Array.map f a
      let fields _ f a = Array.map f a
      let members _ f a = Array.map f a
    end)

let rec output_uint ch i =
  if i < 128 then output_byte ch i
  else (
    output_byte ch (128 + (i land 127));
    output_uint ch (i lsr 7))

module Write = struct
  open Wax_wasm.Wasm_output.Encoder

  let uint = uint
  let name = name

  let nameassoc ch idx nm =
    uint ch idx;
    name ch nm

  let namemap ch l = vec' (fun ch (idx, name) -> nameassoc ch idx name) ch l
end

type 'a exportable_info = {
  mutable func : 'a;
  mutable table : 'a;
  mutable mem : 'a;
  mutable global : 'a;
  mutable tag : 'a;
}

let iter_exportable_info (f : exportable -> 'a -> unit)
    { func; table; mem; global; tag } =
  f Func func;
  f Table table;
  f Memory mem;
  f Global global;
  f Tag tag

let map_exportable_info (f : exportable -> 'a -> 'b)
    { func; table; mem; global; tag } =
  {
    func = f Func func;
    table = f Table table;
    mem = f Memory mem;
    global = f Global global;
    tag = f Tag tag;
  }

let init_exportable_info f =
  { func = f (); table = f (); mem = f (); global = f (); tag = f () }

let make_exportable_info v = init_exportable_info (fun _ -> v)

let get_exportable_info info (kind : exportable) =
  match kind with
  | Func -> info.func
  | Table -> info.table
  | Memory -> info.mem
  | Global -> info.global
  | Tag -> info.tag

let set_exportable_info info (kind : exportable) v =
  match kind with
  | Func -> info.func <- v
  | Table -> info.table <- v
  | Memory -> info.mem <- v
  | Global -> info.global <- v
  | Tag -> info.tag <- v

module Read = struct
  type ch = Wax_wasm.Wasm_parser.ch
  type index = Wax_wasm.Wasm_parser.index

  let pos_in = Wax_wasm.Wasm_parser.pos_in
  let seek_in = Wax_wasm.Wasm_parser.seek_in
  let uint ch = Wax_wasm.Wasm_parser.uint ch

  let repeat' n f ch =
    for _ = 1 to n do
      f ch
    done

  let name = Wax_wasm.Wasm_parser.name

  type t = { id : int; ch : ch; index : index }

  (* [id] is the module's position among the linked inputs; it indexes the
     per-call [type_mappings] array, so the caller passes the input index. *)
  let open_in id f buf =
    Wax_utils.Diagnostic.run ~color:Wax_utils.Colors.Never
      ~palette:Wax_utils.Colors.wat_theme ~source:(Some buf) (fun d ->
        let ch = Wax_wasm.Wasm_parser.make_ch d ~filename:f buf 0 in
        Wax_wasm.Wasm_parser.check_header ch;
        { id; ch; index = Wax_wasm.Wasm_parser.index ch })

  (* A module's parsed type/field names (name subsections 4 and 10), read once
     and cached: the same data feeds both the dedup signature and the emitted
     merged name section. *)
  type name_data = {
    type_names : (int * string) array;
    field_names : (int * (int * string) array) array;
  }

  type types = {
    (* Structural store: assigns each distinct *structure* an internal index.
       Purely internal — it exists only to answer subtyping/exact-match queries
       (via [subtyping_info]); it plays no part in how the output is laid out. *)
    types_store : Wax_wasm.Types.t;
    (* Resolves an *output* type index to its internal (structural) identity, so
       a descriptor expressed in output space can be canonicalised for a
       subtyping query. Populated as each output type is created. *)
    types_map : (int, Wax_wasm.Types.ref_index) Hashtbl.t;
    (* Per module, source type index -> output index (the emitted type-section
       slot). The only per-module mapping: every consumer (emission, code type
       references, name sections, interface descriptors, and reference
       normalization for the store) reads output indices through [types_map]. *)
    type_mappings : int array array;
    (* The output type section, one entry [(mapping, ty)] per emitted rec group
       in reverse order. Output indices are just positions here — a group's slot
       is the running [output_type_count] when it is appended. [mapping] is the
       defining module's source->output map, so emitted references are output
       indices. *)
    mutable kept_rectypes : (int array * subtype array) list;
    mutable output_type_count : int;
    (* Name-aware coalescing (the [--distinct-named-types] flag). Off: two
       structurally-equal groups share one output type. On: they share one only
       if their type/field names also match, else each is emitted separately so
       its names survive. The decision is [output_table]; its key is the
       structure ([first_id]) and, when on, the type/field names together with
       the output slots of the group's external references (so a reference to a
       name-variant keeps the referrer distinct too). The structural store is
       unaffected. *)
    distinct_named : bool;
    output_table : (Wax_wasm.Types.Id.t * int list * string, int) Hashtbl.t;
    mutable current_signatures : int -> string;
    (* Per module, the parsed name subsections 4/10, filled on first use. *)
    name_cache : name_data option array;
  }

  let get_type_mapping types st = types.type_mappings.(st.id)
  let set_type_mapping types st map = types.type_mappings.(st.id) <- map

  let create_types ?(distinct_named = false) n =
    {
      types_store = Wax_wasm.Types.create ();
      types_map = Hashtbl.create 16;
      type_mappings = Array.make n [||];
      kept_rectypes = [];
      output_type_count = 0;
      distinct_named;
      output_table = Hashtbl.create 16;
      current_signatures = (fun _ -> "");
      name_cache = Array.make n None;
    }

  (* Number of types in the emitted type section. *)
  let output_type_count types = types.output_type_count

  let find_section contents n =
    Wax_wasm.Wasm_parser.find_section contents.ch contents.index n

  let focus_on_custom_section contents section =
    let ch, index =
      Wax_wasm.Wasm_parser.focus_on_custom_section contents.ch contents.index
        section
    in
    { contents with ch; index }

  let focus_on_custom_section_payload contents name =
    match Wax_wasm.Wasm_parser.get_custom_section contents.index name with
    | None -> { contents with ch = { contents.ch with pos = 0; limit = 0 } }
    | Some { pos; size; _ } ->
        let ch = { contents.ch with pos; limit = pos + size } in
        ignore (Wax_wasm.Wasm_parser.name ch);
        { contents with ch }

  (* Parse a module's type/field names (name subsections 4 and 10) once, caching
     the result so both the dedup signature and the emitted name section reuse
     the single parse. *)
  let name_data types contents =
    match types.name_cache.(contents.id) with
    | Some d -> d
    | None ->
        let name_section = focus_on_custom_section contents "name" in
        let type_names =
          if find_section name_section 4 then
            Wax_wasm.Wasm_parser.namemap name_section.ch
          else [||]
        in
        let field_names =
          if find_section name_section 10 then
            Wax_wasm.Wasm_parser.indirect_namemap name_section.ch
          else [||]
        in
        let d = { type_names; field_names } in
        types.name_cache.(contents.id) <- Some d;
        d

  (* A per-type name signature (type name from name subsection 4, field names
     from subsection 10), so the dedup key can be built while rec groups are
     added. Missing names yield the empty string, so unnamed types coalesce
     exactly as before. *)
  let read_name_signatures types contents =
    let { type_names; field_names } = name_data types contents in
    let sigs = Hashtbl.create 64 in
    Array.iter (fun (idx, n) -> Hashtbl.replace sigs idx ("t:" ^ n)) type_names;
    Array.iter
      (fun (idx, fields) ->
        let buf = Buffer.create 32 in
        Array.iter
          (fun (fidx, n) ->
            Buffer.add_string buf (Printf.sprintf "|f%d:%s" fidx n))
          fields;
        let prev = try Hashtbl.find sigs idx with Not_found -> "" in
        Hashtbl.replace sigs idx (prev ^ Buffer.contents buf))
      field_names;
    fun idx -> try Hashtbl.find sigs idx with Not_found -> ""

  (* Add one rec group and return the output index its first member maps to,
     filling [type_mapping] over the group's source range ([source_base ..]).

     Two independent things happen. (1) The group is added to the structural
     store, which assigns it an internal identity ([first_id]); references are
     normalized against earlier types via [type_mapping] (output index) →
     [types_map] (→ internal), and an in-group member is [Rec]. (2) An output
     slot is chosen: groups sharing a dedup key collapse to one output type.
     The key is the structure ([first_id]); when on, also the type/field names
     and the output slots of the group's external references, so differently-
     named structural twins, and twins that reference them, each get their own
     output type. A new key appends the group to [kept_rectypes] at the running
     [output_type_count]; [types_map] records the new output indices → internal
     identity so later descriptors in output space resolve for subtyping. *)
  let add_rectype types type_mapping ~source_base ty =
    let count = Array.length ty in
    (* Output slots of the group's external references, gathered as the group is
       normalized. They discriminate the output type beyond its structure: two
       structural twins that reference differently-named (hence differently-
       slotted) types must stay distinct, so a func type returning [$Point]
       does not collapse onto one returning the identically-shaped [$Vec2].
       In-group references need no such treatment — [first_id] already captures
       the recursive topology. *)
    let ext_refs = ref [] in
    let resolve idx =
      if idx >= source_base && idx < source_base + count then
        Wax_wasm.Types.Rec (idx - source_base)
      else
        let out_slot = type_mapping.(idx) in
        (* Only the name-aware key distinguishes by external slot; off, structural
           twins already share slots, so skip gathering them. *)
        if types.distinct_named then ext_refs := out_slot :: !ext_refs;
        Hashtbl.find types.types_map out_slot
    in
    let normalized = To_normalized.rectype resolve ty in
    let first_id = Wax_wasm.Types.add_rectype types.types_store normalized in
    let fill base =
      if source_base + count <= Array.length type_mapping then
        for i = 0 to count - 1 do
          type_mapping.(source_base + i) <- base + i
        done
    in
    let emit () =
      let base = types.output_type_count in
      types.output_type_count <- base + count;
      fill base;
      for i = 0 to count - 1 do
        Hashtbl.replace types.types_map (base + i)
          (Wax_wasm.Types.Def (Wax_wasm.Types.Id.add first_id i))
      done;
      types.kept_rectypes <- (type_mapping, ty) :: types.kept_rectypes;
      base
    in
    let names =
      if types.distinct_named then
        String.concat "\x00"
          (List.init count (fun i -> types.current_signatures (source_base + i)))
      else ""
    in
    let key = (first_id, List.rev !ext_refs, names) in
    match Hashtbl.find_opt types.output_table key with
    | Some base ->
        fill base;
        base
    | None ->
        Hashtbl.add types.output_table key types.output_type_count;
        emit ()

  let translate_tabletype type_mapping (tt : tabletype) : tabletype =
    { tt with reftype = Remap.reftype (Array.get type_mapping) tt.reftype }

  let translate_globaltype type_mapping (gt : globaltype) : globaltype =
    { gt with typ = Remap.valtype (Array.get type_mapping) gt.typ }

  let translate_importdesc type_mapping (desc : importdesc) : importdesc =
    match desc with
    | Func { exact; typ } -> Func { exact; typ = type_mapping.(typ) }
    | Table tt -> Table (translate_tabletype type_mapping tt)
    | Memory lim -> Memory lim
    | Global gt -> Global (translate_globaltype type_mapping gt)
    | Tag idx -> Tag type_mapping.(idx)

  let tabletype st types ch =
    let type_mapping = get_type_mapping types st in
    translate_tabletype type_mapping (Wax_wasm.Wasm_parser.tabletype ch)

  let globaltype st types ch =
    let type_mapping = get_type_mapping types st in
    translate_globaltype type_mapping (Wax_wasm.Wasm_parser.globaltype ch)

  let type_section st types ch =
    let groups = Wax_wasm.Wasm_parser.type_section ch in
    let n = Array.fold_left (fun acc g -> acc + Array.length g) 0 groups in
    let type_mapping = Array.make n 0 in
    set_type_mapping types st type_mapping;
    if types.distinct_named then
      types.current_signatures <- read_name_signatures types st;
    let pos = ref 0 in
    Array.iter
      (fun ty ->
        ignore (add_rectype types type_mapping ~source_base:!pos ty : int);
        pos := !pos + Array.length ty)
      groups

  type interface = {
    imports : import array exportable_info;
    exports : (string * int) list exportable_info;
  }

  let type_section types contents =
    if find_section contents 1 then type_section contents types contents.ch

  let interface types contents =
    let imports =
      if find_section contents 2 then (
        (* Descriptors carry output indices: they go straight to emission, and
           [types_map] resolves them to internal identity for resolution. Read
           right after the module's own types, whose output slots are already
           assigned. *)
        let type_mapping = get_type_mapping types contents in
        let raw_imports =
          Wax_wasm.Ast_utils.flatten_binary_imports
            (Wax_wasm.Wasm_parser.import_section contents.ch)
        in
        let tbl = make_exportable_info [] in
        List.iter
          (fun (imp : import) ->
            let desc = translate_importdesc type_mapping imp.desc in
            let kind : exportable =
              match desc with
              | Func _ -> Func
              | Table _ -> Table
              | Memory _ -> Memory
              | Global _ -> Global
              | Tag _ -> Tag
            in
            set_exportable_info tbl kind
              ({ imp with desc } :: get_exportable_info tbl kind))
          raw_imports;
        map_exportable_info (fun _ l -> Array.of_list (List.rev l)) tbl)
      else make_exportable_info [||]
    in
    let exports =
      let tbl = make_exportable_info [] in
      (if find_section contents 7 then
         let raw_exports = Wax_wasm.Wasm_parser.export_section contents.ch in
         Array.iter
           (fun (exp : export) ->
             set_exportable_info tbl exp.kind
               ((exp.name, exp.index) :: get_exportable_info tbl exp.kind))
           raw_exports);
      (* Prepending above builds each per-kind list in reverse; restore input
         order so the merged module's exports follow it (and linking is
         idempotent), mirroring the imports table above. *)
      map_exportable_info (fun _ l -> List.rev l) tbl
    in
    { imports; exports }

  let functions types contents =
    if find_section contents 3 then
      let raw_funcs = Wax_wasm.Wasm_parser.function_section contents.ch in
      let type_mapping = get_type_mapping types contents in
      Array.map (fun idx -> type_mapping.(idx)) raw_funcs
    else [||]

  let memories contents =
    if find_section contents 5 then
      Wax_wasm.Wasm_parser.memory_section contents.ch
    else [||]

  let tags types contents =
    if find_section contents 13 then
      let raw_tags = Wax_wasm.Wasm_parser.tag_section contents.ch in
      let type_mapping = get_type_mapping types contents in
      Array.map (fun idx -> type_mapping.(idx)) raw_tags
    else [||]

  let data_count contents =
    if find_section contents 12 then
      Wax_wasm.Wasm_parser.datacount_section contents.ch
    else if find_section contents 11 then
      Wax_wasm.Wasm_parser.datacount_section contents.ch
    else 0

  let start contents =
    if find_section contents 8 then
      Some (Wax_wasm.Wasm_parser.start_section contents.ch)
    else None

  let namemap contents = Wax_wasm.Wasm_parser.namemap contents.ch
end

(* The [metadata.code.*] custom sections of the branch-hinting and
   compilation-hints proposals, in the order [Wasm_output] emits them. All four
   share a shape (per function index, a list of (byte offset, payload) pairs) and
   so are merged by one pass; they differ only in whether the payload itself
   names anything the merge renumbers, which the tag beside each name says. The
   hints are
   advisory, so a merge may drop one, but never keep one that has come to point
   somewhere else. *)
let code_metadata_sections =
  [
    ("branch_hint", `Opaque);
    ("instr_freq", `Opaque);
    ("call_targets", `Function_indices);
    ("compilation_priority", `Opaque);
  ]

let read_code_metadata ~name (contents : Read.t) =
  if contents.ch.limit > 0 then
    Array.to_list (Wax_wasm.Wasm_parser.code_metadata_section ~name contents.ch)
  else []

(* Rewrite a [metadata.code.call_targets] payload against a function-index
   mapping: it lists the likely targets of an indirect call, which the merge
   renumbers like any other function reference. [None] drops the hint, which is
   what a payload that does not decode, or that names a function outside the
   module it came from, has to do: the alternative is a hint that now names a
   different function. A target removed by dead code elimination (mapped to
   [-1]) cannot be called, so it is dropped, and so is the hint if no target
   remains. *)
let remap_call_targets func_map payload =
  match Wax_wasm.Hints.call_targets_of_payload payload with
  | Error _ -> None
  | Ok targets -> (
      if List.exists (fun (idx, _) -> idx >= Array.length func_map) targets then
        None
      else
        match
          List.filter_map
            (fun (idx, pct) ->
              let idx = func_map.(idx) in
              if idx >= 0 then Some (idx, pct) else None)
            targets
        with
        | [] -> None
        | targets -> Some (Wax_wasm.Hints.call_targets_payload targets))

(* Raised by the table-section scan when a table initializer reads a global that
   the merged module cannot legally reference at that point: a global that
   linking internalises (a resolved import) is emitted after the whole table
   section, so reading it would be a forward reference and make the output
   invalid. The offending global's *source* index (module-local) is carried so
   the catch site can name the offending import. Signalled through the [global]
   map: the caller sets the sentinel [-1] for every disallowed global, which
   [global_map] turns into this exception. (Global initializers need no such
   check: the globals are ordered so that an initializer only reads preceding
   globals.) *)
exception Init_reads_forward_global of int

module Scan = struct
  let debug = false

  type maps = {
    typ : int array;
    func : int array;
    table : int array;
    mem : int array;
    global : int array;
    elem : int array;
    data : int array;
    tag : int array;
  }

  let default_maps =
    {
      typ = [||];
      func = [||];
      table = [||];
      mem = [||];
      global = [||];
      elem = [||];
      data = [||];
      tag = [||];
    }

  type resize_data = Source_map.resize_data = {
    mutable i : int;
    mutable pos : int array;
    mutable delta : int array;
  }

  let push_resize resize_data pos delta =
    let p = resize_data.pos in
    let i = resize_data.i in
    let p =
      if i = Array.length p then (
        let p = Array.make (2 * i) 0 in
        let d = Array.make (2 * i) 0 in
        Array.blit resize_data.pos 0 p 0 i;
        Array.blit resize_data.delta 0 d 0 i;
        resize_data.pos <- p;
        resize_data.delta <- d;
        p)
      else p
    in
    p.(i) <- pos;
    resize_data.delta.(i) <- delta;
    resize_data.i <- i + 1

  let create_resize_data () =
    { i = 0; pos = Array.make 1024 0; delta = Array.make 1024 0 }

  let clear_resize_data resize_data = resize_data.i <- 0

  type position_data = { mutable i : int; mutable pos : int array }

  let create_position_data () = { i = 0; pos = Array.make 100 0 }
  let clear_position_data position_data = position_data.i <- 0

  let push_position position_data pos =
    let p = position_data.pos in
    let i = position_data.i in
    let p =
      if i = Array.length p then (
        let p = Array.make (2 * i) 0 in
        Array.blit position_data.pos 0 p 0 i;
        position_data.pos <- p;
        p)
      else p
    in
    p.(i) <- pos;
    position_data.i <- i + 1

  (* A live entry refers to an entry which was found dead: the liveness
     analysis missed a reference *)
  let dead_reference idx =
    failwith (Printf.sprintf "Wasm linker: reference to removed entity %d" idx)

  (* The byte-level rewriter at the heart of linking. It walks a section payload
     in [code], copies bytes verbatim into [buf], and renumbers every embedded
     index through [maps] (rewriting the LEB immediate in place). Two callbacks
     observe the walk:
     - [report pos delta]: an index's LEB encoding changed width, so all bytes
       from output position [pos] on are shifted by [delta] (feeds source-map
       resizing);
     - [mark pos]: record a notable *input* position — an entity start, and, with
       [mark_instructions], every instruction start.
     It returns one closure per section kind it knows how to scan; they all
     capture this call's mutable state ([start], [buf], …), so a caller selects
     the closure it needs and ignores the others. *)
  (* The references an analysis scan reports (see [scanner]'s [visit]). *)
  type ref_kind =
    [ `Func
    | `Ref_func (* function referenced by [ref.func] *)
    | `Global
    | `Tag
    | `Elem
    | `Data
    | `Type ]

  type scanner = {
    table_section : count:int -> int -> unit;
    elem_section : keep:(int -> bool) -> count:int -> int -> unit;
    data_section : keep:(int -> bool) -> count:int -> int -> unit;
    func : int -> unit;
    local_namemap : int -> unit;
    table : int -> int;
    global : int -> int;
    global_entry : int -> int;
    elem : int -> int;
    data : int -> int;
  }

  (* In [analysis] mode, nothing is written: the scanner only reports, through
     [visit], the references to functions, globals, tags, element and data
     segments and types (with the module-local index). The single-entry
     functions ([table], [global], [elem], [data]) return the position
     following the entry. *)
  let scanner ?(mark_instructions = false) ?(analysis = false)
      ?(visit = fun (_ : ref_kind) (_ : int) -> ()) report mark maps buf code =
    let rec output_uint buf i =
      if i < 128 then Buffer.add_char buf (Char.chr i)
      else (
        Buffer.add_char buf (Char.chr (128 + (i land 127)));
        output_uint buf (i lsr 7))
    in
    let rec output_sint buf i =
      if i >= -64 && i < 64 then Buffer.add_char buf (Char.chr (i land 127))
      else (
        Buffer.add_char buf (Char.chr (128 + (i land 127)));
        output_sint buf (i asr 7))
    in
    let start = ref 0 in
    (* Set while going through an entry that is dropped (or in analysis mode):
       indices are not rewritten, since the entry may refer to dropped
       entries. *)
    let skipping = ref analysis in
    let in_func = ref false in
    let get pos = Char.code (String.get code pos) in
    let rec int pos = if get pos >= 128 then int (pos + 1) else pos + 1 in
    let rec uint32 pos =
      let i = get pos in
      if i < 128 then (pos + 1, i)
      else
        let pos, i' = pos + 1 |> uint32 in
        (pos, (i' lsl 7) + (i land 0x7f))
    in
    let rec sint32 pos =
      let i = get pos in
      if i < 64 then (pos + 1, i)
      else if i < 128 then (pos + 1, i - 128)
      else
        let pos, i' = pos + 1 |> sint32 in
        (pos, i - 128 + (i' lsl 7))
    in
    let rec repeat n f pos = if n = 0 then pos else repeat (n - 1) f (f pos) in
    let vector f pos =
      let pos, i =
        let i = get pos in
        if i < 128 then (pos + 1, i) else uint32 pos
      in
      repeat i f pos
    in
    let name pos =
      let pos', i =
        let i = get pos in
        if i < 128 then (pos + 1, i) else uint32 pos
      in
      pos' + i
    in
    let flush' pos pos' =
      if (not analysis) && !start < pos then
        Buffer.add_substring buf code !start (pos - !start);
      start := pos'
    in
    let flush pos = flush' pos pos in
    let rewrite visit map pos =
      let pos', idx =
        let i = get pos in
        if i < 128 then (pos + 1, i)
        else
          let i' = get (pos + 1) in
          if i' < 128 then (pos + 2, (i' lsl 7) + (i land 0x7f)) else uint32 pos
      in
      visit idx;
      if !skipping then pos'
      else
        let idx' = map idx in
        if idx' < 0 then dead_reference idx;
        if idx <> idx' then (
          flush' pos pos';
          let p = Buffer.length buf in
          output_uint buf idx';
          let p' = Buffer.length buf in
          let dp = p' - p in
          let dpos = pos' - pos in
          (* The width change reshapes the immediate spanning [pos, pos'); it
           shifts the bytes that *follow* it, so the resize is recorded at
           [pos'] (positions < pos' are unaffected). [rewrite_signed] and
           [memarg] report at [pos'] for the same reason. *)
          if dp <> dpos then report pos' (dp - dpos));
        pos'
    in
    let rewrite_signed visit map pos =
      let pos', idx =
        let i = get pos in
        if i < 64 then (pos + 1, i)
        else if i < 128 then (pos + 1, i - 128)
        else sint32 pos
      in
      visit idx;
      if !skipping then pos'
      else
        let idx' = map idx in
        if idx' < 0 then dead_reference idx;
        if idx <> idx' then (
          flush' pos pos';
          let p = Buffer.length buf in
          output_sint buf idx';
          let p' = Buffer.length buf in
          let dp = p' - p in
          let dpos = pos' - pos in
          if dp <> dpos then report pos' (dp - dpos));
        pos'
    in
    let no_visit _ = () in
    let visit_func idx = visit `Func idx in
    let visit_ref_func idx = visit `Ref_func idx in
    let visit_global idx = visit `Global idx in
    let visit_elem idx = visit `Elem idx in
    let visit_data idx = visit `Data idx in
    let visit_tag idx = visit `Tag idx in
    let visit_type idx = visit `Type idx in
    let typ_map idx = maps.typ.(idx) in
    let typeidx pos = rewrite visit_type typ_map pos in
    let signed_typeidx pos = rewrite_signed visit_type typ_map pos in
    let func_map idx = maps.func.(idx) in
    let funcidx pos = rewrite visit_func func_map pos in
    let table_map idx = maps.table.(idx) in
    let tableidx pos = rewrite no_visit table_map pos in
    let mem_map idx = maps.mem.(idx) in
    let memidx pos = rewrite no_visit mem_map pos in
    let global_map idx =
      (* [-1] marks a global a table-initializer scan must reject (see
         [Init_reads_forward_global]). Elsewhere, it is the mapping of a global
         removed by dead code elimination, which live code never reads (and
         dead code is skipped without looking at the maps). *)
      let v = maps.global.(idx) in
      if v < 0 then raise (Init_reads_forward_global idx);
      v
    in
    let globalidx pos = rewrite visit_global global_map pos in
    let elem_map idx = maps.elem.(idx) in
    let elemidx pos = rewrite visit_elem elem_map pos in
    let data_map idx = maps.data.(idx) in
    let dataidx pos = rewrite visit_data data_map pos in
    let tag_map idx = maps.tag.(idx) in
    let tagidx pos = rewrite visit_tag tag_map pos in
    let labelidx = int in
    let localidx = int in
    let laneidx pos = pos + 1 in
    let heaptype pos =
      let c = get pos in
      if c = 0x62 (* exact: 0x62 then an (unsigned) type index *) then
        pos + 1 |> typeidx
      else if c >= 64 && c < 128 then (* absheaptype *) pos + 1
      else signed_typeidx pos
    in
    let absheaptype pos =
      match get pos with
      | 0X73 (* nofunc *)
      | 0x72 (* noextern *)
      | 0x71 (* none *)
      | 0x70 (* func *)
      | 0x6F (* extern *)
      | 0x6E (* any *)
      | 0x6D (* eq *)
      | 0x6C (* i31 *)
      | 0x6B (* struct *)
      | 0x6A (* array *)
      | 0x69 (* exn *)
      | 0x74 (* noexn *)
      | 0x68 (* cont *)
      | 0x75 (* nocont *) ->
          pos + 1
      | c -> failwith (Printf.sprintf "Bad heap type 0x%02X@." c)
    in
    let reftype pos =
      match get pos with
      | 0x63 | 0x64 -> pos + 1 |> heaptype
      | _ -> pos |> absheaptype
    in
    let valtype pos =
      let c = get pos in
      match c with
      | 0x63 (* ref null ht *) | 0x64 (* ref ht *) -> pos + 1 |> heaptype
      | _ -> pos + 1
    in
    let blocktype pos =
      let c = get pos in
      if c >= 64 && c < 128 then pos |> valtype else pos |> signed_typeidx
    in
    let memarg pos =
      let pos', c = uint32 pos in
      if c < 64 then (
        if (not !skipping) && mem_map 0 <> 0 then (
          flush' pos pos';
          let p = Buffer.length buf in
          output_uint buf (c + 64);
          output_uint buf (mem_map 0);
          let p' = Buffer.length buf in
          let dp = p' - p in
          let dpos = pos' - pos in
          if dp <> dpos then report pos' (dp - dpos));
        pos' |> int)
      else pos' |> memidx |> int
    in
    let rec instructions pos =
      if debug then Format.eprintf "0x%02X (@%d)@." (get pos) pos;
      if mark_instructions && !in_func then mark pos;
      match get pos with
      (* Control instruction *)
      | 0x00 (* unreachable *) | 0x01 (* nop *) | 0x0F (* return *) ->
          pos + 1 |> instructions
      | 0x02 (* block *) | 0x03 (* loop *) ->
          pos + 1 |> blocktype |> instructions |> block_end |> instructions
      | 0x04 (* if *) ->
          pos + 1 |> blocktype |> instructions |> opt_else |> instructions
      | 0x0C (* br *)
      | 0x0D (* br_if *)
      | 0xD5 (* br_on_null *)
      | 0xD6 (* br_on_non_null *) ->
          pos + 1 |> labelidx |> instructions
      | 0x0E (* br_table *) ->
          pos + 1 |> vector labelidx |> labelidx |> instructions
      | 0x10 (* call *) | 0x12 (* return_call *) ->
          pos + 1 |> funcidx |> instructions
      | 0x11 (* call_indirect *) | 0x13 (* return_call_indirect *) ->
          pos + 1 |> typeidx |> tableidx |> instructions
      | 0x14 (* call_ref *) | 0x15 (* return_call_ref *) ->
          pos + 1 |> typeidx |> instructions
      (* Exceptions *)
      | 0x06 (* try *) -> pos + 1 |> blocktype |> instructions |> opt_catch
      | 0x08 (* throw *) -> pos + 1 |> tagidx |> instructions
      | 0x09 (* rethrow *) -> pos + 1 |> int |> instructions
      | 0x0A (* throw_ref *) -> pos + 1 |> instructions
      (* Parametric instructions *)
      | 0x1A (* drop *) | 0x1B (* select *) -> pos + 1 |> instructions
      | 0x1C (* select *) -> pos + 1 |> vector valtype |> instructions
      | 0x1F (* try_table *) ->
          pos + 1 |> blocktype |> vector catch |> instructions |> block_end
          |> instructions
      (* Variable instructions *)
      | 0x20 (* local.get *) | 0x21 (* local.set *) | 0x22 (* local.tee *) ->
          pos + 1 |> localidx |> instructions
      | 0x23 (* global.get *) | 0x24 (* global.set *) ->
          pos + 1 |> globalidx |> instructions
      (* Table instructions *)
      | 0x25 (* table.get *) | 0x26 (* table.set *) ->
          pos + 1 |> tableidx |> instructions
      (* Memory instructions *)
      | 0x28 | 0x29 | 0x2A | 0x2B | 0x2C | 0x2D | 0x2E | 0x2F | 0x30 | 0x31
      | 0x32 | 0x33 | 0x34 | 0x35 (* load *)
      | 0x36 | 0x37 | 0x38 | 0x39 | 0x3A | 0x3B | 0x3C | 0x3D | 0x3E (* store *)
        ->
          pos + 1 |> memarg |> instructions
      | 0x3F | 0x40 -> pos + 1 |> memidx |> instructions
      (* Numeric instructions *)
      | 0x41 (* i32.const *) | 0x42 (* i64.const *) ->
          pos + 1 |> int |> instructions
      | 0x43 (* f32.const *) -> pos + 5 |> instructions
      | 0x44 (* f64.const *) -> pos + 9 |> instructions
      | 0x45 | 0x46 | 0x47 | 0x48 | 0x49 | 0x4A | 0x4B | 0x4C | 0x4D | 0x4E
      | 0x4F | 0x50 | 0x51 | 0x52 | 0x53 | 0x54 | 0x55 | 0x56 | 0x57 | 0x58
      | 0x59 | 0x5A | 0x5B | 0x5C | 0x5D | 0x5E | 0x5F | 0x60 | 0x61 | 0x62
      | 0x63 | 0x64 | 0x65 | 0x66 | 0x67 | 0x68 | 0x69 | 0x6A | 0x6B | 0x6C
      | 0x6D | 0x6E | 0x6F | 0x70 | 0x71 | 0x72 | 0x73 | 0x74 | 0x75 | 0x76
      | 0x77 | 0x78 | 0x79 | 0x7A | 0x7B | 0x7C | 0x7D | 0x7E | 0x7F | 0x80
      | 0x81 | 0x82 | 0x83 | 0x84 | 0x85 | 0x86 | 0x87 | 0x88 | 0x89 | 0x8A
      | 0x8B | 0x8C | 0x8D | 0x8E | 0x8F | 0x90 | 0x91 | 0x92 | 0x93 | 0x94
      | 0x95 | 0x96 | 0x97 | 0x98 | 0x99 | 0x9A | 0x9B | 0x9C | 0x9D | 0x9E
      | 0x9F | 0xA0 | 0xA1 | 0xA2 | 0xA3 | 0xA4 | 0xA5 | 0xA6 | 0xA7 | 0xA8
      | 0xA9 | 0xAA | 0xAB | 0xAC | 0xAD | 0xAE | 0xAF | 0xB0 | 0xB1 | 0xB2
      | 0xB3 | 0xB4 | 0xB5 | 0xB6 | 0xB7 | 0xB8 | 0xB9 | 0xBA | 0xBB | 0xBC
      | 0xBD | 0xBE | 0xBF | 0xC0 | 0xC1 | 0xC2 | 0xC3 | 0xC4 ->
          pos + 1 |> instructions
      (* Reference instructions *)
      | 0xD0 (* ref.null *) -> pos + 1 |> heaptype |> instructions
      | 0xD1 (* ref.is_null *) | 0xD3 (* ref.eq *) | 0xD4 (* ref.as_non_null *)
        ->
          pos + 1 |> instructions
      | 0xD2 (* ref.func *) ->
          pos + 1 |> rewrite visit_ref_func func_map |> instructions
      | 0xE0 (* cont.new *) -> pos + 1 |> typeidx |> instructions
      | 0xE1 (* cont.bind *) -> pos + 1 |> typeidx |> typeidx |> instructions
      | 0xE2 (* suspend *) -> pos + 1 |> tagidx |> instructions
      | 0xE3 (* resume *) ->
          pos + 1 |> typeidx |> vector on_clause |> instructions
      | 0xE4 (* resume_throw *) ->
          pos + 1 |> typeidx |> tagidx |> vector on_clause |> instructions
      | 0xE5 (* resume_throw_ref *) ->
          pos + 1 |> typeidx |> vector on_clause |> instructions
      | 0xE6 (* switch *) -> pos + 1 |> typeidx |> tagidx |> instructions
      | 0xFB -> pos + 1 |> gc_instruction
      | 0xFC -> (
          if debug then Format.eprintf "  %d@." (get (pos + 1));
          match get (pos + 1) with
          | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 (* xx.trunc_sat_xxx_x *)
          | 19 (* add128 *)
          | 20 (* sub128 *)
          | 21 | 22 (* mul_wide *) ->
              pos + 2 |> instructions
          | 8 (* memory.init *) -> pos + 2 |> dataidx |> memidx |> instructions
          | 9 (* data.drop *) -> pos + 2 |> dataidx |> instructions
          | 10 (* memory.copy *) -> pos + 2 |> memidx |> memidx |> instructions
          | 11 (* memory.fill *) -> pos + 2 |> memidx |> instructions
          | 12 (* table.init *) ->
              pos + 2 |> elemidx |> tableidx |> instructions
          | 13 (* elem.drop *) -> pos + 2 |> elemidx |> instructions
          | 14 (* table.copy *) ->
              pos + 2 |> tableidx |> tableidx |> instructions
          | 15 (* table.grow *) | 16 (* table.size *) | 17 (* table.fill *) ->
              pos + 2 |> tableidx |> instructions
          | c -> failwith (Printf.sprintf "Bad instruction 0xFC 0x%02X" c))
      | 0xFD -> pos + 1 |> vector_instruction
      | 0xFE -> pos + 1 |> atomic_instruction
      | _ -> pos
    and gc_instruction pos =
      if debug then Format.eprintf "  %d@." (get pos);
      match get pos with
      | 0 (* struct.new *)
      | 1 (* struct.new_default *)
      | 6 (* array.new *)
      | 7 (* array.new_default *)
      | 11 (* array.get *)
      | 12 (* array.get_s *)
      | 13 (* array.get_u *)
      | 14 (* array.set *)
      | 16 (* array.fill *)
      | 32 (* struct.new_desc *)
      | 33 (* struct.new_default_desc *)
      | 34 (* ref.get_desc *) ->
          pos + 1 |> typeidx |> instructions
      | 2 (* struct.get *)
      | 3 (* struct.get_s *)
      | 4 (* struct.get_u *)
      | 5 (* struct.set *)
      | 8 (* array.new_fixed *) ->
          pos + 1 |> typeidx |> int |> instructions
      | 9 (* array.new_data *) | 18 (* array.init_data *) ->
          pos + 1 |> typeidx |> dataidx |> instructions
      | 10 (* array.new_elem *) | 19 (* array.init_elem *) ->
          pos + 1 |> typeidx |> elemidx |> instructions
      | 15 (* array.len *)
      | 26 (* any.convert_extern *)
      | 27 (* extern.convert_any *)
      | 28 (* ref.i31 *)
      | 29 (* i31.get_s *)
      | 30 (* i31.get_u *) ->
          pos + 1 |> instructions
      | 17 (* array.copy *) -> pos + 1 |> typeidx |> typeidx |> instructions
      | 20 | 21 (* ref_test *)
      | 22 | 23 (* ref.cast*)
      | 35 | 36 (* ref.cast_desc_eq *) ->
          pos + 1 |> heaptype |> instructions
      | 24 (* br_on_cast *)
      | 25 (* br_on_cast_fail *)
      | 37 (* br_on_cast_desc_eq *)
      | 38 (* br_on_cast_desc_eq_fail *) ->
          pos + 2 |> labelidx |> heaptype |> heaptype |> instructions
      | c -> failwith (Printf.sprintf "Bad instruction 0xFB 0x%02X" c)
    and vector_instruction pos =
      if debug then Format.eprintf "  %d@." (get pos);
      (* [uint32] already consumes the (LEB-encoded) SIMD sub-opcode, so each
         arm starts at the immediate — do not skip another byte. *)
      let pos, i = uint32 pos in
      match i with
      | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 92
      | 93 (* v128.load / store *) ->
          pos |> memarg |> instructions
      | 84 | 85 | 86 | 87 | 88 | 89 | 90 | 91 (* v128.load/store_lane *) ->
          pos |> memarg |> laneidx |> instructions
      | 12 (* v128.const *) | 13 (* v128.shuffle *) -> pos + 16 |> instructions
      | 21 | 22 | 23 | 24 | 25 | 26 | 27 | 28 | 29 | 30 | 31 | 32 | 33
      | 34 (* xx.extract/replace_lane *) ->
          pos |> laneidx |> instructions
      | ( 162 | 165 | 166 | 175 | 176 | 178 | 179 | 180 | 187 | 194 | 197 | 198
        | 207 | 208 | 210 | 211 | 212 | 226 | 238 ) as c ->
          failwith (Printf.sprintf "Bad instruction 0xFD 0x%02X" c)
      | c ->
          if c <= 275 then pos |> instructions
          else failwith (Printf.sprintf "Bad instruction 0xFD 0x%02X" c)
    and atomic_instruction pos =
      if debug then Format.eprintf "  %d@." (get pos);
      match get pos with
      | 0 (* memory.atomic.notify *)
      | 1 | 2 (* memory.atomic.waitxx *)
      | 16 | 17 | 18 | 19 | 20 | 21 | 22 (* xx.atomic.load *)
      | 23 | 24 | 25 | 26 | 27 | 28 | 29 (* xx.atomic.store *)
      | 30 | 31 | 32 | 33 | 34 | 35 | 36 (* xx.atomic.rmw.add *)
      | 37 | 38 | 39 | 40 | 41 | 42 | 43 (* xx.atomic.rmw.sub *)
      | 44 | 45 | 46 | 47 | 48 | 49 | 50 (* xx.atomic.rmw.and *)
      | 51 | 52 | 53 | 54 | 55 | 56 | 57 (* xx.atomic.rmw.or *)
      | 58 | 59 | 60 | 61 | 62 | 63 | 64 (* xx.atomic.rmw.xor *)
      | 65 | 66 | 67 | 68 | 69 | 70 | 71 (* xx.atomic.rmw.xchg *)
      | 72 | 73 | 74 | 75 | 76 | 77 | 78 (* xx.atomic.rmw.cmpxchg *) ->
          pos + 1 |> memarg |> instructions
      | 3 (* memory.fence *) ->
          let c = get (pos + 1) in
          assert (c = 0);
          pos + 2 |> instructions
      | c -> failwith (Printf.sprintf "Bad instruction 0xFE 0x%02X" c)
    and opt_else pos =
      if debug then Format.eprintf "0x%02X (@%d) else@." (get pos) pos;
      match get pos with
      | 0x05 (* else *) -> pos + 1 |> instructions |> block_end |> instructions
      | _ -> pos |> block_end |> instructions
    and opt_catch pos =
      if debug then Format.eprintf "0x%02X (@%d) catch@." (get pos) pos;
      match get pos with
      | 0x07 (* catch *) -> pos + 1 |> tagidx |> instructions |> opt_catch
      | 0x19 (* catch_all *) ->
          pos + 1 |> instructions |> block_end |> instructions
      | 0x18 (* delegate *) -> pos + 1 |> labelidx |> instructions
      | _ -> pos |> block_end |> instructions
    and catch pos =
      match get pos with
      | 0 (* catch *) | 1 (* catch_ref *) -> pos + 1 |> tagidx |> labelidx
      | 2 (* catch_all *) | 3 (* catch_all_ref *) -> pos + 1 |> labelidx
      | c -> failwith (Printf.sprintf "bad catch 0x%02x@." c)
    and on_clause pos =
      match get pos with
      | 0 (* on *) -> pos + 1 |> tagidx |> labelidx
      | 1 (* on .. switch *) -> pos + 1 |> tagidx
      | c -> failwith (Printf.sprintf "bad on clause 0x%02x@." c)
    and block_end pos =
      if debug then Format.eprintf "0x%02X (@%d) block end@." (get pos) pos;
      match get pos with
      | 0x0B -> pos + 1
      | c -> failwith (Printf.sprintf "Bad instruction 0x%02X" c)
    in
    let locals pos = pos |> int |> valtype in
    let expr pos = pos |> instructions |> block_end in
    let func pos =
      start := pos;
      in_func := true;
      let res = pos |> vector locals |> expr |> flush in
      in_func := false;
      res
    in
    let mut pos = pos + 1 in
    let limits pos =
      let c = get pos in
      assert (c < 8);
      if c land 1 = 0 then pos + 1 |> int else pos + 1 |> int |> int
    in
    let tabletype pos =
      mark pos;
      pos |> reftype |> limits
    in
    let table pos =
      match get pos with
      | 0x40 ->
          assert (get (pos + 1) = 0);
          pos + 2 |> tabletype |> expr
      | _ -> pos |> tabletype
    in
    let table_section ~count pos =
      start := pos;
      pos |> repeat count table |> flush
    in
    let globaltype pos =
      mark pos;
      pos |> valtype |> mut
    in
    let global pos = pos |> globaltype |> expr in
    let global_entry pos =
      start := pos;
      let pos' = global pos in
      flush pos';
      pos'
    in
    (* Go through [count] entries, dropping the ones not satisfying [keep]. *)
    let filtered_entries entry ~keep ~count pos =
      let rec loop j pos =
        if j = count then pos
        else if keep j then loop (j + 1) (entry pos)
        else (
          flush pos;
          skipping := true;
          let pos' = entry pos in
          skipping := analysis;
          start := pos';
          loop (j + 1) pos')
      in
      loop 0 pos
    in
    let elemkind pos =
      assert (get pos = 0);
      pos + 1
    in
    (* An active element segment with an implicit table (kinds 0 and 4) names
       table 0. When linking moves this module's table 0 to another output index,
       rewrite the segment to its explicit-table form (kinds 2 and 6): swap the
       [flag], insert the remapped index after it, and insert the element type
       ([mid]: an elemkind or a reftype) that the explicit form carries before the
       element vector. [pos] is the flag byte. (Unlike [memarg], this needs no
       [report] of the LEB-width change: resize bookkeeping feeds the source map,
       which describes only the instruction stream, and a segment lives in the
       element section, never in a function body.) *)
    let active_elem ~flag ~mid element pos =
      if !skipping || table_map 0 = 0 then pos + 1 |> expr |> vector element
      else (
        flush' pos (pos + 1);
        Buffer.add_char buf flag;
        output_uint buf (table_map 0);
        let after_expr = pos + 1 |> expr in
        flush' after_expr after_expr;
        Buffer.add_char buf mid;
        after_expr |> vector element)
    in
    let elem pos =
      match get pos with
      | 0 -> pos |> active_elem ~flag:'\x02' ~mid:'\x00' funcidx
      | 1 -> pos + 1 |> elemkind |> vector funcidx
      | 2 -> pos + 1 |> tableidx |> expr |> elemkind |> vector funcidx
      | 3 -> pos + 1 |> elemkind |> vector funcidx
      | 4 -> pos |> active_elem ~flag:'\x06' ~mid:'\x70' expr
      | 5 -> pos + 1 |> reftype |> vector expr
      | 6 -> pos + 1 |> tableidx |> expr |> reftype |> vector expr
      | 7 -> pos + 1 |> reftype |> vector expr
      | c -> failwith (Printf.sprintf "Bad element 0x%02X" c)
    in
    let bytes pos =
      let pos, len = uint32 pos in
      pos + len
    in
    let data pos =
      match get pos with
      | 0 ->
          (* Active data segment with an implicit memory (kind 0) names memory 0;
             rewrite to the explicit-memory form (kind 2) when linking moves this
             module's memory 0 elsewhere. *)
          if !skipping || mem_map 0 = 0 then pos + 1 |> expr |> bytes
          else (
            flush' pos (pos + 1);
            Buffer.add_char buf '\x02';
            output_uint buf (mem_map 0);
            pos + 1 |> expr |> bytes)
      | 1 -> pos + 1 |> bytes
      | 2 -> pos + 1 |> memidx |> expr |> bytes
      | c -> failwith (Printf.sprintf "Bad data segment 0x%02X" c)
    in
    (* A segment that is not kept is a declarative segment, or a passive
       segment which is not used: it only matters as a declaration of the
       functions it mentions, so only the live functions it lists are kept (a
       removed function is mapped to [-1]). A segment of expressions (flags 5
       and 7) becomes a segment of function indices (flags 1 and 3): its type
       and its other expressions may refer to removed entries. *)
    let filtered_elem pos =
      let flag = get pos in
      flush pos;
      let item pos =
        match flag with
        | 1 | 3 ->
            let pos', idx = uint32 pos in
            (pos', Some idx)
        | _ ->
            if get pos = 0xD2 && get (int (pos + 1)) = 0x0B then
              let pos', idx = uint32 (pos + 1) in
              (pos' + 1, Some idx)
            else (expr pos, None)
      in
      let rec collect n pos acc =
        if n = 0 then (pos, List.rev acc)
        else
          let pos', idx = item pos in
          let acc =
            match idx with
            | Some idx when func_map idx >= 0 -> func_map idx :: acc
            | Some _ | None -> acc
          in
          collect (n - 1) pos' acc
      in
      skipping := true;
      let pos' =
        match flag with
        | 1 | 3 -> pos + 1 |> elemkind
        | 5 | 7 -> pos + 1 |> reftype
        | c -> failwith (Printf.sprintf "Bad element 0x%02X" c)
      in
      let pos', n = uint32 pos' in
      let pos', l = collect n pos' [] in
      skipping := analysis;
      Buffer.add_char buf (Char.chr (if flag = 1 || flag = 5 then 1 else 3));
      Buffer.add_char buf (Char.chr 0);
      output_uint buf (List.length l);
      List.iter (fun idx -> output_uint buf idx) l;
      start := pos';
      pos'
    in
    let elem_section ~keep ~count pos =
      start := pos;
      let rec loop j pos =
        if j = count then pos
        else loop (j + 1) (if keep j then elem pos else filtered_elem pos)
      in
      pos |> loop 0 |> flush
    in
    let data_section ~keep ~count pos =
      start := pos;
      pos |> filtered_entries (fun pos -> data pos) ~keep ~count |> flush
    in
    let local_nameassoc pos = pos |> localidx |> name in
    let local_namemap pos =
      start := pos;
      pos |> vector local_nameassoc |> flush
    in
    {
      table_section;
      elem_section;
      data_section;
      func;
      local_namemap;
      table;
      global;
      global_entry;
      elem;
      data;
    }

  let table_section positions maps buf s =
    (scanner
       (fun _ _ -> ())
       (fun pos -> push_position positions pos)
       maps buf s)
      .table_section

  let global_entry maps buf s =
    (scanner (fun _ _ -> ()) (fun _ -> ()) maps buf s).global_entry

  let elem_section maps buf s =
    (scanner (fun _ _ -> ()) (fun _ -> ()) maps buf s).elem_section

  let data_section maps buf s =
    (scanner (fun _ _ -> ()) (fun _ -> ()) maps buf s).data_section

  let func resize_data maps buf s =
    (scanner
       (fun pos delta -> push_resize resize_data pos delta)
       (fun _ -> ())
       maps buf s)
      .func

  let local_namemap buf s =
    (scanner (fun _ _ -> ()) (fun _ -> ()) default_maps buf s).local_namemap

  let analysis ~visit s =
    scanner ~analysis:true ~visit
      (fun _ _ -> ())
      (fun _ -> ())
      default_maps (Buffer.create 0) s
end

type t = {
  module_name : string;
  file : string;
  contents : Read.t;
  source_map_contents : Source_map.Standard.t option;
}

(* Fate of one import after resolution. [Resolved (m, k)]: it binds to entity
   [k] (in the kind's local index space) of input module [m]. [Unresolved i]:
   it stays an import of the merged module, at index [i] among that kind's
   residual imports. *)
type import_status = Resolved of int * int | Unresolved of int

let check_limits export import =
  (* Beyond the min/max bounds, a memory or table type only matches an import
     when the address type (i32 / i64), the page size and the shared flag are
     the same — otherwise, e.g., an i32 memory would satisfy an i64 import.
     [page_size_log2 = None] denotes the default page (2^16), so normalise
     before comparing. *)
  export.address_type = import.address_type
  && export.shared = import.shared
  && Option.value ~default:16 export.page_size_log2
     = Option.value ~default:16 import.page_size_log2
  && Uint64.compare export.mi import.mi >= 0
  &&
  match (export.ma, import.ma) with
  | _, None -> true
  | None, Some _ -> false
  | Some e, Some i -> Uint64.compare e i <= 0

let subtype (info : link_subtyping_info) (i : int) (i' : int) =
  Wax_wasm.Types.heap_subtype info.wasm_info
    (Type (get_id info.types_map i))
    (Type (get_id info.types_map i'))

let val_subtype (info : link_subtyping_info) (ty : valtype) (ty' : valtype) =
  Wax_wasm.Types.val_subtype info.wasm_info
    (To_internal.valtype info.types_map ty)
    (To_internal.valtype info.types_map ty')

let check_export_import_types d ~subtyping_info ~files i (desc : importdesc) i'
    import =
  let ok =
    match (desc, import.desc) with
    | Func { exact = e_exact; typ = t }, Func { exact = i_exact; typ = t' } ->
        (* An exact import ([(func (exact …))], custom-descriptors) requires the
           export to be exact too and to have exactly the imported type, not
           merely a subtype: an inexact export (an inexactly-imported function
           re-exported) could dynamically be a subtype, which a static linker
           cannot rule out, so it is rejected. A defined function is exact
           (see below); canonicalisation gives equal types equal identities, and
           [types_map] resolves both output-space descriptor indices to that
           identity (a name-variant copy resolves to its representative). *)
        if i_exact then e_exact && type_id_eq subtyping_info.types_map t t'
        else subtype subtyping_info t t'
    | ( Table { limits; reftype = typ },
        Table { limits = limits'; reftype = typ' } ) ->
        check_limits limits limits' && reftype_eq subtyping_info typ typ'
    | Memory limits, Memory limits' -> check_limits limits limits'
    | Global { mut; typ }, Global { mut = mut'; typ = typ' } ->
        mut = mut'
        &&
        if mut then valtype_eq subtyping_info typ typ'
        else val_subtype subtyping_info typ typ'
    | Tag t, Tag t' -> type_id_eq subtyping_info.types_map t t'
    | _ -> false
  in
  if not ok then (
    Wax_utils.Diagnostic.report d ~location:dummy_loc ~severity:Error
      ~message:
        Wax_utils.Message.(
          (text "In module" ++ str files.(i').file)
          ^^ text "," ++ text "the import"
             ++ import_atom import.module_ import.name
             ++ text "refers to an export in module"
             ++ str files.(i).file
             ++ text "of an incompatible type.")
      ();
    Wax_utils.Diagnostic.abort ())

(* Output index of every entity of [kind], per input module. The merged layout
   places all residual (unresolved) imports first (there are
   [unresolved_imports] of them), then each module's definitions in module
   order; [counts.(i)] is module [i]'s definition count. The result
   [mappings.(i).(k)] is the output index of local entity [k] of module [i]
   (its imports first, then its definitions). A dead entity (according to
   [live]) is mapped to [-1].

   Two passes: the first lays out definitions and residual imports, leaving a
   resolved import at [-1]; the second patches each resolved import to the
   output index of its target. The split is required because an import may
   resolve to a definition in a *later* module, whose layout the first pass has
   not reached yet. *)
let build_mappings ~live resolved_imports unresolved_imports kind counts =
  let current_offset = ref (get_exportable_info unresolved_imports kind) in
  let mappings =
    Array.mapi
      (fun i count ->
        let imports = get_exportable_info resolved_imports.(i) kind in
        let import_count = Array.length imports in
        let live = get_exportable_info live.(i) kind in
        Array.init
          (Array.length imports + count)
          (fun i ->
            if i < import_count then
              match imports.(i) with Unresolved i -> i | Resolved _ -> -1
            else if live.(i) then (
              let idx = !current_offset in
              incr current_offset;
              idx)
            else -1))
      counts
  in
  Array.iteri
    (fun i map ->
      let imports = get_exportable_info resolved_imports.(i) kind in
      for i = 0 to Array.length imports - 1 do
        match imports.(i) with
        | Unresolved _ -> ()
        | Resolved (j, k) -> map.(i) <- mappings.(j).(k)
      done)
    mappings;
  mappings

(* [build_mappings] for kinds that have no imports (elements, data segments):
   the output is just each module's entities concatenated in module order. *)
let build_simple_mappings ~counts =
  let current_offset = ref 0 in
  Array.map
    (fun count ->
      let offset = !current_offset in
      current_offset := !current_offset + count;
      Array.init count (fun j -> j + offset))
    counts

let add_section out_ch ~id ?count buf =
  match count with
  | Some 0 -> Buffer.clear buf
  | _ ->
      let buf' = Buffer.create 5 in
      Option.iter (fun c -> Write.uint buf' c) count;
      output_byte out_ch id;
      output_uint out_ch (Buffer.length buf' + Buffer.length buf);
      Buffer.output_buffer out_ch buf';
      Buffer.output_buffer out_ch buf;
      Buffer.clear buf

let add_subsection buf ~id ?count buf' =
  match count with
  | Some 0 -> Buffer.clear buf'
  | _ ->
      let buf'' = Buffer.create 5 in
      Option.iter (fun c -> Write.uint buf'' c) count;
      Buffer.add_char buf (Char.chr id);
      Write.uint buf (Buffer.length buf'' + Buffer.length buf');
      Buffer.add_buffer buf buf'';
      Buffer.add_buffer buf buf';
      Buffer.clear buf'

(* Re-check every resolved import against the export it bound to, now that the
   export's own (possibly remapped) type is known. [resolve] already checked
   each hop, but only against the interface as read; this catches mismatches
   that surface once definitions are laid out. [to_desc i' idx'] recovers the
   type of entity [idx'] defined by module [i'] (or [None] if that entity is
   itself a residual import, which needs no check here). *)
let check_exports_against_imports d ~intfs ~subtyping_info ~resolved_imports
    ~files ~kind ~to_desc =
  Array.iteri
    (fun i intf ->
      let imports = get_exportable_info intf.Read.imports kind in
      let statuses = get_exportable_info resolved_imports.(i) kind in
      Array.iter2
        (fun import status ->
          match status with
          | Unresolved _ -> ()
          | Resolved (i', idx') -> (
              match to_desc i' idx' with
              | None -> ()
              | Some desc ->
                  check_export_import_types d ~subtyping_info ~files i' desc i
                    import))
        imports statuses)
    intfs

(* Two ways to supply [check_exports_against_imports]'s [to_desc], i.e. to
   recover a defined entity's type. [read_desc_from_file] re-reads it from the
   input at a byte position stashed during the section scan (used when the type
   was never materialised, e.g. tables/globals); it returns [None] for the
   entity's imports, whose descriptors precede the definitions ([j < offset]).
   [defined_entity] instead reads it from an in-memory array of already-parsed
   entries, [get i k] returning the type of the [k]-th entity defined by module
   [i]; [None] for the entity's imports. Neither depends on the output layout,
   so an import is still checked against an export whose target dead code
   elimination removes. *)
let read_desc_from_file ~intfs ~files ~positions ~read i j =
  let offset =
    Array.length (get_exportable_info intfs.(i).Read.imports Table)
  in
  if j < offset then None
  else
    let { contents; _ } = files.(i) in
    Read.seek_in contents.ch positions.(i).Scan.pos.(j - offset);
    Some (read contents)

let defined_entity ~intfs ~kind ~get i j =
  let offset = Array.length (get_exportable_info intfs.(i).Read.imports kind) in
  if j < offset then None else Some (get i (j - offset))

let write_simple_section d ~live ~intfs ~subtyping_info ~resolved_imports
    ~unresolved_imports ~files ~out_ch ~kind ~read ~to_type ~write =
  let data = Array.map (fun f -> read f.contents) files in
  let entries =
    Array.concat
      (Array.to_list
         (Array.mapi
            (fun i data ->
              let live = get_exportable_info live.(i) kind in
              let offset = Array.length live - Array.length data in
              Array.of_list
                (List.filteri
                   (fun j _ -> live.(j + offset))
                   (Array.to_list data)))
            data))
  in
  if Array.length entries <> 0 then write out_ch entries;
  let counts = Array.map Array.length data in
  let mappings =
    build_mappings ~live resolved_imports unresolved_imports kind counts
  in
  check_exports_against_imports d ~intfs ~subtyping_info ~resolved_imports
    ~files ~kind
    ~to_desc:
      (defined_entity ~intfs ~kind ~get:(fun i k -> to_type data.(i).(k)));
  mappings

(* Scan section [id] of each input. [written i count] is the number of entries
   actually written for module [i] (default: all of them), and [extra] can
   append entries, returning their number. *)
let write_section_with_scan ?(written = fun _ count -> count)
    ?(extra = fun _ -> 0) ~type_maps ~files ~out_ch ~buf ~id ~scan () =
  let counts =
    Array.mapi
      (fun i { contents; _ } ->
        if Read.find_section contents id then (
          let count = Read.uint contents.ch in
          scan i
            { Scan.default_maps with typ = type_maps.(i) }
            buf contents.ch.buf ~count contents.ch.pos;
          count)
        else 0)
      files
  in
  let extra_count = extra buf in
  add_section out_ch ~id
    ~count:(extra_count + Array.fold_left ( + ) 0 (Array.mapi written counts))
    buf;
  counts

let write_simple_namemap ~name_sections ~name_section_buffer ~buf ~section_id
    ~mappings =
  let count = ref 0 in
  Array.iter2
    (fun name_section mapping ->
      if Read.find_section name_section section_id then
        let map = Read.namemap name_section in
        Array.iter
          (fun (idx, name) ->
            let idx = mapping.(idx) in
            if idx >= 0 then (
              Write.nameassoc buf idx name;
              incr count))
          map)
    name_sections mappings;
  add_subsection name_section_buffer ~id:section_id ~count:!count buf

let write_namemap ~resolved_imports ~unresolved_imports ~name_sections
    ~name_section_buffer ~buf ~kind ~section_id ~mappings =
  let import_names =
    Array.make (get_exportable_info unresolved_imports kind) None
  in
  Array.iteri
    (fun i name_section ->
      if Read.find_section name_section section_id then
        let imports = get_exportable_info resolved_imports.(i) kind in
        let import_count = Array.length imports in
        let n = Read.uint name_section.ch in
        let rec loop j =
          if j < n then
            let idx = Read.uint name_section.ch in
            let name = Read.name name_section.ch in
            if idx < import_count then (
              let idx' =
                match imports.(idx) with
                | Unresolved idx' -> idx'
                | Resolved (i', idx') -> mappings.(i').(idx')
              in
              if
                idx' >= 0
                && idx' < Array.length import_names
                && Option.is_none import_names.(idx')
              then import_names.(idx') <- Some name;
              loop (j + 1))
        in
        loop 0)
    name_sections;
  let count = ref 0 in
  Array.iteri
    (fun idx name ->
      match name with
      | None -> ()
      | Some name ->
          incr count;
          Write.nameassoc buf idx name)
    import_names;
  (* Entries must be sorted by index, which may differ from the input order
     (globals are reordered) *)
  let entries = ref [] in
  Array.iteri
    (fun i name_section ->
      if Read.find_section name_section section_id then
        let mapping = mappings.(i) in
        let imports = get_exportable_info resolved_imports.(i) kind in
        let import_count = Array.length imports in
        let n = Read.uint name_section.ch in
        let ch = name_section.ch in
        for _ = 1 to n do
          let idx = Read.uint ch in
          let len = Read.uint ch in
          if idx >= import_count && mapping.(idx) >= 0 then
            entries := (mapping.(idx), ch.buf, ch.pos, len) :: !entries;
          ch.pos <- ch.pos + len
        done)
    name_sections;
  List.iter
    (fun (idx, s, pos, len) ->
      incr count;
      Write.uint buf idx;
      Write.uint buf len;
      Buffer.add_substring buf s pos len)
    (List.sort (fun (i, _, _, _) (i', _, _, _) -> compare i i') !entries);
  add_subsection name_section_buffer ~id:section_id ~count:!count buf

(* Merge the indirect name maps (locals, labels) of each input, remapping the
   outer (function) index through [mappings] (= [func_mappings]) and copying the
   inner map verbatim (local/label indices are per-function, so linking leaves
   them untouched). The concatenation is emitted without an explicit sort yet is
   a valid — sorted, duplicate-free — name map: an indirect name map only ever
   names *defined* functions (imports have no body, hence no locals or labels),
   and for definitions [func_mappings] is order-preserving. Each module's
   defined functions form one contiguous output block with strictly increasing
   bases in module order, the inputs are visited in that same order, and every
   input map is already sorted, so the blocks land back-to-back in order. This
   would only break for a name entry on an *imported* function, which
   well-formed input cannot contain. *)
let write_indirectnamemap ~name_sections ~name_section_buffer ~buf ~section_id
    ~mappings =
  let count = ref 0 in
  Array.iter2
    (fun name_section mapping ->
      if Read.find_section name_section section_id then
        let n = Read.uint name_section.ch in
        let scan_map = Scan.local_namemap buf name_section.ch.buf in
        for _ = 1 to n do
          let idx = mapping.(Read.uint name_section.ch) in
          let p0 = Buffer.length buf in
          Write.uint buf (max idx 0);
          let p = Buffer.length buf in
          scan_map name_section.ch.pos;
          name_section.ch.pos <- name_section.ch.pos + Buffer.length buf - p;
          (* A removed function: drop its entry *)
          if idx >= 0 then incr count else Buffer.truncate buf p0
        done)
    name_sections mappings;
  add_subsection name_section_buffer ~id:section_id ~count:!count buf

(* Resolve an import to the (module, index) that ultimately provides it,
   following re-export chains: when the matched export is itself an imported
   entity (its index falls in the exporting module's import range) recurse into
   that import, stopping at the first real definition — or at the last hop whose
   own target is not exported by the set. Raises [Not_found] (from
   [Hashtbl.find]) when [(module_, name)] is exported nowhere, which leaves the
   import unresolved. [depth] guards against a re-export cycle; every hop is
   type-checked. *)
let rec resolve d depth ~files ~intfs ~subtyping_info ~exports ~kind i
    ({ module_; name; _ } as import) =
  let i', index = Hashtbl.find exports (module_, name) in
  let imports = get_exportable_info intfs.(i').Read.imports kind in
  if index < Array.length imports then (
    if depth > 100 then (
      Wax_utils.Diagnostic.report d ~location:dummy_loc ~severity:Error
        ~message:
          Wax_utils.Message.(
            (text "Import loop on" ++ import_atom module_ name) ^^ text ".")
        ();
      Wax_utils.Diagnostic.abort ());
    let entry = imports.(index) in
    check_export_import_types d ~subtyping_info ~files i' entry.desc i import;
    try
      resolve d (depth + 1) ~files ~intfs ~subtyping_info ~exports ~kind i'
        entry
    with Not_found -> (i', index))
  else (i', index)

type input = {
  module_name : string;
  file : string;
  code : string option;
  opt_source_map : Source_map.Standard.t option;
}

type dependency = {
  name : string;
  export : string option;
  import : (string * string) option;
  reaches : string list;
  root : bool;
}

(* Parse a dependency graph in the JSON format of binaryen's [wasm-metadce]: a
   list of objects with fields [name], and optionally [export], [import] (a pair
   [[module, name]]), [reaches] (a list of node names) and [root]. *)
let parse_dependencies s =
  let open Yojson.Basic.Util in
  let opt f = function `Null -> None | v -> Some (f v) in
  List.map
    (fun node ->
      {
        name = node |> member "name" |> to_string;
        export = node |> member "export" |> opt to_string;
        import =
          node |> member "import"
          |> opt (fun v ->
              match to_list v with
              | [ m; n ] -> (to_string m, to_string n)
              | _ -> raise (Type_error ("bad import", v)));
        reaches =
          node |> member "reaches"
          |> opt (fun l -> List.map to_string (to_list l))
          |> Option.value ~default:[];
        root =
          node |> member "root" |> opt to_bool |> Option.value ~default:false;
      })
    (to_list (Yojson.Basic.from_string s))

(* Raised by [priority_topological_sort] when the dependencies form a cycle,
   with the nodes that could not be ordered. *)
exception Cycle of int list

(* Order the nodes [0 .. n - 1] so that each node comes after the nodes it
   depends on, choosing the node with the highest priority whenever there is a
   choice (then the lowest index). *)
let priority_topological_sort ~n ~deps ~priority =
  let module S = Set.Make (struct
    type t = int * int

    let compare (p, i) (p', i') =
      match compare p' p with 0 -> compare i i' | c -> c
  end) in
  let pending = Array.make n 0 in
  let successors = Array.make n [] in
  for i = 0 to n - 1 do
    List.iter
      (fun j ->
        if j <> i then (
          pending.(i) <- pending.(i) + 1;
          successors.(j) <- i :: successors.(j)))
      (deps i)
  done;
  let ready = ref S.empty in
  for i = 0 to n - 1 do
    if pending.(i) = 0 then ready := S.add (priority i, i) !ready
  done;
  let order = Array.make n 0 in
  for k = 0 to n - 1 do
    if S.is_empty !ready then
      raise
        (Cycle
           (List.filter (fun i -> pending.(i) > 0) (List.init n (fun i -> i))));
    let ((_, i) as elt) = S.min_elt !ready in
    ready := S.remove elt !ready;
    order.(k) <- i;
    List.iter
      (fun j ->
        pending.(j) <- pending.(j) - 1;
        if pending.(j) = 0 then ready := S.add (priority j, j) !ready)
      successors.(i)
  done;
  order

type item =
  | Entity of int * exportable * int
  | Segment of int * int
  | Data_segment of int * int

(* Positions of the entries of a section, given a function that skips one
   entry. *)
let section_entries (contents : Read.t) id skip =
  if Read.find_section contents id then
    let count = Read.uint contents.ch in
    let pos = ref contents.ch.pos in
    Array.init count (fun _ ->
        let p = !pos in
        pos := skip p;
        p)
  else [||]

(* Raised by [order_globals] when global initializers read each other in a
   cycle, with the globals (module, local index) involved. *)
exception Global_initializer_cycle of (int * int) list

(* Positions of the function bodies (after their size). *)
let code_entries (contents : Read.t) =
  if Read.find_section contents 10 then
    let ch = contents.ch in
    let count = Read.uint ch in
    Array.init count (fun _ ->
        let size = Read.uint ch in
        let p = ch.pos in
        ch.pos <- p + size;
        p)
  else [||]

let iter_types f rectype =
  ignore
    (Remap.rectype
       (fun i ->
         f i;
         i)
       rectype
      : rectype)

let iter_importdesc_types f (desc : importdesc) =
  match desc with
  | Func { typ; _ } | Tag typ -> f typ
  | Table { reftype; _ } ->
      ignore
        (Remap.reftype
           (fun i ->
             f i;
             i)
           reftype
          : reftype)
  | Global { typ; _ } ->
      ignore
        (Remap.valtype
           (fun i ->
             f i;
             i)
           typ
          : valtype)
  | Memory _ -> ()

(* Order the live global definitions so that the initializer of a global only
   refers to earlier globals, choosing the most used globals first. *)
let order_globals ~resolved_imports ~live ~global_counts ~global_deps =
  let global_import_count i =
    Array.length (get_exportable_info resolved_imports.(i) Global)
  in
  let definition i j =
    if j < global_import_count i then
      match (get_exportable_info resolved_imports.(i) Global).(j) with
      | Resolved (i', j') when j' >= global_import_count i' -> Some (i', j')
      | Resolved _ | Unresolved _ -> None
    else Some (i, j)
  in
  let global_ids =
    Array.map (fun l -> Array.make (Array.length l.global) (-1)) live
  in
  let nodes = ref [] in
  let n = ref 0 in
  Array.iteri
    (fun i l ->
      Array.iteri
        (fun j is_live ->
          if is_live && j >= global_import_count i then (
            global_ids.(i).(j) <- !n;
            incr n;
            nodes := (i, j) :: !nodes))
        l.global)
    live;
  let nodes = Array.of_list (List.rev !nodes) in
  let node_id i j =
    match definition i j with
    | Some (i', j') -> global_ids.(i').(j')
    | None -> -1
  in
  let priorities = Array.make (Array.length nodes) 0 in
  Array.iteri
    (fun i counts ->
      Array.iteri
        (fun j c ->
          let id = node_id i j in
          if id >= 0 then priorities.(id) <- priorities.(id) + c)
        counts)
    global_counts;
  let order =
    try
      priority_topological_sort ~n:(Array.length nodes)
        ~deps:(fun id ->
          let i, j = nodes.(id) in
          List.filter
            (fun id -> id >= 0)
            (List.map (fun j' -> node_id i j') global_deps.(i).(j)))
        ~priority:(fun id -> priorities.(id))
    with Cycle l ->
      raise (Global_initializer_cycle (List.map (fun id -> nodes.(id)) l))
  in
  Array.map (fun id -> nodes.(id)) order

type ordering = {
  type_groups : int array;
      (** Output slots of the first type of the live rec groups, in order *)
  globals : (int * int) array;
      (** Live global definitions (module, local index), in order *)
  global_positions : int array array;
      (** Position of each global definition in the input modules *)
}

type liveness = {
  live : bool array exportable_info array;
      (** Per input module, for each local index (imports included) *)
  segments : bool array array;
  data : bool array array;
  unresolved : bool array exportable_info;
  keep_export : string -> bool;
      (** Whether an export (by output name) is kept *)
  ordering : ordering;
      (** How to order types and globals; when removing dead code, the most used
          ones get the smallest indices *)
  undeclared_functions : (int * int) list;
      (** Functions referenced by [ref.func] in function bodies which would not
          be declared anymore in the output, since the global initializers or
          exports which declared them have been removed *)
}

(* Compute which entries are reachable from the roots: the start functions, the
   exports that are kept, tables, active data and element segments. If
   [dependencies] is provided, the exports that are kept are the ones reachable
   from its root nodes (see [f]); an import node is reached when the
   corresponding import is live. Without [dependencies], everything is live.

   Types are identified by output slot ([groups] lists the output rec groups,
   in output-slot space, with the slot of their first type). *)
let compute_liveness ~files ~(types : Read.types) ~groups ~resolved_imports
    ~(import_list : import array exportable_info) ~unresolved_imports ~functions
    ~tags ~start_type ~intfs ~exported_names ~dependencies =
  let import_count i kind =
    Array.length (get_exportable_info resolved_imports.(i) kind)
  in
  let dce = Option.is_some dependencies in
  let section_size (contents : Read.t) id =
    if Read.find_section contents id then Read.uint contents.ch else 0
  in
  let live =
    Array.mapi
      (fun i { contents; _ } ->
        {
          func =
            Array.make
              (import_count i Func + Array.length functions.(i))
              (not dce);
          table =
            Array.make (import_count i Table + section_size contents 4) true;
          mem =
            Array.make (import_count i Memory + section_size contents 5) true;
          global =
            Array.make
              (import_count i Global + section_size contents 6)
              (not dce);
          tag =
            Array.make (import_count i Tag + Array.length tags.(i)) (not dce);
        })
      files
  in
  let unresolved =
    map_exportable_info
      (fun kind n ->
        match kind with
        | Table | Memory -> Array.make n true
        | Func | Global | Tag -> Array.make n (not dce))
      unresolved_imports
  in
  let segments =
    Array.map
      (fun { contents; _ } -> Array.make (section_size contents 9) (not dce))
      files
  in
  let data =
    Array.map
      (fun { contents; _ } -> Array.make (Read.data_count contents) (not dce))
      files
  in
  let global_counts =
    Array.map (fun l -> Array.make (Array.length l.global) 0) live
  in
  (* The globals referenced by the initializer of each global *)
  let global_deps =
    Array.map (fun l -> Array.make (Array.length l.global) []) live
  in
  let current_global = ref None in
  let positions id entry =
    Array.map
      (fun { contents; _ } ->
        section_entries contents id
          (entry (Scan.analysis ~visit:(fun _ _ -> ()) contents.ch.buf)))
      files
  in
  if not dce then
    (* Keep the order of the input, except for globals whose initializer
       refers to a global defined later *)
    let global_positions =
      Array.mapi
        (fun i { contents; _ } ->
          let scanner =
            Scan.analysis
              ~visit:(fun kind idx ->
                match (kind, !current_global) with
                | `Global, Some j ->
                    global_deps.(i).(j) <- idx :: global_deps.(i).(j)
                | _ -> ())
              contents.ch.buf
          in
          let k = ref (import_count i Global) in
          section_entries contents 6 (fun pos ->
              current_global := Some !k;
              incr k;
              scanner.global pos))
        files
    in
    {
      live;
      segments;
      data;
      unresolved;
      keep_export = (fun _ -> true);
      ordering =
        {
          type_groups = Array.of_list (List.map fst groups);
          globals =
            order_globals ~resolved_imports ~live ~global_counts ~global_deps;
          global_positions;
        };
      undeclared_functions = [];
    }
  else
    let stack = Stack.create () in
    (* Types (by output slot): a type is live with its whole rec group *)
    let type_count = Read.output_type_count types in
    let type_live = Array.make type_count false in
    let type_counts = Array.make type_count 0 in
    let group_of_slot = Array.make type_count (-1) in
    let group_array = Array.of_list groups in
    Array.iteri
      (fun g (base, rectype) ->
        Array.iteri (fun j _ -> group_of_slot.(base + j) <- g) rectype)
      group_array;
    let rec mark_type t =
      type_counts.(t) <- type_counts.(t) + 1;
      if not type_live.(t) then (
        let base, rectype = group_array.(group_of_slot.(t)) in
        Array.iteri (fun j _ -> type_live.(base + j) <- true) rectype;
        iter_types mark_type rectype)
    in
    Option.iter mark_type start_type;
    (* Functions referenced by [ref.func] in function bodies, and functions
       declared in global initializers *)
    let ref_funcs = ref [] in
    let declared = ref [] in
    let in_function = ref false in
    let mark i kind j =
      let l = get_exportable_info live.(i) kind in
      if not l.(j) then (
        l.(j) <- true;
        Stack.push (Entity (i, kind, j)) stack)
    in
    let mark_segment i j =
      if not segments.(i).(j) then (
        segments.(i).(j) <- true;
        Stack.push (Segment (i, j)) stack)
    in
    let mark_data i j =
      if not data.(i).(j) then (
        data.(i).(j) <- true;
        Stack.push (Data_segment (i, j)) stack)
    in
    (* Exports, by output name *)
    let exports = Hashtbl.create 128 in
    Array.iteri
      (fun i intf ->
        iter_exportable_info
          (fun kind lst ->
            List.iter
              (fun (name, idx) ->
                match exported_names i name with
                | Some name -> Hashtbl.add exports name (i, kind, idx)
                | None -> ())
              lst)
          intf.Read.exports)
      intfs;
    let kept_exports = Hashtbl.create 16 in
    let keep_export name =
      if Hashtbl.mem exports name && not (Hashtbl.mem kept_exports name) then (
        Hashtbl.replace kept_exports name ();
        List.iter
          (fun (i, kind, idx) -> mark i kind idx)
          (Hashtbl.find_all exports name))
    in
    (* Dependency graph *)
    let dependencies = Option.value ~default:[] dependencies in
    let nodes = Hashtbl.create 128 in
    let import_nodes = Hashtbl.create 128 in
    List.iter
      (fun (node : dependency) ->
        Hashtbl.replace nodes node.name node;
        Option.iter
          (fun import -> Hashtbl.add import_nodes import node)
          node.import)
      dependencies;
    let reached = Hashtbl.create 128 in
    let rec reach (node : dependency) =
      if not (Hashtbl.mem reached node.name) then (
        Hashtbl.replace reached node.name ();
        Option.iter keep_export node.export;
        List.iter
          (fun name ->
            match Hashtbl.find_opt nodes name with
            | Some node -> reach node
            | None -> ())
          node.reaches)
    in
    let mark_unresolved kind u =
      let l = get_exportable_info unresolved kind in
      if not l.(u) then (
        l.(u) <- true;
        let { module_; name; desc } =
          (get_exportable_info import_list kind).(u)
        in
        iter_importdesc_types mark_type desc;
        List.iter reach (Hashtbl.find_all import_nodes (module_, name)))
    in
    List.iter
      (fun (node : dependency) -> if node.root then reach node)
      dependencies;
    (* Imported tables and memories are always kept: they are used *)
    Array.iter
      (fun { desc; _ } -> iter_importdesc_types mark_type desc)
      import_list.table;
    Array.iter
      (fun { module_; name; _ } ->
        List.iter reach (Hashtbl.find_all import_nodes (module_, name)))
      (Array.append import_list.table import_list.mem);
    (* Other roots *)
    let scanners =
      Array.mapi
        (fun i { contents; _ } ->
          let type_mapping = Read.get_type_mapping types contents in
          Scan.analysis
            ~visit:(fun kind idx ->
              match kind with
              | `Func -> mark i Func idx
              | `Ref_func ->
                  (match !current_global with
                  | Some _ -> declared := (i, idx) :: !declared
                  | None ->
                      if !in_function then ref_funcs := (i, idx) :: !ref_funcs);
                  mark i Func idx
              | `Global ->
                  global_counts.(i).(idx) <- global_counts.(i).(idx) + 1;
                  (match !current_global with
                  | Some j -> global_deps.(i).(j) <- idx :: global_deps.(i).(j)
                  | None -> ());
                  mark i Global idx
              | `Tag -> mark i Tag idx
              | `Elem -> mark_segment i idx
              | `Data -> mark_data i idx
              | `Type -> mark_type type_mapping.(idx))
            contents.ch.buf)
        files
    in
    let global_positions = positions 6 (fun scanner -> scanner.Scan.global) in
    let segment_positions = positions 9 (fun scanner -> scanner.Scan.elem) in
    let data_positions = positions 11 (fun scanner -> scanner.Scan.data) in
    let code_positions =
      Array.map (fun { contents; _ } -> code_entries contents) files
    in
    Array.iteri
      (fun i { contents; _ } ->
        Option.iter (fun idx -> mark i Func idx) (Read.start contents);
        (* Declarative segments and passive segments which are not used do not
           make the functions they mention live *)
        Array.iteri
          (fun j pos ->
            match Char.code contents.ch.buf.[pos] with
            | 1 | 3 | 5 | 7 -> ()
            | _ -> mark_segment i j)
          segment_positions.(i);
        (* Passive data segments are only live if used *)
        Array.iteri
          (fun j pos ->
            match Char.code contents.ch.buf.[pos] with
            | 1 -> ()
            | _ -> mark_data i j)
          data_positions.(i);
        ignore (section_entries contents 4 scanners.(i).table))
      files;
    (* Propagate *)
    while not (Stack.is_empty stack) do
      match Stack.pop stack with
      | Entity (i, kind, j) -> (
          let imports = get_exportable_info resolved_imports.(i) kind in
          if j < Array.length imports then
            match imports.(j) with
            | Resolved (i', j') -> mark i' kind j'
            | Unresolved u -> mark_unresolved kind u
          else
            let k = j - Array.length imports in
            match kind with
            | Func ->
                mark_type functions.(i).(k);
                in_function := true;
                scanners.(i).func code_positions.(i).(k);
                in_function := false
            | Global ->
                current_global := Some j;
                ignore (scanners.(i).global global_positions.(i).(k));
                current_global := None
            | Tag -> mark_type tags.(i).(k)
            | Table | Memory -> ())
      | Segment (i, j) -> ignore (scanners.(i).elem segment_positions.(i).(j))
      | Data_segment (i, j) -> ignore (scanners.(i).data data_positions.(i).(j))
    done;
    (* Order the type groups: a group can only refer to earlier groups *)
    let live_groups =
      Array.of_list
        (List.filter
           (fun (g, _) -> type_live.(fst group_array.(g)))
           (List.mapi (fun g x -> (g, x)) groups))
    in
    let group_ids = Array.make (Array.length group_array) (-1) in
    Array.iteri (fun n (g, _) -> group_ids.(g) <- n) live_groups;
    let type_order =
      priority_topological_sort ~n:(Array.length live_groups)
        ~deps:(fun n ->
          let l = ref [] in
          iter_types
            (fun t -> l := group_ids.(group_of_slot.(t)) :: !l)
            (snd (snd live_groups.(n)));
          !l)
        ~priority:(fun n ->
          let base, rectype = snd live_groups.(n) in
          let count = ref 0 in
          Array.iteri
            (fun j _ -> count := !count + type_counts.(base + j))
            rectype;
          !count)
    in
    let global_order =
      order_globals ~resolved_imports ~live ~global_counts ~global_deps
    in
    (* A function referenced by [ref.func] in a function body must be declared:
       in an element segment (all are kept, with their live functions), in an
       export, or in a global initializer. *)
    let undeclared_functions =
      let key i j =
        let imports = get_exportable_info resolved_imports.(i) Func in
        if j < Array.length imports then
          match imports.(j) with
          | Resolved (i', j') -> (i', j')
          | Unresolved u -> (-1, u)
        else (i, j)
      in
      let declared_keys = Hashtbl.create 128 in
      let declare (i, j) = Hashtbl.replace declared_keys (key i j) () in
      List.iter declare !declared;
      Array.iteri
        (fun i { contents; _ } ->
          let scanner =
            Scan.analysis
              ~visit:(fun kind idx ->
                match kind with
                | `Func | `Ref_func -> declare (i, idx)
                | `Global | `Tag | `Elem | `Data | `Type -> ())
              contents.ch.buf
          in
          ignore (section_entries contents 4 scanner.table);
          ignore (section_entries contents 9 scanner.elem))
        files;
      Array.iteri
        (fun i intf ->
          List.iter
            (fun (name, idx) ->
              match exported_names i name with
              | Some name when Hashtbl.mem kept_exports name -> declare (i, idx)
              | _ -> ())
            intf.Read.exports.func)
        intfs;
      List.filter
        (fun (i, j) ->
          let k = key i j in
          if Hashtbl.mem declared_keys k then false
          else (
            Hashtbl.replace declared_keys k ();
            true))
        !ref_funcs
    in
    {
      live;
      segments;
      data;
      unresolved;
      keep_export = (fun name -> Hashtbl.mem kept_exports name);
      ordering =
        {
          type_groups =
            Array.map (fun n -> fst (snd live_groups.(n))) type_order;
          globals = global_order;
          global_positions;
        };
      undeclared_functions;
    }

(* Output indices of the globals, in the order given by [ordering]. Dead
   globals are mapped to -1. *)
let compute_global_mappings ~files ~resolved_imports ~unresolved_imports
    ordering =
  let imports i = get_exportable_info resolved_imports.(i) Global in
  let global_mappings =
    Array.mapi
      (fun i _ ->
        Array.make
          (Array.length (imports i) + Array.length ordering.global_positions.(i))
          (-1))
      files
  in
  let offset = get_exportable_info unresolved_imports Global in
  Array.iteri
    (fun n (i, j) -> global_mappings.(i).(j) <- offset + n)
    ordering.globals;
  (* Imports resolve to definitions or to unresolved imports *)
  Array.iteri
    (fun i _ ->
      Array.iteri
        (fun j status ->
          match status with
          | Unresolved u -> global_mappings.(i).(j) <- u
          | Resolved _ -> ())
        (imports i))
    files;
  Array.iteri
    (fun i _ ->
      Array.iteri
        (fun j status ->
          match status with
          | Resolved (i', j') ->
              global_mappings.(i).(j) <- global_mappings.(i').(j')
          | Unresolved _ -> ())
        (imports i))
    files;
  global_mappings

(* Write the global definitions in the order given by [ordering] *)
let write_globals ~files ~resolved_imports ~type_maps ~func_mappings
    ~global_mappings ~(positions : Scan.position_data array) ~buf ordering =
  let imports i = get_exportable_info resolved_imports.(i) Global in
  let scanners =
    Array.mapi
      (fun i { contents; _ } ->
        (* Copy, so that [positions] does not alias the ordering *)
        let p = Array.copy ordering.global_positions.(i) in
        positions.(i).pos <- p;
        positions.(i).i <- Array.length p;
        Scan.global_entry
          {
            Scan.default_maps with
            typ = type_maps.(i);
            func = func_mappings.(i);
            global = global_mappings.(i);
          }
          buf contents.ch.buf)
      files
  in
  Array.iter
    (fun (i, j) ->
      ignore
        (scanners.(i)
           ordering.global_positions.(i).(j - Array.length (imports i))
          : int))
    ordering.globals;
  Array.length ordering.globals

(* Global initializers read each other in a cycle (an invalid input, which
   linking cannot fix): report it, naming the modules involved. *)
let report_global_cycle d (files : t array) l =
  let modules =
    List.map
      (fun i -> str files.(i).file)
      (List.sort_uniq compare (List.map fst l))
  in
  Wax_utils.Diagnostic.report d ~location:dummy_loc ~severity:Error
    ~message:
      Wax_utils.Message.(
        text "The initializers of some globals of"
        ++ (match modules with [ _ ] -> text "module" | _ -> text "modules")
        ++ (match List.rev modules with
          | last :: (_ :: _ as rem) ->
              List.fold_left ( ++ )
                (List.hd (List.rev rem))
                (List.tl (List.rev rem))
              ++ text "and" ++ last
          | _ -> List.hd modules)
        ++ text "read each other in a cycle"
        ^^ text "."
           ++ text
                "A global initializer may only read a preceding global, so \
                 these globals cannot be ordered.")
    ();
  Wax_utils.Diagnostic.abort ()

let compact live =
  let n = ref 0 in
  Array.map
    (fun l ->
      if l then (
        let idx = !n in
        incr n;
        idx)
      else -1)
    live

let f ?(rename_export = fun _ nm -> Some nm) ?(distinct_named_types = false)
    ?dependencies ?(names = true) ?source_map:(emit_source_map = false) files
    ~output_file =
  Wax_utils.Diagnostic.run ~color:Wax_utils.Colors.Never
    ~palette:Wax_utils.Colors.wat_theme ~source:None (fun d ->
      let files =
        Array.mapi
          (fun id { module_name; file; code; opt_source_map } ->
            let data =
              match code with
              | None -> In_channel.with_open_bin file In_channel.input_all
              | Some data -> data
            in
            let contents = Read.open_in id file data in
            {
              module_name;
              file;
              contents;
              source_map_contents = opt_source_map;
            })
          (Array.of_list files)
      in

      let out_ch = open_out_bin output_file in
      (* A rejected link either raises or exits the process directly (a
         diagnostic abort calls [exit] once the errors are flushed), leaving a
         truncated, invalid module on disk. Remove it on every exit path unless
         the link ran to completion. *)
      let succeeded = ref false in
      at_exit (fun () ->
          if not !succeeded then try Sys.remove output_file with _ -> ());
      output_string out_ch Wax_wasm.Wasm_parser.header;
      let buf = Buffer.create 100000 in

      let types =
        Read.create_types ~distinct_named:distinct_named_types
          (Array.length files)
      in
      (* Output type slots are assigned eagerly as each module's rec groups are
         added, so a module's interface descriptors (read straight after its
         types) already see final output indices. *)
      let intfs =
        Array.map
          (fun f ->
            Read.type_section types f.contents;
            Read.interface types f.contents)
          files
      in
      (* If more than one input has a start, the merged module needs a start
         function of type [] -> [] calling each. Add that type now, before the
         type section is emitted, so it participates in the normal output like
         any other type (emitted if new). It is unnamed, so clear the per-module
         signatures first. *)
      let start_count =
        Array.fold_left
          (fun count f ->
            match Read.start f.contents with
            | None -> count
            | Some _ -> count + 1)
          0 files
      in
      let start_type =
        if start_count > 1 then (
          types.current_signatures <- (fun _ -> "");
          let typ : comptype = Func { params = [||]; results = [||] } in
          Some
            (Read.add_rectype types [||] ~source_base:0
               [|
                 {
                   final = true;
                   supertype = None;
                   typ;
                   descriptor = None;
                   describes = None;
                 };
               |]))
        else None
      in
      let subtyping_info =
        {
          wasm_info = Wax_wasm.Types.subtyping_info types.types_store;
          types_map = types.types_map;
        }
      in
      (* The output rec groups, in output-slot space, with the slot of their
         first type *)
      let groups =
        let _, l =
          List.fold_left
            (fun (base, acc) (mapping, rectype) ->
              ( base + Array.length rectype,
                (base, Remap.rectype (fun idx -> mapping.(idx)) rectype) :: acc
              ))
            (0, [])
            (List.rev types.kept_rectypes)
        in
        List.rev l
      in

      (* Import resolution *)
      let exports = init_exportable_info (fun _ -> Hashtbl.create 128) in
      Array.iteri
        (fun i intf ->
          iter_exportable_info
            (fun kind lst ->
              let h = get_exportable_info exports kind in
              List.iter
                (fun (name, index) ->
                  Hashtbl.add h (files.(i).module_name, name) (i, index))
                lst)
            intf.Read.exports)
        intfs;
      let import_list = make_exportable_info [] in
      let unresolved_imports = make_exportable_info 0 in
      let resolved_imports =
        let tbl = Hashtbl.create 128 in
        Array.mapi
          (fun i intf ->
            map_exportable_info
              (fun kind imports ->
                let exports = get_exportable_info exports kind in
                Array.map
                  (fun (import : import) ->
                    match
                      resolve d 0 ~files ~intfs ~subtyping_info ~exports ~kind i
                        import
                    with
                    | i', idx -> Resolved (i', idx)
                    | exception Not_found -> (
                        match Hashtbl.find tbl import with
                        | status -> status
                        | exception Not_found ->
                            let idx =
                              get_exportable_info unresolved_imports kind
                            in
                            let status = Unresolved idx in
                            Hashtbl.replace tbl import status;
                            set_exportable_info unresolved_imports kind (1 + idx);
                            set_exportable_info import_list kind
                              (import :: get_exportable_info import_list kind);
                            status))
                  imports)
              intf.Read.imports)
          intfs
      in
      let import_list =
        map_exportable_info (fun _ l -> Array.of_list (List.rev l)) import_list
      in

      (* Dead code elimination *)
      let functions =
        Array.map (fun f -> Read.functions types f.contents) files
      in
      let tags = Array.map (fun f -> Read.tags types f.contents) files in
      let liveness =
        try
          compute_liveness ~files ~types ~groups ~resolved_imports ~import_list
            ~unresolved_imports ~functions ~tags ~start_type ~intfs
            ~exported_names:(fun i name ->
              rename_export files.(i).module_name name)
            ~dependencies
        with Global_initializer_cycle l -> report_global_cycle d files l
      in
      let live = liveness.live in
      (* Renumber the types which are kept *)
      let type_out = Array.make (Read.output_type_count types) (-1) in
      let rectypes = Hashtbl.create 16 in
      List.iter
        (fun (base, rectype) -> Hashtbl.replace rectypes base rectype)
        groups;
      let output_groups =
        Array.to_list
          (Array.map
             (fun base -> Hashtbl.find rectypes base)
             liveness.ordering.type_groups)
      in
      ignore
        (Array.fold_left
           (fun n base ->
             let rectype = Hashtbl.find rectypes base in
             Array.iteri (fun j _ -> type_out.(base + j) <- n + j) rectype;
             n + Array.length rectype)
           0 liveness.ordering.type_groups
          : int);
      let type_maps =
        Array.map
          (fun { contents; _ } ->
            Array.map
              (fun t -> type_out.(t))
              (Read.get_type_mapping types contents))
          files
      in
      (* Renumber the imports which are kept *)
      let unresolved_mappings =
        map_exportable_info (fun _ l -> compact l) liveness.unresolved
      in
      iter_exportable_info
        (fun kind map ->
          set_exportable_info unresolved_imports kind
            (Array.fold_left (fun n idx -> if idx >= 0 then n + 1 else n) 0 map))
        unresolved_mappings;
      Array.iter
        (fun statuses ->
          iter_exportable_info
            (fun kind statuses ->
              let map = get_exportable_info unresolved_mappings kind in
              Array.iteri
                (fun j status ->
                  match status with
                  | Unresolved u -> statuses.(j) <- Unresolved map.(u)
                  | Resolved _ -> ())
                statuses)
            statuses)
        resolved_imports;

      (* 1: type *)
      ignore
        (Wax_wasm.Wasm_output.type_section out_ch
           (List.map
              (fun rectype -> Remap.rectype (fun idx -> type_out.(idx)) rectype)
              output_groups)
          : int);

      (* 2: import *)
      let imports = ref [] in
      iter_exportable_info
        (fun kind import_list ->
          let map = get_exportable_info unresolved_mappings kind in
          Array.iteri
            (fun idx (import : import) ->
              if map.(idx) >= 0 then
                imports :=
                  Single
                    {
                      import with
                      desc = Read.translate_importdesc type_out import.desc;
                    }
                  :: !imports)
            import_list)
        import_list;
      if !imports <> [] then
        ignore
          (Wax_wasm.Wasm_output.import_section out_ch (List.rev !imports) : int);

      (* 3: function *)
      let func_types =
        let l =
          Array.to_list
            (Array.mapi
               (fun i types ->
                 let live = live.(i).func in
                 let offset = Array.length live - Array.length types in
                 Array.of_list
                   (List.filteri
                      (fun j _ -> live.(j + offset))
                      (Array.to_list types)))
               functions)
        in
        let l =
          match start_type with Some ty -> l @ [ [| ty |] ] | None -> l
        in
        Array.concat l
      in
      ignore
        (Wax_wasm.Wasm_output.function_section out_ch
           (List.map (fun t -> type_out.(t)) (Array.to_list func_types))
          : int);
      let func_counts = Array.map Array.length functions in
      let func_mappings =
        build_mappings ~live resolved_imports unresolved_imports Func
          func_counts
      in
      let func_count = Array.length func_types in
      check_exports_against_imports d ~intfs ~subtyping_info ~resolved_imports
        ~files ~kind:Func
        ~to_desc:
          (defined_entity ~intfs ~kind:Func ~get:(fun i k : importdesc ->
               (* This is a defined function of the merged module (an import
                  resolves either to a definition here or to a residual import
                  handled elsewhere), and a defined function's reference is
                  exact. *)
               Func { exact = true; typ = functions.(i).(k) }));

      (* Global index maps, computed before the table section because a table's
         initializer expression may read a global ([(table … (global.get $g))]);
         the global bodies themselves are emitted later, in section 6, in an
         order where each initializer only reads preceding globals. *)
      let global_mappings =
        compute_global_mappings ~files ~resolved_imports ~unresolved_imports
          liveness.ordering
      in
      (* A table initializer in module [i] read a global at source index [idx]
         that the merged layout cannot place before it (signalled by
         [Init_reads_forward_global]). [idx] is always a resolved global import
         here, so name that import and the module its definition lands in. *)
      let reject_forward_global i idx =
        let import = (get_exportable_info intfs.(i).imports Global).(idx) in
        let i' =
          match (get_exportable_info resolved_imports.(i) Global).(idx) with
          | Resolved (i', _) -> i'
          | Unresolved _ -> assert false
        in
        Wax_utils.Diagnostic.report d ~location:dummy_loc ~severity:Error
          ~message:
            Wax_utils.Message.(
              (text "In module" ++ str files.(i).file)
              ^^ text ","
                 ++ text "a table initializer reads the global import"
                 ++ import_atom import.module_ import.name
              ^^ text ","
                 ++ text "which linking resolves to a definition in module"
                 ++ str files.(i').file
              ^^ text "."
                 ++ text
                      "A table initializer may only read an imported global, \
                       so the linked module would be invalid.")
          ();
        Wax_utils.Diagnostic.abort ()
      in

      (* 4: table *)
      let positions =
        Array.init (Array.length files) (fun _ -> Scan.create_position_data ())
      in
      let table_counts =
        (* A table initializer may only read an *imported* global; a global that
           linking internalises (a resolved import) would follow the table
           section in the output and make the initializer a forward reference —
           an invalid module. Mark every resolved-import global with [-1] so a
           read raises [Init_reads_forward_global] rather than silently
           producing an invalid module (as binaryen's wasm-merge does — it drops
           the initializer). *)
        write_section_with_scan ~type_maps ~files ~out_ch ~buf ~id:4
          ~scan:(fun i maps ->
            let imports = get_exportable_info resolved_imports.(i) Global in
            let import_count = Array.length imports in
            let global =
              Array.mapi
                (fun j idx ->
                  if
                    j < import_count
                    && match imports.(j) with Resolved _ -> true | _ -> false
                  then -1
                  else idx)
                global_mappings.(i)
            in
            let scan =
              Scan.table_section positions.(i)
                { maps with func = func_mappings.(i); global }
            in
            fun buf s ~count pos ->
              try scan buf s ~count pos
              with Init_reads_forward_global idx ->
                reject_forward_global i idx)
          ()
      in
      let table_mappings =
        build_mappings ~live resolved_imports unresolved_imports Table
          table_counts
      in
      check_exports_against_imports d ~intfs ~subtyping_info ~resolved_imports
        ~files ~kind:Table
        ~to_desc:
          (read_desc_from_file ~intfs ~files ~positions
             ~read:(fun contents : importdesc ->
               Table (Read.tabletype contents types contents.ch)));
      Array.iter Scan.clear_position_data positions;

      (* 5: memory *)
      let mem_mappings =
        write_simple_section d ~live ~intfs ~subtyping_info ~resolved_imports
          ~unresolved_imports ~out_ch ~kind:Memory ~read:Read.memories
          ~to_type:(fun limits -> Memory limits)
          ~write:(fun ch entries ->
            ignore
              (Wax_wasm.Wasm_output.memory_section ch (Array.to_list entries)
                : int))
          ~files
      in

      (* 13: tag *)
      let tag_mappings =
        write_simple_section d ~live ~intfs ~subtyping_info ~resolved_imports
          ~unresolved_imports ~out_ch ~kind:Tag ~read:(Read.tags types)
          ~to_type:(fun ty -> Tag ty)
          ~write:(fun ch entries ->
            ignore
              (Wax_wasm.Wasm_output.tag_section ch
                 (List.map (fun t -> type_out.(t)) (Array.to_list entries))
                : int))
          ~files
      in

      (* 6: global *)
      let global_count =
        write_globals ~files ~resolved_imports ~type_maps ~func_mappings
          ~global_mappings ~positions ~buf liveness.ordering
      in
      add_section out_ch ~id:6 ~count:global_count buf;
      check_exports_against_imports d ~intfs ~subtyping_info ~resolved_imports
        ~files ~kind:Global ~to_desc:(fun i j : importdesc option ->
          let offset =
            Array.length (get_exportable_info intfs.(i).imports Global)
          in
          if j < offset then None
          else
            let { contents; _ } = files.(i) in
            Read.seek_in contents.ch positions.(i).pos.(j - offset);
            Some (Global (Read.globaltype contents types contents.ch)));
      Array.iter Scan.clear_position_data positions;

      (* 7: export *)
      let exports =
        Array.mapi
          (fun i intf ->
            let module_name = files.(i).module_name in
            map_exportable_info
              (fun _ exports ->
                List.filter_map
                  (fun (nm, idx) ->
                    match rename_export module_name nm with
                    | Some nm' when liveness.keep_export nm' -> Some (nm', idx)
                    | _ -> None)
                  exports)
              intf.Read.exports)
          intfs
      in
      let export_tbl = StringHashtbl.create 128 in
      let export_list = ref [] in
      Array.iteri
        (fun i exports ->
          iter_exportable_info
            (fun kind lst ->
              let map =
                match kind with
                | Func -> func_mappings.(i)
                | Table -> table_mappings.(i)
                | Memory -> mem_mappings.(i)
                | Global -> global_mappings.(i)
                | Tag -> tag_mappings.(i)
              in
              List.iter
                (fun (name, idx) ->
                  match StringHashtbl.find export_tbl name with
                  | i' ->
                      Wax_utils.Diagnostic.report d ~location:dummy_loc
                        ~severity:Error
                        ~message:
                          Wax_utils.Message.(
                            text "Duplicated export" ++ str name
                            ++ text "found in multiple input modules:"
                            ++ str files.(i').file ++ text "and"
                            ++ str files.(i).file
                            ^^ text ".")
                        ();
                      Wax_utils.Diagnostic.abort ()
                  | exception Not_found ->
                      StringHashtbl.add export_tbl name i;
                      let index = map.(idx) in
                      export_list := { name; kind; index } :: !export_list)
                lst)
            exports)
        exports;
      ignore
        (Wax_wasm.Wasm_output.export_section out_ch (List.rev !export_list)
          : int);

      (* 8: start *)
      let starts =
        Array.mapi
          (fun i f ->
            Read.start f.contents
            |> Option.map (fun idx -> func_mappings.(i).(idx)))
          files
        |> Array.to_list
        |> List.filter_map (fun x -> x)
      in
      (match starts with
      | [] -> ()
      | [ start ] ->
          ignore (Wax_wasm.Wasm_output.start_section out_ch start : int)
      | _ :: _ :: _ ->
          ignore
            (Wax_wasm.Wasm_output.start_section out_ch
               (get_exportable_info unresolved_imports Func + func_count - 1)
              : int));

      (* 9: elements *)
      let elem_counts =
        write_section_with_scan ~type_maps ~files ~out_ch ~buf ~id:9
          ~scan:(fun i maps buf s ->
            Scan.elem_section
              {
                maps with
                func = func_mappings.(i);
                table = table_mappings.(i);
                global = global_mappings.(i);
              }
              buf s
              ~keep:(fun j -> liveness.segments.(i).(j)))
          ~extra:(fun buf ->
            match liveness.undeclared_functions with
            | [] -> 0
            | l ->
                (* A declarative segment *)
                Buffer.add_char buf '\x03';
                Buffer.add_char buf '\x00';
                Write.uint buf (List.length l);
                List.iter (fun (i, j) -> Write.uint buf func_mappings.(i).(j)) l;
                1)
          ()
      in
      let elem_mappings = build_simple_mappings ~counts:elem_counts in

      (* 12: data count *)
      let data_mappings =
        let count = ref 0 in
        Array.map
          (Array.map (fun l ->
               if l then (
                 let idx = !count in
                 incr count;
                 idx)
               else -1))
          liveness.data
      in
      let data_count =
        Array.fold_left
          (Array.fold_left (fun n idx -> if idx >= 0 then n + 1 else n))
          0 data_mappings
      in
      if data_count > 0 then
        ignore (Wax_wasm.Wasm_output.datacount_section out_ch data_count : int);

      (* 10: code *)
      let code_pieces = Buffer.create 100000 in
      let resize_data = Scan.create_resize_data () in
      let source_maps = ref [] in
      let linked_code_metadata =
        List.map
          (fun (name, payload_kind) -> (name, payload_kind, ref []))
          code_metadata_sections
      in
      Write.uint code_pieces func_count;
      Array.iteri
        (fun i { contents; source_map_contents; _ } ->
          if Read.find_section contents 10 then (
            let pos = Buffer.length code_pieces in
            let scan_func =
              Scan.func resize_data
                {
                  typ = type_maps.(i);
                  func = func_mappings.(i);
                  table = table_mappings.(i);
                  mem = mem_mappings.(i);
                  global = global_mappings.(i);
                  elem = elem_mappings.(i);
                  data = data_mappings.(i);
                  tag = tag_mappings.(i);
                }
                buf contents.ch.buf
            in
            let count = Read.uint contents.ch in
            let import_count =
              Array.length (get_exportable_info resolved_imports.(i) Func)
            in
            let func_starts = Array.make count 0 in
            let func_idx = ref 0 in
            let dead_ranges = ref [] in
            let code (ch : Read.ch) =
              let pos = ch.pos in
              let idx = resize_data.i in
              let size = Read.uint ch in
              let pos' = ch.pos in
              func_starts.(!func_idx) <- pos';
              let is_live = live.(i).func.(import_count + !func_idx) in
              incr func_idx;
              if not is_live then (
                (* Drop the function, and the corresponding mappings *)
                ch.pos <- ch.pos + size;
                dead_ranges := (pos, ch.pos) :: !dead_ranges;
                Scan.push_resize resize_data ch.pos (pos - ch.pos))
              else (
                Scan.push_resize resize_data pos' 0;
                scan_func ch.pos;
                ch.pos <- ch.pos + size;
                let p = Buffer.length code_pieces in
                Write.uint code_pieces (Buffer.length buf);
                let p' = Buffer.length code_pieces in
                let delta = p' - p - pos' + pos in
                resize_data.delta.(idx) <- delta;
                Buffer.add_buffer code_pieces buf;
                Buffer.clear buf)
            in
            Scan.clear_resize_data resize_data;
            Scan.push_resize resize_data 0 (-Read.pos_in contents.ch);
            Read.repeat' count code contents.ch;
            (* A hint's offset is relative to the start of its function body, and
               renumbering an index may have changed a LEB's width, so each offset
               moves with the bytes before it. [resize_data] holds those deltas by
               source position; walking it costs nothing as long as the positions
               asked about only grow, which they do within one section (entries are
               in function order, hints in offset order). Hence a fresh walker per
               section rather than one shared across the four. *)
            let make_shift () =
              let idx = ref 0 in
              let acc = ref 0 in
              fun x ->
                while !idx < resize_data.i && x >= resize_data.pos.(!idx) do
                  acc := !acc + resize_data.delta.(!idx);
                  incr idx
                done;
                x + !acc
            in
            List.iter
              (fun (name, payload_kind, linked) ->
                let section =
                  Read.focus_on_custom_section_payload contents
                    ("metadata.code." ^ name)
                in
                let entries = read_code_metadata ~name section in
                let shift = make_shift () in
                let map_payload =
                  match payload_kind with
                  | `Opaque -> fun p -> Some p
                  | `Function_indices -> remap_call_targets func_mappings.(i)
                in
                List.iter
                  (fun (funcidx, hints_list) ->
                    let k = funcidx - import_count in
                    (* An entry naming an import, or a function this module does
                       not define or which has been removed, addresses no body
                       here and is dropped, as the decoder drops it. *)
                    if k >= 0 && k < count && func_mappings.(i).(funcidx) >= 0
                    then
                      let pos' = func_starts.(k) in
                      let pos'_shifted = shift pos' in
                      let mapped_hints =
                        List.filter_map
                          (fun (offset, hint) ->
                            let hint_pos = pos' + offset in
                            let hint_pos_shifted = shift hint_pos in
                            let new_offset = hint_pos_shifted - pos'_shifted in
                            Option.map
                              (fun p -> (new_offset, p))
                              (map_payload hint))
                          hints_list
                      in
                      if mapped_hints <> [] then
                        let new_funcidx = func_mappings.(i).(funcidx) in
                        linked := (new_funcidx, mapped_hints) :: !linked)
                  entries)
              linked_code_metadata;
            Option.iter
              (fun sm ->
                if not (Source_map.is_empty sm) then
                  source_maps :=
                    ( pos,
                      Source_map.resize ~drop:(List.rev !dead_ranges)
                        resize_data sm )
                    :: !source_maps)
              source_map_contents))
        files;
      if start_count > 1 then (
        (* no local *)
        Buffer.add_char buf (Char.chr 0);
        List.iter
          (fun idx ->
            (* call idx *)
            Buffer.add_char buf (Char.chr 0x10);
            Write.uint buf idx)
          starts;
        (* end *)
        Buffer.add_char buf (Char.chr 0x0B);
        Write.uint code_pieces (Buffer.length buf);
        Buffer.add_buffer code_pieces buf;
        Buffer.clear buf);
      (* Every [metadata.code.*] section must precede the code section (both
         proposals require it, and the decoder rejects a later one), so emit them
         before writing code. Their offsets are relative to each function body, so
         they need no rebasing against the code position. The accumulated entries
         come out in function order because the modules were read in order and
         each one's functions are renumbered contiguously. *)
      List.iter
        (fun (name, _, linked) ->
          match List.rev !linked with
          | [] -> ()
          | entries ->
              ignore
                (Wax_wasm.Wasm_output.output_code_metadata_section out_ch name
                   entries
                  : int))
        linked_code_metadata;
      let code_section_offset =
        let b = Buffer.create 5 in
        Write.uint b (Buffer.length code_pieces);
        pos_out out_ch + 1 + Buffer.length b
      in
      add_section out_ch ~id:10 code_pieces;
      let source_map =
        Source_map.concatenate
          (List.map
             (fun (pos, sm) -> (pos + code_section_offset, sm))
             (List.rev !source_maps))
      in

      (* 11: data *)
      ignore
        (write_section_with_scan ~type_maps ~files ~out_ch ~buf ~id:11
           ~scan:(fun i maps buf s ->
             Scan.data_section
               {
                 maps with
                 mem = mem_mappings.(i);
                 global = global_mappings.(i);
               }
               buf s
               ~keep:(fun j -> liveness.data.(i).(j)))
           ~written:(fun i _ ->
             Array.fold_left
               (fun n l -> if l then n + 1 else n)
               0 liveness.data.(i))
           ()
          : int array);

      (* Custom section: name *)
      if names then (
        let name_sections =
          Array.map
            (fun { contents; _ } ->
              Read.focus_on_custom_section contents "name")
            files
        in
        let name_section_buffer = Buffer.create 100000 in
        Write.name name_section_buffer "name";

        (* 1: functions *)
        write_namemap ~resolved_imports ~unresolved_imports ~name_sections
          ~name_section_buffer ~buf ~kind:Func ~section_id:1
          ~mappings:func_mappings;
        (* 2: locals *)
        write_indirectnamemap ~name_sections ~name_section_buffer ~buf
          ~section_id:2 ~mappings:func_mappings;
        (* 3: labels *)
        write_indirectnamemap ~name_sections ~name_section_buffer ~buf
          ~section_id:3 ~mappings:func_mappings;

        (* 4: types *)
        let output_type_count =
          Array.fold_left (fun n t -> if t >= 0 then n + 1 else n) 0 type_out
        in
        let type_names = Array.make output_type_count None in
        Array.iteri
          (fun i { contents; _ } ->
            Array.iter
              (fun (idx, name) ->
                let idx = type_maps.(i).(idx) in
                if idx >= 0 && Option.is_none type_names.(idx) then
                  type_names.(idx) <- Some (idx, name))
              (Read.name_data types contents).type_names)
          files;
        Write.namemap buf
          (Array.of_list
             (List.filter_map (fun x -> x) (Array.to_list type_names)));
        add_subsection name_section_buffer ~id:4 buf;

        (* 5: tables *)
        write_namemap ~resolved_imports ~unresolved_imports ~name_sections
          ~name_section_buffer ~buf ~kind:Table ~section_id:5
          ~mappings:table_mappings;
        (* 6: memories *)
        write_namemap ~resolved_imports ~unresolved_imports ~name_sections
          ~name_section_buffer ~buf ~kind:Memory ~section_id:6
          ~mappings:mem_mappings;
        (* 7: globals *)
        write_namemap ~resolved_imports ~unresolved_imports ~name_sections
          ~name_section_buffer ~buf ~kind:Global ~section_id:7
          ~mappings:global_mappings;
        (* 8: elems *)
        write_simple_namemap ~name_sections ~name_section_buffer ~buf
          ~section_id:8 ~mappings:elem_mappings;
        (* 9: data segments *)
        write_simple_namemap ~name_sections ~name_section_buffer ~buf
          ~section_id:9 ~mappings:data_mappings;

        (* 10: field names *)
        let type_field_names = Array.make output_type_count None in
        Array.iteri
          (fun i { contents; _ } ->
            Array.iter
              (fun (idx, fields) ->
                let idx = type_maps.(i).(idx) in
                if idx >= 0 && Option.is_none type_field_names.(idx) then
                  type_field_names.(idx) <- Some (idx, fields))
              (Read.name_data types contents).field_names)
          files;
        let type_field_names =
          Array.of_list
            (List.filter_map (fun x -> x) (Array.to_list type_field_names))
        in
        Write.uint buf (Array.length type_field_names);
        Array.iter
          (fun (idx, fields) ->
            Write.uint buf idx;
            Write.namemap buf fields)
          type_field_names;
        add_subsection name_section_buffer ~id:10 buf;

        (* 11: tags *)
        write_namemap ~resolved_imports ~unresolved_imports ~name_sections
          ~name_section_buffer ~buf ~kind:Tag ~section_id:11
          ~mappings:tag_mappings;

        add_section out_ch ~id:0 name_section_buffer);

      (* [sourceMappingURL] names the map as a sibling of the output, so the
         section carries the basename rather than the path we were given. Same
         pair of artifacts as [Wasm_output.module_] writes for [wax
         --source-map]. *)
      if emit_source_map then (
        Write.name buf "sourceMappingURL";
        Write.name buf (Filename.basename output_file ^ ".map");
        add_section out_ch ~id:0 buf);

      close_out out_ch;
      succeeded := true;
      if emit_source_map then
        Source_map.to_file source_map (output_file ^ ".map");

      source_map)

let imports file =
  Wax_utils.Diagnostic.run ~color:Wax_utils.Colors.Never
    ~palette:Wax_utils.Colors.wat_theme ~source:None (fun _ ->
      let contents =
        Read.open_in 0 file (In_channel.with_open_bin file In_channel.input_all)
      in
      if Read.find_section contents 2 then
        List.map
          (fun (import : import) -> (import.module_, import.name))
          (Wax_wasm.Ast_utils.flatten_binary_imports
             (Wax_wasm.Wasm_parser.import_section contents.ch))
      else [])

let get_instruction_offsets ~filename buf =
  let offsets = ref [] in
  let mark pos = offsets := pos :: !offsets in
  let count = ref 0 in
  (* The scanner renumbers every index immediate through [maps]; here we only
     want the instruction *positions*, so every index must map to itself.
     [Scan.default_maps] holds empty arrays (any index lookup is then out of
     bounds), so give the scanner identity maps instead. One shared array
     suffices: an index in a valid module is smaller than the module's byte
     length (each referenced entity occupies at least one byte). *)
  let identity = Array.init (String.length buf) Fun.id in
  let identity_maps =
    {
      Scan.typ = identity;
      func = identity;
      table = identity;
      mem = identity;
      global = identity;
      elem = identity;
      data = identity;
      tag = identity;
    }
  in
  Wax_utils.Diagnostic.run ~color:Wax_utils.Colors.Never
    ~palette:Wax_utils.Colors.wat_theme ~source:(Some buf) (fun d ->
      let ch = Wax_wasm.Wasm_parser.make_ch d ~filename buf 0 in
      Wax_wasm.Wasm_parser.check_header ch;
      ch.pos <- 8;
      let index = Wax_wasm.Wasm_parser.index ch in
      let contents = { Read.id = 0; ch; index } in
      if Read.find_section contents 10 then (
        let count' = Read.uint contents.ch in
        count := count';
        let code (ch : Wax_wasm.Wasm_parser.ch) =
          let size = Read.uint ch in
          let pos' = ch.pos in
          let { Scan.func; _ } =
            Scan.scanner ~mark_instructions:true
              (fun _ _ -> ())
              mark identity_maps (Buffer.create 0) ch.buf
          in
          let _ = func pos' in
          ch.pos <- ch.pos + size
        in
        Read.repeat' count' code contents.ch));
  (List.rev !offsets, !count)

open Wax_lang
module Src = Wax_wasm.Ast.Text
module Simd = Wax_wasm.Simd
module Atomics = Wax_wasm.Atomics
module Uint32 = Wax_utils.Uint32
module Cond = Wax_wasm.Cond_solver

(* Raised by [Sequence.get] for a numeric field reference in a module with
   conditional annotations: the field's index depends on which branch is taken,
   so it cannot be resolved to a single Wax name. Caught in [module_] and
   reported as a located diagnostic. *)
exception Numeric_ref_in_conditional of Wax_wasm.Ast.location

(* Raised when an index or label reference resolves to nothing — it is out of
   range, or names an undeclared entity. This only happens on a module that
   validation would reject (with an "unknown ..." error), so conversion gives up
   rather than inventing a target. *)
exception Unresolved_reference of Wax_wasm.Ast.location

(*** Symbol tables and stacks ***)

module Sequence = struct
  type t = {
    index_mapping : (Uint32.t, string) Hashtbl.t;
    label_mapping : (string, string) Hashtbl.t;
    export_mapping : (string, string) Hashtbl.t;
    mutable last_index : int;
    mutable current_index : int;
    namespace : Namespace.t;
    default : string;
    forbid_numeric : bool;
        (* When set (module-level sequences of a module containing conditional
           annotations), numeric references are refused: a field's index depends
           on which branch is taken, so it cannot be resolved to one name. *)
    diagnostics : Wax_utils.Diagnostic.context option;
        (* Where to report a [naming-conflict] / [reserved-word-rename] warning
           when a source name has to be renamed; [None] silences them (for
           internal namespaces without a source identifier to point at). *)
  }

  let make ?(forbid_numeric = false) ?diagnostics namespace default =
    {
      index_mapping = Hashtbl.create 16;
      label_mapping = Hashtbl.create 16;
      export_mapping = Hashtbl.create 16;
      last_index = 0;
      current_index = 0;
      namespace;
      default;
      forbid_numeric;
      diagnostics;
    }

  (* Report that the source name [original] had to be renamed to [renamed]
     (because it is a reserved word, or collides with another name), pointing at
     the source identifier. For a collision, [previous] (when known) points the
     related label at the occurrence that first claimed the name. *)
  let report_rename diagnostics ~location ~previous ~reserved ~original ~renamed
      =
    let warning, message =
      if reserved then
        ( Wax_utils.Warning.Reserved_word_rename,
          fun f () ->
            Format.fprintf f
              "'%s' is a reserved word; renaming this identifier to '%s'."
              original renamed )
      else
        ( Wax_utils.Warning.Naming_conflict,
          fun f () ->
            Format.fprintf f
              "The name '%s' is already in use; renaming this occurrence to \
               '%s'."
              original renamed )
    in
    let related =
      match previous with
      | Some location ->
          [
            {
              Wax_utils.Diagnostic.location;
              message =
                (fun f () ->
                  Format.fprintf f "'%s' first claimed here" original);
            };
          ]
      | None -> []
    in
    Wax_utils.Diagnostic.report diagnostics ~location ~severity:Warning ~warning
      ~related ~message ()

  let register' ?hint ?claimed seq export_tbl (kind : Src.exportable option)
      (id : Src.name option) exports =
    let idx = Uint32.of_int seq.last_index in
    (* The same entity may already have been registered in another branch of a
       conditional. Its identity is the [$id] or, lacking one, a shared export
       name (export names are unique per resolved module, so a collision can
       only mean mutually-exclusive branches). Reuse the Wax name so references
       stay coherent, but still consume an index slot below so positional naming
       via [get_current] stays aligned with the conversion order. This only
       applies to module-level sequences of a conditional module
       ([forbid_numeric]); locals reuse a single sequence across functions,
       where a repeated [$id] is a distinct variable, not the same entity. *)
    let reused =
      if seq.forbid_numeric then
        match id with
        | Some nm ->
            (* An explicit [$id] is authoritative: it is reused only when the
               same id was already bound in another branch. Do not fall back to
               export-name matching, which would conflate this entity with a
               different one that merely shares an export name in a
               mutually-exclusive branch (e.g. [$unix_isatty] versus the
               imported [$isatty], both exporting [unix_isatty]). *)
            Hashtbl.find_opt seq.label_mapping nm.Ast.desc
        | None ->
            List.find_map
              (fun nm -> Hashtbl.find_opt seq.export_mapping nm.Ast.desc)
              exports
      else None
    in
    (* A source name already claimed by the caller's priority pass (see the
       local sequence's pre-pass): it is reserved in the namespace under this
       name and any rename was already reported, so take it as-is. This lets a
       real source name win the plain name over a generated default. *)
    let pre_claimed =
      match (claimed, id) with
      | Some tbl, Some nm -> Hashtbl.find_opt tbl nm.Ast.desc
      | _ -> None
    in
    let name =
      match (reused, pre_claimed) with
      | Some name, _ | _, Some name -> name
      | None, None ->
          (* [src] is the source identifier the name was taken from (with its
             location), or [None] for a synthesized default; only a renamed
             source identifier is worth a warning. *)
          (* An inferred name -- an export name, or the import-name / parent-field
             [hint] -- is usable only when it is a valid Wax identifier that is
             not a keyword: borrowing a keyword would force a suffixed rename
             (e.g. [memory_2]) that reads worse than the generated default. An
             explicit [$id] is authoritative and kept as-is even when it is a
             keyword (it is renamed with a warning, as before). *)
          let usable_inferred nm =
            Lexer.is_valid_identifier nm.Ast.desc
            && not (Namespace.is_reserved seq.namespace nm.Ast.desc)
          in
          let default_or_hint () =
            match hint with
            | Some h when not (Namespace.is_reserved seq.namespace h) ->
                (h, None)
            | _ -> (seq.default, None)
          in
          let candidate, src =
            match (id, exports) with
            | Some nm, _ when Lexer.is_valid_identifier nm.Ast.desc ->
                (nm.Ast.desc, Some nm)
            | None, nm :: _ when usable_inferred nm -> (nm.Ast.desc, Some nm)
            | _ -> (
                match kind with
                | None -> default_or_hint ()
                | Some kind -> (
                    match Hashtbl.find_opt export_tbl (kind, Src.Num idx) with
                    | Some (nm :: _) when usable_inferred nm ->
                        (nm.Ast.desc, Some nm)
                    | _ -> default_or_hint ()))
          in
          let name, outcome =
            match src with
            | Some nm -> Namespace.add' ~loc:nm.Ast.info seq.namespace candidate
            | None -> Namespace.add' seq.namespace candidate
          in
          (match (src, outcome, seq.diagnostics) with
          | Some nm, Namespace.Renamed { reserved; previous }, Some diagnostics
            ->
              report_rename diagnostics ~location:nm.Ast.info ~previous
                ~reserved ~original:candidate ~renamed:name
          | _ -> ());
          name
    in
    seq.last_index <- seq.last_index + 1;
    Hashtbl.add seq.index_mapping idx name;
    Option.iter
      (fun id -> Hashtbl.replace seq.label_mapping id.Ast.desc name)
      id;
    (* Record only the head export as this entity's cross-branch identity, not
       every export: a single multi-export function in one branch may correspond
       to several distinct single-export functions in another (e.g. one wasi
       function exporting [unix_getuid]/[unix_geteuid]/… versus one function per
       id elsewhere). Recording all of them would let each sibling match and
       reuse this one name, binding the same Wax name twice in that branch. *)
    (match exports with
    | nm :: _ -> Hashtbl.replace seq.export_mapping nm.Ast.desc name
    | [] -> ());
    name

  let register ?hint ?claimed seq export_tbl kind id exports =
    ignore (register' ?hint ?claimed seq export_tbl kind id exports)

  (* Claim source name [candidate] in the namespace ahead of positional
     registration, reporting a rename (reserved word, or a collision with an
     already-claimed name) exactly as [register'] would. Returns the final,
     possibly-renamed name. Used to give real source names priority over the
     generated default before any unnamed entity is registered. *)
  let claim_name seq ~loc candidate =
    let name, outcome = Namespace.add' ~loc seq.namespace candidate in
    (match (outcome, seq.diagnostics) with
    | Namespace.Renamed { reserved; previous }, Some diagnostics ->
        report_rename diagnostics ~location:loc ~previous ~reserved
          ~original:candidate ~renamed:name
    | _ -> ());
    name

  let get seq (idx : Src.idx) =
    {
      idx with
      desc =
        (match idx.desc with
        | Num n -> (
            if seq.forbid_numeric then
              raise (Numeric_ref_in_conditional idx.Ast.info);
            match Hashtbl.find_opt seq.index_mapping n with
            | Some name -> name
            | None -> raise (Unresolved_reference idx.Ast.info))
        | Id id -> (
            match Hashtbl.find_opt seq.label_mapping id with
            | Some name -> name
            | None -> raise (Unresolved_reference idx.Ast.info)));
    }

  let get_current seq =
    let i = seq.current_index in
    seq.current_index <- i + 1;
    Ast.no_loc (Hashtbl.find seq.index_mapping (Uint32.of_int i))

  (* A fresh, unique name in this sequence's namespace, for an entity not in the
     source (e.g. an element segment synthesised from an inline table init). *)
  let fresh_name seq = Ast.no_loc (Namespace.add seq.namespace seq.default)

  (* Bind [name] at a specific [idx], for an entity materialised on demand
     outside the normal registration order — an implicit (inline-signature) type
     first referenced from a ref-type position (see [type_ref_name]). *)
  let find_bound seq idx = Hashtbl.find_opt seq.index_mapping idx
  let bind_at seq idx name = Hashtbl.replace seq.index_mapping idx name
  let mint_name seq = Namespace.add seq.namespace seq.default
  let consume_currents seq = seq.current_index <- seq.last_index

  (* Consume an index slot without binding a name, for an entity rendered
     anonymously (a [_] parameter). Later positional references stay aligned. *)
  let skip seq = seq.last_index <- seq.last_index + 1
end

(* Turn a Wasm identifier into a valid Wax identifier. Wasm identifiers are
   ASCII (see the Wasm lexer's [idchar]), so every character Wax does not accept
   in an identifier is mapped to an underscore ([$label$n] -> [label_n]), then
   one more is prefixed when the result still cannot start an identifier (it
   begins with a digit or a ['], as in [$0_bytes] -> [_0_bytes]). We give up
   (returning [None], so the caller falls back to a generated name) when two
   rejected characters sit side by side: a lone separator reads fine, but a run
   of them ([$!!!]) collapses to a [__] blob that no longer resembles a name. *)
let sanitize_identifier s =
  if Lexer.is_valid_identifier s then Some s
  else if s = "" then None
  else
    let is_idchar c =
      (c >= 'a' && c <= 'z')
      || (c >= 'A' && c <= 'Z')
      || (c >= '0' && c <= '9')
      || c = '_' || c = '\''
    in
    let rec adjacent_rejects i =
      i + 1 < String.length s
      && (((not (is_idchar s.[i])) && not (is_idchar s.[i + 1]))
         || adjacent_rejects (i + 1))
    in
    if adjacent_rejects 0 then None
    else
      let mapped = String.map (fun c -> if is_idchar c then c else '_') s in
      let candidate =
        match mapped.[0] with '0' .. '9' | '\'' -> "_" ^ mapped | _ -> mapped
      in
      if Lexer.is_valid_identifier candidate then Some candidate else None

module LabelStack = struct
  type t = {
    ns : Namespace.t;
    stack : (string option * (string * bool ref)) list;
  }

  let push ?diagnostics ?(targeted = true) st (label : Src.name option) =
    let ns = Namespace.dup st.ns in
    let used = ref false in
    (* The source label name made into a valid Wax identifier (sanitizing e.g. a
       leading digit, [$0_bytes] -> ['_0_bytes]); [None] when the source had no
       name or it cannot be sanitized, in which case we fall back to the
       generated "l". *)
    let src =
      match label with
      | Some label -> (
          match sanitize_identifier label.Ast.desc with
          | Some desc -> Some { label with Ast.desc }
          | None -> None)
      | None -> None
    in
    let candidate = match src with Some l -> l.Ast.desc | None -> "l" in
    (* Only claim a name for a label that will actually render: a source-named
       block always renders (see below), and an anonymous block renders only
       when a branch targets it ([targeted]). Reserving a name for an anonymous,
       untargeted block would waste the fallback "l" and needlessly bump a real
       inner label of the same name — the block renders label-free, so it needs
       no name. When not reserved, [name] is a bare candidate that is never
       emitted (its [used] stays false); it would only leak if [targeted]
       under-approximated, which the round-trip corpus would flag. *)
    let name, outcome =
      if Option.is_some src || targeted then
        match src with
        | Some l -> Namespace.add' ~loc:l.Ast.info ns candidate
        | None -> Namespace.add' ns candidate
      else (candidate, Namespace.Available)
    in
    ( (fun () ->
        (* Render the label when a branch targets it, or when the source named
           the block with a name we could keep — a named block keeps its label
           even if no branch targets it, so the name survives the round-trip. An
           anonymous (or unsalvageably-named) unbranched block stays
           label-free. *)
        if !used || Option.is_some src then (
          (* A label namespace reserves no words, so a rename is always a
             collision with an enclosing label of the same name. *)
          (match (src, outcome, diagnostics) with
          | Some l, Namespace.Renamed { reserved; previous }, Some diagnostics
            ->
              Sequence.report_rename diagnostics ~location:l.Ast.info ~previous
                ~reserved ~original:candidate ~renamed:name
          | _ -> ());
          Some
            (match label with
            | Some label -> { label with desc = name }
            | None -> Ast.no_loc name))
        else None),
      {
        ns;
        stack =
          (Option.map (fun l -> l.Ast.desc) label, (name, used)) :: st.stack;
      } )

  let get st (idx : Src.idx) =
    let name, used =
      match idx.desc with
      | Num n -> (
          match List.nth_opt st.stack (Uint32.to_int n) with
          | Some entry -> snd entry
          | None -> raise (Unresolved_reference idx.Ast.info))
      | Id id -> (
          match List.assoc_opt (Some id) st.stack with
          | Some entry -> entry
          | None -> raise (Unresolved_reference idx.Ast.info))
    in
    used := true;
    { idx with desc = name }

  let make () = { ns = Namespace.make ~kind:`Label (); stack = [] }
end

module CondTbl = struct
  (* A single Wax name may stand for several declarations across conditional
     branches with different definitions (e.g. a function imported with a
     different signature, hence a different arity, in each branch of an
     [(@if …)]). Each declaration is recorded with the assumption under which
     it holds, and a lookup resolves against the current branch's assumption,
     so a reference in a given branch sees the matching declaration. With a
     single declaration this degenerates to a plain name-keyed table. *)
  type 'a t = (string, (Cond.t * 'a) list) Hashtbl.t

  let make () : _ t = Hashtbl.create 16

  let add tbl asm name v =
    let prev = try Hashtbl.find tbl name with Not_found -> [] in
    Hashtbl.replace tbl name ((asm, v) :: prev)

  (* Raises [Not_found] when the name is unknown, like the plain table did. *)
  let find tbl asm name =
    match Hashtbl.find tbl name with
    | [ (_, v) ] -> v
    | entries -> (
        (* Resolve to the declaration whose branch is reachable under the
           current assumption, pruning declarations from mutually-exclusive
           branches. Falls back to the most recent if none is compatible
           (only for a reference that is itself unreachable). *)
        match
          List.find_opt
            (fun (c, _) -> Cond.is_satisfiable (Cond.and_ asm c))
            entries
        with
        | Some (_, v) -> v
        | None -> snd (List.hd entries))

  (* All declarations whose branch is reachable under [asm]. More than one
     means the reference does not select a single branch. *)
  let compatible tbl asm name =
    match Hashtbl.find_opt tbl name with
    | None -> []
    | Some entries ->
        List.filter_map
          (fun (c, v) ->
            if Cond.is_satisfiable (Cond.and_ asm c) then Some v else None)
          entries
end

(*** The conversion context ***)

type ctx = {
  types : Sequence.t;
  struct_fields : (string, Sequence.t * string list) Hashtbl.t;
  globals : Sequence.t;
  functions : Sequence.t;
  memories : Sequence.t;
  tables : Sequence.t;
  tags : Sequence.t;
  datas : Sequence.t;
  elems : Sequence.t;
  referenced_elems : (string, unit) Hashtbl.t;
      (* Wax names of element segments used by table.init / elem.drop /
         array.*_elem. A declarative segment is normally dropped (regenerated by
         [to_wasm] from ref.func usage), but one that is referenced this way
         needs an explicit declaration so the reference resolves. *)
  type_defs : Src.subtype CondTbl.t;
  implicit_types : (Uint32.t, Src.functype) Hashtbl.t;
      (* Function types that the WAT text format synthesises from inline
         [(param)]/[(result)] signatures (the type-use abbreviation), keyed by
         the type index they occupy. The source AST keeps such uses inline and
         does not materialise them as [Types] fields, so this table is what lets
         a numeric [(type N)] elsewhere resolve to the implicit type. These types
         are anonymous: they are rendered inline ([&fn(..)] / an inline [sign]),
         never as a named Wax type. Empty for modules with conditional
         annotations, where numeric references are forbidden anyway. *)
  mutable named_implicit : (string * Src.functype) list;
      (* Implicit function types that had to be given a name because they are
         referenced from a ref-type position (where Wax has no inline
         function-type form). Each is emitted as a [type <name> = fn(..)]
         declaration; accumulated in reverse order of first use. *)
  function_types : Src.typeuse CondTbl.t;
  exports :
    ( Src.exportable * string,
      (Cond.t * Wax_wasm.Ast.cond * Src.name) list )
    Hashtbl.t;
      (* Standalone [(export …)] fields, keyed by the Wax name of their target,
         attached to that target as [#[export]] attributes. Each is paired with
         the conditional-branch assumption under which it appears -- both the
         solved form (for satisfiability/implication tests) and the syntactic
         condition (for a [#[export …, if <cond>]] guard) -- so a target that
         exists in several mutually exclusive branches receives only the exports
         of its own branch, and an export narrower than its target's reachability
         is emitted as a guarded attribute. *)
  starts : (string, (Cond.t * Wax_wasm.Ast.cond) list) Hashtbl.t;
      (* [(start …)] fields, keyed by the Wax name of their function, rendered as
         a [#[start]] attribute on it rather than a separate field. As with
         [exports], each is paired with the branch condition under which it
         appears, so a start narrower than its function's reachability becomes a
         guarded [#[start, if <cond>]] and mutually exclusive starts (at most one
         per configuration) stay on their own functions. *)
  locals : Sequence.t;
  labels : LabelStack.t;
  tag_types : Src.typeuse CondTbl.t;
  label_arities : (string option * int) list;
  return_arity : int;
  strict_constants : bool;
      (* When set, every numeric constant is wrapped in a cast to its concrete
         type ([0 as i32], [0.0 as f64], ...). This keeps Wax type inference
         from re-typing an otherwise polymorphic literal, so a type mismatch in
         the source survives the round-trip. *)
  diagnostics : Wax_utils.Diagnostic.context;
  cond_env : Cond.env;
  cond_diag : Wax_utils.Diagnostic.context;
  mutable cond_asm : Cond.t;
      (* Assumption for the conditional branch currently being registered or
         converted; threaded through [Module_if_annotation]/[If_annotation] so
         the type tables above resolve to the right per-branch declaration. *)
}

(*** Names, indices, and type conversions ***)

let get_annot e = fst e.Ast.desc
let get_type e = snd e.Ast.desc

(* Build a located [annotated_array] element ([name : type] in a struct, or a
   subtype in a rec group), keeping the source location so a trailing comment
   attaches to the whole entry. *)
let annotated loc a t = { Ast.desc = (a, t); info = loc }

let idx ctx kind i =
  match kind with
  | `Type -> Sequence.get ctx.types i
  | `Global -> Sequence.get ctx.globals i
  | `Func -> Sequence.get ctx.functions i
  | `Mem -> Sequence.get ctx.memories i
  | `Table -> Sequence.get ctx.tables i
  | `Tag -> Sequence.get ctx.tags i
  | `Data -> Sequence.get ctx.datas i
  | `Elem -> Sequence.get ctx.elems i
  | `Local -> Sequence.get ctx.locals i

let label ctx i = LabelStack.get ctx.labels i

(* The Wax name for a concrete type reference [i] appearing in a ref-type. An
   implicit (inline-signature) function type has no source name and is normally
   rendered inline, but a ref-type position has no inline function-type form, so
   such a type is given a name on first use and emitted as a [type] declaration
   (see [named_implicit] / [extra_type_decls]). *)
let type_ref_name ctx (i : Src.idx) =
  match i.Ast.desc with
  | Src.Num n when Hashtbl.mem ctx.implicit_types n ->
      let name =
        match Sequence.find_bound ctx.types n with
        | Some name -> name
        | None ->
            let name = Sequence.mint_name ctx.types in
            Sequence.bind_at ctx.types n name;
            ctx.named_implicit <-
              (name, Hashtbl.find ctx.implicit_types n) :: ctx.named_implicit;
            name
      in
      { i with desc = name }
  | _ -> idx ctx `Type i

(* The spine ([heaptype]…[fieldtype]) copies each constructor through, naming
   each index via [type_ref_name]; [functype]/[comptype]/[subtype] below stay
   hand-written because they allocate Wax names (with rename diagnostics) and
   look up struct-field names. *)
module Map =
  Wax_wasm.Ast.Map_types_spine (Src) (Ast)
    (struct
      type nonrec ctx = ctx

      let idx st i = type_ref_name st i
    end)

let heaptype = Map.heaptype
let reftype = Map.reftype
let valtype = Map.valtype

(* Render a function type's parameters into a fresh namespace, renaming a named
   parameter that is a reserved word or collides with an earlier one (and
   warning about it, as for any other declared name). Unnamed parameters stay
   anonymous. Shared by function-type definitions and inline signatures. *)
let functype_params ctx params =
  let ns = Namespace.make () in
  Array.map
    (fun p ->
      let id, t = p.Ast.desc in
      let id =
        Option.map
          (fun id ->
            let name, outcome =
              Namespace.add' ~loc:id.Ast.info ns id.Ast.desc
            in
            (match outcome with
            | Namespace.Renamed { reserved; previous } ->
                Sequence.report_rename ctx.diagnostics ~location:id.Ast.info
                  ~previous ~reserved ~original:id.Ast.desc ~renamed:name
            | Namespace.Available -> ());
            { id with Ast.desc = name })
          id
      in
      (* Keep the parameter's source location on the Wax side too. *)
      annotated p.Ast.info id (valtype ctx t))
    params

let functype st (t : Src.functype) : Ast.functype =
  {
    params = functype_params st t.params;
    results = Array.map (fun t -> valtype st t) t.results;
  }

let muttype typ st (t : _ Src.muttype) : _ Ast.muttype =
  { t with typ = typ st t.typ }

let fieldtype = Map.fieldtype

let comptype st name (t : Src.comptype) : Ast.comptype =
  match t with
  | Func t -> Func (functype st t)
  | Struct l ->
      let seq = fst (Hashtbl.find st.struct_fields name) in
      Struct
        (Array.mapi
           (fun i t ->
             let id =
               Sequence.get seq
                 (match get_annot t with
                 | None -> Ast.no_loc (Src.Num (Uint32.of_int i))
                 | Some id -> { id with desc = Id id.Ast.desc })
             in
             annotated t.Ast.info id (fieldtype st (get_type t)))
           l)
  | Array t -> Array (fieldtype st t)
  | Cont i -> Cont (idx st `Type i)

let subtype st name (t : Src.subtype) : Ast.subtype =
  {
    typ = comptype st name t.typ;
    supertype = Option.map (fun i -> idx st `Type i) t.supertype;
    final = t.final;
    descriptor = Option.map (fun i -> idx st `Type i) t.descriptor;
    describes = Option.map (fun i -> idx st `Type i) t.describes;
  }

let rectype st (t : Src.rectype) : Ast.rectype =
  Array.map
    (fun t ->
      let name = Sequence.get_current st.types in
      annotated t.Ast.info name (subtype st name.desc (get_type t)))
    t

let globaltype st = muttype valtype st

(*** Type lookup and arity ***)

type _ kind =
  | Type : Src.subtype kind
  | Func : Src.typeuse kind
  | Tag : Src.typeuse kind

(* Run [f] with [ctx.cond_asm] extended by the branch condition [cond] (taken
   positively for [@then], negatively for [@else]), restoring it afterwards.
   Used in both the name-registration passes and the conversion so that type
   declarations are recorded under, and references resolved against, the
   assumption of the branch they appear in. *)
let with_cond ctx ~location cond positive f =
  let saved = ctx.cond_asm in
  let c = Cond.of_cond ctx.cond_env ctx.cond_diag ~location cond in
  ctx.cond_asm <- Cond.and_ saved (if positive then c else Cond.not_ c);
  Fun.protect ~finally:(fun () -> ctx.cond_asm <- saved) f

let lookup_type (type typ) ctx (kind : typ kind) idx : typ =
  let get seq tbl idx =
    CondTbl.find tbl ctx.cond_asm (Sequence.get seq idx).desc
  in
  match kind with
  | Type -> get ctx.types ctx.type_defs idx
  | Func -> get ctx.functions ctx.function_types idx
  | Tag -> get ctx.tags ctx.tag_types idx

let register_type (type typ) ?hint ctx export_tbl (kind : typ kind) idx exports
    (typ : typ) =
  let register seq tbl kind idx =
    CondTbl.add tbl ctx.cond_asm
      (Sequence.register' ?hint seq export_tbl kind idx exports)
      typ
  in
  match kind with
  | Type -> assert false
  | Func -> register ctx.functions ctx.function_types (Some Func) idx
  | Tag -> register ctx.tags ctx.tag_types (Some Tag) idx

(* The source module is converted without being validated first (validation is
   off by default), so it may be type-invalid in ways the conversion cannot
   represent. Report such a case and abort the conversion rather than crashing
   on an [assert false]. *)
let conversion_error ctx ~location message =
  Wax_utils.Diagnostic.report ctx.diagnostics ~location ~severity:Error ~message
    ();
  Wax_utils.Diagnostic.abort ()

(* The field sequence and names of the struct type [type_name] refers to.
   [ctx.struct_fields] holds only struct types, so a miss means the index names a
   non-struct type -- a [struct.new]/[.get]/[.set] validation would reject.
   Report it and abort like other conversion errors rather than crash on the
   missing table entry. *)
let struct_fields ctx type_name =
  match Hashtbl.find_opt ctx.struct_fields type_name.Ast.desc with
  | Some fields -> fields
  | None ->
      conversion_error ctx ~location:type_name.Ast.info (fun f () ->
          Format.fprintf f "This type should be a struct type.")

(* Decompilation ergonomics: when a reconstructed struct's leading fields exactly
   match (name and type) its supertype's full field list, replace that prefix
   with a [..] splice sentinel so the printer renders [type c: p = { .., delta }].
   A renamed or covariantly-refined inherited field breaks the match and stays
   explicit. Field types are compared at the Src level, which carries no Wax
   source locations (Ast field types would differ on location alone). The
   supertype is always defined-before (earlier in the group or in an earlier
   group), so the reconstructed [..] re-typechecks. *)
let collapse_splices ctx (rt : Ast.rectype) : Ast.rectype =
  let src_struct name =
    match
      try Some (CondTbl.find ctx.type_defs ctx.cond_asm name.Ast.desc)
      with Not_found -> None
    with
    | Some { Src.typ = Struct fields; _ } -> Some fields
    | _ -> None
  in
  (* Compare field types without their source locations (which differ between a
     supertype's declaration and the subtype's copy): [Src] text-format indices
     carry a location, so print the reconstructed Wax type and compare that. *)
  let same_type (a : Ast.fieldtype) (b : Ast.fieldtype) =
    let s (ft : Ast.fieldtype) =
      Format.asprintf "%t" (fun f ->
          Wax_utils.Printer.run f (fun pp ->
              Wax_lang.Output.storagetype pp ft.typ))
    in
    a.mut = b.mut && String.equal (s a) (s b)
  in
  Array.map
    (fun elt ->
      let name, (sub : Ast.subtype) = elt.Ast.desc in
      match (sub.typ, sub.supertype) with
      | Struct child_ast_fields, Some parent_name -> (
          match
            ( src_struct parent_name,
              Hashtbl.find_opt ctx.struct_fields parent_name.Ast.desc )
          with
          | Some parent_src, Some (_, parent_names) ->
              let parent_names = Array.of_list parent_names in
              let n = Array.length parent_src in
              let prefix_matches =
                (* [n = 0] would splice nothing, so [..] is pure noise there. *)
                n >= 1
                && n <= Array.length child_ast_fields
                && n <= Array.length parent_names
                &&
                let ok = ref true in
                for i = 0 to n - 1 do
                  if
                    not
                      (String.equal (fst child_ast_fields.(i).Ast.desc).desc
                         parent_names.(i)
                      && same_type
                           (snd child_ast_fields.(i).Ast.desc)
                           (fieldtype ctx (get_type parent_src.(i))))
                  then ok := false
                done;
                !ok
              in
              if prefix_matches then
                let delta =
                  Array.sub child_ast_fields n
                    (Array.length child_ast_fields - n)
                in
                let fields =
                  Array.append [| Ast.splice_field name.Ast.info |] delta
                in
                { elt with desc = (name, { sub with typ = Struct fields }) }
              else elt
          | _ -> elt)
      | _ -> elt)
    rt

let functype_arity { Src.params; results } =
  (Array.length params, Array.length results)

(* The implicit (anonymous) function type a numeric [(type N)] denotes, if [N]
   was synthesised from an inline signature; [None] for a named/explicit type or
   a symbolic reference. Consulted before the named-type tables so such a
   reference resolves to its signature rather than raising. *)
let implicit_functype ctx (idx : Src.idx) =
  match idx.Ast.desc with
  | Src.Num n -> Hashtbl.find_opt ctx.implicit_types n
  | Id _ -> None

let type_arity ctx idx =
  match implicit_functype ctx idx with
  | Some ty -> functype_arity ty
  | None -> (
      match (lookup_type ctx Type idx).typ with
      | Func ty -> functype_arity ty
      | Struct _ | Array _ | Cont _ ->
          conversion_error ctx ~location:idx.Ast.info (fun f () ->
              Format.fprintf f "This type should be a function type."))

let typeuse_arity ctx (i, ty) =
  match (i, ty) with
  | _, Some t -> functype_arity t
  | Some i, None -> type_arity ctx i
  | None, None -> assert false

let blocktype_arity ctx (typ : Src.blocktype option) =
  match typ with
  | None -> (0, 0)
  | Some (Valtype _) -> (0, 1)
  | Some (Typeuse t) -> typeuse_arity ctx t

(* The arity used to convert a reference (how many operands a call consumes) is
   fixed in the produced Wax, so it must be the same in every branch reachable
   here. If a name is declared with different arities in mutually-exclusive
   branches and the reference does not select one (e.g. it sits in unconditional
   code, as [dv_make] does in io.wat), there is no single faithful conversion;
   report it rather than emit a wrong-arity call. *)
let checked_arity ctx kind tbl what name_idx compatible =
  let arity = typeuse_arity ctx (lookup_type ctx kind name_idx) in
  let name = (Sequence.get tbl name_idx).Ast.desc in
  (match compatible ctx.cond_asm name with
  | _ :: _ :: _ as l when List.exists (fun t -> typeuse_arity ctx t <> arity) l
    ->
      Wax_utils.Diagnostic.report ctx.diagnostics ~location:name_idx.Ast.info
        ~severity:Error
        ~message:(fun f () ->
          Format.fprintf f
            "%s $%s is declared with different arities in mutually-exclusive \
             conditional branches but referenced where the branch is \
             undetermined; this cannot be converted to Wax."
            what name)
        ()
  | _ -> ());
  arity

let function_arity ctx f =
  checked_arity ctx Func ctx.functions "Function" f
    (CondTbl.compatible ctx.function_types)

let tag_arity ctx t =
  checked_arity ctx Tag ctx.tags "Tag" t (CondTbl.compatible ctx.tag_types)

let label_arity ctx (idx : Src.idx) =
  match idx.desc with
  | Id id -> (
      match
        List.find_opt
          (fun e -> match e with Some id', _ -> id = id' | _ -> false)
          ctx.label_arities
      with
      | Some e -> snd e
      | None -> raise (Unresolved_reference idx.Ast.info))
  | Num i -> (
      match List.nth_opt ctx.label_arities (Uint32.to_int i) with
      | Some e -> snd e
      | None -> raise (Unresolved_reference idx.Ast.info))

(* (parameter count, result count) of the function type a continuation type
   wraps. *)
let cont_arity ctx idx =
  match (lookup_type ctx Type idx).typ with
  | Cont ft -> type_arity ctx ft
  | Func _ | Struct _ | Array _ ->
      conversion_error ctx ~location:idx.Ast.info (fun f () ->
          Format.fprintf f "This type should be a continuation type.")

(* Number of values a [switch] to continuation [ct] produces: the parameters of
   the continuation referenced by the last parameter of [ct]'s function type. *)
let switch_output ctx ct =
  match (lookup_type ctx Type ct).typ with
  | Cont ft -> (
      match (lookup_type ctx Type ft).typ with
      | Func { params; _ } when Array.length params > 0 -> (
          match snd params.(Array.length params - 1).Ast.desc with
          | Ref { typ = Type ct2; _ } -> fst (cont_arity ctx ct2)
          | _ -> 0)
      | Func _ | Struct _ | Array _ | Cont _ -> 0)
  | Func _ | Struct _ | Array _ -> 0

let on_clause ctx (c : Src.on_clause) : Ast.on_clause =
  match c with
  | OnLabel (tag, lbl) -> OnLabel (idx ctx `Tag tag, label ctx lbl)
  | OnSwitch tag -> OnSwitch (idx ctx `Tag tag)

(*
Step 1: traverse types and find existing names
Step 2: use this info to generate using names without reusing existing names
*)

(*** The conversion stack ***)

module Stack = struct
  (* Each entry is [(present, width, instr)]. [width] records the numeric result
     width the producing opcode states — a const or arithmetic op tags its own
     width, everything else is [None].

     The two pops encode whether the consuming instruction's Wax surface syntax
     preserves or erases that width, so the choice is explicit at every call site
     (a "width eraser" left as a plain pop would silently drift):
     - [pop_width_preserved]: the operand's width is recoverable from the printed
       form — either the operand is not numeric, or the consumer's result has the
       same width and re-pins it (arithmetic: [a + b] round-trips to the operand
       width via the sum's own type).
     - [pop_width_erased]: the consumer's surface carries a *different* width (or
       none) — [drop], [i32.wrap_i64], comparisons, [eqz] — so an anchor-free
       operand tree re-defaults to i32 on re-parse, silently changing its width
       (and value: [(4096 >>u 40)] is 0 as i64, 16 as i32). It pins any non-i32
       opcode width with a cast so the width (and value) survive. [None] and
       [I32] need no pin (a typed anchor re-pins, or i32 is the default);
       [simplify]'s [load_bearing_literal] drops the pin again when it is
       redundant. *)
  type width = [ `I32 | `I64 | `F32 | `F64 ] option
  type stack = (bool * width * Ast.location Ast.instr) list
  type 'a t = stack -> stack * 'a

  let rec complete n cur =
    if n = 0 then cur else complete (n - 1) (Ast.no_loc Ast.Hole :: cur)

  let rec grab_rec n stack cur =
    if n = 0 then (stack, cur)
    else
      match stack with
      | (true, _, instr) :: rem -> grab_rec (n - 1) rem (instr :: cur)
      | _ -> (stack, complete n cur)

  let consume inputs stack =
    if inputs = 0 then (stack, ())
    else
      ( (match stack with
        | (true, w, instr) :: rem -> (false, w, instr) :: rem
        | _ -> stack),
        () )

  let grab n stack = grab_rec n stack []
  let push arity i stack = ((arity = 1, None, i) :: stack, ())

  (* Push a numeric value tagged with the width its opcode states. *)
  let push_num width i stack = ((true, width, i) :: stack, ())
  let push_poly i stack = ((false, None, i) :: stack, ())

  let pop_width_preserved stack =
    match stack with
    | (true, _, i) :: rem -> (rem, i)
    | _ -> (stack, Ast.no_loc Ast.Hole)

  (* Wrap [i] in an identity cast to its non-i32 opcode width (see the module
     comment). [None]/[I32] are the re-parse default, so leave the tree as is. *)
  let pin_width w i =
    match w with
    | Some `I64 -> { i with Ast.desc = Ast.Cast (i, Valtype I64) }
    | Some `F32 -> { i with Ast.desc = Ast.Cast (i, Valtype F32) }
    | Some `F64 -> { i with Ast.desc = Ast.Cast (i, Valtype F64) }
    | Some `I32 | None -> i

  (* Pop, pinning the operand's opcode width. Used by single-operand width
     erasers ([drop], [wrap], [promote], [demote]). *)
  let pop_width_erased stack =
    match stack with
    | (true, w, i) :: rem -> (rem, pin_width w i)
    | _ -> (stack, Ast.no_loc Ast.Hole)

  (* Pop with the width tag, without pinning — the caller decides (used by
     comparisons, which pin one operand only when *both* are anchor-free). *)
  let pop_tagged stack =
    match stack with
    | (true, w, i) :: rem -> (rem, (i, w))
    | _ -> (stack, (Ast.no_loc Ast.Hole, None))

  let try_pop stack =
    match stack with (true, _, i) :: rem -> (rem, Some i) | _ -> (stack, None)

  (* [try_pop] carrying the width tag — a method-form op tags its result with its
     receiver's flexibility, so an erasing consumer pins it (and the pin, cast on
     the result, propagates back to the receiver: [((5).clz()) as i64] is
     [i64.clz]). *)
  let try_pop_tagged stack =
    match stack with
    | (true, w, i) :: rem -> (rem, Some (i, w))
    | _ -> (stack, None)

  let run f =
    let st, () = f [] in
    List.rev_map (fun (_, _, i) -> i) st
end

let ( let* ) e f st =
  let st, v = e st in
  f v st

let return v st = (st, v)
let sequence l = match l with [ i ] -> i | _ -> Ast.no_loc (Ast.Sequence l)

(*** Instruction-conversion helpers ***)

let is_integer =
  let int_re =
    Re.(
      compile
        (whole_string
           (alt
              [
                rep1 (alt [ rg '0' '9'; char '_' ]);
                seq
                  [
                    str "0x";
                    rep1 (alt [ rg '0' '9'; rg 'a' 'f'; rg 'A' 'F'; char '_' ]);
                  ];
              ])))
  in
  fun s -> Re.execp int_re s

let is_negative n = n.[0] = '-'

let remove_sign n =
  if n.[0] = '-' || n.[0] = '+' then String.sub n 1 (String.length n - 1) else n

(* A Wax operator carries its own source location; reuse the (source or target)
   instruction's, which is the best approximation we have when reconstructing
   from Wasm. Polymorphic in the carried [desc] so it works for either AST. *)
let op_loc (i : (_, Ast.location) Ast.annotated) op :
    (_, Ast.location) Ast.annotated =
  { i with Ast.desc = op }

let integer i n : _ Ast.instr =
  let e : _ Ast.instr = { i with desc = Int (remove_sign n) } in
  if is_negative n then { i with desc = UnOp (op_loc i Ast.Neg, e) } else e

let float i n =
  (* Test the magnitude, not the signed string: a negative integer-valued float
     (e.g. [-4.0] printed as [-4]) must take the [integer] path too, else it
     becomes a [Float] node whose integer-looking text ([-4]) re-lexes as an
     integer literal on the round-trip — dropping the block/cast annotation that
     pinned it to a float and leaving [.to_bits()] applied to an [i64]. *)
  if is_integer (remove_sign n) then integer i n
  else
    let e : _ Ast.instr = { i with desc = Float (remove_sign n) } in
    if is_negative n then { i with desc = UnOp (op_loc i Ast.Neg, e) } else e

let sequence_opt l =
  match l with
  | [] -> None
  | [ i ] -> Some i
  | l -> Some (Ast.no_loc (Ast.Sequence l))

let reasonable_string =
  Re.(
    compile
      (whole_string
         (rep
            (alt
               [ diff any (rg '\000' '\031'); char '\n'; char '\r'; char '\t' ]))))

let string_args n args =
  if n = Uint32.zero then None
  else
    let byte_of_arg arg =
      match arg.Ast.desc with
      | Ast.Int c -> (
          (* [int_of_string_opt]: a byte value too large for an [int] (let alone a
             byte) is simply not a string byte, not a crash. *)
          match int_of_string_opt c with
          | Some c when c >= 0 && c < 256 -> Some c
          | _ -> None)
      | Ast.Char c when Uchar.to_int c < 128 -> Some (Uchar.to_int c)
      | _ -> None
    in
    try
      if Uint32.of_int (List.length args) <> n then raise Exit;
      let b = Bytes.create (Uint32.to_int n) in
      List.iteri
        (fun i arg ->
          match byte_of_arg arg with
          | Some c -> Bytes.set b i (Char.chr c)
          | None -> raise Exit)
        args;
      let s = Bytes.to_string b in
      if String.is_valid_utf_8 s && Re.execp reasonable_string s then Some s
      else None
    with Exit -> None

(* As [string_args], but for an [i16] array: each argument is a UTF-16 code unit
   (0..0xffff), decoded back to the source string. Falls back ([None]) on a
   value out of range or a lone surrogate, so a genuine numeric array stays one. *)
let wide_string_args n args =
  if n = Uint32.zero then None
  else
    let unit_of_arg arg =
      match arg.Ast.desc with
      | Ast.Int c -> (
          match int_of_string_opt c with
          | Some c when c >= 0 && c < 0x10000 -> Some c
          | _ -> None)
      | Ast.Char c when Uchar.to_int c < 0x10000 -> Some (Uchar.to_int c)
      | _ -> None
    in
    try
      if Uint32.of_int (List.length args) <> n then raise Exit;
      let units =
        List.map
          (fun arg ->
            match unit_of_arg arg with Some c -> c | None -> raise Exit)
          args
      in
      match Wax_utils.Unicode.utf16_decode units with
      | Some s when Re.execp reasonable_string s -> Some s
      | _ -> None
    with Exit -> None

let inttype ty : Ast.valtype =
  match ty with
  | `I32 -> I32
  | `I64 -> I64
  | `F32 -> I32
  | `F64 -> I64
  | _ -> assert false

let floattype ty : Ast.valtype =
  match ty with
  | `I32 -> F32
  | `I64 -> F64
  | `F32 -> F32
  | `F64 -> F64
  | _ -> assert false

let int_un_op i0 sz (op : Src.int_un_op) =
  let with_loc (i : _ Ast.instr_desc) = { i0 with Ast.desc = i } in
  (* A no-argument instruction method [recv.meth()]. *)
  let method_call recv meth =
    with_loc (Call (with_loc (StructGet (recv, Ast.no_loc meth)), []))
  in
  let* recv = Stack.try_pop_tagged in
  let e' = Option.map fst recv in
  (* The operand's own width tag (its flexibility): a method-form op below
     ([clz]/[ctz]/[popcnt]/[extend8_s]/[extend16_s]) has result width = receiver
     width, so it carries the receiver's flexibility to its result — an erasing
     consumer then pins it, and the pin (a cast on the result) propagates back to
     the receiver. Ops that fix a concrete result width (a cast: [trunc], [eqz]'s
     i32) are grounded, [None]. *)
  let recv_w = match recv with Some (_, w) -> w | None -> None in
  let e ty =
    match e' with
    | Some e -> e
    | None -> Ast.no_loc (Ast.Cast (Ast.no_loc Ast.Hole, Valtype ty))
  in
  (* Materialise the operand with its scalar width [ty] pinned by a cast when
     [ty] is a non-default width (i64/f32/f64) and the operand is inlined —
     otherwise the surface form re-defaults it (a bare float literal to f64, a
     bare integer to i32). An absent operand ([None]) is already the hole cast
     [e] builds; an [i32] target needs no pin (i32 is the re-parse default), so
     it also leaves the operand's shape untouched (keeping the [eqz] special case
     below matchable). Used by the width-erasing unary ops whose surface carries
     the *result* width, not the operand's: the truncations (float source) and
     [eqz] (i64 operand -> i32 result). *)
  let pin ty =
    let x = e ty in
    match (e', ty) with
    | Some _, (Ast.I64 | F32 | F64) ->
        { x with Ast.desc = Ast.Cast (x, Valtype ty) }
    | _ -> x
  in
  (* Width-preserving method-form ops carry the receiver's flexibility; the rest
     produce a concrete (grounded) result. *)
  let result_w =
    match op with
    | Clz | Ctz | Popcnt | ExtendS (`_8 | `_16) -> recv_w
    | _ -> None
  in
  Stack.push_num result_w
    (match op with
    | Clz -> method_call (e (inttype sz)) "clz"
    | Ctz -> method_call (e (inttype sz)) "ctz"
    | Popcnt -> method_call (e (inttype sz)) "popcnt"
    | Eqz -> (
        let operand = pin (inttype sz) in
        match operand.Ast.desc with
        (* [eqz] of an equality is exactly the negated comparison; recover
           [i32.eqz (ref.eq a b)] — how [a != b] on references lowers — as
           [a != b] rather than [!(a == b)]. ([sz] is [i32] here, so [pin] leaves
           the [BinOp] shape untouched.) *)
        | BinOp ({ Ast.desc = Ast.Eq; _ }, e1, e2) ->
            with_loc (BinOp (op_loc i0 Ast.Ne, e1, e2))
        | _ -> with_loc (UnOp (op_loc i0 Ast.Not, operand)))
    | Trunc (f, signage) ->
        (* The operand is a float of [f]'s width, NOT [floattype sz] ([sz] is the
           integer *result* size — wrong for e.g. [i32.trunc_f64], whose operand
           is f64 not f32). Unlike the trunc's own [as int] cast (which fixes the
           *result* width), nothing here pins the *source* float width, so an
           inlined operand must carry it explicitly: a bare float literal
           re-defaults to f64 (so an f32 source drifts), and an integer-valued
           float const prints as a bare integer that re-defaults to i32 (so even
           an f64 source drifts) — both silently changing which inputs trap. Pin
           it with a cast, as [Reinterpret] does; [simplify] drops the pin again
           when the operand already settles on [fty] (a plain f64 literal). *)
        let fty : Ast.valtype = match f with `F32 -> F32 | `F64 -> F64 in
        with_loc
          (Cast (pin fty, Signedtype { typ = sz; signage; strict = true }))
    | TruncSat (f, signage) ->
        let fty : Ast.valtype = match f with `F32 -> F32 | `F64 -> F64 in
        with_loc
          (Cast (pin fty, Signedtype { typ = sz; signage; strict = false }))
    | Reinterpret ->
        method_call
          (let e = e (floattype sz) in
           if e' = None then e
           else { e with desc = Ast.Cast (e, Valtype (floattype sz)) })
          "to_bits"
    | ExtendS `_32 ->
        (* i64.extend32_s *)
        with_loc
          (Cast
             ( (let e = e (inttype `I32) in
                if e' = None then e
                else { e with desc = Ast.Cast (e, Valtype (inttype `I32)) }),
               Signedtype { typ = sz; signage = Signed; strict = false } ))
    | ExtendS `_8 -> method_call (e (inttype sz)) "extend8_s"
    | ExtendS `_16 -> method_call (e (inttype sz)) "extend16_s")

(* Pop an operand for a method-form intrinsic, ascribing it the operator's
   scalar type [ty]. A non-inlinable operand becomes a typed hole [(_ as ty)]
   rather than a bare [_], so the call type-checks in unreachable code where the
   operand stack is polymorphic (mirrors the unary ops [int_un_op]/[float_un_op]).
   The arithmetic/comparison operators need no such cast: they lower to plain
   [BinOp]s, which accept a polymorphic operand. *)
let pop_typed ty =
  let* o = Stack.try_pop in
  return
    (match o with
    | Some e -> e
    | None -> Ast.no_loc (Ast.Cast (Ast.no_loc Ast.Hole, Valtype ty)))

(* [pop_typed] carrying the receiver's width tag, for a method-form op that
   inherits its receiver's flexibility (a rotate, a float method). A hole is
   grounded ([None]). *)
let pop_typed_tagged ty =
  let* o = Stack.try_pop_tagged in
  return
    (match o with
    | Some (e, w) -> (e, w)
    | None -> (Ast.no_loc (Ast.Cast (Ast.no_loc Ast.Hole, Valtype ty)), None))

let int_bin_op i0 sz (op : Src.int_bin_op) =
  let with_loc (i : _ Ast.instr_desc) = { i0 with Ast.desc = i } in
  (* An arithmetic operator yields the operand width, so [a + b] round-trips to
     that width via the sum's own type — operands are width-preserved. Its result
     is a flexible literal tree (tagged) only when BOTH operands are; if either is
     grounded (tag [None]: a local, a call — a typed anchor), the sum is grounded
     too ([x + 1] re-parses to [x]'s width on its own), so it takes no tag and no
     downstream eraser pins it. *)
  let symbol width op =
    let* e2, w2 = Stack.pop_tagged in
    let* e1, w1 = Stack.pop_tagged in
    let width = match (w1, w2) with Some _, Some _ -> width | _ -> None in
    Stack.push_num width (with_loc (BinOp (op_loc i0 op, e1, e2)))
  in
  let arith = Some (sz :> [ `I32 | `I64 | `F32 | `F64 ]) in
  (* A comparison yields i32 whatever its operands' width, so it *erases* it:
     [(4096 >>u 40) == 0] would re-default the shift to i32 and flip true->false.
     Pin one operand's width only when *both* are anchor-free numeric producers
     (both tagged) — an anchored operand (tag [None]: a local, a call result)
     already fixes the width and the other unifies to it, so [x <s 0] needs no
     pin. The i32 result carries no tag. *)
  let compare op =
    let* e2, w2 = Stack.pop_tagged in
    let* e1, w1 = Stack.pop_tagged in
    let e1 =
      match (w1, w2) with Some _, Some _ -> Stack.pin_width arith e1 | _ -> e1
    in
    Stack.push 1 (with_loc (BinOp (op_loc i0 op, e1, e2)))
  in
  (* [rotl]/[rotr]: result width = receiver width, so it carries the receiver's
     flexibility (the count arg is pinned by the method once the receiver fixes
     it). Like [clz], an erasing consumer then pins it back to the receiver. *)
  let meth name =
    let* e2 = pop_typed (inttype sz) in
    let* e1, w1 = pop_typed_tagged (inttype sz) in
    Stack.push_num w1
      (with_loc (Call (with_loc (StructGet (e1, Ast.no_loc name)), [ e2 ])))
  in
  match op with
  | Add -> symbol arith Add
  | Sub -> symbol arith Sub
  | Mul -> symbol arith Mul
  | Div s -> symbol arith (Div (Some s))
  | Rem s -> symbol arith (Rem s)
  | And -> symbol arith And
  | Or -> symbol arith Or
  | Xor -> symbol arith Xor
  | Shl -> symbol arith Shl
  | Shr s -> symbol arith (Shr s)
  | Rotl -> meth "rotl"
  | Rotr -> meth "rotr"
  | Eq -> compare Eq
  | Ne -> compare Ne
  | Lt s -> compare (Lt (Some s))
  | Gt s -> compare (Gt (Some s))
  | Le s -> compare (Le (Some s))
  | Ge s -> compare (Ge (Some s))

let float_un_op i0 sz (op : Src.float_un_op) =
  let with_loc (i : _ Ast.instr_desc) = { i0 with Ast.desc = i } in
  (* A no-argument instruction method [recv.meth()]. *)
  let method_call recv meth =
    with_loc (Call (with_loc (StructGet (recv, Ast.no_loc meth)), []))
  in
  let* recv = Stack.try_pop_tagged in
  let e' = Option.map fst recv in
  let recv_w = match recv with Some (_, w) -> w | None -> None in
  let e ty =
    match e' with
    | Some e -> e
    | None -> Ast.no_loc (Ast.Cast (Ast.no_loc Ast.Hole, Valtype ty))
  in
  (* [neg]/[abs]/…/[sqrt] have result width = operand width, so they carry the
     operand's flexibility (like [clz]); [convert]/[reinterpret] fix a concrete
     result width via a cast, so they are grounded ([None]). *)
  let result_w =
    match op with
    | Neg | Abs | Ceil | Floor | Trunc | Nearest | Sqrt -> recv_w
    | Convert _ | Reinterpret -> None
  in
  Stack.push_num result_w
    (match op with
    | Neg -> with_loc (UnOp (op_loc i0 Ast.Neg, e (floattype sz)))
    | Abs -> method_call (e (floattype sz)) "abs"
    | Ceil -> method_call (e (floattype sz)) "ceil"
    | Floor -> method_call (e (floattype sz)) "floor"
    | Trunc -> method_call (e (floattype sz)) "trunc"
    | Nearest -> method_call (e (floattype sz)) "nearest"
    | Sqrt -> method_call (e (floattype sz)) "sqrt"
    | Convert (sz', signage) ->
        with_loc
          (Cast
             ( e (inttype (sz' :> [ `I32 | `I64 | `F32 | `F64 ])),
               Signedtype { typ = sz; signage; strict = false } ))
    | Reinterpret ->
        method_call
          (let e = e (inttype sz) in
           if e' = None then e
           else { e with desc = Ast.Cast (e, Valtype (inttype sz)) })
          "from_bits")

let float_bin_op i0 sz (op : Src.float_bin_op) =
  let with_loc (i : _ Ast.instr_desc) = { i0 with Ast.desc = i } in
  (* As for [int_bin_op]: an arithmetic operator preserves the operand width and
     its result is flexible only when both operands are (else grounded, no tag); a
     comparison erases the width (i32 result), so it pins its operands. *)
  let symbol width op =
    let* e2, w2 = Stack.pop_tagged in
    let* e1, w1 = Stack.pop_tagged in
    let width = match (w1, w2) with Some _, Some _ -> width | _ -> None in
    Stack.push_num width (with_loc (BinOp (op_loc i0 op, e1, e2)))
  in
  let arith = Some (sz :> [ `I32 | `I64 | `F32 | `F64 ]) in
  (* As for [int_bin_op]: pin one operand only when both are anchor-free. *)
  let compare op =
    let* e2, w2 = Stack.pop_tagged in
    let* e1, w1 = Stack.pop_tagged in
    let e1 =
      match (w1, w2) with Some _, Some _ -> Stack.pin_width arith e1 | _ -> e1
    in
    Stack.push 1 (with_loc (BinOp (op_loc i0 op, e1, e2)))
  in
  (* [min]/[max]/[copysign]: result width = receiver width (as [rotl]). *)
  let meth name =
    let* e2 = pop_typed (floattype sz) in
    let* e1, w1 = pop_typed_tagged (floattype sz) in
    Stack.push_num w1
      (with_loc (Call (with_loc (StructGet (e1, Ast.no_loc name)), [ e2 ])))
  in
  match op with
  | Add -> symbol arith Add
  | Sub -> symbol arith Sub
  | Mul -> symbol arith Mul
  | Div -> symbol arith (Div None)
  | Min -> meth "min"
  | Max -> meth "max"
  | CopySign -> meth "copysign"
  | Eq -> compare Eq
  | Ne -> compare Ne
  | Lt -> compare (Lt None)
  | Gt -> compare (Gt None)
  | Le -> compare (Le None)
  | Ge -> compare (Ge None)

let blocktype ctx (typ : Src.blocktype option) =
  match typ with
  | None -> { Ast.params = [||]; results = [||] }
  | Some (Valtype ty) -> { Ast.params = [||]; results = [| valtype ctx ty |] }
  | Some (Typeuse (ty_idx, sign)) ->
      let { Src.params; results } =
        match (ty_idx, sign) with
        | _, Some sign -> sign
        | Some idx, _ -> (
            let ty = lookup_type ctx Type idx in
            match ty.typ with
            | Struct _ | Array _ | Cont _ -> assert false
            | Func sign -> sign)
        | None, None -> assert false
      in
      {
        Ast.params =
          Array.map
            (fun p -> annotated p.Ast.info None (valtype ctx (snd p.Ast.desc)))
            params;
        results = Array.map (fun t -> valtype ctx t) results;
      }

let label_targeted (instrs : _ Src.instr list) =
  let hit depth (idx : Src.idx) =
    match idx.desc with Num n -> Uint32.to_int n = depth | Id _ -> false
  in
  let rec any depth instrs = List.exists (one depth) instrs
  and one depth (i : _ Src.instr) =
    match i.desc with
    | Br i
    | Br_if i
    | Br_on_null i
    | Br_on_non_null i
    | Br_on_cast (i, _, _)
    | Br_on_cast_fail (i, _, _)
    | Br_on_cast_desc_eq (i, _, _)
    | Br_on_cast_desc_eq_fail (i, _, _) ->
        hit depth i
    | Br_table (labels, lab) -> List.exists (hit depth) (lab :: labels)
    | Block { block; _ } | Loop { block; _ } -> any (depth + 1) block.desc
    | If { if_block; else_block; _ } ->
        any (depth + 1) if_block.desc || any (depth + 1) else_block.desc
    | TryTable { block; catches; _ } ->
        any (depth + 1) block.desc
        || List.exists
             (fun (c : Src.catch) ->
               match c with
               | Catch (_, l) | CatchRef (_, l) | CatchAll l | CatchAllRef l ->
                   hit depth l)
             catches
    | Try { block; catches; catch_all; _ } -> (
        any (depth + 1) block.desc
        || List.exists (fun (_, b) -> any (depth + 1) b.Ast.desc) catches
        ||
        match catch_all with
        | Some b -> any (depth + 1) b.Ast.desc
        | None -> false)
    | Resume (_, handlers)
    | ResumeThrowRef (_, handlers)
    | ResumeThrow (_, _, handlers) ->
        List.exists
          (fun (c : Src.on_clause) ->
            match c with OnLabel (_, l) -> hit depth l | OnSwitch _ -> false)
          handlers
    | Hinted (_, i) -> one depth i
    (* Folded WAT form: the operands [l] and the head [i] run at this same
       depth (the wrapper opens no block scope), mirroring how [instruction]
       flattens it. *)
    | Folded (i, l) -> one depth i || any depth l
    | _ -> false
  in
  any 0 instrs

let push_label ctx ~loop ~targeted label typ =
  let arity = blocktype_arity ctx typ in
  let i = if loop then fst arity else snd arity in
  let label_arities =
    (Option.map (fun l -> l.Ast.desc) label, i) :: ctx.label_arities
  in
  let label, labels =
    LabelStack.push ~diagnostics:ctx.diagnostics ~targeted ctx.labels label
  in
  (label, { ctx with labels; label_arities })

(*
let bottom_heap_type ctx (t : Src.heaptype) : Ast.heaptype =
  match t with
  | Any | Eq | I31 | Struct | Array | None_ -> None_
  | Func | NoFunc -> NoFunc
  | Exn | NoExn -> NoExn
  | Extern | NoExtern -> NoExtern
  | Type ty -> (
      match (lookup_type ctx Type ty).typ with
      | Struct _ | Array _ -> None_
      | Func _ -> NoFunc)
*)
(* Trailing [align]/[offset] literal arguments of a memory access: [align] only
   when it differs from the natural alignment, [offset] only when non-zero (and
   then [align] too, since they are positional). *)
let mem_extra with_loc (memarg : Src.memarg) nat =
  let lit v = with_loc (Ast.Int (Wax_utils.Uint64.to_string v)) in
  let nat = Wax_utils.Uint64.of_int nat in
  if Wax_utils.Uint64.compare memarg.offset Wax_utils.Uint64.zero <> 0 then
    [ lit memarg.align; lit memarg.offset ]
  else if Wax_utils.Uint64.compare memarg.align nat <> 0 then
    [ lit memarg.align ]
  else []

(* The callee of an indirect call: [tab[index]] narrowed to the call's function
   type, i.e. [tab[index] as &$ft] (named type) or [tab[index] as &fn(..)] (an
   inline type, with no named type to reference). The cast is always emitted;
   [to_wasm] re-fuses the whole pattern back to [call_indirect]. *)
let indirect_callee ctx with_loc tab ((tyidx, sign) : Src.typeuse) index =
  let tabget =
    with_loc (Ast.ArrayGet (with_loc (Ast.Get (idx ctx `Table tab)), index))
  in
  let inline_functype (s : Src.functype) : Ast.casttype =
    let sign : Ast.functype =
      {
        params = functype_params ctx s.params;
        results = Array.map (fun t -> valtype ctx t) s.results;
      }
    in
    Ast.Functype { nullable = true; sign }
  in
  let cast_type : Ast.casttype option =
    match Option.bind tyidx (implicit_functype ctx) with
    | Some ft ->
        (* Anonymous implicit type: no named type to reference, render inline. *)
        Some (inline_functype ft)
    | None -> (
        match tyidx with
        | Some ti ->
            Some
              (Ast.Valtype
                 (Ast.Ref { nullable = true; typ = Ast.Type (idx ctx `Type ti) }))
        | None -> Option.map inline_functype sign)
  in
  match cast_type with
  | Some ct -> with_loc (Ast.Cast (tabget, ct))
  | None -> tabget

(* A bottom descriptor operand carries no descriptor type of its own — a hole
   (dead code, popped from an empty stack) or a [ref.null none]-style null (a cast
   to a bottom heap type) — so the typer cannot recover the target from it. Pin it
   to the descriptor type of the target [x] ([exact] matching the target's
   exactness); a concrete operand keeps its own type. An existing bottom cast's
   target is rewritten in place, so [simplify] cannot fold the pin back to bottom. *)
let pin_descriptor ctx ~exact x d =
  match (lookup_type ctx Type x).descriptor with
  | None -> d
  | Some y -> (
      let y = idx ctx `Type y in
      let pin =
        Ast.Valtype
          (Ast.Ref
             {
               nullable = true;
               typ = (if exact then Ast.Exact y else Ast.Type y);
             })
      in
      let is_bottom (t : Ast.heaptype) =
        match t with
        | None_ | NoFunc | NoExtern | NoExn | NoCont -> true
        | _ -> false
      in
      match d.Ast.desc with
      | Ast.Hole | Ast.Null -> { d with Ast.desc = Ast.Cast (d, pin) }
      | Ast.Cast (inner, Ast.Valtype (Ast.Ref { typ; _ })) when is_bottom typ ->
          { d with Ast.desc = Ast.Cast (inner, pin) }
      | _ -> d)

(* As [pin_descriptor], taking the target as the [reftype] the branch/cast
   immediate carries (an abstract target has no descriptor — leave the hole). *)
let pin_descriptor_reftype ctx (t : Src.reftype) d =
  match t.typ with
  | Type x -> pin_descriptor ctx ~exact:false x d
  | Exact x -> pin_descriptor ctx ~exact:true x d
  | _ -> d

(*** The instruction converter ***)

(* Only value-producing arithmetic and bitwise operators have a compound-
   assignment form; comparisons do not. *)
let has_compound_form : Ast.binop -> bool = function
  | Add | Sub | Mul | Div _ | Rem _ | And | Or | Xor | Shl | Shr _ -> true
  | Eq | Ne | Lt _ | Gt _ | Le _ | Ge _ -> false

(* Build the assignment [target = e], collapsing [x = x op e] back into the
   compound assignment [x op= e] — the inverse of the lowering in {!To_wasm}.
   The variable must be the operator's left operand. *)
let set_desc target e =
  match e.Ast.desc with
  | Ast.BinOp (op, { desc = Get y; _ }, rhs)
    when has_compound_form op.desc && String.equal y.desc target.Ast.desc ->
      Ast.Set (target, Some op, rhs)
  | _ -> Ast.Set (target, None, e)

(* A decompiled struct-literal field. When the value is a plain [Get] of the
   like-named local/global/function, use the punning shorthand [{x}] ([None])
   rather than the redundant [{x: x}]; re-parsing resolves the pun to that same
   [Get], so the output round-trips. *)
let struct_field nm (v : _ Ast.instr) =
  match v.desc with
  | Ast.Get x when String.equal x.desc nm -> (Ast.no_loc nm, None)
  | _ -> (Ast.no_loc nm, Some v)

let rec instruction ctx (i : _ Src.instr) : unit Stack.t =
  let with_loc (i' : _ Ast.instr_desc) = { i with Ast.desc = i' } in
  let mem_call m meth args =
    with_loc
      (Ast.Call
         ( with_loc
             (Ast.StructGet
                (with_loc (Ast.Get (idx ctx `Mem m)), Ast.no_loc meth)),
           args ))
  in
  let table_call t meth args =
    with_loc
      (Ast.Call
         ( with_loc
             (Ast.StructGet
                (with_loc (Ast.Get (idx ctx `Table t)), Ast.no_loc meth)),
           args ))
  in
  (* [seg.drop()] on a data or element segment. *)
  let drop_call kind seg =
    with_loc
      (Ast.Call
         ( with_loc
             (Ast.StructGet
                (with_loc (Ast.Get (idx ctx kind seg)), Ast.no_loc "drop")),
           [] ))
  in
  (* [recv.meth(args)] method call and [f(args)] free-function call, used for
     SIMD intrinsics. *)
  let meth_call recv meth args =
    with_loc (Ast.Call (with_loc (Ast.StructGet (recv, Ast.no_loc meth)), args))
  in
  (* [ns::name(args)] qualified-path intrinsic call (SIMD free functions, wide
     arithmetic). *)
  let path_call ns name args =
    with_loc
      (Ast.Call (with_loc (Ast.Path (Ast.no_loc ns, Ast.no_loc name)), args))
  in
  (* Ascribe a (struct/array) method receiver its reference type, so the method
     resolves even when the receiver is a hole on a polymorphic stack (unreachable
     code); a redundant cast on a concrete receiver is dropped by [simplify]. *)
  let cast_ref recv typ =
    {
      recv with
      Ast.desc = Ast.Cast (recv, Valtype (Ref { nullable = true; typ }));
    }
  in
  match i.desc with
  | Block { label; typ; block } ->
      let label, ctx =
        push_label ctx ~loop:false
          ~targeted:(label_targeted block.desc)
          label typ
      in
      let block = Stack.run (instructions ctx block.desc) in
      let inputs, outputs = blocktype_arity ctx typ in
      let* () = Stack.consume inputs in
      Stack.push
        (if inputs > 0 then 0 else outputs)
        (with_loc
           (Block
              {
                label = label ();
                typ = blocktype ctx typ;
                block = Ast.no_loc block;
              }))
  | Loop { label; typ; block } ->
      let label, ctx =
        push_label ctx ~loop:true
          ~targeted:(label_targeted block.desc)
          label typ
      in
      let block = Stack.run (instructions ctx block.desc) in
      let inputs, outputs = blocktype_arity ctx typ in
      let* () = Stack.consume inputs in
      Stack.push
        (if inputs > 0 then 0 else outputs)
        (with_loc
           (Loop
              {
                label = label ();
                typ = blocktype ctx typ;
                block = Ast.no_loc block;
              }))
  | If { label; typ; if_block; else_block } ->
      let label, ctx =
        push_label ctx ~loop:false
          ~targeted:
            (label_targeted if_block.desc || label_targeted else_block.desc)
          label typ
      in
      (* Keep the (then ...)/(else ...) clause locations on the Wax blocks so a
         comment opening a clause attaches to the block rather than the
         condition or the previous clause's last instruction. *)
      let if_block =
        { if_block with Ast.desc = Stack.run (instructions ctx if_block.desc) }
      in
      let else_block =
        if else_block.desc = [] then None
        else
          Some
            {
              else_block with
              Ast.desc = Stack.run (instructions ctx else_block.desc);
            }
      in
      let inputs, outputs = blocktype_arity ctx typ in
      let* cond = Stack.pop_width_preserved in
      let* () = Stack.consume inputs in
      Stack.push
        (if inputs > 0 then 0 else outputs)
        (with_loc
           (If
              {
                label = label ();
                typ = blocktype ctx typ;
                cond;
                if_block;
                else_block;
              }))
  | TryTable { label = labl; typ; block; catches } ->
      let labl, block_ctx =
        push_label ctx ~loop:false
          ~targeted:(label_targeted block.desc)
          labl typ
      in
      let block = Stack.run (instructions block_ctx block.desc) in
      let catches =
        List.map
          (fun (catch : Src.catch) : Ast.catch ->
            match catch with
            | Catch (t, l) -> Catch (idx ctx `Tag t, label ctx l)
            | CatchRef (t, l) -> CatchRef (idx ctx `Tag t, label ctx l)
            | CatchAll l -> CatchAll (label ctx l)
            | CatchAllRef l -> CatchAllRef (label ctx l))
          catches
      in
      let inputs, outputs = blocktype_arity ctx typ in
      let* () = Stack.consume inputs in
      Stack.push
        (if inputs > 0 then 0 else outputs)
        (with_loc
           (TryTable
              {
                label = labl ();
                typ = blocktype ctx typ;
                block = Ast.no_loc block;
                catches;
              }))
  | Try { label; typ; block; catches; catch_all } ->
      (* A [br] out of the try's body or any of its handler blocks targets the
         one try scope, so all of them bear on whether this label renders. *)
      let targeted =
        label_targeted block.desc
        || List.exists (fun (_, b) -> label_targeted b.Ast.desc) catches
        ||
        match catch_all with
        | Some b -> label_targeted b.Ast.desc
        | None -> false
      in
      let label, ctx = push_label ctx ~loop:false ~targeted label typ in
      let block = Stack.run (instructions ctx block.desc) in
      let catches =
        List.map
          (fun (t, block) ->
            ( idx ctx `Tag t,
              Ast.no_loc (Stack.run (instructions ctx block.Ast.desc)) ))
          catches
      in
      let catch_all =
        Option.map
          (fun block ->
            Ast.no_loc (Stack.run (instructions ctx block.Ast.desc)))
          catch_all
      in
      let inputs, outputs = blocktype_arity ctx typ in
      let* () = Stack.consume inputs in
      Stack.push
        (if inputs > 0 then 0 else outputs)
        (with_loc
           (Try
              {
                label = label ();
                typ = blocktype ctx typ;
                block = Ast.no_loc block;
                catches;
                catch_all;
              }))
  | Unreachable -> Stack.push_poly (with_loc Unreachable)
  | Nop -> Stack.push 0 (with_loc Nop)
  | Drop ->
      (* A dropped value supplies no expected type: a width eraser (see [Stack]).
         [i64.div_u (2147483648 + 2147483648)] would re-default its divisor to a
         trapping [0]. The drop is an anonymous [Let] ([_ = e]); a non-default
         flexible width is pinned in its type annotation ([_: i64 = e]) rather
         than by an identity cast on the value, so the reader is never left to
         disambiguate a genuine [as] conversion from a width pin. The keep/drop
         of that annotation then reuses the ordinary [Let] machinery. *)
      let* e, w = Stack.pop_tagged in
      let annot : Ast.valtype option =
        match w with
        | Some `I64 -> Some I64
        | Some `F32 -> Some F32
        | Some `F64 -> Some F64
        | Some `I32 | None -> None
      in
      Stack.push 0 (with_loc (Let ([ (None, annot) ], Some e)))
  | Br i ->
      let input = label_arity ctx i in
      let* args = Stack.grab input in
      Stack.push_poly (with_loc (Br (label ctx i, sequence_opt args)))
  | Br_if i ->
      let input = label_arity ctx i in
      let* args = Stack.grab (input + 1) in
      Stack.push input (with_loc (Br_if (label ctx i, sequence args)))
  (* Branch-hinting proposal: convert the wrapped branch, then re-wrap the Wax
     instruction it left on the stack in [Hinted]. *)
  | Hinted (h, inner) -> (
      let* () = instruction ctx inner in
      fun stack ->
        match stack with
        | (arity, w, top) :: rem ->
            ((arity, w, with_loc (Hinted (h, top))) :: rem, ())
        | [] -> ([], ()))
  | Br_table (labels, lab) ->
      let input = label_arity ctx lab in
      let* args = Stack.grab (input + 1) in
      Stack.push_poly
        (with_loc
           (Br_table
              (List.map (fun i -> label ctx i) (labels @ [ lab ]), sequence args)))
  | Br_on_null i ->
      let input = label_arity ctx i in
      let* args = Stack.grab (input + 1) in
      Stack.push (input + 1)
        (with_loc (Br_on_null (label ctx i, sequence args)))
  | Br_on_non_null i ->
      let input = label_arity ctx i in
      let* args = Stack.grab input in
      Stack.push (input - 1)
        (with_loc (Br_on_non_null (label ctx i, sequence args)))
  | Br_on_cast (i, _, t) ->
      let input = label_arity ctx i in
      let* args = Stack.grab input in
      Stack.push input
        (with_loc (Br_on_cast (label ctx i, reftype ctx t, sequence args)))
  | Br_on_cast_fail (i, _, t) ->
      let input = label_arity ctx i in
      let* args = Stack.grab input in
      Stack.push input
        (with_loc (Br_on_cast_fail (label ctx i, reftype ctx t, sequence args)))
  | Br_on_cast_desc_eq (i, _, t) ->
      (* The descriptor operand is on top of the branch operands. The target type
         and its exactness are recovered from the descriptor, so only the result
         nullability of [t] is kept. *)
      let input = label_arity ctx i in
      let* d = Stack.pop_width_preserved in
      let d = pin_descriptor_reftype ctx t d in
      let* args = Stack.grab input in
      Stack.push input
        (with_loc
           (Br_on_cast_desc_eq (label ctx i, t.nullable, sequence args, d)))
  | Br_on_cast_desc_eq_fail (i, _, t) ->
      let input = label_arity ctx i in
      let* d = Stack.pop_width_preserved in
      let d = pin_descriptor_reftype ctx t d in
      let* args = Stack.grab input in
      Stack.push input
        (with_loc
           (Br_on_cast_desc_eq_fail (label ctx i, t.nullable, sequence args, d)))
  | Folded (i, l) ->
      let* () = instructions ctx l in
      instruction ctx i
  | LocalGet x -> Stack.push 1 (with_loc (Get (idx ctx `Local x)))
  | GlobalGet x -> Stack.push 1 (with_loc (Get (idx ctx `Global x)))
  | LocalSet x ->
      let* e = Stack.pop_width_preserved in
      Stack.push 0 (with_loc (set_desc (idx ctx `Local x) e))
  | GlobalSet x ->
      let* e = Stack.pop_width_preserved in
      Stack.push 0 (with_loc (set_desc (idx ctx `Global x) e))
  | LocalTee x ->
      let* e = Stack.pop_width_preserved in
      Stack.push 1 (with_loc (Tee (idx ctx `Local x, e)))
  | BinOp (I32 op) -> int_bin_op i `I32 op
  | BinOp (I64 op) -> int_bin_op i `I64 op
  | BinOp (F32 op) -> float_bin_op i `F32 op
  | BinOp (F64 op) -> float_bin_op i `F64 op
  | Add128 | Sub128 | MulWide _ ->
      (* Wide arithmetic decompiles to the [i64::...] path intrinsics, whose two
         i64 results are consumed by a multi-value [let]. *)
      let name, input =
        match i.desc with
        | Add128 -> ("add128", 4)
        | Sub128 -> ("sub128", 4)
        | MulWide Signed -> ("mul_wide_s", 2)
        | MulWide Unsigned -> ("mul_wide_u", 2)
        | _ -> assert false
      in
      let* args = Stack.grab input in
      Stack.push 2 (path_call "i64" name args)
  | UnOp (I64 op) -> int_un_op i `I64 op
  | UnOp (I32 op) -> int_un_op i `I32 op
  | UnOp (F64 op) -> float_un_op i `F64 op
  | UnOp (F32 op) -> float_un_op i `F32 op
  | StructNew i ->
      let type_name = idx ctx `Type i in
      let fields = snd (struct_fields ctx type_name) in
      let* args = Stack.grab (List.length fields) in
      Stack.push 1
        (with_loc
           (Struct (Some (idx ctx `Type i), List.map2 struct_field fields args)))
  | StructNewDefault i ->
      Stack.push 1 (with_loc (StructDefault (Some (idx ctx `Type i))))
  | StructNewDesc i ->
      let type_name = idx ctx `Type i in
      let fields = snd (struct_fields ctx type_name) in
      (* The descriptor operand is on top of the field values. The struct type is
         recovered from the descriptor, so it is not written. *)
      let* d = Stack.pop_width_preserved in
      let d = pin_descriptor ctx ~exact:true i d in
      let* args = Stack.grab (List.length fields) in
      Stack.push 1
        (with_loc (StructDesc (d, List.map2 struct_field fields args)))
  | StructNewDefaultDesc i ->
      let* d = Stack.pop_width_preserved in
      let d = pin_descriptor ctx ~exact:true i d in
      Stack.push 1 (with_loc (StructDefaultDesc d))
  | StructGet (s, t, f) ->
      let type_name = idx ctx `Type t in
      let name = Sequence.get (fst (struct_fields ctx type_name)) f in
      let* arg = Stack.pop_width_preserved in
      let arg =
        {
          arg with
          desc =
            Ast.Cast
              (arg, Valtype (Ref { nullable = true; typ = Type type_name }));
        }
      in
      let e = with_loc (StructGet (arg, name)) in
      Stack.push 1
        (match s with
        | None -> e
        | Some signage ->
            with_loc
              (Cast (e, Signedtype { typ = `I32; signage; strict = false })))
  | StructSet (t, f) ->
      let type_name = idx ctx `Type t in
      let name = Sequence.get (fst (struct_fields ctx type_name)) f in
      let* e2 = Stack.pop_width_preserved in
      let* e1 = Stack.pop_width_preserved in
      let e1 =
        {
          e1 with
          desc =
            Ast.Cast
              (e1, Valtype (Ref { nullable = true; typ = Type type_name }));
        }
      in
      Stack.push 0 (with_loc (StructSet (e1, name, e2)))
  | ArrayNew t ->
      let* len = Stack.pop_width_preserved in
      let* v = Stack.pop_width_preserved in
      Stack.push 1 (with_loc (Array (Some (idx ctx `Type t), v, len)))
  | ArrayNewDefault t ->
      let* len = Stack.pop_width_preserved in
      Stack.push 1 (with_loc (ArrayDefault (Some (idx ctx `Type t), len)))
  | ArrayNewFixed (t, n) ->
      (* [n] is a u32 immediate and each element becomes an argument node, so a
         faithful decompilation of a huge [n] is inherently that large (the
         operands not on the stack are filled with holes). No validation runs
         on this path, so an adversarial [n] (e.g. 2^31) makes conversion slow /
         memory-hungry. Left unguarded by design: capping [n] would silently
         mis-convert valid dead code that legitimately needs holes, and any real
         module's count is small. Validation itself is O(operands present) --
         see [pop_repeat] in validation.ml. *)
      let* args = Stack.grab (Uint32.to_int n) in
      (* A string only builds an [i8] (raw bytes) or [i16] (UTF-16) array, so
         only those decode back to a string literal; any other element type
         stays an array literal. *)
      let str =
        match (lookup_type ctx Type t).typ with
        | Array { typ = Packed I8; _ } -> string_args n args
        | Array { typ = Packed I16; _ } -> wide_string_args n args
        | _ -> None
      in
      Stack.push 1
        (match str with
        | Some s -> with_loc (String (Some (idx ctx `Type t), s))
        | None -> with_loc (ArrayFixed (Some (idx ctx `Type t), args)))
  | ArrayGet (s, t) ->
      let* e2 = Stack.pop_width_preserved in
      let* e1 = Stack.pop_width_preserved in
      let e1 =
        {
          e1 with
          desc =
            Ast.Cast
              ( e1,
                Valtype (Ref { nullable = true; typ = Type (idx ctx `Type t) })
              );
        }
      in
      let e = with_loc (ArrayGet (e1, e2)) in
      Stack.push 1
        (match s with
        | None -> e
        | Some signage ->
            with_loc
              (Cast (e, Signedtype { typ = `I32; signage; strict = false })))
  | ArraySet t ->
      let* e3 = Stack.pop_width_preserved in
      let* e2 = Stack.pop_width_preserved in
      let* e1 = Stack.pop_width_preserved in
      let e1 =
        {
          e1 with
          desc =
            Ast.Cast
              ( e1,
                Valtype (Ref { nullable = true; typ = Type (idx ctx `Type t) })
              );
        }
      in
      Stack.push 0 (with_loc (ArraySet (e1, e2, e3)))
  | Call f ->
      let input, output = function_arity ctx f in
      let* args = Stack.grab input in
      Stack.push output
        (with_loc (Call (with_loc (Get (idx ctx `Func f)), args)))
  | CallRef t ->
      let input, output = type_arity ctx t in
      let* f = Stack.pop_width_preserved in
      let f =
        {
          f with
          desc =
            Ast.Cast
              ( f,
                Valtype (Ref { nullable = true; typ = Type (idx ctx `Type t) })
              );
        }
      in
      let* args = Stack.grab input in
      Stack.push output (with_loc (Call (f, args)))
  | ReturnCall f ->
      let input, _ = function_arity ctx f in
      let* args = Stack.grab input in
      Stack.push_poly
        (with_loc (TailCall (with_loc (Get (idx ctx `Func f)), args)))
  | ReturnCallRef t ->
      let input, _ = type_arity ctx t in
      let* f = Stack.pop_width_preserved in
      let f =
        {
          f with
          desc =
            Ast.Cast
              ( f,
                Valtype (Ref { nullable = true; typ = Type (idx ctx `Type t) })
              );
        }
      in
      let* args = Stack.grab input in
      Stack.push_poly (with_loc (TailCall (f, args)))
  | Return ->
      let* args = Stack.grab ctx.return_arity in
      Stack.push_poly (with_loc (Return (sequence_opt args)))
  | Const c ->
      let lit, ty, width =
        match c with
        | I32 n -> (integer i n, Ast.I32, `I32)
        | I64 n -> (integer i n, Ast.I64, `I64)
        | F32 f -> (float i f, Ast.F32, `F32)
        | F64 f -> (float i f, Ast.F64, `F64)
      in
      Stack.push_num (Some width)
        (if ctx.strict_constants then with_loc (Cast (lit, Valtype ty)) else lit)
  | RefI31 ->
      let* e = Stack.pop_width_preserved in
      Stack.push 1
        (with_loc (Cast (e, Valtype (Ref { nullable = false; typ = I31 }))))
  | I31Get signage ->
      let* e = Stack.pop_width_preserved in
      Stack.push 1
        (with_loc
           (Cast (e, Signedtype { typ = `I32; signage; strict = false })))
  | I64ExtendI32 signage ->
      let* e = Stack.pop_width_preserved in
      Stack.push 1
        (with_loc
           (Cast (e, Signedtype { typ = `I64; signage; strict = false })))
  | I32WrapI64 ->
      (* Width eraser: [i32.wrap_i64 (4096 >>u 40)] is 0, but a bare [4096 >>u 40]
         re-defaults to i32 and the shift count masks to 8, yielding 16 (a LIVE
         miscompilation). Pin the i64 operand. *)
      let* e = Stack.pop_width_erased in
      Stack.push 1 (with_loc (Cast (e, Valtype I32)))
  | F64PromoteF32 ->
      (* Width eraser: the f32 source is not carried by [e as f64]; a bare float
         literal re-defaults to f64, dropping the promote (and its f32 rounding). *)
      let* e = Stack.pop_width_erased in
      Stack.push 1 (with_loc (Cast (e, Valtype F64)))
  | F32DemoteF64 ->
      (* Width eraser: an integer-valued f64 source prints as a bare integer that
         re-defaults to i32, turning the demote into an i32->f32 convert. *)
      let* e = Stack.pop_width_erased in
      Stack.push 1 (with_loc (Cast (e, Valtype F32)))
  | ExternConvertAny ->
      let* e = Stack.pop_width_preserved in
      Stack.push 1
        (with_loc (Cast (e, Valtype (Ref { nullable = true; typ = Extern }))))
  | AnyConvertExtern ->
      let* e = Stack.pop_width_preserved in
      Stack.push 1
        (with_loc (Cast (e, Valtype (Ref { nullable = true; typ = Any }))))
  | ArrayNewData (t, d) ->
      let* len = Stack.pop_width_preserved in
      let* off = Stack.pop_width_preserved in
      Stack.push 1
        (with_loc
           (ArraySegment (Some (idx ctx `Type t), idx ctx `Data d, off, len)))
  | ArrayNewElem (t, e) ->
      let* len = Stack.pop_width_preserved in
      let* off = Stack.pop_width_preserved in
      Stack.push 1
        (with_loc
           (ArraySegment (Some (idx ctx `Type t), idx ctx `Elem e, off, len)))
  | TableGet t ->
      let* index = Stack.pop_width_preserved in
      Stack.push 1
        (with_loc (ArrayGet (with_loc (Get (idx ctx `Table t)), index)))
  | TableSet t ->
      let* value = Stack.pop_width_preserved in
      let* index = Stack.pop_width_preserved in
      Stack.push 0
        (with_loc (ArraySet (with_loc (Get (idx ctx `Table t)), index, value)))
  (* call_indirect desugars to [(tab[i] as &$functype)(args)] (a call_ref);
     [to_wasm] re-fuses this back to call_indirect. *)
  | CallIndirect (tab, tu) ->
      let input, output = typeuse_arity ctx tu in
      let* index = Stack.pop_width_preserved in
      let* args = Stack.grab input in
      let f = indirect_callee ctx with_loc tab tu index in
      Stack.push output (with_loc (Call (f, args)))
  | ReturnCallIndirect (tab, tu) ->
      let input, _ = typeuse_arity ctx tu in
      let* index = Stack.pop_width_preserved in
      let* args = Stack.grab input in
      let f = indirect_callee ctx with_loc tab tu index in
      Stack.push_poly (with_loc (TailCall (f, args)))
  | ArrayLen ->
      let* e = Stack.pop_width_preserved in
      let e = cast_ref e Array in
      Stack.push 1
        (with_loc (Call (with_loc (StructGet (e, Ast.no_loc "length")), [])))
  | RefCast t ->
      let* e = Stack.pop_width_preserved in
      Stack.push 1 (with_loc (Cast (e, Valtype (Ref (reftype ctx t)))))
  | RefCastDescEq t ->
      (* The descriptor operand is on top of the value. The target type and its
         exactness are recovered from the descriptor, so only [t]'s result
         nullability is kept. *)
      let* d = Stack.pop_width_preserved in
      let d = pin_descriptor_reftype ctx t d in
      let* e = Stack.pop_width_preserved in
      Stack.push 1 (with_loc (CastDesc (e, t.nullable, d)))
  | RefGetDesc t ->
      let type_name = idx ctx `Type t in
      let* arg = Stack.pop_width_preserved in
      (* [ref.get_desc $t] requires its operand to be [<: (ref null (exact? $t))],
         so a concrete operand already carries a descriptor-bearing type and
         [e.descriptor] resolves directly — casting it to [&?$t] would only strip
         its exactness (the result's exactness mirrors the operand's). Cast only
         an operand with no descriptor of its own: a bottom reference (a hole in
         dead code, or a [ref.null none]-style null cast to a bottom heap type)
         or a bare null. *)
      (* A bottom operand fits the *exact* operand type, and [ref.get_desc]'s
         result is then exact (validation takes the most precise), so pin the
         exact descriptor type. Rewrite the target of an existing bottom cast
         ([ref.null none] → [null as &?none]) in place rather than wrapping it —
         a nested [(null as &?none) as &?!t] is folded back to the bottom by
         [simplify], undoing the pin. *)
      let exact_pin =
        Ast.Valtype (Ref { nullable = true; typ = Exact type_name })
      in
      let is_bottom (t : Ast.heaptype) =
        match t with
        | None_ | NoFunc | NoExtern | NoExn | NoCont -> true
        | _ -> false
      in
      let arg =
        match arg.Ast.desc with
        | Ast.Hole | Ast.Null -> { arg with desc = Ast.Cast (arg, exact_pin) }
        | Ast.Cast (inner, Valtype (Ref { typ; _ })) when is_bottom typ ->
            { arg with desc = Ast.Cast (inner, exact_pin) }
        | _ -> arg
      in
      Stack.push 1 (with_loc (GetDescriptor arg))
  | RefTest t ->
      let* e = Stack.pop_width_preserved in
      Stack.push 1 (with_loc (Test (e, reftype ctx t)))
  | RefEq ->
      let* e2 = Stack.pop_width_preserved in
      let* e1 = Stack.pop_width_preserved in
      Stack.push 1 (with_loc (BinOp (op_loc i Ast.Eq, e1, e2)))
  | RefFunc f -> Stack.push 1 (with_loc (Get (idx ctx `Func f)))
  | RefNull typ ->
      Stack.push 1
        (with_loc
           (Cast
              ( with_loc Null,
                Valtype (Ref { nullable = true; typ = heaptype ctx typ }) )))
  | RefIsNull ->
      let* e = Stack.pop_width_preserved in
      Stack.push 1 (with_loc (UnOp (op_loc i Ast.Not, e)))
  | Select tys ->
      (* The Wax [?:] carries no result type, but resolve the annotation (if
         any) so an out-of-range type reference is still caught. *)
      Option.iter
        (List.iter (fun t -> ignore (valtype ctx t : Ast.valtype)))
        tys;
      let* cond = Stack.pop_width_preserved in
      let* e2 = Stack.pop_width_preserved in
      let* e1 = Stack.pop_width_preserved in
      Stack.push 1 (with_loc (Select (cond, e1, e2)))
  | Throw t ->
      let input, _ = tag_arity ctx t in
      let* args = Stack.grab input in
      Stack.push_poly (with_loc (Throw (idx ctx `Tag t, sequence_opt args)))
  | ThrowRef ->
      let* e = Stack.pop_width_preserved in
      Stack.push_poly (with_loc (ThrowRef e))
  | ContNew ct ->
      let* f = Stack.pop_width_preserved in
      Stack.push 1 (with_loc (ContNew (idx ctx `Type ct, f)))
  | ContBind (src, dst) ->
      let sp, _ = cont_arity ctx src in
      let dp, _ = cont_arity ctx dst in
      let* args = Stack.grab (sp - dp + 1) in
      Stack.push 1
        (with_loc (ContBind (idx ctx `Type src, idx ctx `Type dst, args)))
  | Suspend t ->
      let input, output = tag_arity ctx t in
      let* args = Stack.grab input in
      Stack.push output (with_loc (Suspend (idx ctx `Tag t, args)))
  | Resume (ct, handlers) ->
      let input, output = cont_arity ctx ct in
      let* args = Stack.grab (input + 1) in
      Stack.push output
        (with_loc
           (Resume (idx ctx `Type ct, List.map (on_clause ctx) handlers, args)))
  | ResumeThrow (ct, tag, handlers) ->
      let tinput, _ = tag_arity ctx tag in
      let _, output = cont_arity ctx ct in
      let* args = Stack.grab (tinput + 1) in
      Stack.push output
        (with_loc
           (ResumeThrow
              ( idx ctx `Type ct,
                idx ctx `Tag tag,
                List.map (on_clause ctx) handlers,
                args )))
  | ResumeThrowRef (ct, handlers) ->
      let _, output = cont_arity ctx ct in
      let* args = Stack.grab 2 in
      Stack.push output
        (with_loc
           (ResumeThrowRef
              (idx ctx `Type ct, List.map (on_clause ctx) handlers, args)))
  | Switch (ct, tag) ->
      let input, _ = cont_arity ctx ct in
      let output = switch_output ctx ct in
      let* args = Stack.grab input in
      Stack.push output
        (with_loc (Switch (idx ctx `Type ct, idx ctx `Tag tag, args)))
  | RefAsNonNull ->
      let* e = Stack.pop_width_preserved in
      Stack.push 1 (with_loc (NonNull e))
  | ArrayFill t ->
      let* n = Stack.pop_width_preserved in
      let* v = Stack.pop_width_preserved in
      let* i = Stack.pop_width_preserved in
      let* a = Stack.pop_width_preserved in
      let a = cast_ref a (Type (idx ctx `Type t)) in
      Stack.push 0
        (with_loc
           (Call (with_loc (StructGet (a, Ast.no_loc "fill")), [ i; v; n ])))
  | ArrayCopy (t1, t2) ->
      let* n = Stack.pop_width_preserved in
      let* i2 = Stack.pop_width_preserved in
      let* a2 = Stack.pop_width_preserved in
      let* i1 = Stack.pop_width_preserved in
      let* a1 = Stack.pop_width_preserved in
      let a1 = cast_ref a1 (Type (idx ctx `Type t1)) in
      let a2 = cast_ref a2 (Type (idx ctx `Type t2)) in
      Stack.push 0
        (with_loc
           (Call
              (with_loc (StructGet (a1, Ast.no_loc "copy")), [ i1; a2; i2; n ])))
  | Load (m, memarg, nt) ->
      let* addr = Stack.pop_width_preserved in
      let meth, nat =
        match nt with
        | NumI32 -> ("load32", 4)
        | NumI64 -> ("load64", 8)
        | NumF32 -> ("loadf32", 4)
        | NumF64 -> ("loadf64", 8)
      in
      Stack.push 1 (mem_call m meth (addr :: mem_extra with_loc memarg nat))
  | LoadS (m, memarg, result_ty, size, signage) ->
      let* addr = Stack.pop_width_preserved in
      let meth, nat =
        match size with
        | `I8 -> ("load8", 1)
        | `I16 -> ("load16", 2)
        | `I32 -> ("load32", 4)
      in
      let call = mem_call m meth (addr :: mem_extra with_loc memarg nat) in
      let cast typ e =
        with_loc (Ast.Cast (e, Signedtype { typ; signage; strict = false }))
      in
      let result =
        match (size, result_ty) with
        | _, `I32 -> cast `I32 call
        | `I32, `I64 -> cast `I64 call
        | (`I8 | `I16), `I64 -> cast `I64 (cast `I32 call)
      in
      Stack.push 1 result
  | Store (m, memarg, nt) ->
      let* value = Stack.pop_width_preserved in
      let* addr = Stack.pop_width_preserved in
      let meth, nat =
        match nt with
        | NumI32 -> ("store32", 4)
        | NumI64 -> ("store64", 8)
        | NumF32 -> ("storef32", 4)
        | NumF64 -> ("storef64", 8)
      in
      Stack.push 0
        (mem_call m meth (addr :: value :: mem_extra with_loc memarg nat))
  | StoreS (m, memarg, _result_ty, size) ->
      let* value = Stack.pop_width_preserved in
      let* addr = Stack.pop_width_preserved in
      let meth, nat =
        match size with
        | `I8 -> ("store8", 1)
        | `I16 -> ("store16", 2)
        | `I32 -> ("store32", 4)
      in
      Stack.push 0
        (mem_call m meth (addr :: value :: mem_extra with_loc memarg nat))
  | Atomic (m, op, memarg) ->
      let operands, results = Atomics.signature op in
      let* ops = Stack.grab (List.length operands) in
      let* addr = Stack.pop_width_preserved in
      let nat = 1 lsl Atomics.natural_align_log2 op in
      Stack.push (List.length results)
        (mem_call m (Atomics.method_name op)
           ((addr :: ops) @ mem_extra with_loc memarg nat))
  | AtomicFence -> Stack.push 0 (path_call "atomic" "fence" [])
  | Char c -> Stack.push 1 (with_loc (Char c))
  | String (t, s) ->
      let s = Wax_utils.Ast.concat_desc s in
      Stack.push 1 (with_loc (String (Option.map (idx ctx `Type) t, s)))
  | If_annotation { cond; then_body; else_body } ->
      let then_body =
        {
          then_body with
          Ast.desc =
            with_cond ctx ~location:i.info cond true (fun () ->
                Stack.run (instructions ctx then_body.desc));
        }
      in
      let else_body =
        Option.map
          (fun b ->
            {
              b with
              Ast.desc =
                with_cond ctx ~location:i.info cond false (fun () ->
                    Stack.run (instructions ctx b.Ast.desc));
            })
          else_body
      in
      Stack.push 0 (with_loc (If_annotation { cond; then_body; else_body }))
  | MemorySize m -> Stack.push 1 (mem_call m "size" [])
  | MemoryGrow m ->
      let* d = Stack.pop_width_preserved in
      Stack.push 1 (mem_call m "grow" [ d ])
  | MemoryFill m ->
      let* n = Stack.pop_width_preserved in
      let* v = Stack.pop_width_preserved in
      let* d = Stack.pop_width_preserved in
      Stack.push 0 (mem_call m "fill" [ d; v; n ])
  | MemoryCopy (m, m') ->
      let* n = Stack.pop_width_preserved in
      let* s = Stack.pop_width_preserved in
      let* d = Stack.pop_width_preserved in
      (* A copy between two different memories names the source explicitly. *)
      let args =
        if (idx ctx `Mem m).desc = (idx ctx `Mem m').desc then [ d; s; n ]
        else with_loc (Ast.Get (idx ctx `Mem m')) :: [ d; s; n ]
      in
      Stack.push 0 (mem_call m "copy" args)
  | MemoryInit (m, data) ->
      let* n = Stack.pop_width_preserved in
      let* s = Stack.pop_width_preserved in
      let* d = Stack.pop_width_preserved in
      let seg = with_loc (Ast.Get (idx ctx `Data data)) in
      Stack.push 0 (mem_call m "init" [ seg; d; s; n ])
  | DataDrop data -> Stack.push 0 (drop_call `Data data)
  | TableSize t -> Stack.push 1 (table_call t "size" [])
  | TableGrow t ->
      let* n = Stack.pop_width_preserved in
      let* v = Stack.pop_width_preserved in
      Stack.push 1 (table_call t "grow" [ v; n ])
  | TableFill t ->
      let* n = Stack.pop_width_preserved in
      let* v = Stack.pop_width_preserved in
      let* d = Stack.pop_width_preserved in
      Stack.push 0 (table_call t "fill" [ d; v; n ])
  | TableCopy (t, t') ->
      let* n = Stack.pop_width_preserved in
      let* s = Stack.pop_width_preserved in
      let* d = Stack.pop_width_preserved in
      let args =
        if (idx ctx `Table t).desc = (idx ctx `Table t').desc then [ d; s; n ]
        else with_loc (Ast.Get (idx ctx `Table t')) :: [ d; s; n ]
      in
      Stack.push 0 (table_call t "copy" args)
  | TableInit (t, elem) ->
      let* n = Stack.pop_width_preserved in
      let* s = Stack.pop_width_preserved in
      let* d = Stack.pop_width_preserved in
      let seg = with_loc (Ast.Get (idx ctx `Elem elem)) in
      Stack.push 0 (table_call t "init" [ seg; d; s; n ])
  | ElemDrop elem -> Stack.push 0 (drop_call `Elem elem)
  | ArrayInitData (t, data) ->
      let* n = Stack.pop_width_preserved in
      let* s = Stack.pop_width_preserved in
      let* d = Stack.pop_width_preserved in
      let* a = Stack.pop_width_preserved in
      let a = cast_ref a (Type (idx ctx `Type t)) in
      let seg = with_loc (Ast.Get (idx ctx `Data data)) in
      Stack.push 0
        (with_loc
           (Call (with_loc (StructGet (a, Ast.no_loc "init")), [ seg; d; s; n ])))
  | ArrayInitElem (t, elem) ->
      let* n = Stack.pop_width_preserved in
      let* s = Stack.pop_width_preserved in
      let* d = Stack.pop_width_preserved in
      let* a = Stack.pop_width_preserved in
      let a = cast_ref a (Type (idx ctx `Type t)) in
      let seg = with_loc (Ast.Get (idx ctx `Elem elem)) in
      Stack.push 0
        (with_loc
           (Call (with_loc (StructGet (a, Ast.no_loc "init")), [ seg; d; s; n ])))
  | VecUnOp op ->
      let* v = Stack.pop_width_preserved in
      Stack.push 1 (meth_call v (Simd.unop_name op) [])
  | VecBinOp op ->
      let* e2 = Stack.pop_width_preserved in
      let* e1 = Stack.pop_width_preserved in
      Stack.push 1 (meth_call e1 (Simd.binop_name op) [ e2 ])
  | VecTernOp op ->
      let* e3 = Stack.pop_width_preserved in
      let* e2 = Stack.pop_width_preserved in
      let* e1 = Stack.pop_width_preserved in
      Stack.push 1 (meth_call e1 (Simd.ternop_name op) [ e2; e3 ])
  | VecShift op ->
      let* count = Stack.pop_width_preserved in
      let* v = Stack.pop_width_preserved in
      Stack.push 1 (meth_call v (Simd.shift_name op) [ count ])
  | VecTest op ->
      let* v = Stack.pop_width_preserved in
      Stack.push 1 (meth_call v (Simd.test_name op) [])
  | VecBitmask op ->
      let* v = Stack.pop_width_preserved in
      Stack.push 1 (meth_call v (Simd.bitmask_name op) [])
  | VecSplat s ->
      let* x = Stack.pop_width_preserved in
      Stack.push 1 (meth_call x (Simd.splat_name s) [])
  | VecBitselect ->
      let* e3 = Stack.pop_width_preserved in
      let* e2 = Stack.pop_width_preserved in
      let* e1 = Stack.pop_width_preserved in
      Stack.push 1
        (path_call Simd.free_namespace
           (Simd.free_member Simd.bitselect_name)
           [ e1; e2; e3 ])
  | VecExtract (s, sign, lane) ->
      let* v = Stack.pop_width_preserved in
      Stack.push 1
        (meth_call v (Simd.extract_name s sign)
           [ integer i (Int.to_string lane) ])
  | VecReplace (s, lane) ->
      let* value = Stack.pop_width_preserved in
      let* v = Stack.pop_width_preserved in
      Stack.push 1
        (meth_call v (Simd.replace_name s)
           [ integer i (Int.to_string lane); value ])
  | VecShuffle lanes ->
      let* e2 = Stack.pop_width_preserved in
      let* e1 = Stack.pop_width_preserved in
      let imms =
        List.init 16 (fun k -> integer i (Int.to_string (Char.code lanes.[k])))
      in
      Stack.push 1 (meth_call e1 Simd.shuffle_name (imms @ [ e2 ]))
  | VecConst v ->
      let lit =
        match v.Wax_utils.V128.shape with
        | F32x4 | F64x2 -> float i
        | I8x16 | I16x8 | I32x4 | I64x2 -> integer i
      in
      Stack.push 1
        (path_call Simd.free_namespace
           (Simd.free_member (Simd.const_name v.shape))
           (List.map lit v.components))
  | VecLoad (m, op, memarg) ->
      let* addr = Stack.pop_width_preserved in
      let nat = Simd.vec_load_nat_align op in
      Stack.push 1
        (mem_call m (Simd.vec_load_name op)
           (addr :: mem_extra with_loc memarg nat))
  | VecStore (m, memarg) ->
      let* value = Stack.pop_width_preserved in
      let* addr = Stack.pop_width_preserved in
      Stack.push 0
        (mem_call m Simd.store_name
           (addr :: value :: mem_extra with_loc memarg 16))
  | VecLoadSplat (m, w, memarg) ->
      let* addr = Stack.pop_width_preserved in
      let nat = Simd.lane_nat_align w in
      Stack.push 1
        (mem_call m (Simd.load_splat_name w)
           (addr :: mem_extra with_loc memarg nat))
  | VecLoadLane (m, w, memarg, lane) ->
      let* v = Stack.pop_width_preserved in
      let* addr = Stack.pop_width_preserved in
      let nat = Simd.lane_nat_align w in
      Stack.push 1
        (mem_call m (Simd.load_lane_name w)
           (addr :: v
           :: integer i (Int.to_string lane)
           :: mem_extra with_loc memarg nat))
  | VecStoreLane (m, w, memarg, lane) ->
      let* v = Stack.pop_width_preserved in
      let* addr = Stack.pop_width_preserved in
      let nat = Simd.lane_nat_align w in
      Stack.push 0
        (mem_call m (Simd.store_lane_name w)
           (addr :: v
           :: integer i (Int.to_string lane)
           :: mem_extra with_loc memarg nat))

and instructions ctx l =
  match l with
  | [] -> return ()
  | i :: rem ->
      let* () = instruction ctx i in
      instructions ctx rem

(*** Module-field conversion ***)

let bind_locals st l =
  List.map
    (fun e ->
      let _, t = e.Ast.desc in
      Ast.no_loc
        (Ast.Let
           ( [ (Some (Sequence.get_current st.locals), Some (valtype st t)) ],
             None )))
    l

let typeuse ctx ((typ, sign) : Src.typeuse) =
  let signature ({ params; results } : Src.functype) : Ast.functype =
    {
      params = functype_params ctx params;
      results = Array.map (fun t -> valtype ctx t) results;
    }
  in
  match Option.bind typ (implicit_functype ctx) with
  | Some ft ->
      (* The reference points at an anonymous implicit type; there is no named
         type to refer to, so render it inline. *)
      (None, Some (signature (match sign with Some s -> s | None -> ft)))
  | None ->
      (Option.map (fun i -> idx ctx `Type i) typ, Option.map signature sign)

let string_of_name (nm : Src.name) =
  { nm with desc = Ast.String (None, nm.desc) }

(* Reserve, in a function's fresh local namespace, the Wax names of the
   module-level entities its body references by a bare identifier: globals (via
   [global.get]/[global.set]), functions (via [call]/[return_call]/[ref.func]),
   the memories/tables a memory/table access names as its receiver
   ([mem.load(..)], [tab[..]], [tab.size()], …), and the data/element segments
   named by [seg.drop()] / [mem.init] / [tab.init] / array segment ops. Without
   this an auto-named local could be assigned a colliding name and shadow the
   reference, since Wax resolves a bare name to a local before anything else. *)
let rec reserve_module_names_in_instr ctx ns (i : _ Src.instr) =
  match i.desc with
  | Block { block; _ } | Loop { block; _ } | TryTable { block; _ } ->
      reserve_module_names_in_instrs ctx ns block.desc
  | If { if_block; else_block; _ } ->
      reserve_module_names_in_instrs ctx ns if_block.desc;
      reserve_module_names_in_instrs ctx ns else_block.desc
  | Try { block; catches; catch_all; _ } ->
      reserve_module_names_in_instrs ctx ns block.desc;
      List.iter
        (fun (_, block) -> reserve_module_names_in_instrs ctx ns block.Ast.desc)
        catches;
      Option.iter
        (fun block -> reserve_module_names_in_instrs ctx ns block.Ast.desc)
        catch_all
  | Folded (i, l) ->
      reserve_module_names_in_instrs ctx ns l;
      reserve_module_names_in_instr ctx ns i
  | Hinted (_, i) -> reserve_module_names_in_instr ctx ns i
  | GlobalGet x | GlobalSet x -> Namespace.reserve ns (idx ctx `Global x).desc
  | Call f | ReturnCall f | RefFunc f ->
      Namespace.reserve ns (idx ctx `Func f).desc
  | Load (m, _, _)
  | LoadS (m, _, _, _, _)
  | Store (m, _, _)
  | StoreS (m, _, _, _)
  | MemorySize m
  | MemoryGrow m
  | MemoryFill m
  | VecLoad (m, _, _)
  | VecStore (m, _)
  | VecLoadSplat (m, _, _)
  | VecLoadLane (m, _, _, _)
  | VecStoreLane (m, _, _, _) ->
      Namespace.reserve ns (idx ctx `Mem m).desc
  | MemoryCopy (m, m') ->
      Namespace.reserve ns (idx ctx `Mem m).desc;
      Namespace.reserve ns (idx ctx `Mem m').desc
  | MemoryInit (m, d) ->
      Namespace.reserve ns (idx ctx `Mem m).desc;
      Namespace.reserve ns (idx ctx `Data d).desc
  | TableGet t
  | TableSet t
  | TableSize t
  | TableGrow t
  | TableFill t
  | CallIndirect (t, _)
  | ReturnCallIndirect (t, _) ->
      Namespace.reserve ns (idx ctx `Table t).desc
  | TableCopy (t, t') ->
      Namespace.reserve ns (idx ctx `Table t).desc;
      Namespace.reserve ns (idx ctx `Table t').desc
  | TableInit (t, e) ->
      Namespace.reserve ns (idx ctx `Table t).desc;
      Namespace.reserve ns (idx ctx `Elem e).desc
  | DataDrop d | ArrayNewData (_, d) | ArrayInitData (_, d) ->
      Namespace.reserve ns (idx ctx `Data d).desc
  | ElemDrop e | ArrayNewElem (_, e) | ArrayInitElem (_, e) ->
      Namespace.reserve ns (idx ctx `Elem e).desc
  | _ -> ()

and reserve_module_names_in_instrs ctx ns l =
  List.iter (reserve_module_names_in_instr ctx ns) l

(* Collect the Wax names of element segments referenced by table.init /
   elem.drop / array.new_elem / array.init_elem, so a declarative segment used
   this way is emitted explicitly rather than dropped. *)
let rec collect_elem_refs ctx acc (i : _ Src.instr) =
  match i.desc with
  | Block { block; _ } | Loop { block; _ } | TryTable { block; _ } ->
      collect_elem_refs_instrs ctx acc block.desc
  | If { if_block; else_block; _ } ->
      collect_elem_refs_instrs ctx acc if_block.desc;
      collect_elem_refs_instrs ctx acc else_block.desc
  | Try { block; catches; catch_all; _ } ->
      collect_elem_refs_instrs ctx acc block.desc;
      List.iter
        (fun (_, b) -> collect_elem_refs_instrs ctx acc b.Ast.desc)
        catches;
      Option.iter
        (fun b -> collect_elem_refs_instrs ctx acc b.Ast.desc)
        catch_all
  | Folded (i, l) ->
      collect_elem_refs_instrs ctx acc l;
      collect_elem_refs ctx acc i
  | Hinted (_, i) -> collect_elem_refs ctx acc i
  | TableInit (_, e) | ElemDrop e | ArrayNewElem (_, e) | ArrayInitElem (_, e)
    -> (
      try Hashtbl.replace acc (idx ctx `Elem e).desc () with _ -> ())
  | _ -> ()

and collect_elem_refs_instrs ctx acc l = List.iter (collect_elem_refs ctx acc) l

(* Collect the wasm indices of locals referenced by a function body. A parameter
   that is both unnamed in the source and absent here needs no Wax name: it can
   be rendered anonymously instead of inventing one. Only numeric references
   matter, since an unnamed parameter has no [$id] to be referenced by. *)
let rec collect_local_refs acc (i : _ Src.instr) =
  match i.desc with
  | Block { block; _ } | Loop { block; _ } | TryTable { block; _ } ->
      collect_local_refs_instrs acc block.desc
  | If { if_block; else_block; _ } ->
      collect_local_refs_instrs acc if_block.desc;
      collect_local_refs_instrs acc else_block.desc
  | Try { block; catches; catch_all; _ } ->
      collect_local_refs_instrs acc block.desc;
      List.iter (fun (_, b) -> collect_local_refs_instrs acc b.Ast.desc) catches;
      Option.iter (fun b -> collect_local_refs_instrs acc b.Ast.desc) catch_all
  | Folded (i, l) ->
      collect_local_refs_instrs acc l;
      collect_local_refs acc i
  | Hinted (_, i) -> collect_local_refs acc i
  | LocalGet x | LocalSet x | LocalTee x -> (
      match x.Ast.desc with Num n -> Hashtbl.replace acc n () | Id _ -> ())
  | _ -> ()

and collect_local_refs_instrs acc l = List.iter (collect_local_refs acc) l

(* The guard printed on a folded attribute (an [export]/[start] moved onto a
   definition) is its branch condition with the conjuncts already entailed by
   the target's own position ([ctx.cond_asm]) dropped: the target is emitted
   inside those enclosing conditionals, so repeating them would be redundant
   (and, worse, would re-accumulate on every round-trip). [location] anchors the
   condition, which has no source of its own in the binary. *)
let simplify_guard ctx ~location (syn : Wax_wasm.Ast.cond) :
    (Wax_wasm.Ast.cond, Ast.location) Ast.annotated =
  let rec conjuncts (c : Wax_wasm.Ast.cond) =
    match c with Cond_and l -> List.concat_map conjuncts l | c -> [ c ]
  in
  let kept =
    List.filter
      (fun c ->
        not
          (Cond.logical_implies ctx.cond_asm
             (Cond.of_cond ctx.cond_env ctx.cond_diag ~location c)))
      (conjuncts syn)
  in
  {
    Ast.desc = (match kept with [] -> syn | [ c ] -> c | l -> Cond_and l);
    info = location;
  }

(* Fold the branch conditions [entries] of some attribute that a [(…)] field
   attaches to a definition (an export, a start) into attribute guards on a
   target at [ctx.cond_asm]: drop the attribute where its branch is unreachable,
   keep it plain where the target's position already entails the branch, and
   otherwise guard it with the branch condition simplified against the position.
   [make guard nm] builds the attribute for one entry, [guard] being [None] for
   a plain attribute. *)
let folded_attrs ctx ~location entries make =
  List.filter_map
    (fun (c, syn, nm) ->
      if not (Cond.is_satisfiable (Cond.and_ ctx.cond_asm c)) then None
      else if Cond.logical_implies ctx.cond_asm c then Some (make None nm)
      else Some (make (Some (simplify_guard ctx ~location syn)) nm))
    entries

let exports ctx kind name e =
  (* Reuse the bare [#[export]] short form when the export name matches the
     field's own Wax name; only a differing name needs to be spelled out.
     [guard] makes just this export conditional. *)
  let attr guard nm =
    let value =
      if nm.Ast.desc = name.Ast.desc then None else Some (string_of_name nm)
    in
    ("export", value, guard)
  in
  (* [e] are the inline exports declared on this field (already in the right
     branch), so they inherit the field's reachability unconditionally. *)
  let inline = List.map (fun nm -> attr None nm) e in
  (* The table holds standalone exports; each is kept only when its branch is
     reachable here, plain or guarded per [folded_attrs]. *)
  let standalone =
    match Hashtbl.find_opt ctx.exports (kind, name.Ast.desc) with
    | None -> []
    | Some entries -> folded_attrs ctx ~location:name.Ast.info entries attr
  in
  (* When a field carries several exports, put the unnamed [#[export]] (the one
     reusing the field's own Wax name) first; [partition] is stable, so the rest
     keep their order. *)
  let unnamed, named =
    List.partition (fun (_, v, _) -> Option.is_none v) (inline @ standalone)
  in
  unnamed @ named

(* The [#[start]] attribute(s) on function [name]: a [(start …)] whose branch is
   reachable here, plain or guarded like a standalone export. *)
let start_attribute ctx name =
  match Hashtbl.find_opt ctx.starts name.Ast.desc with
  | None -> []
  | Some entries ->
      folded_attrs ctx ~location:name.Ast.info
        (List.map (fun (c, syn) -> (c, syn, ())) entries)
        (fun guard () -> ("start", None, guard))

let single_expression ctx ~location l =
  match l with
  | [ e ] -> e
  | _ ->
      conversion_error ctx ~location (fun f () ->
          Format.fprintf f "A constant expression must produce a single value.")

let rec modulefield ctx export_tbl (f : (_ Src.modulefield, _) Ast.annotated) =
  (* Sibling fields synthesised alongside [f] (e.g. an element segment for an
     inline table initializer), emitted right after it. *)
  let extra = ref [] in
  let desc : _ Ast.modulefield option =
    match f.desc with
    | Types t -> Some (Type (collapse_splices ctx (rectype ctx t)))
    | Func { locals; instrs; typ; exports = e; _ } ->
        let label, labels =
          LabelStack.push ~targeted:(label_targeted instrs) (LabelStack.make ())
            None
        in
        let ctx =
          let return_arity = snd (typeuse_arity ctx typ) in
          let local_namespace =
            let ns = Namespace.make () in
            reserve_module_names_in_instrs ctx ns instrs;
            ns
          in
          {
            ctx with
            locals =
              Sequence.make ~diagnostics:ctx.diagnostics local_namespace "x";
            labels;
            label_arities = [ (None, return_arity) ];
            return_arity;
          }
        in
        let used_locals =
          let acc = Hashtbl.create 16 in
          collect_local_refs_instrs acc instrs;
          acc
        in
        (* Name a parameter, unless it is unnamed in the source and never
           referenced by the body, in which case it is rendered anonymously. Its
           index slot is still consumed so later locals stay correctly aligned.
           [i] is the parameter's position, i.e. its wasm local index. *)
        let convert_params ~claimed params =
          Array.mapi
            (fun i p ->
              let id, t = p.Ast.desc in
              let pat =
                if
                  Option.is_none id
                  && not (Hashtbl.mem used_locals (Uint32.of_int i))
                then (
                  Sequence.skip ctx.locals;
                  None)
                else
                  let name =
                    Sequence.register' ~claimed ctx.locals export_tbl None id []
                  in
                  Some
                    (match id with
                    | None ->
                        (* Unnamed in the source but referenced by the body, so
                           it cannot be rendered anonymously: warn that a name
                           was invented, pointing at the parameter. *)
                        Wax_utils.Diagnostic.report ctx.diagnostics
                          ~location:p.Ast.info ~severity:Warning
                          ~warning:Wax_utils.Warning.Generated_name
                          ~message:(fun fmt () ->
                            Format.fprintf fmt
                              "An unnamed parameter is used; generating the \
                               name '%s' for it."
                              name)
                          ();
                        Ast.no_loc name
                    | Some id -> { id with Ast.desc = name })
              in
              annotated p.Ast.info pat (valtype ctx t))
            params
        in
        let param_arr, result_arr =
          match typ with
          | _, Some { params; results } -> (params, results)
          | Some i, None -> (
              let functype =
                match implicit_functype ctx i with
                | Some ft -> Some ft
                | None -> (
                    match (lookup_type ctx Type i).typ with
                    | Func ft -> Some ft
                    | Struct _ | Array _ | Cont _ -> None)
              in
              match functype with
              | Some { params; results } -> (params, results)
              | None -> assert false)
          | None, None -> assert false (* Should not happen *)
        in
        (* Priority pass: claim every source name (params, then locals) before
           any unnamed entity is registered, so the generated default never
           displaces a real source name (a user local [$x] keeps [x], the
           unnamed one becomes [x_2], not the reverse). Renames are reported here
           once; [register']/[register] then take the claimed name as-is. *)
        let claimed = Hashtbl.create 16 in
        let claim id =
          match id with
          | Some nm
            when Lexer.is_valid_identifier nm.Ast.desc
                 && not (Hashtbl.mem claimed nm.Ast.desc) ->
              Hashtbl.replace claimed nm.Ast.desc
                (Sequence.claim_name ctx.locals ~loc:nm.Ast.info nm.Ast.desc)
          | _ -> ()
        in
        Array.iter (fun p -> claim (fst p.Ast.desc)) param_arr;
        List.iter (fun e -> claim (fst e.Ast.desc)) locals;
        let sign =
          let params = convert_params ~claimed param_arr in
          Sequence.consume_currents ctx.locals;
          {
            Ast.params;
            results = Array.map (fun t -> valtype ctx t) result_arr;
          }
        in
        (* An anonymous implicit type has no name to reference; the inline [sign]
           above already carries its signature, so drop the named reference. *)
        let typ =
          match fst typ with
          | Some i when Option.is_some (implicit_functype ctx i) -> None
          | t -> Option.map (fun i -> idx ctx `Type i) t
        in
        List.iter
          (fun e ->
            Sequence.register ~claimed ctx.locals export_tbl None
              (fst e.Ast.desc) [])
          locals;
        let locals = bind_locals ctx locals in
        let name = Sequence.get_current ctx.functions in
        Some
          (Func
             {
               name;
               typ;
               sign = Some sign;
               body = (label (), locals @ Stack.run (instructions ctx instrs));
               attributes = start_attribute ctx name @ exports ctx Func name e;
             })
    | Import { module_; name = nm; desc; exports = e; _ } -> (
        (* Build a single [import "module" <decl>;]. A name-only
           [#[import = "name"]] is emitted only when the imported name differs
           from the Wax name; consecutive same-module imports are grouped into
           blocks in a later pass. *)
        let build id kind export_kind =
          let attributes =
            (if nm.Ast.desc = id.Ast.desc then []
             else [ ("import", Some (string_of_name nm), None) ])
            @ exports ctx export_kind id e
          in
          Some
            (Ast.Import
               {
                 module_;
                 decl =
                   { Ast.desc = { Ast.id; kind; attributes }; info = f.info };
               })
        in
        match desc with
        | Func { exact; typ } ->
            let typ, sign = typeuse ctx typ in
            build
              (Sequence.get_current ctx.functions)
              (Import_func { typ; sign; exact })
              Func
        | Tag typ ->
            let typ, sign = typeuse ctx typ in
            build (Sequence.get_current ctx.tags) (Import_tag { typ; sign }) Tag
        | Global typ ->
            let typ' = globaltype ctx typ in
            build
              (Sequence.get_current ctx.globals)
              (Import_global { mut = typ'.mut; typ = typ'.typ })
              Global
        | Memory lim ->
            let l = lim.Ast.desc in
            build
              (Sequence.get_current ctx.memories)
              (Import_memory
                 {
                   address_type = l.address_type;
                   limits = Some (l.mi, l.ma);
                   page_size_log2 = l.page_size_log2;
                   shared = l.shared;
                 })
              Memory
        | Table tt ->
            let l = tt.Src.limits.Ast.desc in
            build
              (Sequence.get_current ctx.tables)
              (Import_table
                 {
                   address_type = l.address_type;
                   reftype = reftype ctx tt.Src.reftype;
                   limits = Some (l.mi, l.ma);
                 })
              Table)
    | Global { typ; init; exports = e; _ } ->
        let typ' = globaltype ctx typ in
        let name = Sequence.get_current ctx.globals in
        Some
          (Global
             {
               name;
               mut = typ'.mut;
               typ = Some typ'.typ;
               def =
                 single_expression ctx ~location:f.info
                   (Stack.run (instructions ctx init));
               attributes = exports ctx Global name e;
             })
    | Tag { typ; exports = e; _ } ->
        let typ, sign = typeuse ctx typ in
        let name = Sequence.get_current ctx.tags in
        Some (Tag { name; typ; sign; attributes = exports ctx Tag name e })
    | Memory { limits = lim; init; exports = e; _ } ->
        let l = lim.Ast.desc in
        let name = Sequence.get_current ctx.memories in
        let data =
          match init with
          | None -> []
          | Some bytes ->
              let s = Wax_utils.Ast.concat_desc bytes in
              [
                {
                  Ast.data_name = None;
                  offset = Ast.no_loc (Ast.Int "0");
                  init = s;
                };
              ]
        in
        Some
          (Memory
             {
               name;
               address_type = l.address_type;
               limits = Some (l.mi, l.ma);
               page_size_log2 = l.page_size_log2;
               shared = l.shared;
               data;
               attributes = exports ctx Memory name e;
             })
    | Data { init; mode; _ } ->
        let name = Sequence.get_current ctx.datas in
        let s = Wax_utils.Ast.concat_desc init in
        let mode' : _ Ast.datamode =
          match mode with
          | Passive -> Passive
          | Active (memidx, off) ->
              Active
                ( idx ctx `Mem memidx,
                  single_expression ctx ~location:f.info
                    (Stack.run (instructions ctx off)) )
        in
        Some
          (Data { name = Some name; mode = mode'; init = s; attributes = [] })
    | Table { typ = tt; init; exports = e; _ } ->
        let name = Sequence.get_current ctx.tables in
        let l = tt.Src.limits.Ast.desc in
        let init =
          match init with
          | Init_default -> None
          | Init_expr ex ->
              Some
                (single_expression ctx ~location:f.info
                   (Stack.run (instructions ctx ex)))
          | Init_segment segs ->
              (* A per-element initializer is not expressible on the table
                 itself; desugar it into a separate active element segment
                 filling the table from offset 0. *)
              let elem_init =
                List.map
                  (fun ex ->
                    single_expression ctx ~location:f.info
                      (Stack.run (instructions ctx ex)))
                  segs
              in
              let elem : _ Ast.modulefield =
                Elem
                  {
                    name = Sequence.fresh_name ctx.elems;
                    reftype = reftype ctx tt.Src.reftype;
                    mode = EActive (name, Ast.no_loc (Ast.Int "0"));
                    init = elem_init;
                    attributes = [];
                  }
              in
              extra := [ { f with desc = elem } ];
              None
        in
        Some
          (Table
             {
               name;
               address_type = l.address_type;
               reftype = reftype ctx tt.Src.reftype;
               limits = Some (l.mi, l.ma);
               init;
               attributes = exports ctx Table name e;
             })
    | Elem { typ; init; mode; _ } -> (
        (* Declare elems are regenerated by [to_wasm] from [call_ref] usage, so
           they are normally dropped. One referenced by table.init / elem.drop /
           array.*_elem still needs a binding: emit it as an empty passive
           segment, which is runtime-equivalent (a declarative segment is a
           dropped passive one — table.init traps, elem.drop is a no-op). *)
        match mode with
        | Declare ->
            let name = Sequence.get_current ctx.elems in
            if Hashtbl.mem ctx.referenced_elems name.Ast.desc then
              Some
                (Elem
                   {
                     name;
                     reftype = reftype ctx typ;
                     mode = EPassive;
                     init = [];
                     attributes = [];
                   })
            else None
        | Passive | Active _ ->
            let name = Sequence.get_current ctx.elems in
            let init =
              List.map
                (fun e ->
                  single_expression ctx ~location:f.info
                    (Stack.run (instructions ctx e)))
                init
            in
            let mode' : _ Ast.elemmode =
              match mode with
              | Passive -> EPassive
              | Active (tab, off) ->
                  EActive
                    ( idx ctx `Table tab,
                      single_expression ctx ~location:f.info
                        (Stack.run (instructions ctx off)) )
              | Declare -> assert false
            in
            Some
              (Elem
                 {
                   name;
                   reftype = reftype ctx typ;
                   mode = mode';
                   init;
                   attributes = [];
                 }))
    | Start _ | Export _ -> None
    | String_global { typ; init; _ } ->
        let name = Sequence.get_current ctx.globals in
        Some
          (Global
             {
               name;
               mut = false;
               typ = None;
               def =
                 {
                   f with
                   desc =
                     String
                       ( Option.map (idx ctx `Type) typ,
                         Wax_utils.Ast.concat_desc init );
                 };
               attributes = [];
             })
    | Module_if_annotation { cond; then_fields; else_fields } ->
        (* Convert [then] before [else]: positional naming via [get_current]
           must consume names in the same order [register_names] registered
           them (then-branch first). A record literal would leave the field
           evaluation order unspecified (OCaml evaluates right-to-left), which
           would consume the names swapped and scramble them across branches.
           [with_cond] sets the branch assumption so per-branch declarations
           (e.g. an import with a branch-dependent signature) resolve correctly
           in the branch's bodies. *)
        let then_fields =
          {
            then_fields with
            Ast.desc =
              with_cond ctx ~location:f.info cond true (fun () ->
                  List.concat_map (modulefield ctx export_tbl) then_fields.desc);
          }
        in
        let else_fields =
          Option.map
            (fun e ->
              {
                e with
                Ast.desc =
                  with_cond ctx ~location:f.info cond false (fun () ->
                      List.concat_map (modulefield ctx export_tbl) e.Ast.desc);
              })
            else_fields
        in
        (* An [@else] emptied by pulling out its standalone exports carries no
           fields, so drop it; a conditional left empty in both branches -- e.g.
           one that held only a standalone [(export …)] now re-emitted as a
           guard on its target -- is a no-op and is dropped entirely. *)
        let else_fields =
          match else_fields with Some e when e.Ast.desc = [] -> None | e -> e
        in
        if then_fields.Ast.desc = [] && else_fields = None then None
        else Some (Conditional { cond; then_fields; else_fields })
  in
  Option.to_list (Option.map (fun desc -> { f with desc }) desc) @ !extra

(*** Implicit type elaboration and name registration ***)

(* Structural equality on function types, ignoring parameter names and source
   locations. Used to replicate the WAT type-use abbreviation, where an inline
   signature reuses an identical existing type rather than minting a new one. *)
let rec valtype_eq (a : Src.valtype) (b : Src.valtype) =
  match (a, b) with
  | I32, I32 | I64, I64 | F32, F32 | F64, F64 | V128, V128 -> true
  | Ref x, Ref y -> x.nullable = y.nullable && heaptype_eq x.typ y.typ
  | (I32 | I64 | F32 | F64 | V128 | Ref _), _ -> false

and heaptype_eq (a : Src.heaptype) (b : Src.heaptype) =
  match (a, b) with
  | Type i, Type j -> (
      match (i.Ast.desc, j.Ast.desc) with
      | Num m, Num n -> Uint32.compare m n = 0
      | Id s, Id t -> String.equal s t
      | (Num _ | Id _), _ -> false)
  | _ -> a = b

let functype_eq (a : Src.functype) (b : Src.functype) =
  let valtypes a = List.map (fun p -> snd p.Ast.desc) (Array.to_list a) in
  Array.length a.params = Array.length b.params
  && Array.length a.results = Array.length b.results
  && List.for_all2 valtype_eq (valtypes a.params) (valtypes b.params)
  && List.for_all2 valtype_eq (Array.to_list a.results)
       (Array.to_list b.results)

let empty_functype : Src.functype = { params = [||]; results = [||] }

(* Populate [ctx.implicit_types] with the function types the WAT text format
   synthesises from inline [(param)]/[(result)] signatures. Explicit type
   definitions occupy the low indices in source order; each inline signature
   then reuses the lowest-indexed identical type, or appends a new one at the
   end of the index space. This mirrors the spec's elaboration so that a numeric
   [(type N)] referring to such a type resolves to the right signature.

   Only called for modules without conditional annotations (where numeric
   references are allowed); there the index space is unambiguous. *)
let elaborate_implicit_types ctx fields =
  let next = ref 0 in
  (* Known function types by index, explicit ones first, then minted implicit
     ones, used to decide whether an inline signature needs a fresh index. *)
  let known = ref [] in
  let record ft = known := (Uint32.of_int !next, ft) :: !known in
  (* Phase 1: explicit type definitions, in source order. *)
  List.iter
    (fun (field : (_ Src.modulefield, _) Ast.annotated) ->
      match field.desc with
      | Types rectype ->
          Array.iter
            (fun e ->
              (match (snd e.Ast.desc : Src.subtype).typ with
              | Func ft -> record ft
              | Struct _ | Array _ | Cont _ -> ());
              incr next)
            rectype
      | _ -> ())
    fields;
  (* Phase 2: every inline signature, in source order, appended after the
     explicit types. *)
  let consider ((typ, sign) : Src.typeuse) =
    match typ with
    | Some _ -> () (* references an existing type; mints nothing *)
    | None ->
        let ft = Option.value sign ~default:empty_functype in
        if not (List.exists (fun (_, ft') -> functype_eq ft ft') !known) then (
          Hashtbl.replace ctx.implicit_types (Uint32.of_int !next) ft;
          record ft;
          incr next)
  in
  let blocktype = function Some (Src.Typeuse tu) -> consider tu | _ -> () in
  let rec instr (i : _ Src.instr) =
    match i.Ast.desc with
    | CallIndirect (_, tu) | ReturnCallIndirect (_, tu) -> consider tu
    | Block { typ; block; _ } | Loop { typ; block; _ } ->
        blocktype typ;
        instrs block.desc
    | If { typ; if_block; else_block; _ } ->
        blocktype typ;
        instrs if_block.Ast.desc;
        instrs else_block.Ast.desc
    | TryTable { typ; block; _ } ->
        blocktype typ;
        instrs block.desc
    | Try { typ; block; catches; catch_all; _ } ->
        blocktype typ;
        instrs block.desc;
        List.iter (fun (_, b) -> instrs b.Ast.desc) catches;
        Option.iter (fun b -> instrs b.Ast.desc) catch_all
    | Folded (i, l) ->
        instr i;
        instrs l
    | Hinted (_, i) -> instr i
    | _ -> ()
  and instrs l = List.iter instr l in
  List.iter
    (fun (field : (_ Src.modulefield, _) Ast.annotated) ->
      match field.desc with
      | Func { typ; instrs = body; _ } ->
          consider typ;
          instrs body
      | Import { desc = Func { typ = tu; _ }; _ } | Import { desc = Tag tu; _ }
        ->
          consider tu
      | Tag { typ; _ } -> consider typ
      | Global { init; _ } -> instrs init
      | Elem { init; _ } -> List.iter instrs init
      | Table { init = Init_expr e; _ } -> instrs e
      | Table { init = Init_segment l; _ } -> List.iter instrs l
      | Types _ | Import _ | Memory _ | Table _ | Export _ | Start _ | Data _
      | String_global _ | Module_if_annotation _ ->
          ())
    fields

let register_names ctx export_tbl fields =
  (* Both passes recurse into the branches of a conditional, in the same order
     the converter visits them, so positional naming stays aligned. *)
  let rec pass1 fields =
    List.iter
      (fun (field : (_ Src.modulefield, _) Ast.annotated) ->
        match field.desc with
        | Import { id; name; desc; exports; _ } -> (
            (* Failing an explicit [$id] and an export name, borrow the imported
               name as the Wax name (like an export name), so an imported
               [malloc] is named [malloc] rather than the generic default. *)
            let hint =
              if Lexer.is_valid_identifier name.Ast.desc then Some name.Ast.desc
              else None
            in
            match desc with
            | Func _ -> ()
            | Memory _ ->
                Sequence.register ?hint ctx.memories export_tbl
                  (Some (Memory : Src.exportable))
                  id exports
            | Table _ ->
                Sequence.register ?hint ctx.tables export_tbl (Some Table) id
                  exports
            | Global _ ->
                Sequence.register ?hint ctx.globals export_tbl (Some Global) id
                  exports
            | Tag ty -> register_type ?hint ctx export_tbl Tag id exports ty)
        | Types rectype ->
            Array.iter
              (fun e ->
                let id, ty = e.Ast.desc in
                let name = Sequence.register' ctx.types export_tbl None id [] in
                CondTbl.add ctx.type_defs ctx.cond_asm name ty;
                match (ty : Src.subtype).typ with
                | Func _ | Array _ | Cont _ -> ()
                | Struct l ->
                    let seq =
                      Sequence.make ~diagnostics:ctx.diagnostics
                        (Namespace.make ()) "f"
                    in
                    (* A struct subtype inherits its supertype's fields by
                       position, so an unnamed field can borrow the name the
                       parent gave that slot rather than the generic "f". *)
                    let parent_fields =
                      match ty.supertype with
                      | None -> [||]
                      | Some sup -> (
                          match Sequence.get ctx.types sup with
                          | exception
                              ( Unresolved_reference _
                              | Numeric_ref_in_conditional _ ) ->
                              [||]
                          | { desc = parent; _ } -> (
                              match
                                Hashtbl.find_opt ctx.struct_fields parent
                              with
                              | Some (_, names) -> Array.of_list names
                              | None -> [||]))
                    in
                    let fields =
                      Array.mapi
                        (fun i t ->
                          let hint =
                            if i < Array.length parent_fields then
                              Some parent_fields.(i)
                            else None
                          in
                          Sequence.register' ?hint seq export_tbl None
                            (get_annot t) [])
                        l
                    in
                    Hashtbl.replace ctx.struct_fields name
                      (seq, Array.to_list fields))
              rectype
        | Global { id; exports; _ } ->
            Sequence.register ctx.globals export_tbl (Some Global) id exports
        | Func _ | Export _ | Start _ -> ()
        | Elem { id; _ } -> Sequence.register ctx.elems export_tbl None id []
        | Data { id; _ } -> Sequence.register ctx.datas export_tbl None id []
        | Memory { id; exports; _ } ->
            Sequence.register ctx.memories export_tbl (Some Memory) id exports
        | Table { id; exports; _ } ->
            Sequence.register ctx.tables export_tbl (Some Table) id exports
        | Tag { id; exports; typ; _ } ->
            register_type ctx export_tbl Tag id exports typ
        | String_global { id; _ } ->
            Sequence.register ctx.globals export_tbl (Some Global) (Some id) []
        | Module_if_annotation { then_fields; else_fields; cond } ->
            with_cond ctx ~location:field.info cond true (fun () ->
                pass1 then_fields.desc);
            Option.iter
              (fun e ->
                with_cond ctx ~location:field.info cond false (fun () ->
                    pass1 e.Ast.desc))
              else_fields)
      fields
  in
  let rec pass2 fields =
    List.iter
      (fun (field : (_ Src.modulefield, _) Ast.annotated) ->
        match field.desc with
        | Import { id; name; desc; exports; _ } -> (
            match desc with
            | Func { typ; _ } ->
                let hint =
                  if Lexer.is_valid_identifier name.Ast.desc then
                    Some name.Ast.desc
                  else None
                in
                register_type ?hint ctx export_tbl Func id exports typ
            | Memory _ | Table _ | Global _ | Tag _ -> ())
        | Func { id; exports; typ; _ } ->
            register_type ctx export_tbl Func id exports typ
        | Module_if_annotation { then_fields; else_fields; cond } ->
            with_cond ctx ~location:field.info cond true (fun () ->
                pass2 then_fields.desc);
            Option.iter
              (fun e ->
                with_cond ctx ~location:field.info cond false (fun () ->
                    pass2 e.Ast.desc))
              else_fields
        | Types _ | Global _ | Export _ | Start _ | Elem _ | Data _ | Memory _
        | Table _ | Tag _ | String_global _ ->
            ())
      fields
  in
  pass1 fields;
  pass2 fields

let collect_exports cond_env diagnostics fields =
  let tbl = Hashtbl.create 16 in
  let lst = ref [] in
  let start_lst = ref [] in
  (* Combine the accumulated branch conditions ([syn], a list of conjuncts, each
     already negated for an [@else]) into one syntactic condition, kept alongside
     the solved [asm] so a standalone export narrower than its target can be
     re-emitted as a [#[export …, if <cond>]] guard. *)
  let combine syn : Wax_wasm.Ast.cond =
    match syn with [ c ] -> c | l -> Cond_and l
  in
  (* [asm]/[syn] are the branch assumption under which the fields being walked
     appear (solved / syntactic), so each standalone export is recorded with the
     condition that guards it. *)
  let rec go asm syn fields =
    List.iter
      (fun (field : (_ Src.modulefield, _) Ast.annotated) ->
        match field.desc with
        | Export { name; kind; index } ->
            (* Don't keep a meaningless location *)
            lst := (kind, index, Ast.no_loc name.desc, asm, combine syn) :: !lst;
            let k = (kind, index.Ast.desc) in
            Hashtbl.replace tbl k
              (name :: (try Hashtbl.find tbl k with Not_found -> []))
        | Start index -> start_lst := (index, asm, combine syn) :: !start_lst
        | Module_if_annotation { cond; then_fields; else_fields } ->
            let c =
              Cond.of_cond cond_env diagnostics ~location:field.info cond
            in
            go (Cond.and_ asm c) (syn @ [ cond ]) then_fields.desc;
            Option.iter
              (fun e ->
                go
                  (Cond.and_ asm (Cond.not_ c))
                  (syn @ [ Cond_not cond ]) e.Ast.desc)
              else_fields
        | _ -> ())
      fields
  in
  go Cond.true_ [] fields;
  (tbl, !lst, !start_lst)

(*** Module conversion ***)

let rec module_has_conditional fields =
  List.exists
    (fun (f : (_ Src.modulefield, _) Ast.annotated) ->
      match f.desc with
      | Module_if_annotation { then_fields; else_fields; _ } ->
          module_has_conditional then_fields.desc
          || Option.fold ~none:false
               ~some:(fun e -> module_has_conditional e.Ast.desc)
               else_fields
          || true
      | _ -> false)
    fields

let rec count_memories fields =
  List.fold_left
    (fun n (f : (_ Src.modulefield, _) Ast.annotated) ->
      match f.desc with
      | Memory _ | Import { desc = Memory _; _ } -> n + 1
      | Module_if_annotation { then_fields; else_fields; _ } ->
          n
          + count_memories then_fields.desc
          + Option.fold ~none:0
              ~some:(fun e -> count_memories e.Ast.desc)
              else_fields
      | _ -> n)
    0 fields

(* The [type <name> = fn(..)] declarations for implicit function types that were
   named because a ref-type referenced them ([type_ref_name]). Converting a
   signature can itself name further implicit types (a nested ref-type use), so
   drain [named_implicit] to a fixpoint; a dependency named while converting an
   earlier one is emitted before it. *)
let extra_type_decls ctx =
  let rec loop acc =
    match ctx.named_implicit with
    | [] -> acc
    | pending ->
        ctx.named_implicit <- [];
        let decls =
          List.rev_map
            (fun (name, ft) ->
              let name = Ast.no_loc name in
              let sub : Ast.subtype =
                {
                  typ = Func (functype ctx ft);
                  supertype = None;
                  final = true;
                  descriptor = None;
                  describes = None;
                }
              in
              Ast.no_loc (Ast.Type [| annotated name.Ast.info name sub |]))
            pending
        in
        loop (decls @ acc)
  in
  loop []

(* Merge maximal runs of consecutive single imports from the same module into
   one [import "module" { ... }] block; a lone import stays as the standalone
   [import "module" <decl>;] form. Recurses through groups and conditionals. *)
let rec group_imports fields =
  let recurse f =
    match f.Ast.desc with
    | Ast.Conditional c ->
        {
          f with
          Ast.desc =
            Ast.Conditional
              {
                c with
                then_fields =
                  {
                    c.then_fields with
                    Ast.desc = group_imports c.then_fields.Ast.desc;
                  };
                else_fields =
                  Option.map
                    (fun b -> { b with Ast.desc = group_imports b.Ast.desc })
                    c.else_fields;
              };
        }
    | _ -> f
  in
  let rec merge = function
    | [] -> []
    | f :: rest -> (
        match f.Ast.desc with
        | Ast.Import { module_; decl } ->
            let rec take acc = function
              | g :: tl
                when match g.Ast.desc with
                     | Ast.Import { module_ = m2; _ } ->
                         m2.Ast.desc = module_.desc
                     | _ -> false ->
                  let d =
                    match g.Ast.desc with
                    | Ast.Import { decl; _ } -> decl
                    | _ -> assert false
                  in
                  take (d :: acc) tl
              | tl -> (List.rev acc, tl)
            in
            let decls, tl = take [ decl ] rest in
            let field =
              match decls with
              | [ _ ] -> f
              | _ -> { f with Ast.desc = Ast.Import_group { module_; decls } }
            in
            field :: merge tl
        | _ -> f :: merge rest)
  in
  merge (List.map recurse fields)

let module_ ?(strict_constants = false) diagnostics (module_name, fields) =
  Wax_utils.Debug.timed "convert" @@ fun () ->
  try
    let forbid_numeric = module_has_conditional fields in
    (* Loads/stores reference the memory implicitly by index 0. When the module
     has a single memory that numeric reference is unambiguous (even if the
     memory itself sits in a conditional branch), so numeric memory references
     are allowed; with several memories, indices may shift across branches like
     any other field, so the general constraint stands. *)
    let forbid_numeric_memory = forbid_numeric && count_memories fields > 1 in
    let ctx =
      let common_namespace = Namespace.make () in
      {
        diagnostics;
        types =
          Sequence.make ~forbid_numeric ~diagnostics
            (Namespace.make ~kind:`Type ())
            "t";
        struct_fields = Hashtbl.create 16;
        globals =
          Sequence.make ~forbid_numeric ~diagnostics common_namespace "g";
        functions =
          Sequence.make ~forbid_numeric ~diagnostics common_namespace "f";
        memories =
          Sequence.make ~forbid_numeric:forbid_numeric_memory ~diagnostics
            common_namespace "m";
        tables = Sequence.make ~forbid_numeric ~diagnostics common_namespace "t";
        tags =
          Sequence.make ~forbid_numeric ~diagnostics (Namespace.make ()) "t";
        datas = Sequence.make ~forbid_numeric ~diagnostics common_namespace "d";
        elems = Sequence.make ~forbid_numeric ~diagnostics common_namespace "e";
        referenced_elems = Hashtbl.create 16;
        type_defs = CondTbl.make ();
        implicit_types = Hashtbl.create 16;
        named_implicit = [];
        function_types = CondTbl.make ();
        tag_types = CondTbl.make ();
        exports = Hashtbl.create 16;
        starts = Hashtbl.create 16;
        locals = Sequence.make ~diagnostics common_namespace "x";
        labels = LabelStack.make ();
        label_arities = [];
        return_arity = 0;
        strict_constants;
        cond_env = Cond.create ();
        cond_diag = Wax_utils.Diagnostic.collector ();
        cond_asm = Cond.true_;
      }
    in
    let export_tbl, export_lst, start_lst =
      collect_exports ctx.cond_env ctx.cond_diag fields
    in
    register_names ctx export_tbl fields;
    if not forbid_numeric then elaborate_implicit_types ctx fields;
    (* Resolve each [(start …)] to its function's Wax name, keeping the branch
       condition it appeared under; rendered as a [#[start]] attribute on that
       function (guarded when the start is narrower than the function). *)
    List.iter
      (fun (index, asm, syn) ->
        let name = (idx ctx `Func index).Ast.desc in
        Hashtbl.replace ctx.starts name
          ((asm, syn)
          :: Option.value ~default:[] (Hashtbl.find_opt ctx.starts name)))
      start_lst;
    List.iter
      (fun (kind, index, name, asm, syn) ->
        let k =
          ( kind,
            (idx ctx
               (match (kind : Src.exportable) with
               | Func -> `Func
               | Memory -> `Mem
               | Table -> `Table
               | Tag -> `Tag
               | Global -> `Global)
               index)
              .desc )
        in
        let l =
          (asm, syn, name)
          ::
          (match Hashtbl.find_opt ctx.exports k with
          | None -> []
          | Some l -> l)
        in
        Hashtbl.replace ctx.exports k l)
      export_lst;
    (* Record which element segments are referenced by table.init / elem.drop /
     array.*_elem (recursing into conditional branches), so a declarative
     segment used this way is declared rather than dropped. *)
    let rec collect_field (f : (_ Src.modulefield, _) Ast.annotated) =
      match f.Ast.desc with
      | Func { instrs; _ } ->
          collect_elem_refs_instrs ctx ctx.referenced_elems instrs
      | Module_if_annotation { then_fields; else_fields; _ } ->
          List.iter collect_field then_fields.desc;
          Option.iter (fun e -> List.iter collect_field e.Ast.desc) else_fields
      | _ -> ()
    in
    List.iter collect_field fields;
    let converted =
      List.concat_map (fun f -> modulefield ctx export_tbl f) fields
    in
    (* Prepend the type declarations synthesised for implicit types named by a
       ref-type reference (computed after conversion, which is what names them). *)
    let converted = extra_type_decls ctx @ converted in
    let recovered =
      Recover_match.module_
        (Sink_let.module_
           (Recover_loops.module_ (Recover_dispatch.module_ converted)))
    in
    (* A named module becomes a leading [#![module = "name"]] inner attribute. *)
    let name_annotation =
      match module_name with
      | Some nm ->
          [
            Ast.no_loc
              (Ast.Module_annotation
                 [ ("module", Some (string_of_name nm), None) ]);
          ]
      | None -> []
    in
    name_annotation @ group_imports recovered
  with
  | Numeric_ref_in_conditional location ->
      Wax_utils.Diagnostic.report diagnostics ~location ~severity:Error
        ~message:(fun f () ->
          Format.pp_print_string f
            "Numeric references to module fields are not supported in a module \
             with conditional annotations; use a symbolic $name.")
        ();
      Wax_utils.Diagnostic.abort ()
  | Unresolved_reference location ->
      Wax_utils.Diagnostic.report diagnostics ~location ~severity:Error
        ~message:(fun f () ->
          Format.pp_print_string f
            "This reference resolves to nothing: it is out of range or names \
             an undeclared entity.")
        ();
      Wax_utils.Diagnostic.abort ()

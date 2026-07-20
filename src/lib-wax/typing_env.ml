open Ast
module Cond = Wax_wasm.Cond_solver

type typed_module_annotation = Ast.storagetype option array * Ast.location

open Infer

(* The typed tree as it stands during checking, before the cells are resolved to
   [typed_module_annotation]: each node carries the inference cells for the
   values it leaves on the stack, plus its span. [f] resolves these to storage
   types for the Wasm conversion; the editor reads the cells directly (they carry
   the flexible-literal / unknown distinctions [output_inferred_type] renders,
   which resolution discards). *)
type inferred_module_annotation = inferred_type Cell.t array * Ast.location

(* A resolved name or label reference: the source span of a *use*, the span(s)
   of the *definition(s)* it binds to, and a rendered one-line summary of what it
   resolves to (the referenced type's structure, or a variable's type) for a
   hover on a name that is not itself an expression. There is more than one
   definition only under conditional compilation (a name declared in several
   mutually exclusive branches). Accumulated during type checking into a
   [reference list ref] when the caller supplies one, for the editor's
   go-to-definition and hover; nil otherwise, so an ordinary compile pays
   nothing. *)
(* What a resolved reference summarises for a hover on a name that is not itself
   an expression: a variable's type, or a referenced type's definition. Kept as
   data, not a rendered string — nothing is formatted until a hover actually
   asks (the editor renders the one it needs), so a check pays only a boxing per
   reference. *)
type hover_target = Value_type of inferred_valtype | Type_def of subtype

type reference = {
  use : Ast.location;
  definitions : Ast.location list;
  hover : hover_target option;
}

type resolve_sink = reference list ref option

(* A synthesized node (an interned function type looked up for a call, a
   desugared construct) carries [Ast.dummy_loc] rather than a source span; skip
   those, so only genuine source references are recorded. *)
let is_source (l : location) = l.loc_start.Lexing.pos_cnum >= 0

let same_span (a : location) (b : location) =
  a.loc_start.Lexing.pos_cnum = b.loc_start.Lexing.pos_cnum
  && a.loc_end.Lexing.pos_cnum = b.loc_end.Lexing.pos_cnum

(* The single inference cell an instruction leaves on the stack, or [None] if it
   is not a one-value expression (it leaves zero or several). The error-free
   counterpart of the typer's [expression_type] (which reports [not_an_expression]
   and yields an [Error] cell): a lint/suggest site reads the cell when there is
   exactly one and silently skips otherwise, never emitting the duplicate
   diagnostic the typer already owns. *)
let expression_type_opt i =
  match fst i.info with [| ty |] -> Some ty | _ -> None

(* The value type [&?none] / [&none] (the nullable / non-nullable bottom
   reference), precomputed. [None_] is a built-in abstract bottom heap type, so
   its internal form carries no type-store index and is context-independent —
   [standalone_valtype] builds it without a type context, matching what
   [internalize_valtype ctx (Ref { typ = None_; _ })] would return. *)
let ref_none_valtype ~nullable : inferred_valtype =
  {
    typ = Ref { nullable; typ = None_ };
    internal = Internal.Ref { nullable; typ = Internal.None_ };
    anon_comptype = None;
  }

(* The concrete value type an inference cell stands for on its own, or [None]
   when it has none yet (a packed [i8]/[i16], or an unresolved [Unknown]/[Error]/
   [Collecting]). A still-flexible literal takes its default width (int/number ->
   i32, large number -> i64, float -> f64); [Null]/[UnknownRef] concretize to the
   nullable / non-nullable bottom reference. Pure and context-free: unlike the
   typer's ctx-threading path it never consults the type table, since the only
   reference it produces is the built-in [None_] bottom. *)
let standalone_valtype ty =
  match Cell.get ty with
  | Valtype v -> Some v
  | Int | Number -> Some i32_valtype
  | LargeInt -> Some i64_valtype
  | Float -> Some f64_valtype
  | Null -> Some (ref_none_valtype ~nullable:true)
  (* The bottom reference concretizes to the non-null [&none], matching the type
     [null!] produced before [UnknownRef] existed. *)
  | UnknownRef -> Some (ref_none_valtype ~nullable:false)
  | Int8 | Int16 | Unknown | Error | Collecting _ -> None

(* Record a punned struct-literal field's span (the field name, which is also
   the variable use), so the editor can expand it on rename. *)
let record_pun (sink : location list ref option) (name_info : location) =
  match sink with
  | Some r when is_source name_info -> r := name_info :: !r
  | _ -> ()

(* Record, at a struct field access, the (possibly partial) field's span and the
   receiver it is on, for member completion. [None] outside the editor. *)
let record_members (sink : (location * Members.member_receiver) list ref option)
    field receiver =
  match sink with
  | Some r when is_source field -> r := (field, receiver) :: !r
  | _ -> ()

let record_reference ?(hover = None) (sink : resolve_sink) use definitions =
  match sink with
  | Some r when is_source use -> (
      (* Drop synthesized definitions and the self-reference a name's own
         declaration makes when it looks itself up (go-to-definition on a
         definition has nowhere useful to go). *)
      match
        List.filter (fun d -> is_source d && not (same_span d use)) definitions
      with
      | [] -> ()
      | definitions -> r := { use; definitions; hover } :: !r)
  | _ -> ()

module StringSet = Set.Make (String)
module StringMap = Map.Make (String)

(* The option let-operators (the [@] suffix denotes "optional"): [let*@] binds
   through [Some]/short-circuits on [None] (Option.bind), [let+@] maps the
   payload (Option.map), and [let>@] runs an effect only when [Some]
   (Option.iter). Distinct from the stack-threading [let*]/[let*!] defined with
   the typing monad further down. *)
let ( let*@ ) = Option.bind
let ( let+@ ) o f = Option.map f o
let ( let>@ ) o f = Option.iter f o

(* Names are resolved relative to a "current assumption" — the conjunction of
   the conditional-branch conditions enclosing the point being typed. The cell
   is shared by every namespace and table of one module typing, and updated as
   the passes descend into [#[if]]/[#[else]] branches. When no conditionals are
   present (or when checking a single specialized configuration) it stays
   [true_] and these structures behave like plain name-keyed tables. *)
module Namespace = struct
  type t = {
    cond : Cond.t ref;
    tbl : (string, (string * location * Cond.t) list) Hashtbl.t;
    links : resolve_sink;
        (* Where [Tbl.resolve] records a use -> definition(s) reference, shared
           across the namespaces of one module; [None] disables recording. *)
  }
end

module Tbl = struct
  type 'a t = {
    kind : string;
    namespace : Namespace.t;
    tbl : (string, (Cond.t * 'a) list) Hashtbl.t;
    (* Names referenced (looked up) through this table, so a declaration that is
       never referenced can be reported as unused. Populated by [resolve];
       queried by [is_used]. *)
    used : (string, unit) Hashtbl.t;
    hover : 'a -> hover_target option;
        (* A summary of a resolved value (its type / definition), attached to
           the reference [resolve] records, for editor hover on a name that is
           not an expression. [fun _ -> None] leaves the reference hover-less. *)
  }
end

(*** Types and the type context ***)

type types = (Wax_wasm.Types.ref_index * subtype) Tbl.t

type type_context = {
  internal_types : Wax_wasm.Types.t;
  types : (Wax_wasm.Types.ref_index * subtype) Tbl.t;
  features : Wax_utils.Feature.set;
      (* The enabled optional features / proposals, and which are used. *)
  mutable subtyping_info_cache : Wax_wasm.Types.subtyping_info option;
      (* Memoised subtyping info for [internal_types]; invalidated by [add_type]
         when a type is added (including function types minted while
         type-checking, e.g. an inline [&fn(..)] cast target), so subtyping
         queries always see the current type space. Read via [subtyping_info]. *)
}

type module_context = {
  (* --- Diagnostics and whole-run configuration --- *)
  diagnostics : Wax_utils.Diagnostic.context;
  warn_unused : bool;
      (* Whether to report locals declared by a [let] but never read. Enabled
         only when validation is requested. *)
  simplify : bool;
  (* Whether to rewrite the AST while typing: drop casts the inferred types
         make redundant and tighten [&?extern]/[&?any] casts to
         [&extern]/[&any]. Enabled only when converting from Wasm; for
         hand-written Wax (formatting, or compiling to Wasm) casts are kept as
         written. *)
  suggest : bool;
  (* Whether to emit [Suggestion] diagnostics carrying machine-applicable
         rewrites (redundant-cast removal, compound assignment, field punning, a
         redundant [let] annotation), for editor quick fixes and [wax check].
         The AST is left untouched (unlike [simplify], which rewrites it); the
         two are mutually exclusive. Enabled for hand-written Wax only. *)
  (* --- Module-wide type and name tables (built once, before any body) --- *)
  type_context : type_context;
  types : (Wax_wasm.Types.ref_index * subtype) Tbl.t;
  (* Per function: interned type index, type name, and whether a reference to it
     is exact (a defined function or an exact import — custom-descriptors).
     [None] is a poison entry — a function whose signature failed to resolve
     (reported at the definition): the name stays bound so its uses do not
     cascade into unbound-name reports, mirroring the Wasm validator's poisoned
     index entries. *)
  functions : (Wax_wasm.Types.Id.t * string * bool) option Tbl.t;
  globals : (*mutable:*) (bool * inferred_valtype option) Tbl.t;
      (* As for [locals], the type is [None] for a global whose initializer
         failed to type — a poison global read as [Error] to avoid cascades. *)
  import_globals : (bool * inferred_valtype option) Tbl.t;
      (* The globals in scope for a table initializer: only the imported ones.
         A table is typed before the module's own globals are registered, so its
         initializer can reference only imports (unlike a global initializer,
         which sees the globals declared before it). *)
  tags : functype Tbl.t;
  memories : (int * [ `I32 | `I64 ]) Tbl.t;
  datas : unit Tbl.t;
  tables : ([ `I32 | `I64 ] * reftype) Tbl.t;
  elems : reftype Tbl.t;
  structs_by_fields : (string, ident option) Hashtbl.t;
  (* Maps a struct's canonical field-set key (see [field_set_key]) to the
         unique struct type with that field set, or [None] when several share
         it. Lets a struct literal whose name is omitted resolve from its fields
         alone (and the name be dropped when the fields make it unambiguous).
         Built once at module-context creation. *)
  not_expression_reported : (int * int, unit) Hashtbl.t;
  (* Source spans (byte offsets) already reported by [expression_type]'s
         "an expression is expected here". [expression_type] is a *query* with
         a reporting side effect, and one node is legitimately queried by
         several consumers (a call's callee twice, a labelled block as both
         value and statement), which would repeat the identical report — so it
         fires once per span. Shared by the [{ ctx with … }] copies (one table
         per configuration). *)
  (* --- Per-function state (reset on entry to each function) --- *)
  mutable locals : (inferred_valtype option * location) StringMap.t;
      (* The local's type paired with its binding site's source span (for
         go-to-definition). The type is [None] when it could not be determined
         because its initializer failed to type — an error-recovery "poison"
         local, read as the [Error] type so its uses don't cascade into further
         errors. *)
  mutable initialized_locals : StringSet.t;
      (* Locals known to hold a value at the current point. A non-defaultable
         (non-nullable reference) local starts uninitialized and must be
         assigned before it is read. The set is captured by [{ ctx with ... }]
         on block entry, so an assignment inside a block does not escape it.
         Within a straight-line operand sequence it only grows, which is what
         lets a trailing operand typed out of emission order be reconciled by
         [type_trailing_operand]. *)
  mutable deferred_uninit : ident list ref list;
      (* A stack of collectors for uninitialized-local reads deferred by a
         trailing operand typed out of emission order (see
         [type_trailing_operand]). While non-empty, an uninitialized read funnels
         into the innermost (head) collector instead of erroring, to be re-checked
         against the true state at the operand's emission slot. Empty outside such
         an operand, so a read then reports immediately. *)
  unresolved_label : bool ref;
      (* Whether a branch in the current function failed to resolve its label
         (reported by [branch_target]). While set, a value-shape complaint
         ([expression_type]'s "an expression is expected here") is suppressed
         as a likely cascade: a block whose only value delivery was the
         unresolved branch legitimately computes no value, and reporting that
         would anchor a derived error away from the unbound label. The
         per-function analogue of the error-recovery-mode suppression. Reset
         per function. *)
  read_locals : StringSet.t ref;
      (* Names of locals read so far in the current function. A [ref] (rather
         than a snapshot field) so reads inside a block propagate to the
         function level. Reset per function. *)
  local_decls : ident list ref;
      (* The [let]-bound locals declared in the current function, in declaration
         order, so an unread one can be reported as unused. Reset per function. *)
  used_labels : StringSet.t ref;
      (* Names of block labels branched to so far in the current function
         (marked by [branch_target]). A [ref] so a branch nested in a block
         propagates to the function level. Reset per function. *)
  deferred_lints : (unit -> unit) list ref;
      (* Lints that must read a result cell only once typing has pinned it (the
         [shift-count-overflow] lint reads the shifted operand's width, which a
         later context can widen). Accumulated across the whole configuration and
         flushed at the end of [type_configuration], when every cell is final. *)
  label_decls : ident list;
      (* The block labels declared in the current function's body, collected up
         front from the source AST (see [collect_labels]), so one never branched
         to can be reported as unused. Reset per function. *)
  assigned_locals : StringSet.t;
      (* Names of locals assigned ([Set]/[Tee] targets) anywhere in the current
         function, collected once on entry (see [collect_assigned_locals]). Lets
         the annotation-drop on a fused [let x: T = e] tell a write-once local —
         which may narrow to [e]'s subtype just like an immutable global — from
         one a later assignment still needs the wider [T] for. Reset per
         function. *)
  control_types : (label option * inferred_type Cell.t array) list;
      (* Each enclosing control frame's label (kept as its [ident], so a branch
         can be linked to the labelled construct for go-to-definition) and the
         types it delivers. *)
  return_types : inferred_type Cell.t array;
  (* --- Conditional-compilation branch assumption --- *)
  cond : Cond.t ref;
      (* Current branch assumption (shared with every namespace/table above);
         set while typing a conditional branch so names resolve per branch. *)
  cond_env : Cond.env;
  resolve_links : resolve_sink;
      (* Where use -> definition references are recorded (locals via
         [resolve_variable], labels via [branch_target]; module fields via
         [Tbl.resolve] through the namespaces). The same sink the namespaces
         hold; [None] outside the editor. *)
  pun_spans : location list ref option;
      (* The span of each punned struct-literal field (the bare-name form,
         [x] standing for [x: x]), recorded at the field name. Such a span is
         both a field name and a variable use, so the editor must expand it
         ([x] -> [x: new]) rather than replace it on rename. [None] outside the
         editor. *)
  member_completions : (location * Members.member_receiver) list ref option;
      (* At each struct field access [recv.field], the field-name span paired
         with the receiver's members (a struct's fields, or the value methods of
         a numeric / array receiver), for member completion. The editor offers
         those when the cursor is on the (possibly partial) field. [None]
         outside the editor. *)
}

(*** Source-slice utilities for editor suggestions ***)

(* The source text a location spans, or [None] when the source is unavailable or
   the span is out of range. The suggestion quick fixes read the exact bytes a
   construct occupies (an annotation, an operand) to splice a rewrite. *)
let source_slice ctx (loc : Ast.location) =
  match Wax_utils.Diagnostic.source ctx.diagnostics with
  | Some src ->
      let s = loc.loc_start.Lexing.pos_cnum
      and e = loc.loc_end.Lexing.pos_cnum in
      if 0 <= s && s <= e && e <= String.length src then
        Some (String.sub src s (e - s))
      else None
  | None -> None

(* The location running from position [loc_start] to [loc_end], used to describe
   the exact span a suggestion's edit replaces (e.g. the ' as t' suffix of a
   redundant cast). *)
let span (loc_start : Lexing.position) (loc_end : Lexing.position) :
    Ast.location =
  { Ast.loc_start; loc_end }

(* A deletion edit: the machine-applicable rewrite that removes the span [loc]
   (an empty replacement). The removal-style suggestions — a redundant
   annotation, a punned field's [: x], a construction/block/if result type, a
   redundant cast — all build this. *)
let deletion_edit (loc : Ast.location) : Wax_utils.Diagnostic.edit =
  { Wax_utils.Diagnostic.edit_location = loc; new_text = "" }

(* [s] with every comment blanked to spaces (newlines kept, so byte offsets and
   line structure are preserved). Wax has [//] line comments and nesting [/* */]
   block comments; the source-scanning suggestions run on this so a delimiter
   ([:], [|], a keyword) inside a comment is never mistaken for real syntax. *)
let blank_comments s =
  let n = String.length s in
  let b = Bytes.of_string s in
  let blank lo hi =
    for k = lo to hi - 1 do
      if s.[k] <> '\n' then Bytes.set b k ' '
    done
  in
  let i = ref 0 in
  while !i < n do
    if !i + 1 < n && s.[!i] = '/' && s.[!i + 1] = '/' then (
      let j = ref (!i + 2) in
      while !j < n && s.[!j] <> '\n' do
        incr j
      done;
      blank !i !j;
      i := !j)
    else if !i + 1 < n && s.[!i] = '/' && s.[!i + 1] = '*' then (
      let j = ref (!i + 2) and depth = ref 1 in
      while !depth > 0 && !j < n do
        if !j + 1 < n && s.[!j] = '/' && s.[!j + 1] = '*' then (
          j := !j + 2;
          incr depth)
        else if !j + 1 < n && s.[!j] = '*' && s.[!j + 1] = '/' then (
          j := !j + 2;
          decr depth)
        else incr j
      done;
      blank !i !j;
      i := !j)
    else incr i
  done;
  Bytes.to_string b

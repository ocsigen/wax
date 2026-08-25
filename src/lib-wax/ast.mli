(** Wax Abstract Syntax Tree. *)

type ('desc, 'info) annotated = ('desc, 'info) Wax_utils.Ast.annotated = {
  desc : 'desc;
  info : 'info;
}

type location = Wax_utils.Ast.location = {
  loc_start : Lexing.position;
  loc_end : Lexing.position;
}

val no_loc : 'desc -> ('desc, location) annotated

(* [instr] shares the [desc]/[info] field names with [annotated] and, being
   declared later, wins field disambiguation wherever the receiver's type is not
   already known. Read a *generic* node's fields through this alias to say which
   record is meant: [x.Annot.desc]. *)
module Annot = Wax_utils.Ast

type ident = (string, location) annotated
(** An identifier with its source location. *)

include module type of Wax_wasm.Ast.Make_types (struct
  type idx = ident
  type 'a annotated_array = (ident * 'a, location) annotated array
  type 'a opt_annotated_array = (ident option * 'a, location) annotated array
end)

val splice_field_name : string
(** The reserved field name marking a [..] splice at the head of a struct
    definition (inherits the supertype's fields). Not a valid identifier, so it
    never collides with a real field. *)

val is_splice_field : (ident * fieldtype, location) annotated -> bool
(** Whether a struct field is the [..] splice sentinel. *)

val splice_field : location -> (ident * fieldtype, location) annotated
(** Build a [..] splice sentinel field at the given location. *)

(** The located [(name, thing)] pairs the type family carries: a function
    parameter (its name optional), a struct field, a rec-group member. Named
    accessors rather than [fst]/[snd] over [.desc], because [desc] on a node
    whose type is not already known resolves to the instruction record's field
    of that name (see {!Annot}). Their declared return types also let a chained
    read — [(field_name f).desc] — resolve on its own. *)

val param_name : (ident option * valtype, location) annotated -> ident option
val param_type : (ident option * valtype, location) annotated -> valtype
val field_name : (ident * fieldtype, location) annotated -> ident
val field_type : (ident * fieldtype, location) annotated -> fieldtype
val member_name : (ident * subtype, location) annotated -> ident
val member_type : (ident * subtype, location) annotated -> subtype

(** Signage for integer operations. *)
type signage = Wax_wasm.Ast.signage = Signed | Unsigned

(** Unary operators. *)
type unop = Neg | Pos | Not

(** Binary operators. *)
type binop =
  | Add
  | Sub
  | Mul
  | Div of signage option
  | Rem of signage
  | And
  | Or
  | Xor
  | Shl
  | Shr of signage
  | Eq
  | Ne
  | Lt of signage option
  | Gt of signage option
  | Le of signage option
  | Ge of signage option

type label = ident

type casttype =
  | Valtype of valtype
  | Functype of { nullable : bool; sign : functype }
  | Signedtype of {
      typ : [ `I32 | `I64 | `F32 | `F64 ];
      signage : signage;
      strict : bool;
    }

val format_signed_type :
  [ `F32 | `F64 | `I32 | `I64 ] -> signage -> bool -> string
(** Helper to format signed types (e.g., "i32_s_strict"). *)

type catch =
  | Catch of ident * label
  | CatchRef of ident * label
  | CatchAll of label
  | CatchAllRef of label

type on_clause = OnLabel of ident * label | OnSwitch of ident

(** A [match] arm pattern: a (optionally bound) reference-type test, or a null
    test. See the [Match] node and {!Ast_utils.lower_match}. *)
type match_pattern = MatchCast of ident option * reftype | MatchNull

type 'info instr_desc =
  | Block of {
      label : label option;
      typ : functype;
      block : ('info instr list, location) annotated;
    }
  | Loop of {
      label : label option;
      typ : functype;
      block : ('info instr list, location) annotated;
    }
  | While of {
      label : label option;
      cond : 'info instr;
      (* Zig-style continue-expression: a statement run at the end of every
         iteration, including on a [continue] (a branch to the loop label). *)
      step : 'info instr option;
      block : ('info instr list, location) annotated;
    }
  | If of {
      label : label option;
      typ : functype;
      cond : 'info instr;
      if_block : ('info instr list, location) annotated;
      else_block : ('info instr list, location) annotated option;
    }
  | TryTable of {
      label : label option;
      typ : functype;
      catches : catch list;
      block : ('info instr list, location) annotated;
    }
  | Try of {
      label : label option;
      typ : functype;
      block : ('info instr list, location) annotated;
      catches : (ident * ('info instr list, location) annotated) list;
      catch_all : ('info instr list, location) annotated option;
    }
      (** The deprecated legacy exception handler ([try_legacy]), compiling to
          the legacy [try]/[catch] instructions. *)
  | TryCatch of {
      label : label option;
      typ : functype;
      block : ('info instr list, location) annotated;
      arms : 'info trycatch_arm list;
    }
      (** The structured [try { … } catch { tag => { … } … }], lowering to
          [try_table] plus a block ladder. Arms are honest trailing code in
          clause order: an arm's completion falls into the next arm, the last
          arm's into the join; the body's completion escapes past all arms. The
          label (the join) is a block-like exit carrying the result. *)
  | Unreachable
  | Nop
  | Hole
  | Null
  | Get of ident
  (* A qualified name [namespace::member], used as the callee of a built-in
     intrinsic call such as [i64::add128(...)]. *)
  | Path of ident * ident
  (* Assignment to a named local or global. The middle field is the
     compound-assignment operator: [None] for a plain [x = e]; [Some op] for
     [x op= e], which is equivalent to [x = x op e]. The operator is preserved
     through typing and lowering so it round-trips in both directions ([x op= e]
     on the Wax side, a [get]/op/[set] on the Wasm side); the middle field
     carries the RHS type. A discarded value ([_ = e]) is not a [Set] but an
     anonymous [Let] ([Let ([ (None, _) ], Some e)]); see {!Let}. *)
  | Set of ident * (binop, location) annotated option * 'info instr
  | Tee of ident * 'info instr
  | Call of 'info instr * 'info instr list
  | TailCall of 'info instr * 'info instr list
  (* A labelled call argument [name: expr], used for the static [offset]/
     [align]/[lane] immediates of a memory access; see [ast.ml]. *)
  | Labelled of ident * 'info instr
  | Char of Uchar.t
  | String of ident option * string
  | Int of string
  | Float of string
  | Cast of 'info instr * casttype
  | CastDesc of 'info instr * (* nullable result *) bool * 'info instr
  | Test of 'info instr * reftype
  | NonNull of 'info instr
  (* A field's value is [None] when written in the punning shorthand [{x}],
     abbreviating [{x: x}]; see the [Struct] constructor in [ast.ml]. *)
  | Struct of ident option * (ident * 'info instr option) list
  | StructDefault of ident option
  | StructDesc of 'info instr * (ident * 'info instr option) list
  | StructDefaultDesc of 'info instr
  | StructGet of 'info instr * ident
  | GetDescriptor of 'info instr
  | StructSet of 'info instr * ident * 'info instr
  | Array of ident option * 'info instr * 'info instr
  | ArrayDefault of ident option * 'info instr
  | ArrayFixed of ident option * 'info instr list
  | ArraySegment of ident option * ident * 'info instr * 'info instr
  | ArrayGet of 'info instr * 'info instr
  | ArraySet of 'info instr * 'info instr * 'info instr
  | BinOp of (binop, location) annotated * 'info instr * 'info instr
  | UnOp of (unop, location) annotated * 'info instr
  | Let of (ident option * valtype option) list * 'info instr option
  | Br of label * 'info instr option
  | Br_if of label * 'info instr
  | Br_table of label list * 'info instr
  | Dispatch of {
      index : 'info instr;
      cases : label list;
      default : label;
      arms : (label * ('info instr list, location) annotated) list;
    }
  | Match of {
      scrutinee : 'info instr;
      arms : (match_pattern * ('info instr list, location) annotated) list;
      default : ('info instr list, location) annotated;
    }
  | Br_on_null of label * 'info instr
  | Br_on_non_null of label * 'info instr
  | Br_on_cast of label * reftype * 'info instr
  | Br_on_cast_fail of label * reftype * 'info instr
  | Br_on_cast_desc_eq of
      label * (* nullable *) bool * 'info instr * 'info instr
  | Br_on_cast_desc_eq_fail of
      label * (* nullable *) bool * 'info instr * 'info instr
  | Throw of ident * 'info instr list
  | ThrowRef of 'info instr
  | ContNew of ident * 'info instr
  | ContBind of ident * ident * 'info instr list
  | Suspend of ident * 'info instr list
  | Resume of ident * on_clause list * 'info instr list
  | ResumeThrow of ident * ident * on_clause list * 'info instr list
  | ResumeThrowRef of ident * on_clause list * 'info instr list
  | Switch of ident * ident * 'info instr list
  | On of 'info instr * on_clause list
      (** The postfix handler clause [e on [t -> 'l, ...]] as parsed; the typer
          folds it into the [Resume]/[ResumeThrow]/[ResumeThrowRef] it wraps. *)
  | Return of 'info instr option
  | Sequence of 'info instr list
  | Select of 'info instr * 'info instr * 'info instr
  | If_annotation of {
      cond : Wax_wasm.Ast.cond;
      then_body : ('info instr list, location) annotated;
      else_body : ('info instr list, location) annotated option;
    }

and expectation =
  | Unset
      (** No producer ever considered this node: the default for parsed source
          and for nodes synthesized after the Wasm-to-Wax conversion. On a
          numeric-valued node the conversion emitted, it is a recording GAP —
          invisible to the width check by construction, so only able to surface
          as a silent drift; [--debug width-record] reports every such node. *)
  | Contextual
      (** A producer considered this node and deliberately made no claim: its
          width comes from its context rather than its own printed form
          ({!Wax_conversion.From_wasm}'s [forget_expected]), or its type is a
          reference — the one class outside the width channel. *)
  | Recorded of valtype
      (** The type the value this node produces MUST have, known independently
          of Wax inference: the type stated by the Wasm opcode this node was
          decompiled from. *)

and 'info instr = {
  desc : 'info instr_desc;
  info : 'info;
  hints : ident Wax_wasm.Hints.t;
      (** The advisory [metadata.code.*] metadata of this instruction
          (branch-hinting and compilation-hints proposals), written in Wax as an
          attribute prefixing it ([#[likely]], [#[freq = 16]], ...). A field
          rather than a wrapper node, so that the matches on [desc] — which is
          nearly every match on an instruction — neither see it nor have to see
          through it. *)
  expected : expectation;
      (** What this node's producer states about the type of the value it
          produces: {!Wax_conversion.From_wasm} records the type stated by the
          Wasm opcode a node was decompiled from. Nothing in the source language
          sets it (a parsed module leaves every node [Unset]) and nothing
          user-visible reads it — unlike [hints] it is never printed. The
          typer's width-check mode ({!Typing.f}'s [~width_check]) compares its
          own inferred type for the node against a [Recorded] claim, so a
          decompiled expression whose printed form Wax would re-infer at another
          width — silently changing the opcode on recompile — is reported
          instead of shipped. Readers asking "does this node state its type?"
          must treat [Unset] and [Contextual] identically (only [Recorded]
          informs); the two exist as distinct states solely so the recording-gap
          census can tell "never considered" from "deliberately no claim". A
          field rather than a location-keyed side table, because a synthesized
          dead-code node carries no real span. *)
}

and 'info trycatch_arm = {
  arm_tag : ident option;  (** [None] for the trailing catch-all *)
  arm_ref : bool;  (** [&] arm: the [&exn] is delivered above the payload *)
  arm_types : valtype array;
      (** the arm's entry stack — the tag's payload, plus the [&exn] for a [&]
          arm: [[||]] as parsed, filled by the typer for [To_wasm]'s re-lowering
      *)
  arm_body : ('info instr list, location) annotated;
}

(* Each attribute is a name, an optional value, and an optional
   conditional-compilation guard ([#[export = "f", if not(portable)]]); only
   [export] may be guarded; the guard is located at its [if] keyword. *)
val no_loc_instr : location instr_desc -> location instr
(** A synthesized instruction: no source location, no hints. The instruction
    counterpart of {!no_loc}, which builds an {!annotated} and so cannot serve a
    record that carries hints as well. *)

type attribute = {
  attr_name : string;
  attr_value : location instr option;
      (** [#[export = "f"]] carries one, [#[start]] does not. *)
  attr_guard : (Wax_wasm.Ast.cond, location) annotated option;
      (** A conditional-compilation guard, [#[export = "f", if not(portable)]],
          making just this attribute conditional (independent of the field's own
          reachability). Only [export] may be guarded; located at its [if]. *)
  attr_span : location;
      (** The whole [#[...]], so a diagnostic about the attribute names it
          rather than falling back to {!attr_value} (absent on a valueless
          attribute) or to the whole field. A synthesized attribute — one the
          Wasm-to-Wax conversion invents rather than reads — takes the entity's
          span. *)
}

type attributes = attribute list

(* What an [import "module" { ... }] entry brings in. Imports have no body, so
   these carry only type-level information (no ['info]-annotated instructions):
   [exact] marks an exact function import ([fn f: !t]). *)
type import_kind =
  | Import_func of { typ : ident option; sign : functype option; exact : bool }
  | Import_global of { mut : bool; typ : valtype }
  | Import_tag of { typ : ident option; sign : functype option }
  | Import_memory of {
      address_type : [ `I32 | `I64 ];
      limits : (Wax_utils.Uint64.t * Wax_utils.Uint64.t option) option;
      page_size_log2 : int option;
      shared : bool;
    }
  | Import_table of {
      address_type : [ `I32 | `I64 ];
      reftype : reftype;
      limits : (Wax_utils.Uint64.t * Wax_utils.Uint64.t option) option;
    }

(* A single imported entity. [id] is its Wax name; it is imported under that
   name unless a name-only [#[import = "name"]] attribute overrides it.
   [attributes] also carries e.g. [#[export]] to re-export it. *)
type import_decl = { id : ident; kind : import_kind; attributes : attributes }

(* One element of a data segment's contents (WAT "numeric values" proposal): a
   string literal (its raw bytes), a scalar numeric run [[f32: 1.5, nan, …]], or a
   [v128] run [[v128: i32x4(1,2,3,4), …]]. In a run the element type is stated
   once and the values are raw literal strings, packed little-endian. Holds no
   instructions — every value is a literal. *)
type data_elem =
  | Data_string of string
  | Data_run of storagetype * (string, location) annotated list
  | Data_v128 of (Wax_utils.V128.t, location) annotated list

(* A data segment's contents: elements concatenated in order; an empty list is an
   empty segment. *)
type 'info memdata = {
  data_name : ident option;
  offset : 'info instr;
  init : data_elem list;
}

type 'info datamode = Passive | Active of ident * 'info instr
type 'info elemmode = EPassive | EActive of ident * 'info instr

type 'info modulefield =
  | Type of rectype
  | Func of {
      name : ident;
      typ : ident option;
      sign : functype option;
      body : label option * 'info instr list;
      attributes : attributes;
    }
  | Global of {
      name : ident;
      mut : bool;
      typ : valtype option;
      def : 'info instr;
      attributes : attributes;
    }
  | Tag of {
      name : ident;
      typ : ident option;
      sign : functype option;
      attributes : attributes;
    }
  | Memory of {
      name : ident;
      address_type : [ `I32 | `I64 ];
      limits : (Wax_utils.Uint64.t * Wax_utils.Uint64.t option) option;
      (* Custom page size as its base-2 logarithm ([None] is the default
         65536-byte page). *)
      page_size_log2 : int option;
      shared : bool;
      data : 'info memdata list;
      attributes : attributes;
    }
  | Data of {
      name : ident option;
      mode : 'info datamode;
      init : data_elem list;
      attributes : attributes;
    }
  | Table of {
      name : ident;
      address_type : [ `I32 | `I64 ];
      reftype : reftype;
      limits : (Wax_utils.Uint64.t * Wax_utils.Uint64.t option) option;
      init : 'info instr option;
      attributes : attributes;
    }
  | Elem of {
      name : ident;
      reftype : reftype;
      mode : 'info elemmode;
      init : 'info instr list;
      attributes : attributes;
    }
  (* A single import, [import "module" fn f();]. *)
  | Import of {
      module_ : (string, location) annotated;
      decl : (import_decl, location) annotated;
    }
  (* A grouped import block, [import "module" { fn f(); const c: i32; }]: several
     imports sharing one module. *)
  | Import_group of {
      module_ : (string, location) annotated;
      decls : (import_decl, location) annotated list;
    }
  (* A module-level inner attribute, [#![module = "name"]]. Unlike the outer
     attributes above it is attached to the whole module rather than a field;
     the only one recognized is [module], which names the module. *)
  | Module_annotation of attributes
  | Conditional of {
      cond : Wax_wasm.Ast.cond;
      then_fields :
        (('info modulefield, location) annotated list, location) annotated;
      else_fields :
        (('info modulefield, location) annotated list, location) annotated
        option;
    }

type 'info module_ = ('info modulefield, location) annotated list

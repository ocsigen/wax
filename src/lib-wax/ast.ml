type ('desc, 'info) annotated = ('desc, 'info) Wax_utils.Ast.annotated = {
  desc : 'desc;
  info : 'info;
}

type location = Wax_utils.Ast.location = {
  loc_start : Lexing.position;
  loc_end : Lexing.position;
}

let no_loc = Wax_utils.Ast.no_loc

type ident = (string, location) annotated

include Wax_wasm.Ast.Make_types (struct
  type idx = ident

  (* Each element carries a source location spanning the whole entry (e.g. a
     struct field [name: type]), so a trailing comment can attach to it even
     when the name is absent or synthesized. *)
  type 'a annotated_array = (ident * 'a, location) annotated array
  type 'a opt_annotated_array = (ident option * 'a, location) annotated array
end)

(* A [..] splice at the head of a struct definition inherits the supertype's
   fields. It is carried through the AST as a sentinel field whose name is
   [splice_field_name] — not a valid identifier, so it never collides with a real
   field. Typing replaces it with the supertype's fields; the printer renders it
   back as [..]. Its field type is a placeholder and is never inspected. *)
let splice_field_name = ".."

let is_splice_field (f : (ident * fieldtype, location) annotated) =
  String.equal (fst f.desc).desc splice_field_name

let splice_field loc : (ident * fieldtype, location) annotated =
  {
    desc =
      ( { desc = splice_field_name; info = loc },
        { mut = false; typ = Value I32 } );
    info = loc;
  }

type signage = Wax_wasm.Ast.signage = Signed | Unsigned
type unop = Neg | Pos | Not

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

let format_signed_type typ signage strict =
  Printf.sprintf "%s_%s%s"
    (match typ with
    | `I32 -> "i32"
    | `I64 -> "i64"
    | `F32 -> "f32"
    | `F64 -> "f64")
    (match signage with Signed -> "s" | Unsigned -> "u")
    (if strict then "_strict" else "")

type catch =
  | Catch of ident * label
  | CatchRef of ident * label
  | CatchAll of label
  | CatchAllRef of label

type on_clause = OnLabel of ident * label | OnSwitch of ident

(* A [match] arm pattern: a (optionally bound) reference-type test, or a null
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
         iteration, including when the body branches to the loop label
         ([continue]). Lowered so a [continue] runs it before re-testing. *)
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
     [align]/[lane] immediates of a memory access. Produced by the parser only
     as a direct element of a [Call]/[TailCall] argument list; typing rejects
     it anywhere else. *)
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
     which abbreviates [{x: x}] (the value is taken from the like-named
     local/global). Typing resolves the pun to the explicit [Get] before
     lowering; the printer renders [None] back as the shorthand. *)
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
  (* Branch-hinting proposal: wraps a conditional branch ([if], [br_if], or a
     [br_on_*]) with its hint ([true] = likely taken, [false] = unlikely). It has
     no runtime effect; on lowering the hint is emitted into the
     [metadata.code.branch_hint] section at the wrapped instruction's offset. *)
  | Hinted of (* likely *) bool * 'info instr
  | Throw of ident * 'info instr option
  | ThrowRef of 'info instr
  | ContNew of ident * 'info instr
  | ContBind of ident * ident * 'info instr list
  | Suspend of ident * 'info instr list
  | Resume of ident * on_clause list * 'info instr list
  | ResumeThrow of ident * ident * on_clause list * 'info instr list
  | ResumeThrowRef of ident * on_clause list * 'info instr list
  | Switch of ident * ident * 'info instr list
  | Return of 'info instr option
  | Sequence of 'info instr list
  | Select of 'info instr * 'info instr * 'info instr
  | If_annotation of {
      cond : Wax_wasm.Ast.cond;
      then_body : ('info instr list, location) annotated;
      else_body : ('info instr list, location) annotated option;
    }

and 'info instr = ('info instr_desc, 'info) annotated

(* An attribute is a name with an optional value expression and an optional
   conditional-compilation guard: [#[export = "f"]] carries a value, [#[start]]
   does not, and [#[export = "f", if not(portable)]] carries a guard that makes
   just this export conditional (independent of the field's own reachability).
   Only [export] may be guarded. The guard is located at its [if] keyword, to
   anchor a diagnostic. *)
type attributes =
  (string
  * location instr option
  * (Wax_wasm.Ast.cond, location) annotated option)
  list

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

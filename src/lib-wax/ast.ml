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
  | Block of { label : label option; typ : functype; block : 'info instr list }
  | Loop of { label : label option; typ : functype; block : 'info instr list }
  | While of {
      label : label option;
      cond : 'info instr;
      block : 'info instr list;
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
      block : 'info instr list;
    }
  | Try of {
      label : label option;
      typ : functype;
      block : 'info instr list;
      catches : (ident * 'info instr list) list;
      catch_all : 'info instr list option;
    }
  | Unreachable
  | Nop
  | Hole
  | Null
  | Get of ident
  (* A qualified name [namespace::member], used as the callee of a built-in
     intrinsic call such as [i64::add128(...)]. *)
  | Path of ident * ident
  | Set of ident option * 'info instr
  | Tee of ident * 'info instr
  | Call of 'info instr * 'info instr list
  | TailCall of 'info instr * 'info instr list
  | Char of Uchar.t
  | String of ident option * string
  | Int of string
  | Float of string
  | Cast of 'info instr * casttype
  | Test of 'info instr * reftype
  | NonNull of 'info instr
  | Struct of ident option * (ident * 'info instr) list
  | StructDefault of ident option
  | StructGet of 'info instr * ident
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
      arms : (label * 'info instr list) list;
    }
  | Match of {
      scrutinee : 'info instr;
      arms : (match_pattern * 'info instr list) list;
      default : 'info instr list;
    }
  | Br_on_null of label * 'info instr
  | Br_on_non_null of label * 'info instr
  | Br_on_cast of label * reftype * 'info instr
  | Br_on_cast_fail of label * reftype * 'info instr
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
      then_body : 'info instr list;
      else_body : 'info instr list option;
    }

and 'info instr = ('info instr_desc, 'info) annotated

(* An attribute is a name with an optional value expression: [#[export = "f"]]
   carries a value, [#[start]] does not. *)
type attributes = (string * location instr option) list

type 'info memdata = {
  data_name : ident option;
  offset : 'info instr;
  init : string;
}

type 'info datamode = Passive | Active of ident * 'info instr
type 'info elemmode = EPassive | EActive of ident * 'info instr

type 'info modulefield =
  | Type of rectype
  | Fundecl of {
      name : ident;
      typ : ident option;
      sign : functype option;
      attributes : attributes;
    }
  | Func of {
      name : ident;
      typ : ident option;
      sign : functype option;
      body : label option * 'info instr list;
      attributes : attributes;
    }
  | GlobalDecl of {
      name : ident;
      mut : bool;
      typ : valtype;
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
      data : 'info memdata list;
      attributes : attributes;
    }
  | Data of {
      name : ident option;
      mode : 'info datamode;
      init : string;
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
  | Group of {
      attributes : attributes;
      fields : ('info modulefield, location) annotated list;
    }
  | Conditional of {
      cond : Wax_wasm.Ast.cond;
      then_fields : ('info modulefield, location) annotated list;
      else_fields : ('info modulefield, location) annotated list option;
    }

type 'info module_ = ('info modulefield, location) annotated list

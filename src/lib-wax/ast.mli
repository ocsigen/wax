(** Wax Abstract Syntax Tree. *)

type ('desc, 'info) annotated = ('desc, 'info) Utils.Ast.annotated = {
  desc : 'desc;
  info : 'info;
}

type location = Utils.Ast.location = {
  loc_start : Lexing.position;
  loc_end : Lexing.position;
}

val no_loc : 'desc -> ('desc, location) annotated

type ident = (string, location) annotated
(** An identifier with its source location. *)

include module type of Wasm.Ast.Make_types (struct
  type idx = ident
  type 'a annotated_array = (ident * 'a) array
  type 'a opt_annotated_array = (ident option * 'a) array
end)

(** Signage for integer operations. *)
type signage = Wasm.Ast.signage = Signed | Unsigned

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

type 'info instr_desc =
  | Block of { label : label option; typ : functype; block : 'info instr list }
  | Loop of { label : label option; typ : functype; block : 'info instr list }
  | If of {
      label : label option;
      typ : functype;
      cond : 'info instr;
      if_block : 'info instr list;
      else_block : 'info instr list option;
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
  | BinOp of binop * 'info instr * 'info instr
  | UnOp of unop * 'info instr
  | Let of (ident option * valtype option) list * 'info instr option
  | Br of label * 'info instr option
  | Br_if of label * 'info instr
  | Br_table of label list * 'info instr
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
      cond : Wasm.Ast.cond;
      then_body : 'info instr list;
      else_body : 'info instr list option;
    }

and 'info instr = ('info instr_desc, 'info) annotated

type attributes = (string * location instr) list

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
      limits : (Utils.Uint64.t * Utils.Uint64.t option) option;
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
      reftype : reftype;
      limits : (Utils.Uint64.t * Utils.Uint64.t option) option;
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
      cond : Wasm.Ast.cond;
      then_fields : ('info modulefield, location) annotated list;
      else_fields : ('info modulefield, location) annotated list option;
    }

type 'info module_ = ('info modulefield, location) annotated list

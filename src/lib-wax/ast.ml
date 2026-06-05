type ('desc, 'info) annotated = ('desc, 'info) Utils.Ast.annotated = {
  desc : 'desc;
  info : 'info;
}

type location = Utils.Ast.location = {
  loc_start : Lexing.position;
  loc_end : Lexing.position;
}

let no_loc = Utils.Ast.no_loc

type ident = (string, location) annotated

include Wasm.Ast.Make_types (struct
  type idx = ident
  type 'a annotated_array = (ident * 'a) array
  type 'a opt_annotated_array = (ident option * 'a) array
end)

type signage = Wasm.Ast.signage = Signed | Unsigned
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

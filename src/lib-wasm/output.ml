open Wax_utils.Colors
module Printer = Wax_utils.Printer
module Trivia = Wax_utils.Trivia
module Styled = Wax_utils.Styled_printer
module Uint32 = Wax_utils.Uint32
module Uint64 = Wax_utils.Uint64
open Ast.Text

let get_theme use_color =
  if use_color then
    {
      keyword = Ansi.bold ^ Ansi.magenta;
      instruction = Ansi.white;
      attribute = Ansi.magenta;
      type_ = Ansi.red;
      identifier = Ansi.yellow;
      constant = Ansi.bold ^ Ansi.blue;
      string = Ansi.green;
      annotation = Ansi.blue;
      comment = Ansi.grey;
      punctuation = Ansi.cyan;
      operator = "";
      reset = Ansi.reset;
    }
  else no_color

type format = Compact | Expansive | Hybrid | Adaptive
type ctx = { base : Styled.t; format : format; indent_level : int }

let _ = (Compact, Hybrid, Adaptive)

(* The styling and trivia plumbing is shared with the Wax printer in
   [Wax_utils.Styled_printer]; only [format]/[indent_level] are specific here. *)
let print_styled ctx style ?(len = None) text =
  Styled.print_styled ctx.base style ~len text

let print_trivia ctx lst = Styled.print_trivia ctx.base lst
let get_trivia ctx loc = Styled.get_trivia ctx.base loc
let atomic_node ctx loc f = Styled.atomic_node ctx.base loc f

let string_node ctx loc style len s =
  atomic_node ctx loc @@ fun () -> print_styled ctx style ~len s

type sexp =
  | Atom of {
      loc : Ast.location option;
      len : int option;
      style : style;
      s : string;
    }
  | List of Ast.location option * sexp list
  | Block of {
      loc : Ast.location option;
      l : sexp list;
      transparent : bool;
      bk : [ `Box | `Hov | `Hv ];
    }
  | Vertical_block of Ast.location option * sexp list
  | Structured_block of Ast.location option * structure list

and structure = Delimiter of sexp | Contents of sexp list

let rec format_sexp in_block depth first ctx s =
  let p = ctx.base.printer in
  match s with
  | Atom { loc; len; style; s } -> string_node ctx loc style len s
  | List (loc, l)
    when (ctx.format = Hybrid && depth > 1) || ctx.format = Compact ->
      let trivia = get_trivia ctx loc in
      print_trivia ctx trivia.before;
      Printer.box p (fun () ->
          print_styled ctx Punctuation "(";
          Printer.hvbox p ~indent:(ctx.indent_level - 1) (fun () ->
              List.iteri
                (fun i v ->
                  if i > 0 then Printer.space p ();
                  format_sexp in_block depth (i = 0) ctx v)
                l);
          print_trivia ctx trivia.within;
          print_styled ctx Punctuation ")";
          print_trivia ctx trivia.after)
  | List (loc, l) ->
      let trivia = get_trivia ctx loc in
      print_trivia ctx trivia.before;
      (if (not in_block) && ctx.format = Expansive then Printer.vbox
       else Printer.hvbox) p (fun () ->
          print_styled ctx Punctuation "(";
          Printer.indent p ctx.indent_level (fun () ->
              List.iteri
                (fun i v ->
                  if i > 0 then Printer.space p ();
                  format_sexp in_block (depth + 1) (i = 0) ctx v)
                l);
          Printer.cut p ();
          print_trivia ctx trivia.within;
          Printer.box p (fun () ->
              print_styled ctx Punctuation ")";
              print_trivia ctx trivia.after))
  | Block { l; transparent; loc; bk } ->
      let trivia = get_trivia ctx loc in
      let indent = if first then ctx.indent_level - 1 else 0 in
      print_trivia ctx trivia.before;
      (match bk with
      | `Hv -> Printer.hvbox
      | `Hov -> Printer.hovbox
      | `Box ->
          if (not in_block) && transparent && ctx.format = Expansive then
            Printer.vbox
          else Printer.box) p ~indent (fun () ->
          List.iteri
            (fun i v ->
              if i > 0 then Printer.space p ();
              format_sexp
                (in_block || not transparent)
                depth
                (first && i = 0)
                ctx v)
            l;
          print_trivia ctx trivia.within;
          print_trivia ctx trivia.after)
  | Vertical_block (loc, l) ->
      let trivia = get_trivia ctx loc in
      (* Printed before the box opens so a comment leading the first element
         merges with the line break before the block instead of doubling it
         into a blank line. *)
      print_trivia ctx trivia.before;
      Printer.vbox p (fun () ->
          List.iteri
            (fun i v ->
              if i > 0 then Printer.space p ();
              format_sexp in_block depth false ctx v)
            l;
          print_trivia ctx trivia.within;
          print_trivia ctx trivia.after)
  | Structured_block (loc, l) ->
      let trivia = get_trivia ctx loc in
      print_trivia ctx trivia.before;
      Printer.hvbox p (fun () ->
          let len = List.length l in
          List.iteri
            (fun i s ->
              match s with
              | Delimiter d ->
                  if i > 0 then Printer.space p ();
                  if i = len - 1 then print_trivia ctx trivia.within;
                  Printer.box p (fun () ->
                      format_sexp in_block depth false ctx d;
                      print_trivia ctx trivia.after)
              | Contents [] -> ()
              | Contents l ->
                  Printer.indent p ctx.indent_level (fun () ->
                      Printer.space p ();
                      Printer.hvbox p (fun () ->
                          List.iteri
                            (fun i v ->
                              if i > 0 then Printer.space p ();
                              format_sexp in_block depth false ctx v)
                            l)))
            l)

let atom ~style ?loc s = Atom { loc; len = None; style; s }
let keyword ?loc s = atom ~style:Keyword ?loc s
let instruction ?loc s = atom ~style:Instruction ?loc s
let type_ ?loc s = atom ~style:Type ?loc s
let list ?loc l = List (loc, l)

let block ?loc ?(transparent = false) ?(bk = `Box) l =
  Block { loc; l; transparent; bk }

let structured_block ?loc l = Structured_block (loc, l)
let option f x = match x with None -> [] | Some x -> f x
let u32 ~style ?loc i = atom ~style ?loc (Uint32.to_string i)
let u64 ?loc i = atom ?loc (Uint64.to_string i)
let escape_string = Misc.escape_string

let id ?(style = Identifier) ?loc x =
  if Lexer.is_valid_identifier x then
    Atom
      {
        loc;
        style;
        len = Some (Wax_utils.Unicode.terminal_width x + 1);
        s = "$" ^ x;
      }
  else
    let i, s = escape_string x in
    Atom { loc; style; len = Some (i + 3); s = "$\"" ^ s ^ "\"" }

let opt_id = option (fun i -> [ id ~loc:i.Ast.info i.Ast.desc ])

let index ?(style = Identifier) x =
  let loc = x.Ast.info in
  match x.desc with Num i -> u32 ~style ~loc i | Id s -> id ~style ~loc s

let heaptype (ty : heaptype) =
  match heaptype_keyword ty with
  | Some kw -> type_ kw
  | None -> ( match ty with Type t -> index t | _ -> assert false)

let reftype { nullable; typ } =
  match (nullable, typ) with
  | true, Func -> type_ "funcref"
  | true, NoFunc -> type_ "nullfuncref"
  | true, Extern -> type_ "externref"
  | true, NoExtern -> type_ "nullexternref"
  | true, Any -> type_ "anyref"
  | true, Eq -> type_ "eqref"
  | true, I31 -> type_ "i31ref"
  | true, Struct -> type_ "structref"
  | true, Array -> type_ "arrayref"
  | true, None_ -> type_ "nullref"
  | _ ->
      let r = [ heaptype typ ] in
      list (type_ "ref" :: (if nullable then type_ "null" :: r else r))

let valtype (t : valtype) =
  match t with
  | I32 -> type_ "i32"
  | I64 -> type_ "i64"
  | F32 -> type_ "f32"
  | F64 -> type_ "f64"
  | V128 -> type_ "v128"
  | Ref ty -> reftype ty

let packedtype t = match t with I8 -> type_ "i8" | I16 -> type_ "i16"

let make_list ~kind ?(always = false) name f l =
  if (not always) && l = [] then [] else [ list (kind name :: f l) ]

let valtype_list name tl =
  make_list ~kind:keyword name (fun tl -> List.map valtype tl) tl

let functype { params; results } =
  let params = Array.to_list params in
  let params_sexp =
    if List.for_all (fun p -> fst p.Ast.desc = None) params then
      valtype_list "param" (List.map (fun p -> snd p.Ast.desc) params)
    else
      (* Anchor each [(param …)] at the parameter's own location (the name is
         anchored separately via [opt_id]), so a trailing comment attaches to
         the parameter. *)
      List.map
        (fun p ->
          let i, t = p.Ast.desc in
          list ~loc:p.Ast.info (keyword "param" :: (opt_id i @ [ valtype t ])))
        params
  in
  params_sexp @ valtype_list "result" (Array.to_list results)

let storagetype typ =
  match typ with Value typ -> valtype typ | Packed typ -> packedtype typ

let mut_type f { mut; typ } =
  if mut then list [ keyword "mut"; f typ ] else f typ

let fieldtype typ = mut_type (fun t -> storagetype t) typ
let globaltype typ = mut_type (fun t -> valtype t) typ

let comptype (typ : comptype) =
  match typ with
  | Func ty -> list (keyword "func" :: functype ty)
  | Struct l ->
      list
        (keyword "struct"
        :: List.map
             (fun fld ->
               let nm, f = fld.Ast.desc in
               list ~loc:fld.Ast.info
                 (keyword "field" :: (opt_id nm @ [ fieldtype f ])))
             (Array.to_list l))
  | Array ty -> list [ keyword "array"; fieldtype ty ]
  | Cont idx -> list [ keyword "cont"; index idx ]

let typeuse idx = [ list [ keyword "type"; index idx ] ]
let typeuse' (idx, typ) = option typeuse idx @ option functype typ

let blocktype =
  option @@ fun t ->
  match t with
  | Valtype t -> [ list [ keyword "result"; valtype t ] ]
  | Typeuse t -> typeuse' t

let address_type at = match at with `I32 -> [] | `I64 -> [ keyword "i64" ]

let limits { Ast.desc = { mi; ma; address_type = at }; _ } =
  address_type at
  @ (u64 ~style:Constant mi :: option (fun i -> [ u64 ~style:Constant i ]) ma)

let tabletype { limits = l; reftype = typ } = limits l @ [ reftype typ ]

let quoted_string s =
  let loc = s.Ast.info in
  let i, s = escape_string s.Ast.desc in
  Atom
    { loc = Some loc; style = String; len = Some (i + 2); s = "\"" ^ s ^ "\"" }

let exports l =
  List.map (fun name -> list [ keyword "export"; quoted_string name ]) l

let type_prefix op nm =
  (match op with
    | I32 _ -> "i32."
    | I64 _ -> "i64."
    | F32 _ -> "f32."
    | F64 _ -> "f64.")
  ^ nm

let signage op (s : signage) =
  op ^ match s with Signed -> "_s" | Unsigned -> "_u"

let size sz =
  match sz with `F32 -> "f32" | `F64 -> "f64" | `I32 -> "i32" | `I64 -> "i64"

let int_un_op width op =
  match op with
  | Clz -> "clz"
  | Ctz -> "ctz"
  | Popcnt -> "popcnt"
  | Eqz -> "eqz"
  | Trunc (sz, s) -> signage ("trunc_" ^ size sz) s
  | TruncSat (sz, s) -> signage ("trunc_sat_" ^ size sz) s
  | Reinterpret -> "reinterpret_f" ^ width
  | ExtendS sz -> (
      match sz with
      | `_8 -> "extend8_s"
      | `_16 -> "extend16_s"
      | `_32 -> "extend32_s")

let int_bin_op _ (op : int_bin_op) =
  match op with
  | Add -> "add"
  | Sub -> "sub"
  | Mul -> "mul"
  | Div s -> signage "div" s
  | Rem s -> signage "rem" s
  | And -> "and"
  | Or -> "or"
  | Xor -> "xor"
  | Shl -> "shl"
  | Shr s -> signage "shr" s
  | Rotl -> "rotl"
  | Rotr -> "rotr"
  | Eq -> "eq"
  | Ne -> "ne"
  | Lt s -> signage "lt" s
  | Gt s -> signage "gt" s
  | Le s -> signage "le" s
  | Ge s -> signage "ge" s

let float_un_op sz op =
  match op with
  | Neg -> "neg"
  | Abs -> "abs"
  | Ceil -> "ceil"
  | Floor -> "floor"
  | Trunc -> "trunc"
  | Nearest -> "nearest"
  | Sqrt -> "sqrt"
  | Convert (`I32, s) -> signage "convert_i32" s
  | Convert (`I64, s) -> signage "convert_i64" s
  | Reinterpret -> "reinterpret_i" ^ sz

let float_bin_op _ op =
  match op with
  | Add -> "add"
  | Sub -> "sub"
  | Mul -> "mul"
  | Div -> "div"
  | Min -> "min"
  | Max -> "max"
  | CopySign -> "copysign"
  | Eq -> "eq"
  | Ne -> "ne"
  | Lt -> "lt"
  | Gt -> "gt"
  | Le -> "le"
  | Ge -> "ge"

let select i32 i64 f32 f64 _ op =
  match op with
  | I32 x -> i32 "32" x
  | I64 x -> i64 "64" x
  | F32 x -> f32 "32" x
  | F64 x -> f64 "64" x

let memidx i = if i.Ast.desc = Num Uint32.zero then [] else [ index i ]

let memarg align' { offset; align } =
  (if offset = Uint64.zero then []
   else [ atom ~style:Attribute ("offset=" ^ Uint64.to_string offset) ])
  @
  if align = align' then []
  else
    [ atom ~style:Attribute (Printf.sprintf "align=" ^ Uint64.to_string align) ]

let vec_shape = function
  | I8x16 -> "i8x16"
  | I16x8 -> "i16x8"
  | I32x4 -> "i32x4"
  | I64x2 -> "i64x2"
  | F32x4 -> "f32x4"
  | F64x2 -> "f64x2"

let vec_un_op op =
  match op with
  | VecNeg _ -> "neg"
  | VecAbs _ -> "abs"
  | VecSqrt _ -> "sqrt"
  | VecNot -> "not"
  | VecTruncSat (f, s) ->
      let f_str = match f with `F32 -> "f32x4" | `F64 -> "f64x2" in
      signage ("trunc_sat_" ^ f_str) s
  | VecConvert (f, s) ->
      let low = match f with `F32 -> "" | `F64 -> "low_" in
      signage ("convert_" ^ low ^ "i32x4") s
  | VecExtend (h, sz, s) ->
      let h_str = match h with `Low -> "low" | `High -> "high" in
      let sz_str =
        match sz with `_8 -> "i8x16" | `_16 -> "i16x8" | `_32 -> "i32x4"
      in
      signage ("extend_" ^ h_str ^ "_" ^ sz_str) s
  | VecPromote -> "promote_low_f32x4"
  | VecDemote -> "demote_f64x2_zero"
  | VecCeil _ -> "ceil"
  | VecFloor _ -> "floor"
  | VecTrunc _ -> "trunc"
  | VecNearest _ -> "nearest"
  | VecPopcnt -> "popcnt"
  | VecExtAddPairwise (s, sz) ->
      signage
        ("extadd_pairwise_" ^ match sz with `I8 -> "i8x16" | `I16 -> "i16x8")
        s
  (* Relaxed SIMD *)
  | VecRelaxedTrunc s -> signage "relaxed_trunc_f32x4" s
  | VecRelaxedTruncZero s -> signage "relaxed_trunc_f64x2" s ^ "_zero"

let vec_bin_op op =
  match op with
  | VecAdd _ -> "add"
  | VecSub _ -> "sub"
  | VecMul _ -> "mul"
  | VecDiv _ -> "div"
  | VecMin (s, _) ->
      "min" ^ Option.fold ~none:"" ~some:(fun s -> signage "" s) s
  | VecMax (s, _) ->
      "max" ^ Option.fold ~none:"" ~some:(fun s -> signage "" s) s
  | VecPMin _ -> "pmin"
  | VecPMax _ -> "pmax"
  | VecAvgr _ -> "avgr_u"
  | VecQ15MulrSat -> "q15mulr_sat_s"
  | VecAddSat (s, _) -> signage "add_sat" s
  | VecSubSat (s, _) -> signage "sub_sat" s
  | VecDot -> "dot_i16x8_s"
  | VecEq _ -> "eq"
  | VecNe _ -> "ne"
  | VecLt (s, shape) -> (
      match (shape, s) with
      | (I8x16 | I16x8 | I32x4 | I64x2), Some Signed -> "lt_s"
      | (I8x16 | I16x8 | I32x4), Some Unsigned -> "lt_u"
      | (F32x4 | F64x2), None -> "lt"
      | _ -> assert false)
  | VecGt (s, shape) -> (
      match (shape, s) with
      | (I8x16 | I16x8 | I32x4 | I64x2), Some Signed -> "gt_s"
      | (I8x16 | I16x8 | I32x4), Some Unsigned -> "gt_u"
      | (F32x4 | F64x2), None -> "gt"
      | _ -> assert false)
  | VecLe (s, shape) -> (
      match (shape, s) with
      | (I8x16 | I16x8 | I32x4 | I64x2), Some Signed -> "le_s"
      | (I8x16 | I16x8 | I32x4), Some Unsigned -> "le_u"
      | (F32x4 | F64x2), None -> "le"
      | _ -> assert false)
  | VecGe (s, shape) -> (
      match (shape, s) with
      | (I8x16 | I16x8 | I32x4 | I64x2), Some Signed -> "ge_s"
      | (I8x16 | I16x8 | I32x4), Some Unsigned -> "ge_u"
      | (F32x4 | F64x2), None -> "ge"
      | _ -> assert false)
  | VecAnd -> "and"
  | VecOr -> "or"
  | VecXor -> "xor"
  | VecAndNot -> "andnot"
  | VecNarrow (s, sh) ->
      let in_shape = match sh with `I8 -> "i16x8" | `I16 -> "i32x4" in
      signage ("narrow_" ^ in_shape) s
  | VecSwizzle -> "swizzle"
  | VecExtMulLow (s, sh) ->
      let in_shape =
        match sh with `_8 -> "i8x16" | `_16 -> "i16x8" | `_32 -> "i32x4"
      in
      signage ("extmul_low_" ^ in_shape) s
  | VecExtMulHigh (s, sh) ->
      let in_shape =
        match sh with `_8 -> "i8x16" | `_16 -> "i16x8" | `_32 -> "i32x4"
      in
      signage ("extmul_high_" ^ in_shape) s
  (* Relaxed SIMD *)
  | VecRelaxedSwizzle -> "relaxed_swizzle"
  | VecRelaxedMin _ -> "relaxed_min"
  | VecRelaxedMax _ -> "relaxed_max"
  | VecRelaxedQ15Mulr -> "relaxed_q15mulr_s"
  | VecRelaxedDot -> "relaxed_dot_i8x16_i7x16_s"

let vec_tern_op op =
  match op with
  | VecRelaxedMAdd _ -> "relaxed_madd"
  | VecRelaxedNMAdd _ -> "relaxed_nmadd"
  | VecRelaxedLaneSelect _ -> "relaxed_laneselect"
  | VecRelaxedDotAdd -> "relaxed_dot_i8x16_i7x16_add_s"

let vec_test_op op =
  match op with
  | AnyTrue -> "v128.any_true"
  | AllTrue shape -> vec_shape shape ^ ".all_true"

let vec_shift_op op =
  match op with
  | Shl shape -> vec_shape shape ^ ".shl"
  | Shr (s, shape) -> signage (vec_shape shape ^ ".shr") s

let vec_bitmask_op_shape = function Bitmask s -> s

let vec_const { Wax_utils.V128.shape; components } =
  keyword
    (match shape with
    | I8x16 -> "i8x16"
    | I16x8 -> "i16x8"
    | I32x4 -> "i32x4"
    | I64x2 -> "i64x2"
    | F32x4 -> "f32x4"
    | F64x2 -> "f64x2")
  :: List.map (atom ~style:Constant) components

let vec_load_op_nat_align = function
  | Load128 -> 16
  | Load8x8S | Load8x8U | Load16x4S | Load16x4U | Load32x2S | Load32x2U
  | Load64Zero ->
      8
  | Load32Zero -> 4

let vec_lane_op_nat_align = function
  | `I8 -> 1
  | `I16 -> 2
  | `I32 -> 4
  | `I64 -> 8

let num_type_nat_align = function NumI32 | NumF32 -> 4 | NumI64 | NumF64 -> 8
let storage_type_nat_align = function `I8 -> 1 | `I16 -> 2 | `I32 -> 4

let catches l =
  List.map
    (fun c ->
      match c with
      | Catch (x, l) -> list [ keyword "catch"; index x; index l ]
      | CatchRef (x, l) -> list [ keyword "catch_ref"; index x; index l ]
      | CatchAll l -> list [ keyword "catch_all"; index l ]
      | CatchAllRef l -> list [ keyword "catch_all_ref"; index l ])
    l

let on_clauses l =
  List.map
    (fun c ->
      match c with
      | OnLabel (x, l) -> list [ keyword "on"; index x; index l ]
      | OnSwitch x -> list [ keyword "on"; index x; keyword "switch" ])
    l

let cmp_op_string (op : Ast.cmp_op) =
  match op with
  | Eq -> "="
  | Ne -> "<>"
  | Lt -> "<"
  | Gt -> ">"
  | Le -> "<="
  | Ge -> ">="

let rec cond_doc (c : Ast.cond) =
  match c with
  | Cond_var v -> id ~style:Annotation ~loc:v.Ast.info v.Ast.desc
  | Cond_string s ->
      let i, str = escape_string s.Ast.desc in
      Atom
        {
          loc = Some s.Ast.info;
          style = Annotation;
          len = Some (i + 2);
          s = "\"" ^ str ^ "\"";
        }
  | Cond_version (a, b, c) ->
      list
        (List.map
           (fun n -> atom ~style:Annotation (string_of_int n))
           [ a; b; c ])
  | Cond_and l -> list (atom ~style:Annotation "and" :: List.map cond_doc l)
  | Cond_or l -> list (atom ~style:Annotation "or" :: List.map cond_doc l)
  | Cond_not e -> list [ atom ~style:Annotation "not"; cond_doc e ]
  | Cond_cmp (op, a, b) ->
      list [ atom ~style:Annotation (cmp_op_string op); cond_doc a; cond_doc b ]

let rec instr i =
  let loc = i.Ast.info in
  match i.Ast.desc with
  | ExternConvertAny -> instruction ~loc "extern.convert_any"
  | AnyConvertExtern -> instruction ~loc "any.convert_extern"
  | Const op ->
      block ~loc
        [
          instruction (type_prefix op "const");
          atom ~style:Constant
            (select
               (fun _ i -> i)
               (fun _ i -> i)
               (fun _ i -> i)
               (fun _ i -> i)
               (fun _ i -> i)
               op);
        ]
  | UnOp (I32 op) -> instruction ~loc ("i32." ^ int_un_op "32" op)
  | UnOp (I64 op) -> instruction ~loc ("i64." ^ int_un_op "64" op)
  | UnOp (F32 op) -> instruction ~loc ("f32." ^ float_un_op "32" op)
  | UnOp (F64 op) -> instruction ~loc ("f64." ^ float_un_op "64" op)
  | BinOp (I32 op) -> instruction ~loc ("i32." ^ int_bin_op "32" op)
  | BinOp (I64 op) -> instruction ~loc ("i64." ^ int_bin_op "64" op)
  | BinOp (F32 op) -> instruction ~loc ("f32." ^ float_bin_op "32" op)
  | BinOp (F64 op) -> instruction ~loc ("f64." ^ float_bin_op "64" op)
  | Add128 -> instruction ~loc "i64.add128"
  | Sub128 -> instruction ~loc "i64.sub128"
  | MulWide s -> instruction ~loc (signage "i64.mul_wide" s)
  | I32WrapI64 -> instruction ~loc "i32.wrap_i64"
  | I64ExtendI32 s -> instruction ~loc (signage "i64.extend_i32" s)
  | F32DemoteF64 -> instruction ~loc "f32.demote_f64"
  | F64PromoteF32 -> instruction ~loc "f64.promote_f32"
  | VecConst c -> block ~loc (instruction "v128.const" :: vec_const c)
  | VecShuffle lanes ->
      block ~loc
        (instruction "i8x16.shuffle"
        :: List.init 16 (fun i ->
            atom ~style:Constant (Int.to_string (Char.code lanes.[i]))))
  | VecExtract (op, s, lane) ->
      block ~loc
        [
          instruction ~loc
            (vec_shape op ^ ".extract_lane"
            ^ match s with Some s -> signage "" s | None -> "");
          atom ~style:Constant (Int.to_string lane);
        ]
  | VecReplace (op, lane) ->
      block
        [
          instruction ~loc (vec_shape op ^ ".replace_lane");
          atom ~style:Constant (Int.to_string lane);
        ]
  | VecSplat sh -> instruction ~loc (vec_shape sh ^ ".splat")
  | VecUnOp op ->
      let shape_str =
        match op with
        | VecNeg s | VecAbs s -> vec_shape s
        | VecPopcnt -> "i8x16"
        | VecNot -> "v128"
        | VecTruncSat _ -> vec_shape I32x4
        | VecCeil f
        | VecFloor f
        | VecTrunc f
        | VecNearest f
        | VecSqrt f
        | VecConvert (f, _) ->
            vec_shape (match f with `F32 -> F32x4 | `F64 -> F64x2)
        | VecExtend (_, sz, _) ->
            vec_shape
              (match sz with `_8 -> I16x8 | `_16 -> I32x4 | `_32 -> I64x2)
        | VecPromote -> vec_shape F64x2
        | VecDemote -> vec_shape F32x4
        | VecExtAddPairwise (_, sz) ->
            vec_shape (match sz with `I8 -> I16x8 | `I16 -> I32x4)
        | VecRelaxedTrunc _ -> vec_shape I32x4
        | VecRelaxedTruncZero _ -> vec_shape I32x4
      in
      instruction ~loc (shape_str ^ "." ^ vec_un_op op)
  | VecBinOp op ->
      let shape_str =
        match op with
        | VecAdd s
        | VecSub s
        | VecMul s
        | VecMin (_, s)
        | VecMax (_, s)
        | VecEq s
        | VecNe s
        | VecLt (_, s)
        | VecGt (_, s)
        | VecLe (_, s)
        | VecGe (_, s) ->
            vec_shape s
        | VecDiv s | VecPMin s | VecPMax s -> (
            match s with `F32 -> "f32x4" | `F64 -> "f64x2")
        | VecDot -> "i32x4"
        | VecNarrow (_, s) | VecAvgr s | VecAddSat (_, s) | VecSubSat (_, s)
          -> (
            match s with `I8 -> "i8x16" | `I16 -> "i16x8")
        | VecAnd | VecOr | VecXor | VecAndNot -> "v128"
        | VecSwizzle | VecRelaxedSwizzle -> "i8x16"
        | VecQ15MulrSat -> "i16x8"
        | VecRelaxedMin s | VecRelaxedMax s -> vec_shape s
        | VecRelaxedQ15Mulr -> "i16x8"
        | VecRelaxedDot -> "i16x8"
        | VecExtMulLow (_, s) | VecExtMulHigh (_, s) ->
            vec_shape
              (match s with `_8 -> I16x8 | `_16 -> I32x4 | `_32 -> I64x2)
      in
      instruction ~loc (shape_str ^ "." ^ vec_bin_op op)
  | VecTest op -> instruction ~loc (vec_test_op op)
  | VecShift op -> instruction ~loc (vec_shift_op op)
  | VecBitmask op ->
      instruction ~loc (vec_shape (vec_bitmask_op_shape op) ^ ".bitmask")
  | VecTernOp op ->
      let shape_str =
        match op with
        | VecRelaxedMAdd s | VecRelaxedNMAdd s -> (
            match s with `F32 -> "f32x4" | `F64 -> "f64x2")
        | VecRelaxedLaneSelect s -> vec_shape s
        | VecRelaxedDotAdd -> "i32x4"
      in
      instruction ~loc (shape_str ^ "." ^ vec_tern_op op)
  | VecBitselect -> instruction ~loc "v128.bitselect"
  | VecLoad (i, op, m) ->
      block ~loc
        (instruction
           (match op with
           | Load128 -> "v128.load"
           | Load8x8S -> "v128.load8x8_s"
           | Load8x8U -> "v128.load8x8_u"
           | Load16x4S -> "v128.load16x4_s"
           | Load16x4U -> "v128.load16x4_u"
           | Load32x2S -> "v128.load32x2_s"
           | Load32x2U -> "v128.load32x2_u"
           | Load32Zero -> "v128.load32_zero"
           | Load64Zero -> "v128.load64_zero")
        :: (memidx i @ memarg (Uint64.of_int (vec_load_op_nat_align op)) m))
  | VecStore (i, m) ->
      block ~loc
        (instruction "v128.store" :: (memidx i @ memarg (Uint64.of_int 16) m))
  | VecLoadLane (i, op, m, lane) ->
      block ~loc
        (instruction
           (Printf.sprintf "v128.load%s_lane"
              (match op with
              | `I8 -> "8"
              | `I16 -> "16"
              | `I32 -> "32"
              | `I64 -> "64"))
        :: (memidx i
           @ memarg (Uint64.of_int (vec_lane_op_nat_align op)) m
           @ [ atom ~style:Constant (Int.to_string lane) ]))
  | VecStoreLane (i, op, m, lane) ->
      block ~loc
        (instruction
           (Printf.sprintf "v128.store%s_lane"
              (match op with
              | `I8 -> "8"
              | `I16 -> "16"
              | `I32 -> "32"
              | `I64 -> "64"))
        :: (memidx i
           @ memarg (Uint64.of_int (vec_lane_op_nat_align op)) m
           @ [ atom ~style:Constant (Int.to_string lane) ]))
  | VecLoadSplat (i, op, m) ->
      block ~loc
        (instruction
           (Printf.sprintf "v128.load%s_splat"
              (match op with
              | `I8 -> "8"
              | `I16 -> "16"
              | `I32 -> "32"
              | `I64 -> "64"))
        :: (memidx i @ memarg (Uint64.of_int (vec_lane_op_nat_align op)) m))
  | Load (i, m, sz) ->
      block ~loc
        (instruction
           (Printf.sprintf "%s.load"
              (match sz with
              | NumI32 -> "i32"
              | NumI64 -> "i64"
              | NumF32 -> "f32"
              | NumF64 -> "f64"))
        :: (memidx i @ memarg (Uint64.of_int (num_type_nat_align sz)) m))
  | LoadS (i, m, sz, sz', s) ->
      block ~loc
        (instruction
           (signage
              (Printf.sprintf "%s.load%s"
                 (match sz with `I32 -> "i32" | `I64 -> "i64")
                 (match sz' with `I8 -> "8" | `I16 -> "16" | `I32 -> "32"))
              s)
        :: (memidx i @ memarg (Uint64.of_int (storage_type_nat_align sz')) m))
  | Store (i, m, sz) ->
      block ~loc
        (instruction
           (Printf.sprintf "%s.store"
              (match sz with
              | NumI32 -> "i32"
              | NumI64 -> "i64"
              | NumF32 -> "f32"
              | NumF64 -> "f64"))
        :: (memidx i @ memarg (Uint64.of_int (num_type_nat_align sz)) m))
  | StoreS (i, m, sz, sz') ->
      block ~loc
        (instruction
           (Printf.sprintf "%s.store%s"
              (match sz with `I32 -> "i32" | `I64 -> "i64")
              (match sz' with `I8 -> "8" | `I16 -> "16" | `I32 -> "32"))
        :: (memidx i @ memarg (Uint64.of_int (storage_type_nat_align sz')) m))
  | MemorySize m -> block ~loc (instruction "memory.size" :: memidx m)
  | MemoryGrow m -> block ~loc (instruction "memory.grow" :: memidx m)
  | MemoryFill m -> block ~loc (instruction "memory.fill" :: memidx m)
  | MemoryCopy (m, m') ->
      block ~loc
        (instruction "memory.copy"
        ::
        (if m.desc = Num Uint32.zero && m'.desc = Num Uint32.zero then []
         else [ index m; index m' ]))
  | MemoryInit (m, d) ->
      block ~loc (instruction "memory.init" :: (memidx m @ [ index d ]))
  | DataDrop d -> block ~loc [ instruction "data.drop"; index d ]
  | TableGet m -> block ~loc (instruction "table.get" :: memidx m)
  | TableSet m -> block ~loc (instruction "table.set" :: memidx m)
  | TableSize m -> block ~loc (instruction "table.size" :: memidx m)
  | TableGrow m -> block ~loc (instruction "table.grow" :: memidx m)
  | TableFill m -> block ~loc (instruction "table.fill" :: memidx m)
  | TableCopy (m, m') ->
      block ~loc
        (instruction "table.copy"
        ::
        (if m.desc = Num Uint32.zero && m'.desc = Num Uint32.zero then []
         else [ index m; index m' ]))
  | TableInit (m, d) ->
      block ~loc (instruction "table.init" :: (memidx m @ [ index d ]))
  | ElemDrop d -> block ~loc [ instruction "elem.drop"; index d ]
  | LocalGet i -> block ~loc [ instruction "local.get"; index i ]
  | LocalTee i -> block ~loc [ instruction "local.tee"; index i ]
  | GlobalGet i -> block ~loc [ instruction "global.get"; index i ]
  | CallIndirect (id, typ) ->
      block ~loc
        (instruction "call_indirect"
        :: ((if id.desc = Num Uint32.zero then [] else [ index id ])
           @ typeuse' typ))
  | ReturnCallIndirect (id, typ) ->
      block ~loc
        (instruction "return_call_indirect"
        :: ((if id.desc = Num Uint32.zero then [] else [ index id ])
           @ typeuse' typ))
  | Call f -> block ~loc [ instruction "call"; index f ]
  | Select t ->
      block ~loc
        (instruction "select" :: option (fun t -> valtype_list "result" t) t)
  | RefFunc i -> block ~loc [ instruction "ref.func"; index i ]
  | RefIsNull -> block ~loc [ instruction "ref.is_null" ]
  | RefAsNonNull -> block ~loc [ instruction "ref.as_non_null" ]
  | CallRef t -> block ~loc [ instruction "call_ref"; index t ]
  | RefI31 -> instruction ~loc "ref.i31"
  | I31Get s -> instruction ~loc (signage "i31.get" s)
  | ArrayNew t -> block ~loc [ instruction "array.new"; index t ]
  | ArrayNewDefault t -> block ~loc [ instruction "array.new_default"; index t ]
  | ArrayNewFixed (t, i) ->
      block ~loc
        [ instruction "array.new_fixed"; index t; u32 ~style:Constant i ]
  | ArrayNewElem (i, i') ->
      block ~loc [ instruction "array.new_elem"; index i; index i' ]
  | ArrayNewData (typ, data) ->
      block ~loc [ instruction "array.new_data"; index typ; index data ]
  | ArrayInitData (i, i') ->
      block ~loc [ instruction "array.init_data"; index i; index i' ]
  | ArrayInitElem (i, i') ->
      block ~loc [ instruction "array.init_elem"; index i; index i' ]
  | ArrayGet (None, typ) -> block ~loc [ instruction "array.get"; index typ ]
  | ArrayGet (Some s, typ) ->
      block ~loc [ instruction (signage "array.get" s); index typ ]
  | ArrayLen -> instruction ~loc "array.len"
  | ArrayCopy (i, i') ->
      block ~loc [ instruction "array.copy"; index i; index i' ]
  | ArrayFill i -> block ~loc [ instruction "array.fill"; index i ]
  | StructNew typ -> block ~loc [ instruction "struct.new"; index typ ]
  | StructNewDefault typ ->
      block ~loc [ instruction "struct.new_default"; index typ ]
  | StructGet (None, typ, f) ->
      block ~loc [ instruction "struct.get"; index typ; index f ]
  | StructGet (Some s, typ, f) ->
      block ~loc [ instruction (signage "struct.get" s); index typ; index f ]
  | RefCast ty -> block ~loc [ instruction "ref.cast"; reftype ty ]
  | RefTest ty -> block ~loc [ instruction "ref.test"; reftype ty ]
  | RefEq -> instruction ~loc "ref.eq"
  | RefNull ty -> block ~loc [ instruction "ref.null"; heaptype ty ]
  | If { label; typ; if_block; else_block } ->
      structured_block ~loc
        (Delimiter (block (instruction "if" :: (opt_id label @ blocktype typ)))
        :: Contents (List.map instr if_block.desc)
        ::
        (if else_block.desc = [] then [ Delimiter (instruction "end") ]
         else
           [
             Delimiter (instruction "else");
             Contents (List.map instr else_block.desc);
             Delimiter (instruction "end");
           ]))
  | Drop -> instruction ~loc "drop"
  | LocalSet i -> block ~loc [ instruction "local.set"; index i ]
  | GlobalSet i -> block ~loc [ instruction "global.set"; index i ]
  | Block { label; typ; block = b } ->
      structured_block ~loc
        [
          Delimiter
            (block (instruction "block" :: (opt_id label @ blocktype typ)));
          Contents (List.map instr b);
          Delimiter (instruction "end");
          (*ZZZ Comment?*)
        ]
  | Loop { label; typ; block = b } ->
      structured_block ~loc
        [
          Delimiter
            (block (instruction "loop" :: (opt_id label @ blocktype typ)));
          Contents (List.map instr b);
          Delimiter (instruction "end");
          (*ZZZ Comment?*)
        ]
  | TryTable { label; typ; catches = c; block = b } ->
      structured_block ~loc
        [
          Delimiter
            (block (instruction "try_table" :: (opt_id label @ blocktype typ)));
          Contents (catches c @ List.map instr b);
          Delimiter (instruction "end");
          (*ZZZ Comment?*)
        ]
  | Try { label; typ; block = b; catches; catch_all } ->
      structured_block ~loc
        (Delimiter (block (instruction "try" :: (opt_id label @ blocktype typ)))
        :: Contents (List.map instr b)
        :: (List.flatten
              (List.map
                 (fun (i, l) ->
                   [
                     Delimiter (block [ instruction "catch"; index i ]);
                     Contents (List.map instr l);
                   ])
                 catches)
           @ (match catch_all with
             | None -> []
             | Some c ->
                 [
                   Delimiter (instruction "catch_all");
                   Contents (List.map instr c);
                 ])
           @ [ Delimiter (instruction "end") (*ZZZ Comment?*) ]))
  | Br_table (l, i) ->
      block ~loc
        (instruction "br_table" :: List.map (fun i -> index i) (l @ [ i ]))
  | Br i -> block ~loc [ instruction "br"; index i ]
  | Br_if i -> block ~loc [ instruction "br_if"; index i ]
  | Br_on_null i -> block ~loc [ instruction "br_on_null"; index i ]
  | Br_on_non_null i -> block ~loc [ instruction "br_on_non_null"; index i ]
  | Br_on_cast (i, ty, ty') ->
      block ~loc [ instruction "br_on_cast"; index i; reftype ty; reftype ty' ]
  | Br_on_cast_fail (i, ty, ty') ->
      block ~loc
        [ instruction "br_on_cast_fail"; index i; reftype ty; reftype ty' ]
  | Return -> instruction ~loc "return"
  | Throw tag -> block ~loc [ instruction "throw"; index tag ]
  | ThrowRef -> block ~loc [ instruction "throw_ref" ]
  | ContNew i -> block ~loc [ instruction "cont.new"; index i ]
  | ContBind (i, j) -> block ~loc [ instruction "cont.bind"; index i; index j ]
  | Suspend i -> block ~loc [ instruction "suspend"; index i ]
  | Resume (i, clauses) ->
      block ~loc (instruction "resume" :: index i :: on_clauses clauses)
  | ResumeThrow (i, j, clauses) ->
      block ~loc
        (instruction "resume_throw" :: index i :: index j :: on_clauses clauses)
  | ResumeThrowRef (i, clauses) ->
      block ~loc
        (instruction "resume_throw_ref" :: index i :: on_clauses clauses)
  | Switch (i, j) -> block ~loc [ instruction "switch"; index i; index j ]
  | Nop -> instruction ~loc "nop"
  | Unreachable -> instruction ~loc "unreachable"
  | ArraySet typ -> block ~loc [ instruction "array.set"; index typ ]
  | StructSet (typ, i) ->
      block ~loc [ instruction "struct.set"; index typ; index i ]
  | ReturnCall f -> block ~loc [ instruction "return_call"; index f ]
  | ReturnCallRef typ -> block ~loc [ instruction "return_call_ref"; index typ ]
  | Folded ({ desc = If { label; typ; if_block; else_block }; _ }, l) ->
      (* Give each clause the location of its (then ...)/(else ...) group so
         a comment trailing the clause attaches to it. *)
      let clause ?(always = false) name b =
        if (not always) && b.Ast.desc = [] then []
        else
          [
            list ~loc:b.Ast.info (instruction name :: List.map instr b.Ast.desc);
          ]
      in
      list ~loc
        (block ~transparent:true
           (block (instruction "if" :: (opt_id label @ blocktype typ))
           :: List.map instr l)
        :: (clause ~always:true "then" if_block @ clause "else" else_block))
  | Folded ({ desc = Block { label; typ; block = b }; _ }, l) ->
      assert (l = []);
      list ~loc
        (block (instruction "block" :: (opt_id label @ blocktype typ))
        :: List.map instr b)
      (*ZZZ Comment?*)
  | Folded ({ desc = Loop { label; typ; block = b }; _ }, l) ->
      assert (l = []);
      list ~loc
        (block (instruction "loop" :: (opt_id label @ blocktype typ))
        :: List.map instr b)
      (*ZZZ Comment?*)
  | Folded ({ desc = TryTable { label; typ; catches = c; block = b }; _ }, l) ->
      assert (l = []);
      list ~loc
        (block (instruction "try_table" :: (opt_id label @ blocktype typ))
        :: block (catches c)
        :: List.map instr b)
      (*ZZZ Comment?*)
  | Folded ({ desc = Try { label; typ; block = b; catches; catch_all }; _ }, l)
    ->
      assert (l = []);
      list ~loc
        (block (instruction "try" :: (opt_id label @ blocktype typ))
        :: list (instruction "do" :: List.map instr b)
        :: (List.map
              (fun (i, l) ->
                list (block [ instruction "catch"; index i ] :: List.map instr l))
              catches
           @
           match catch_all with
           | None -> []
           | Some l -> [ list (instruction "catch_all" :: List.map instr l) ]))
  | String (id, s) | Folded ({ desc = String (id, s); _ }, []) ->
      list ~loc
        (block
           (atom ~style:Annotation "@string"
           :: option (fun id -> [ index ~style:Annotation id ]) id)
        :: List.map
             (fun s ->
               let loc = Some s.Ast.info in
               let i, s = escape_string s.Ast.desc in
               Atom
                 {
                   loc;
                   style = Annotation;
                   len = Some (i + 2);
                   s = "\"" ^ s ^ "\"";
                 })
             s)
  | Char c | Folded ({ desc = Char c; _ }, []) ->
      let n = Uchar.utf_8_byte_length c in
      let b = Bytes.create n in
      ignore (Bytes.set_utf_8_uchar b 0 c);
      list ~loc
        [
          atom ~style:Annotation "@char";
          (let i, s = escape_string (Bytes.to_string b) in
           Atom
             {
               loc = None;
               style = Annotation;
               len = Some (i + 2);
               s = "\"" ^ s ^ "\"";
             });
        ]
  | If_annotation { cond; then_body; else_body }
  | Folded ({ desc = If_annotation { cond; then_body; else_body }; _ }, []) ->
      let clause head body =
        list (atom ~style:Annotation ("@" ^ head) :: List.map instr body)
      in
      list ~loc
        (block [ atom ~style:Annotation "@if"; cond_doc cond ]
        :: clause "then" then_body
        :: option (fun e -> [ clause "else" e ]) else_body)
  | Folded (i, l) ->
      list ~loc [ block ~transparent:true (instr i :: List.map instr l) ]

let instrs l =
  match l with [] -> [] | _ -> [ Vertical_block (None, List.map instr l) ]

let subtype ?loc t =
  let id, { typ; supertype; final } = t.Ast.desc in
  let loc = match loc with Some _ -> loc | None -> Some t.Ast.info in
  if final && Option.is_none supertype then
    list ?loc [ block (keyword "type" :: opt_id id); block [ comptype typ ] ]
  else
    list ?loc
      [
        block (keyword "type" :: opt_id id);
        list
          [
            block
              [
                block
                  (keyword "sub"
                  :: ((if final then [ keyword "final" ] else [])
                     @ option (fun i -> [ index i ]) supertype));
                comptype typ;
              ];
          ];
      ]

let fundecl (idx, typ) =
  option typeuse idx
  @ option
      (fun { params; results } ->
        if params = [||] && results = [||] then []
        else
          [
            block
              ((if Array.for_all (fun p -> fst p.Ast.desc = None) params then
                  make_list ~kind:keyword "param"
                    (fun tl -> List.map valtype tl)
                    (Array.to_list (Array.map (fun p -> snd p.Ast.desc) params))
                else
                  Array.to_list
                    (Array.map
                       (fun p ->
                         let i, t = p.Ast.desc in
                         list ~loc:p.Ast.info
                           (keyword "param" :: (opt_id i @ [ valtype t ])))
                       params))
              @ valtype_list "result" (Array.to_list results));
          ])
      typ

let expr name e =
  match e with
  | [ ({ Ast.desc = Folded _; _ } as i) ] -> instr i
  | _ -> list (keyword name :: instrs e)

let function_indices lst =
  let extract i =
    match i with
    | [
     ( { Ast.desc = RefFunc idx; _ }
     | { Ast.desc = Folded ({ desc = RefFunc idx; _ }, []); _ } );
    ] ->
        Some idx
    | _ -> None
  in
  if List.for_all (fun i -> extract i <> None) lst then
    Some (List.filter_map extract lst)
  else None

let rec modulefield f =
  let loc = f.Ast.info in
  match f.Ast.desc with
  (* Carry the field location (which spans the whole type definition) so a
     leading comment or blank line attaches before the type rather than to its
     inner name — the array element itself is built with a dummy location. *)
  | Types [| t |] -> subtype ~loc t
  | Types l -> list ~loc (keyword "rec" :: List.map subtype (Array.to_list l))
  | Func { id; typ; locals; instrs = i; exports = e } ->
      let local_sexp e =
        let nm, t = e.Ast.desc in
        (* The hovbox lets a comment before any local break correctly while the
           locals stay packed. *)
        list ~loc:e.Ast.info (keyword "local" :: (opt_id nm @ [ valtype t ]))
      in
      let locals_block =
        match locals with
        | [] -> []
        | _ -> [ block ~bk:`Hov (List.map local_sexp locals) ]
      in
      list ~loc
        (block (keyword "func" :: (opt_id id @ exports e @ fundecl typ))
        :: (locals_block @ instrs i))
  | Import { module_; name; id; desc; exports = e } -> (
      let kind, typ =
        match desc with
        | Func typ -> ("func", fundecl typ)
        | Global ty -> ("global", [ globaltype ty ])
        | Tag typ -> ("tag", fundecl typ)
        | Memory l -> ("memory", limits l)
        | Table ty -> ("table", tabletype ty)
      in
      match e with
      | [] ->
          list ~loc
            [
              block
                [ keyword "import"; quoted_string module_; quoted_string name ];
              list [ block (keyword kind :: (opt_id id @ typ)) ];
            ]
      | _ ->
          list ~loc
            (block
               (keyword kind
               :: (opt_id id @ exports e
                  @ [
                      list
                        [
                          keyword "import";
                          quoted_string module_;
                          quoted_string name;
                        ];
                    ]))
            :: typ))
  | Global { id; typ; init; exports = e } ->
      list ~loc
        (block (keyword "global" :: (opt_id id @ exports e @ [ globaltype typ ]))
        :: instrs init)
  | Tag { id; typ; exports = e } ->
      list ~loc (keyword "tag" :: (opt_id id @ exports e @ fundecl typ))
  | Data { id; init; mode } ->
      list ~loc
        (block (keyword "data" :: opt_id id)
        :: ((match mode with
              | Passive -> []
              | Active (i, e) ->
                  (if i.desc = Num Uint32.zero then []
                   else [ list [ keyword "memory"; index i ] ])
                  @ [ expr "offset" e ])
           @ List.map quoted_string init))
  | Start idx -> list ~loc [ keyword "start"; index idx ]
  | Memory { id; limits = l; init; exports = e } ->
      list ~loc
        (block
           (keyword "memory"
           :: (opt_id id @ exports e
              @ match init with None -> limits l | Some _ -> []))
        ::
        (match init with
        | None -> []
        | Some init ->
            address_type l.desc.address_type
            @ [ list (keyword "data" :: List.map quoted_string init) ]))
  | Table { id; typ; init; exports = e } ->
      list ~loc
        (block
           (keyword "table"
           :: (opt_id id @ exports e
              @
              match init with
              | Init_default | Init_expr _ -> tabletype typ
              | Init_segment _ ->
                  address_type typ.limits.desc.address_type
                  @ [ reftype typ.reftype ]))
        ::
        (match init with
        | Init_default -> []
        | Init_expr i -> instrs i
        | Init_segment seg ->
            [
              list
                (keyword "elem"
                ::
                (match function_indices seg with
                | Some lst -> List.map index lst
                | None -> List.map (fun e -> expr "item" e) seg));
            ]))
  | Export { name; kind; index = i } ->
      list ~loc
        [
          keyword "export";
          quoted_string name;
          list
            [
              keyword
                (match kind with
                | Func -> "func"
                | Memory -> "memory"
                | Table -> "table"
                | Tag -> "tag"
                | Global -> "global");
              index i;
            ];
        ]
  | Elem { id; typ; init; mode } ->
      let lst =
        (* The [func] shorthand denotes element type [(ref func)] (non-null,
           matching the [ref.func] elements), not the nullable [funcref]. It
           may therefore only be used for a non-nullable [Func] type;
           abbreviating a [funcref] segment would silently drop its
           nullability. *)
        match typ with
        | { nullable = false; typ = Func } -> function_indices init
        | _ -> None
      in
      list ~loc
        [
          block
            (keyword "elem"
            :: (opt_id id
               @ (match mode with
                 | Passive -> []
                 | Active (idx, ofs) ->
                     (if idx.desc = Num Uint32.zero then []
                      else [ list [ keyword "table"; index idx ] ])
                     @ [ expr "offset" ofs ]
                 | Declare -> [ keyword "declare" ])
               @ [ (if lst = None then reftype typ else keyword "func") ]));
          block
            (match lst with
            | Some lst -> List.map index lst
            | _ -> List.map (fun e -> expr "item" e) init);
        ]
  | String_global { id = i; typ; init } ->
      list ~loc
        (block
           (atom ~style:Annotation "@string"
           :: id ~style:Annotation i.Ast.desc
           :: option (fun id -> [ index ~style:Annotation id ]) typ)
        :: List.map
             (fun s ->
               let i, s = escape_string s.Ast.desc in
               Atom
                 {
                   loc = None;
                   style = Annotation;
                   len = Some (i + 2);
                   s = "\"" ^ s ^ "\"";
                 })
             init)
  | Module_if_annotation { cond; then_fields; else_fields } ->
      let clause head fields =
        list (atom ~style:Annotation ("@" ^ head) :: List.map modulefield fields)
      in
      list ~loc
        (block [ atom ~style:Annotation "@if"; cond_doc cond ]
        :: clause "then" then_fields
        :: option (fun e -> [ clause "else" e ]) else_fields)

let module_ ?(color = Auto) ?out_channel ?(tail = []) ?collect printer ~trivia
    (id, fields) =
  (* [collect] marks the dry trivia-collection traversal; time the real emit
     only, so a single "output" timing is reported. *)
  Wax_utils.Debug.timed_if (collect = None) "output" @@ fun () ->
  let use_color = should_use_color ~color ~out_channel in
  let theme = get_theme use_color in
  let ctx =
    {
      base = Styled.create ~printer ~theme ?collect ~trivia ();
      format = Hybrid;
      indent_level = 2;
    }
  in
  let sexp =
    (* Top-level fields are laid out strictly one per line. *)
    if id = None then Vertical_block (None, List.map modulefield fields)
    else
      list
        (block ~transparent:true (keyword "module" :: opt_id id)
        :: List.map modulefield fields)
  in
  format_sexp false (if id = None then 1 else 0) false ctx sexp;
  (* Comments owned by no location (trailing comments, or the whole file for an
     empty module) are printed last so they are not dropped. Blank lines at the
     very end are dropped (end-of-file whitespace), but blank lines separating
     tail comments are kept. *)
  let tail = Trivia.drop_trailing_blank_lines tail in
  print_trivia ctx tail

let instr printer i =
  let use_color = should_use_color ~color:Auto ~out_channel:(Some stderr) in
  let theme = get_theme use_color in
  format_sexp false 2 false
    {
      base = Styled.create ~printer ~theme ~trivia:(Hashtbl.create 16) ();
      format = Compact;
      indent_level = 2;
    }
    (instr i)

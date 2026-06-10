module Uint32 = Utils.Uint32
module Ast = Wasm.Ast
module Binary = Ast.Binary
module Text = Ast.Text
module Simd = Wasm.Simd
open Wax.Ast
module StringMap = Map.Make (String)

type ctx = {
  globals : (string, unit) Hashtbl.t;
  functions : (string, unit) Hashtbl.t;
  memories : (string, unit) Hashtbl.t;
  tables : (string, reftype) Hashtbl.t;
  elems : (string, unit) Hashtbl.t;
  mutable locals : string StringMap.t;
  allocated_locals : (Text.name option * Text.valtype) list ref;
  namespace : Namespace.t;
  type_kinds : (string, [ `Struct | `Array | `Func ]) Hashtbl.t;
  struct_fields : (string, string list) Hashtbl.t;
  referenced_functions : (string, unit) Hashtbl.t;
  extra_types : (string, Text.name * subtype) Hashtbl.t;
  types : Wax.Typing.types;
  diagnostics : Utils.Diagnostic.context;
}

let with_loc loc desc = { desc; info = loc }
let index wax_idx : Text.idx = with_loc wax_idx.info (Text.Id wax_idx.desc)

let rec heaptype (h : heaptype) : Text.heaptype =
  match h with
  | Func -> Func
  | NoFunc -> NoFunc
  | Exn -> Exn
  | NoExn -> NoExn
  | Cont -> Cont
  | NoCont -> NoCont
  | Extern -> Extern
  | NoExtern -> NoExtern
  | Any -> Any
  | Eq -> Eq
  | I31 -> I31
  | Struct -> Struct
  | Array -> Array
  | None_ -> None_
  | Type idx -> Type (index idx)

and valtype ty : Text.valtype =
  match ty with
  | I32 -> I32
  | I64 -> I64
  | F32 -> F32
  | F64 -> F64
  | V128 -> V128
  | Ref { nullable; typ } -> Ref { nullable; typ = heaptype typ }

let reftype r : Text.reftype = { nullable = r.nullable; typ = heaptype r.typ }
let unpack_type f = match f with Value v -> v | Packed _ -> I32

let is_mgmt_method m =
  match m with "size" | "grow" | "fill" | "copy" | "init" -> true | _ -> false

(* No-argument unary instruction methods written as [x.sqrt()] etc. (not
   [length], which becomes [array.len]). *)
let is_unary_op_method m =
  match m with
  | "clz" | "ctz" | "popcnt" | "extend8_s" | "extend16_s" | "abs" | "ceil"
  | "floor" | "trunc" | "nearest" | "sqrt" | "to_bits" | "from_bits" ->
      true
  | _ -> false

let functype typ : Text.functype =
  let params = Array.map (fun (id, t) -> (id, valtype t)) typ.params in
  let results = Array.map valtype typ.results in
  { params; results }

let blocktype typ : Text.blocktype option =
  match (typ.params, typ.results) with
  | [||], [||] -> None
  | [||], [| typ |] -> Some (Valtype (valtype typ))
  | _ -> Some (Typeuse (None, Some (functype typ)))

let print_instr i =
  Format.eprintf "%a@."
    (fun f i -> Utils.Printer.run f (fun pp -> Wax.Output.instr pp i))
    i

(*
let print_storagetype i =
  Format.eprintf "%a@."
    (fun f i -> Utils.Printer.run f (fun pp -> Wax.Output.storagetype pp i))
    i
*)
let print_valtype i =
  Format.eprintf "%a@."
    (fun f i -> Utils.Printer.run f (fun pp -> Wax.Output.valtype pp i))
    i

let binop i op operand_type : _ Text.instr_desc =
  match (op, operand_type) with
  | Add, I32 -> BinOp (I32 Add)
  | Sub, I32 -> BinOp (I32 Sub)
  | Mul, I32 -> BinOp (I32 Mul)
  | Div (Some Signed), I32 -> BinOp (I32 (Div Signed))
  | Div (Some Unsigned), I32 -> BinOp (I32 (Div Unsigned))
  | Rem Signed, I32 -> BinOp (I32 (Rem Signed))
  | Rem Unsigned, I32 -> BinOp (I32 (Rem Unsigned))
  | And, I32 -> BinOp (I32 And)
  | Or, I32 -> BinOp (I32 Or)
  | Xor, I32 -> BinOp (I32 Xor)
  | Shl, I32 -> BinOp (I32 Shl)
  | Shr Signed, I32 -> BinOp (I32 (Shr Signed))
  | Shr Unsigned, I32 -> BinOp (I32 (Shr Unsigned))
  | Eq, I32 -> BinOp (I32 Eq)
  | Ne, I32 -> BinOp (I32 Ne)
  | Lt (Some Signed), I32 -> BinOp (I32 (Lt Signed))
  | Lt (Some Unsigned), I32 -> BinOp (I32 (Lt Unsigned))
  | Gt (Some Signed), I32 -> BinOp (I32 (Gt Signed))
  | Gt (Some Unsigned), I32 -> BinOp (I32 (Gt Unsigned))
  | Le (Some Signed), I32 -> BinOp (I32 (Le Signed))
  | Le (Some Unsigned), I32 -> BinOp (I32 (Le Unsigned))
  | Ge (Some Signed), I32 -> BinOp (I32 (Ge Signed))
  | Ge (Some Unsigned), I32 -> BinOp (I32 (Ge Unsigned))
  | Add, I64 -> BinOp (I64 Add)
  | Sub, I64 -> BinOp (I64 Sub)
  | Mul, I64 -> BinOp (I64 Mul)
  | Div (Some Signed), I64 -> BinOp (I64 (Div Signed))
  | Div (Some Unsigned), I64 -> BinOp (I64 (Div Unsigned))
  | Rem Signed, I64 -> BinOp (I64 (Rem Signed))
  | Rem Unsigned, I64 -> BinOp (I64 (Rem Unsigned))
  | And, I64 -> BinOp (I64 And)
  | Or, I64 -> BinOp (I64 Or)
  | Xor, I64 -> BinOp (I64 Xor)
  | Shl, I64 -> BinOp (I64 Shl)
  | Shr Signed, I64 -> BinOp (I64 (Shr Signed))
  | Shr Unsigned, I64 -> BinOp (I64 (Shr Unsigned))
  | Eq, I64 -> BinOp (I64 Eq)
  | Ne, I64 -> BinOp (I64 Ne)
  | Lt (Some Signed), I64 -> BinOp (I64 (Lt Signed))
  | Lt (Some Unsigned), I64 -> BinOp (I64 (Lt Unsigned))
  | Gt (Some Signed), I64 -> BinOp (I64 (Gt Signed))
  | Gt (Some Unsigned), I64 -> BinOp (I64 (Gt Unsigned))
  | Le (Some Signed), I64 -> BinOp (I64 (Le Signed))
  | Le (Some Unsigned), I64 -> BinOp (I64 (Le Unsigned))
  | Ge (Some Signed), I64 -> BinOp (I64 (Ge Signed))
  | Ge (Some Unsigned), I64 -> BinOp (I64 (Ge Unsigned))
  | Add, F32 -> BinOp (F32 Add)
  | Sub, F32 -> BinOp (F32 Sub)
  | Mul, F32 -> BinOp (F32 Mul)
  | Div None, F32 -> BinOp (F32 Div)
  | Eq, F32 -> BinOp (F32 Eq)
  | Ne, F32 -> BinOp (F32 Ne)
  | Lt None, F32 -> BinOp (F32 Lt)
  | Gt None, F32 -> BinOp (F32 Gt)
  | Le None, F32 -> BinOp (F32 Le)
  | Ge None, F32 -> BinOp (F32 Ge)
  | Add, F64 -> BinOp (F64 Add)
  | Sub, F64 -> BinOp (F64 Sub)
  | Mul, F64 -> BinOp (F64 Mul)
  | Div None, F64 -> BinOp (F64 Div)
  | Eq, F64 -> BinOp (F64 Eq)
  | Ne, F64 -> BinOp (F64 Ne)
  | Lt None, F64 -> BinOp (F64 Lt)
  | Gt None, F64 -> BinOp (F64 Gt)
  | Le None, F64 -> BinOp (F64 Le)
  | Ge None, F64 -> BinOp (F64 Ge)
  | _ ->
      print_instr i;
      assert false

let folded loc desc args =
  [ with_loc loc (Text.Folded (with_loc loc desc, args)) ]

let typeuse typ sign =
  let idx = Option.map index typ in
  let type_info =
    Option.map
      (fun s ->
        let params = Array.map (fun (id, t) -> (id, valtype t)) s.params in
        let results = Array.map valtype s.results in
        { Text.params; results })
      sign
  in
  (idx, type_info)

let expr_type i =
  match i.info with
  | [| Some t |], _ -> t
  | _ ->
      print_instr i;
      assert false

let expr_opt_valtype i =
  match i.info with
  | [| Some t |], _ -> Some (unpack_type t)
  | [| None |], _ -> None
  | _ ->
      print_instr i;
      assert false

let expr_valtype i = unpack_type (expr_type i)
let expr_reftype i = match expr_valtype i with Ref r -> r | _ -> assert false

let expr_opt_reftype i =
  match expr_opt_valtype i with
  | Some (Ref r) -> Some r
  | None -> None
  | _ -> assert false

let expr_type_name i =
  match expr_reftype i with
  | { typ = Type idx; _ } -> idx
  | _ ->
      print_valtype (Ref (expr_reftype i));
      print_instr i;
      assert false

let label ret (lab : ident) =
  match ret with
  | Some (lab', depth) when lab.desc = lab' ->
      { lab with desc = Text.Num (Uint32.of_int depth) }
  | _ -> { lab with desc = Text.Id lab.desc }

let on_clause ret (c : on_clause) : Text.on_clause =
  match c with
  | OnLabel (tag, labl) -> OnLabel (index tag, label ret labl)
  | OnSwitch tag -> OnSwitch (index tag)

let push ret label =
  match (ret, label) with
  | Some (label, _), Some label' when label = label'.desc -> None
  | Some (label, i), _ -> Some (label, i + 1)
  | None, _ -> None

let ensure_type_is_defined ctx typ =
  match typ with
  | Ref { typ = Type nm; _ } when nm.desc.[0] = '<' ->
      if not (Hashtbl.mem ctx.extra_types nm.desc) then
        Option.iter
          (fun subtype -> Hashtbl.add ctx.extra_types nm.desc (nm, subtype))
          (Wax.Typing.get_type_definition ctx.diagnostics ctx.types nm)
  | _ -> ()

let mem_store_method = function
  | "store8" | "store16" | "store32" | "store64" | "storef32" | "storef64" ->
      true
  | _ -> false

let mem_load_method = function
  | "load8" | "load16" | "load32" | "load64" | "loadf32" | "loadf64" -> true
  | _ -> false

let is_mem_method m = mem_store_method m || mem_load_method m

let mem_natural_align = function
  | "load8" | "store8" -> 1
  | "load16" | "store16" -> 2
  | "load32" | "store32" | "loadf32" | "storef32" -> 4
  | _ -> 8

(* Build a [memarg] from the trailing literal [align]/[offset] arguments (after
   the [nstack] stack operands), defaulting [align] to the natural alignment. *)
let mem_memarg meth nstack args : Ast.memarg =
  let int_lit a =
    match a.desc with
    (* [Uint64.of_string] handles the full unsigned 64-bit range; a memory64
       offset/align may exceed [Int64.max_int]. *)
    | Int s -> Utils.Uint64.of_string s
    | _ -> assert false
  in
  let extra = List.filteri (fun k _ -> k >= nstack) args in
  let align =
    match extra with
    | a :: _ -> int_lit a
    | [] -> Utils.Uint64.of_int (mem_natural_align meth)
  in
  let offset =
    match extra with _ :: o :: _ -> int_lit o | _ -> Utils.Uint64.zero
  in
  { offset; align }

(* Literal value of a [v128_const_*] lane argument, as a string for
   [Utils.V128.t]; a negative literal is [UnOp (Neg, _)]. *)
let rec literal_string a =
  match a.desc with
  | Int s | Float s -> s
  | UnOp (Neg, b) -> "-" ^ literal_string b
  | _ -> assert false

(* Read a constant integer immediate (lane index). *)
let lane_imm a =
  match a.desc with Int s -> int_of_string s | _ -> assert false

let rec instruction ret ctx i : location Text.instr list =
  let _, loc = i.info in
  match i.desc with
  | Block { label; typ; block = body } ->
      let inner_ctx = { ctx with locals = ctx.locals } in
      let block =
        List.concat_map (instruction (push ret label) inner_ctx) body
      in
      folded loc (Block { label; typ = blocktype typ; block }) []
  | Loop { label; typ; block = body } ->
      let inner_ctx = { ctx with locals = ctx.locals } in
      let block =
        List.concat_map (instruction (push ret label) inner_ctx) body
      in
      folded loc (Loop { label; typ = blocktype typ; block }) []
  | If { label; typ; cond; if_block; else_block } ->
      let cond_code = instruction ret ctx cond in
      let then_ctx = { ctx with locals = ctx.locals } in
      let if_block =
        {
          if_block with
          Ast.desc =
            List.concat_map
              (instruction (push ret label) then_ctx)
              if_block.desc;
        }
      in
      let else_block =
        match else_block with
        | Some e ->
            let else_ctx = { ctx with locals = ctx.locals } in
            {
              e with
              Ast.desc =
                List.concat_map (instruction (push ret label) else_ctx) e.desc;
            }
        | None -> Ast.no_loc []
      in
      folded loc
        (If { label; typ = blocktype typ; if_block; else_block })
        cond_code
  | TryTable { label = labl; typ; block; catches } ->
      let inner_ctx = { ctx with locals = ctx.locals } in
      let block =
        List.concat_map (instruction (push ret labl) inner_ctx) block
      in
      let catches =
        List.map
          (fun catch : Text.catch ->
            match catch with
            | Catch (tag, labl) -> Catch (index tag, label ret labl)
            | CatchRef (tag, labl) -> CatchRef (index tag, label ret labl)
            | CatchAll labl -> CatchAll (label ret labl)
            | CatchAllRef labl -> CatchAllRef (label ret labl))
          catches
      in
      folded loc
        (TryTable { label = labl; typ = blocktype typ; block; catches })
        []
  | Try { label; typ; block; catches; catch_all } ->
      let inner_ctx = { ctx with locals = ctx.locals } in
      let block =
        List.concat_map (instruction (push ret label) inner_ctx) block
      in
      let catches =
        List.map
          (fun (tag, block) ->
            let inner_ctx = { ctx with locals = ctx.locals } in
            ( index tag,
              List.concat_map (instruction (push ret label) inner_ctx) block ))
          catches
      in
      let catch_all =
        Option.map
          (fun block ->
            let inner_ctx = { ctx with locals = ctx.locals } in
            List.concat_map (instruction (push ret label) inner_ctx) block)
          catch_all
      in
      folded loc
        (Try { label; typ = blocktype typ; block; catches; catch_all })
        []
  | Unreachable -> folded loc Unreachable []
  | Nop -> folded loc Nop []
  | Hole -> []
  | Null -> folded loc (RefNull (heaptype (expr_reftype i).typ)) []
  | Get idx ->
      if StringMap.mem idx.desc ctx.locals then
        let wasm_name = StringMap.find idx.desc ctx.locals in
        folded loc (Text.LocalGet (with_loc idx.info (Text.Id wasm_name))) []
      else if Hashtbl.mem ctx.functions idx.desc then
        (Hashtbl.replace ctx.referenced_functions idx.desc ();
         folded loc (Text.RefFunc (index idx)))
          []
      else folded loc (Text.GlobalGet (index idx)) []
  | Set (None, expr) -> folded loc Drop (instruction ret ctx expr)
  | Set (Some idx, expr) ->
      let code = instruction ret ctx expr in
      if StringMap.mem idx.desc ctx.locals then
        let wasm_name = StringMap.find idx.desc ctx.locals in
        folded loc (LocalSet (with_loc idx.info (Text.Id wasm_name))) code
      else folded loc (GlobalSet (index idx)) code
  | Tee (idx, expr) ->
      let code = instruction ret ctx expr in
      let wasm_name = StringMap.find idx.desc ctx.locals in
      folded loc (LocalTee (with_loc idx.info (Text.Id wasm_name))) code
  | Call (f, args) -> (
      let arg_code = List.concat_map (instruction ret ctx) args in
      match f.desc with
      (* SIMD free-function intrinsics: [v128_const_<shape>(...)] and
         [v128_bitselect(a, b, mask)]. A user binding of the same name wins. *)
      | Get name
        when Simd.is_free_intrinsic name.desc
             && (not (Hashtbl.mem ctx.functions name.desc))
             && (not (Hashtbl.mem ctx.globals name.desc))
             && not (StringMap.mem name.desc ctx.locals) -> (
          match Simd.const_shape_of_name name.desc with
          | Some shape ->
              let components = List.map literal_string args in
              folded loc (VecConst { Utils.V128.shape; components }) []
          | None -> folded loc VecBitselect arg_code)
      | Get idx ->
          if
            Hashtbl.mem ctx.functions idx.desc
            && not (StringMap.mem idx.desc ctx.locals)
          then folded loc (Call (index idx)) arg_code
          else
            let code = instruction ret ctx f in
            folded loc (CallRef (index (expr_type_name f))) (arg_code @ code)
      (* Memory access: mem.loadN/storeN(addr [, align [, offset]]). Signed
         narrow loads are handled (under an [as iN_s] cast) in the Cast case. *)
      | StructGet ({ desc = Get memname; _ }, meth)
        when Hashtbl.mem ctx.memories memname.desc && is_mem_method meth.desc ->
          let memidx = index memname in
          if mem_store_method meth.desc then
            let memarg = mem_memarg meth.desc 2 args in
            let addr_code = instruction ret ctx (List.nth args 0) in
            let value = List.nth args 1 in
            let value_code = instruction ret ctx value in
            let desc =
              (* The value type is unknown ([None]) in unreachable code; the
                 width is what matters there, so default to the i32 form. *)
              match (meth.desc, expr_opt_valtype value) with
              | "store8", Some I64 -> Text.StoreS (memidx, memarg, `I64, `I8)
              | "store8", _ -> Text.StoreS (memidx, memarg, `I32, `I8)
              | "store16", Some I64 -> Text.StoreS (memidx, memarg, `I64, `I16)
              | "store16", _ -> Text.StoreS (memidx, memarg, `I32, `I16)
              | "store32", Some I64 -> Text.StoreS (memidx, memarg, `I64, `I32)
              | "store32", _ -> Text.Store (memidx, memarg, NumI32)
              | "store64", _ -> Text.Store (memidx, memarg, NumI64)
              | "storef32", _ -> Text.Store (memidx, memarg, NumF32)
              | _ -> Text.Store (memidx, memarg, NumF64)
            in
            folded loc desc (addr_code @ value_code)
          else
            let memarg = mem_memarg meth.desc 1 args in
            let addr_code = instruction ret ctx (List.nth args 0) in
            let desc =
              match meth.desc with
              | "load8" -> Text.LoadS (memidx, memarg, `I32, `I8, Unsigned)
              | "load16" -> Text.LoadS (memidx, memarg, `I32, `I16, Unsigned)
              | "load32" -> Text.Load (memidx, memarg, NumI32)
              | "load64" -> Text.Load (memidx, memarg, NumI64)
              | "loadf32" -> Text.Load (memidx, memarg, NumF32)
              | _ -> Text.Load (memidx, memarg, NumF64)
            in
            folded loc desc addr_code
      (* SIMD memory accesses: mem.v128_load(addr [,align[,offset]]),
         mem.v128_store(addr, v, ...), mem.v128_load8_lane(addr, v, lane, ...).
         Stack operands first, then the constant lane immediate (if any), then
         align/offset. *)
      | StructGet ({ desc = Get memname; _ }, meth)
        when Hashtbl.mem ctx.memories memname.desc
             && Simd.is_mem_method meth.desc ->
          let mop = Option.get (Simd.mem_method meth.desc) in
          let memidx = index memname in
          let nstack = List.length mop.m_operands in
          let nimm = if mop.m_lane then 1 else 0 in
          let lane =
            if mop.m_lane then lane_imm (List.nth args nstack) else 0
          in
          let extra = List.filteri (fun k _ -> k >= nstack + nimm) args in
          let int_lit a =
            match a.desc with
            | Int s -> Utils.Uint64.of_string s
            | _ -> assert false
          in
          let align =
            match extra with
            | a :: _ -> int_lit a
            | [] -> Utils.Uint64.of_int mop.m_nat_align
          in
          let offset =
            match extra with _ :: o :: _ -> int_lit o | _ -> Utils.Uint64.zero
          in
          let memarg : Ast.memarg = { offset; align } in
          let operand_code =
            List.concat_map (instruction ret ctx)
              (List.filteri (fun k _ -> k < nstack) args)
          in
          folded loc (mop.m_make memidx memarg lane) operand_code
      (* Binary intrinsics, written with the dot notation *)
      | StructGet (obj, { desc = "rotl"; _ }) -> (
          let obj_code = instruction ret ctx obj in
          match expr_valtype i with
          | I32 -> folded loc (BinOp (I32 Rotl)) (obj_code @ arg_code)
          | I64 -> folded loc (BinOp (I64 Rotl)) (obj_code @ arg_code)
          | _ -> assert false)
      | StructGet (obj, { desc = "rotr"; _ }) -> (
          let obj_code = instruction ret ctx obj in
          match expr_valtype i with
          | I32 -> folded loc (BinOp (I32 Rotr)) (obj_code @ arg_code)
          | I64 -> folded loc (BinOp (I64 Rotr)) (obj_code @ arg_code)
          | _ -> assert false)
      | StructGet (obj, { desc = "min"; _ }) -> (
          let obj_code = instruction ret ctx obj in
          match expr_valtype i with
          | F32 -> folded loc (BinOp (F32 Min)) (obj_code @ arg_code)
          | F64 -> folded loc (BinOp (F64 Min)) (obj_code @ arg_code)
          | _ -> assert false)
      | StructGet (obj, { desc = "max"; _ }) -> (
          let obj_code = instruction ret ctx obj in
          match expr_valtype i with
          | F32 -> folded loc (BinOp (F32 Max)) (obj_code @ arg_code)
          | F64 -> folded loc (BinOp (F64 Max)) (obj_code @ arg_code)
          | _ -> assert false)
      | StructGet (obj, { desc = "copysign"; _ }) -> (
          let obj_code = instruction ret ctx obj in
          match expr_valtype i with
          | F32 -> folded loc (BinOp (F32 CopySign)) (obj_code @ arg_code)
          | F64 -> folded loc (BinOp (F64 CopySign)) (obj_code @ arg_code)
          | _ -> assert false)
      (* No-argument instruction methods written with dot notation:
         [arr.length()], and the unary operators / reinterpret casts below. *)
      | StructGet (obj, { desc = "length"; _ }) ->
          folded loc ArrayLen (instruction ret ctx obj)
      | StructGet (obj, meth) when is_unary_op_method meth.desc -> (
          let obj_code = instruction ret ctx obj in
          match (meth.desc, expr_valtype obj) with
          (* Int Unary *)
          | "clz", I32 -> folded loc (UnOp (I32 Clz)) obj_code
          | "ctz", I32 -> folded loc (UnOp (I32 Ctz)) obj_code
          | "popcnt", I32 -> folded loc (UnOp (I32 Popcnt)) obj_code
          | "clz", I64 -> folded loc (UnOp (I64 Clz)) obj_code
          | "ctz", I64 -> folded loc (UnOp (I64 Ctz)) obj_code
          | "popcnt", I64 -> folded loc (UnOp (I64 Popcnt)) obj_code
          | "extend8_s", I32 -> folded loc (UnOp (I32 (ExtendS `_8))) obj_code
          | "extend16_s", I32 -> folded loc (UnOp (I32 (ExtendS `_16))) obj_code
          | "extend8_s", I64 -> folded loc (UnOp (I64 (ExtendS `_8))) obj_code
          | "extend16_s", I64 -> folded loc (UnOp (I64 (ExtendS `_16))) obj_code
          (* Float Unary *)
          | "abs", F32 -> folded loc (UnOp (F32 Abs)) obj_code
          | "ceil", F32 -> folded loc (UnOp (F32 Ceil)) obj_code
          | "floor", F32 -> folded loc (UnOp (F32 Floor)) obj_code
          | "trunc", F32 -> folded loc (UnOp (F32 Trunc)) obj_code
          | "nearest", F32 -> folded loc (UnOp (F32 Nearest)) obj_code
          | "sqrt", F32 -> folded loc (UnOp (F32 Sqrt)) obj_code
          | "abs", F64 -> folded loc (UnOp (F64 Abs)) obj_code
          | "ceil", F64 -> folded loc (UnOp (F64 Ceil)) obj_code
          | "floor", F64 -> folded loc (UnOp (F64 Floor)) obj_code
          | "trunc", F64 -> folded loc (UnOp (F64 Trunc)) obj_code
          | "nearest", F64 -> folded loc (UnOp (F64 Nearest)) obj_code
          | "sqrt", F64 -> folded loc (UnOp (F64 Sqrt)) obj_code
          (* Reinterpret *)
          | "to_bits", F32 -> folded loc (UnOp (I32 Reinterpret)) obj_code
          | "from_bits", I32 -> folded loc (UnOp (F32 Reinterpret)) obj_code
          | "to_bits", F64 -> folded loc (UnOp (I64 Reinterpret)) obj_code
          | "from_bits", I64 -> folded loc (UnOp (F64 Reinterpret)) obj_code
          | _ -> assert false)
      (* SIMD vector op written as a method intrinsic, [recv.add_i32x4(b)]. The
         lane shape comes from the method name; arguments are the lane immediates
         (if any) followed by the remaining stack operands. *)
      | StructGet (obj, meth) when Simd.classify meth.desc <> None ->
          let op = Option.get (Simd.classify meth.desc) in
          let nimm =
            match op.imm with No_imm -> 0 | Lane _ -> 1 | Shuffle -> 16
          in
          let lanes =
            List.filteri (fun k _ -> k < nimm) args |> List.map lane_imm
          in
          let stack_args = List.filteri (fun k _ -> k >= nimm) args in
          let obj_code = instruction ret ctx obj in
          let stack_code = List.concat_map (instruction ret ctx) stack_args in
          folded loc (op.build lanes) (obj_code @ stack_code)
      (* Memory management: mem.size/grow/fill/copy/init *)
      | StructGet ({ desc = Get name; _ }, meth)
        when Hashtbl.mem ctx.memories name.desc && is_mgmt_method meth.desc -> (
          let m = index name in
          match meth.desc with
          | "size" -> folded loc (MemorySize m) []
          | "grow" -> folded loc (MemoryGrow m) arg_code
          | "fill" -> folded loc (MemoryFill m) arg_code
          | "copy" -> (
              (* Cross-memory copy names the source memory as the first arg. *)
              match args with
              | { desc = Get src; _ } :: rest
                when Hashtbl.mem ctx.memories src.desc ->
                  let rest_code = List.concat_map (instruction ret ctx) rest in
                  folded loc (MemoryCopy (m, index src)) rest_code
              | _ -> folded loc (MemoryCopy (m, m)) arg_code)
          | _ (* init *) ->
              let seg =
                match args with
                | { desc = Get s; _ } :: _ -> s
                | _ -> assert false
              in
              let rest_code =
                List.concat_map (instruction ret ctx) (List.tl args)
              in
              folded loc (MemoryInit (m, index seg)) rest_code)
      (* Table management: tab.size/grow/fill/copy/init *)
      | StructGet ({ desc = Get name; _ }, meth)
        when Hashtbl.mem ctx.tables name.desc && is_mgmt_method meth.desc -> (
          let t = index name in
          match meth.desc with
          | "size" -> folded loc (TableSize t) []
          | "grow" -> folded loc (TableGrow t) arg_code
          | "fill" -> folded loc (TableFill t) arg_code
          | "copy" -> (
              (* Cross-table copy names the source table as the first arg. *)
              match args with
              | { desc = Get src; _ } :: rest
                when Hashtbl.mem ctx.tables src.desc ->
                  let rest_code = List.concat_map (instruction ret ctx) rest in
                  folded loc (TableCopy (t, index src)) rest_code
              | _ -> folded loc (TableCopy (t, t)) arg_code)
          | _ (* init *) ->
              let seg =
                match args with
                | { desc = Get s; _ } :: _ -> s
                | _ -> assert false
              in
              let rest_code =
                List.concat_map (instruction ret ctx) (List.tl args)
              in
              folded loc (TableInit (t, index seg)) rest_code)
      (* data.drop / elem.drop *)
      | StructGet ({ desc = Get name; _ }, { desc = "drop"; _ }) ->
          if Hashtbl.mem ctx.elems name.desc then
            folded loc (ElemDrop (index name)) []
          else folded loc (DataDrop (index name)) []
      | StructGet (obj, { desc = "fill"; _ }) ->
          let array_code = instruction ret ctx obj in
          let type_name_idx = expr_type_name obj in
          folded loc (ArrayFill (index type_name_idx)) (array_code @ arg_code)
      | StructGet (obj, { desc = "copy"; _ }) ->
          let a1_code = instruction ret ctx obj in
          let type_a1 = expr_type_name obj in
          let a2_code = List.nth args 1 in
          let type_a2 = expr_type_name a2_code in
          folded loc
            (ArrayCopy (index type_a1, index type_a2))
            (a1_code @ arg_code)
      (* array.init_data / array.init_elem: arr.init(seg, dest, src, len) *)
      | StructGet (obj, { desc = "init"; _ }) ->
          let seg =
            match args with { desc = Get s; _ } :: _ -> s | _ -> assert false
          in
          let obj_code = instruction ret ctx obj in
          let rest_code =
            List.concat_map (instruction ret ctx) (List.tl args)
          in
          let arrty = expr_type_name obj in
          let desc : _ Text.instr_desc =
            if Hashtbl.mem ctx.elems seg.desc then
              ArrayInitElem (index arrty, index seg)
            else ArrayInitData (index arrty, index seg)
          in
          folded loc desc (obj_code @ rest_code)
      (* Indirect call: re-fuse [(tab[i] as &$ft)(args)] (and the cast-free
         [tab[i](args)] when the table element is already a concrete &$ft) back
         to [call_indirect]. *)
      | Cast
          ( { desc = ArrayGet ({ desc = Get tab; _ }, idx_expr); _ },
            Valtype (Ref { typ = Type ft; _ }) )
        when Hashtbl.mem ctx.tables tab.desc ->
          let index_code = instruction ret ctx idx_expr in
          folded loc
            (CallIndirect (index tab, (Some (index ft), None)))
            (arg_code @ index_code)
      | Cast
          ( { desc = ArrayGet ({ desc = Get tab; _ }, idx_expr); _ },
            Functype { sign; _ } )
        when Hashtbl.mem ctx.tables tab.desc ->
          (* Inline function type: emit an inline typeuse [(result ..)]. *)
          let index_code = instruction ret ctx idx_expr in
          folded loc
            (CallIndirect (index tab, (None, Some (functype sign))))
            (arg_code @ index_code)
      | ArrayGet ({ desc = Get tab; _ }, idx_expr)
        when Hashtbl.mem ctx.tables tab.desc
             &&
             match Hashtbl.find ctx.tables tab.desc with
             | { typ = Type _; _ } -> true
             | _ -> false ->
          let ft =
            match Hashtbl.find ctx.tables tab.desc with
            | { typ = Type ft; _ } -> ft
            | _ -> assert false
          in
          let index_code = instruction ret ctx idx_expr in
          folded loc
            (CallIndirect (index tab, (Some (index ft), None)))
            (arg_code @ index_code)
      | _ ->
          let code = instruction ret ctx f in
          folded loc (CallRef (index (expr_type_name f))) (arg_code @ code))
  | TailCall (f, args) -> (
      (*ZZZ handle intrinsics as well? (Or reject while typing?) *)
      let arg_code = List.concat_map (instruction ret ctx) args in
      match f.desc with
      | Get idx when Hashtbl.mem ctx.functions idx.desc ->
          folded loc (ReturnCall (index idx)) arg_code
      | Cast
          ( { desc = ArrayGet ({ desc = Get tab; _ }, idx_expr); _ },
            Valtype (Ref { typ = Type ft; _ }) )
        when Hashtbl.mem ctx.tables tab.desc ->
          let index_code = instruction ret ctx idx_expr in
          folded loc
            (ReturnCallIndirect (index tab, (Some (index ft), None)))
            (arg_code @ index_code)
      | Cast
          ( { desc = ArrayGet ({ desc = Get tab; _ }, idx_expr); _ },
            Functype { sign; _ } )
        when Hashtbl.mem ctx.tables tab.desc ->
          let index_code = instruction ret ctx idx_expr in
          folded loc
            (ReturnCallIndirect (index tab, (None, Some (functype sign))))
            (arg_code @ index_code)
      | ArrayGet ({ desc = Get tab; _ }, idx_expr)
        when Hashtbl.mem ctx.tables tab.desc
             &&
             match Hashtbl.find ctx.tables tab.desc with
             | { typ = Type _; _ } -> true
             | _ -> false ->
          let ft =
            match Hashtbl.find ctx.tables tab.desc with
            | { typ = Type ft; _ } -> ft
            | _ -> assert false
          in
          let index_code = instruction ret ctx idx_expr in
          folded loc
            (ReturnCallIndirect (index tab, (Some (index ft), None)))
            (arg_code @ index_code)
      | _ ->
          let code = instruction ret ctx f in
          folded loc (ReturnCallRef (index (expr_type_name f))) (arg_code @ code)
      )
  | Int s -> (
      match expr_valtype i with
      | I32 -> folded loc (Const (I32 s)) []
      | I64 -> folded loc (Const (I64 s)) []
      | F32 -> folded loc (Const (F32 s)) []
      | F64 -> folded loc (Const (F64 s)) []
      | _ -> assert false)
  | Float s -> (
      match expr_valtype i with
      | F32 -> folded loc (Const (F32 s)) []
      | F64 -> folded loc (Const (F64 s)) []
      | _ -> assert false)
  | Cast (expr, cast_ty) -> (
      let default_cast () =
        let code = instruction ret ctx expr in
        match expr_opt_valtype expr with
        | None -> code
        | Some in_ty ->
            let instr : _ Text.instr_desc =
              match (in_ty, cast_ty) with
              (* I31 *)
              | I32, Valtype (Ref { typ = I31; _ }) -> RefI31
              | Ref _, Signedtype { typ = `I32; signage; _ } -> I31Get signage
              (* Extern / Any *)
              | ( Ref { typ = Any | I31 | Struct | Array | Type _ | None_; _ },
                  Valtype (Ref { typ = Extern; _ }) ) ->
                  ExternConvertAny
              | Ref { typ = Extern; _ }, Valtype (Ref { typ = Any; _ }) ->
                  AnyConvertExtern
              (* RefCast *)
              | Ref _, Valtype (Ref r) -> RefCast (reftype r)
              (* Numeric conversions *)
              | I64, Valtype I32 -> I32WrapI64
              | F64, Valtype F32 -> F32DemoteF64
              | F32, Valtype F64 -> F64PromoteF32
              | I32, Signedtype { typ = `I64; signage; _ } ->
                  I64ExtendI32 signage
              (* Trunc *)
              | F32, Signedtype { typ = `I32; signage = s; strict } ->
                  UnOp
                    (I32
                       (if strict then Trunc (`F32, s) else TruncSat (`F32, s)))
              | F64, Signedtype { typ = `I32; signage = s; strict } ->
                  UnOp
                    (I32
                       (if strict then Trunc (`F64, s) else TruncSat (`F64, s)))
              | F32, Signedtype { typ = `I64; signage = s; strict } ->
                  UnOp
                    (I64
                       (if strict then Trunc (`F32, s) else TruncSat (`F32, s)))
              | F64, Signedtype { typ = `I64; signage = s; strict } ->
                  UnOp
                    (I64
                       (if strict then Trunc (`F64, s) else TruncSat (`F64, s)))
              (* Convert *)
              | I32, Signedtype { typ = `F32; signage; _ } ->
                  UnOp (F32 (Convert (`I32, signage)))
              | I64, Signedtype { typ = `F32; signage; _ } ->
                  UnOp (F32 (Convert (`I64, signage)))
              | I32, Signedtype { typ = `F64; signage; _ } ->
                  UnOp (F64 (Convert (`I32, signage)))
              | I64, Signedtype { typ = `F64; signage; _ } ->
                  UnOp (F64 (Convert (`I64, signage)))
              (* Identity *)
              | I32, Valtype I32
              | I64, Valtype I64
              | F32, Valtype F32
              | F64, Valtype F64 ->
                  Nop
              (* Cast to an inline function type: ref.cast to the anonymous
                 function type minted for the cast's result. *)
              | _, Functype _ ->
                  ensure_type_is_defined ctx (Ref (expr_reftype i));
                  RefCast (reftype (expr_reftype i))
              | _ ->
                  print_valtype in_ty;
                  print_instr i;
                  assert false
            in
            folded loc instr code
      in
      match expr.desc with
      (* (mem.load8/16(p) as i32_S) as i64_S  ->  i64.load8/16_S *)
      | Cast
          ( {
              desc =
                Call
                  ( { desc = StructGet ({ desc = Get memname; _ }, meth); _ },
                    args );
              _;
            },
            Signedtype { typ = `I32; signage = s1; _ } )
        when Hashtbl.mem ctx.memories memname.desc
             && (meth.desc = "load8" || meth.desc = "load16") -> (
          match cast_ty with
          | Signedtype { typ = `I64; signage = s2; _ } when s1 = s2 ->
              let memidx = index memname in
              let memarg = mem_memarg meth.desc 1 args in
              let addr_code = instruction ret ctx (List.nth args 0) in
              let size = if meth.desc = "load8" then `I8 else `I16 in
              folded (snd expr.info)
                (LoadS (memidx, memarg, `I64, size, s1))
                addr_code
          | _ -> default_cast ())
      (* mem.load8/16(p) as i32_S -> i32.load8/16_S ; mem.load32(p) as i64_S ->
         i64.load32_S *)
      | Call ({ desc = StructGet ({ desc = Get memname; _ }, meth); _ }, args)
        when Hashtbl.mem ctx.memories memname.desc
             && (meth.desc = "load8" || meth.desc = "load16"
               || meth.desc = "load32") -> (
          let emit result_ty size signage =
            let memidx = index memname in
            let memarg = mem_memarg meth.desc 1 args in
            let addr_code = instruction ret ctx (List.nth args 0) in
            folded (snd expr.info)
              (LoadS (memidx, memarg, result_ty, size, signage))
              addr_code
          in
          match (meth.desc, cast_ty) with
          | "load8", Signedtype { typ = `I32; signage; _ } ->
              emit `I32 `I8 signage
          | "load16", Signedtype { typ = `I32; signage; _ } ->
              emit `I32 `I16 signage
          | "load32", Signedtype { typ = `I64; signage; _ } ->
              emit `I64 `I32 signage
          | _ -> default_cast ())
      | StructGet (instr_val, field_idx) -> (
          match (expr_type expr, cast_ty) with
          | Packed _, Signedtype { typ = `I32; signage; _ } ->
              let type_name_idx = expr_type_name instr_val in
              folded (snd expr.info)
                (StructGet (Some signage, index type_name_idx, index field_idx))
                (instruction ret ctx instr_val)
          | _ -> default_cast ())
      | ArrayGet (arr_instr, idx_instr) -> (
          match (expr_type expr, cast_ty) with
          | Packed _, Signedtype { typ = `I32; signage; _ } ->
              let type_name_idx = expr_type_name arr_instr in
              folded (snd expr.info)
                (ArrayGet (Some signage, index type_name_idx))
                (instruction ret ctx arr_instr @ instruction ret ctx idx_instr)
          | _ -> default_cast ())
      | Null -> (
          match cast_ty with
          | Valtype (Ref r) ->
              let null = folded (snd expr.info) (RefNull (heaptype r.typ)) [] in
              if r.nullable then null else folded loc (RefCast (reftype r)) null
          | _ -> default_cast ())
      | _ -> default_cast ())
  | Test (expr, typ) ->
      folded loc (RefTest (reftype typ)) (instruction ret ctx expr)
  | NonNull expr -> folded loc RefAsNonNull (instruction ret ctx expr)
  | Struct (opt_idx, fields) ->
      let idx = Option.value ~default:(expr_type_name i) opt_idx in
      let field_names = Hashtbl.find ctx.struct_fields idx.desc in
      let field_map =
        List.fold_left
          (fun acc (name, instr) -> StringMap.add name.desc instr acc)
          StringMap.empty fields
      in
      let instrs =
        List.map (fun name -> StringMap.find name field_map) field_names
      in
      let args_code = List.concat_map (instruction ret ctx) instrs in
      folded loc (StructNew (index idx)) args_code
  | StructDefault opt_idx ->
      let idx = Option.value ~default:(expr_type_name i) opt_idx in
      folded loc (StructNewDefault (index idx)) []
  | StructGet (instr_val, field) ->
      (* Plain struct field access; the instruction methods that used to share
         this syntax now take parentheses and are handled in the [Call] case. *)
      folded loc
        (StructGet (None, index (expr_type_name instr_val), index field))
        (instruction ret ctx instr_val)
  | StructSet (instr_val, field_idx, new_val) ->
      let code_val = instruction ret ctx instr_val in
      let code_new = instruction ret ctx new_val in
      folded loc
        (StructSet (index (expr_type_name instr_val), index field_idx))
        (code_val @ code_new)
  | Array (opt_idx, val_instr, len_instr) ->
      let idx = Option.value ~default:(expr_type_name i) opt_idx in
      folded loc
        (ArrayNew (index idx))
        (instruction ret ctx val_instr @ instruction ret ctx len_instr)
  | ArrayDefault (opt_idx, len_instr) ->
      let idx = Option.value ~default:(expr_type_name i) opt_idx in
      folded loc (ArrayNewDefault (index idx)) (instruction ret ctx len_instr)
  | ArrayFixed (opt_idx, instrs) ->
      let idx = Option.value ~default:(expr_type_name i) opt_idx in
      let args_code = List.concat_map (instruction ret ctx) instrs in
      let len = Uint32.of_int (List.length instrs) in
      folded loc (ArrayNewFixed (index idx, len)) args_code
  | ArraySegment (opt_idx, seg, off_instr, len_instr) ->
      let idx = Option.value ~default:(expr_type_name i) opt_idx in
      (* An element segment means [array.new_elem]; otherwise a data segment. *)
      let desc : _ Text.instr_desc =
        if Hashtbl.mem ctx.elems seg.desc then
          ArrayNewElem (index idx, index seg)
        else ArrayNewData (index idx, index seg)
      in
      folded loc desc
        (instruction ret ctx off_instr @ instruction ret ctx len_instr)
  (* [tab[i]] on a table name is [table.get]. *)
  | ArrayGet ({ desc = Get name; _ }, idx_instr)
    when Hashtbl.mem ctx.tables name.desc ->
      folded loc (TableGet (index name)) (instruction ret ctx idx_instr)
  | ArrayGet (arr_instr, idx_instr) ->
      (* Signed accesses are under a cast *)
      folded loc
        (ArrayGet (None, index (expr_type_name arr_instr)))
        (instruction ret ctx arr_instr @ instruction ret ctx idx_instr)
  (* [tab[i] = v] on a table name is [table.set]. *)
  | ArraySet ({ desc = Get name; _ }, idx_instr, val_instr)
    when Hashtbl.mem ctx.tables name.desc ->
      folded loc
        (TableSet (index name))
        (instruction ret ctx idx_instr @ instruction ret ctx val_instr)
  | ArraySet (arr_instr, idx_instr, val_instr) ->
      folded loc
        (ArraySet (index (expr_type_name arr_instr)))
        (instruction ret ctx arr_instr
        @ instruction ret ctx idx_instr
        @ instruction ret ctx val_instr)
  | BinOp (op, a, b) -> (
      let code_a = instruction ret ctx a in
      let code_b = instruction ret ctx b in
      let operand_type = expr_valtype a in
      match (op, operand_type) with
      | Eq, Ref _ -> folded loc RefEq (code_a @ code_b)
      | Ne, Ref _ ->
          (* !(a == b) *)
          (*ZZZ Support in types?*)
          folded loc (Text.UnOp (I32 Eqz)) (folded loc RefEq (code_a @ code_b))
      | _ ->
          let opcode = binop i op operand_type in
          folded loc opcode (code_a @ code_b))
  | UnOp (Neg, ({ desc = Int n | Float n; _ } as a)) ->
      let n = "-" ^ n in
      folded loc
        (Const
           (match expr_opt_valtype a with
           | Some I32 | None -> I32 n
           | Some I64 -> I64 n
           | Some F32 -> F32 n
           | Some F64 -> F64 n
           | _ -> assert false))
        []
  | UnOp (op, a) -> (
      let operand_type = expr_opt_valtype a in
      match (op, operand_type) with
      | Neg, (Some I32 | None) ->
          (* 0 - a *)
          let zero = folded loc (Const (I32 "0")) [] in
          let sub = Text.BinOp (I32 Sub) in
          folded loc sub (zero @ instruction ret ctx a)
      | Neg, Some I64 ->
          let zero = folded loc (Const (I64 "0")) [] in
          let sub = Text.BinOp (I64 Sub) in
          folded loc sub (zero @ instruction ret ctx a)
      | Neg, Some F32 -> folded loc (UnOp (F32 Neg)) (instruction ret ctx a)
      | Neg, Some F64 -> folded loc (UnOp (F64 Neg)) (instruction ret ctx a)
      | Not, (Some I32 | None) ->
          folded loc (UnOp (I32 Eqz)) (instruction ret ctx a)
      | Not, Some I64 -> folded loc (UnOp (I64 Eqz)) (instruction ret ctx a)
      (* Ref IsNull *)
      | Not, Some (Ref _) -> folded loc RefIsNull (instruction ret ctx a)
      | Pos, _ -> instruction ret ctx a
      | _, Some _ -> assert false)
  | Let (decls, None) ->
      let binding (id, ty) =
        match id with
        | Some name ->
            let ty = Option.get ty in
            let wasm_name = Namespace.add ctx.namespace name.desc in
            ctx.locals <- StringMap.add name.desc wasm_name ctx.locals;
            ctx.allocated_locals :=
              (Some { name with desc = wasm_name }, valtype ty)
              :: !(ctx.allocated_locals)
        | None -> assert false
      in
      List.iter binding (List.rev decls);
      []
  | Let ([ (id, ty) ], Some body) -> (
      (* Single binding: fold the initializer into the [local.set]. *)
      match id with
      | Some name ->
          let ty = match ty with Some ty -> ty | None -> expr_valtype body in
          let wasm_name = Namespace.add ctx.namespace name.desc in
          ctx.locals <- StringMap.add name.desc wasm_name ctx.locals;
          ctx.allocated_locals :=
            (Some { name with desc = wasm_name }, valtype ty)
            :: !(ctx.allocated_locals);
          folded loc
            (Text.LocalSet (with_loc name.info (Text.Id wasm_name)))
            (instruction ret ctx body)
      | None -> folded loc Text.Drop (instruction ret ctx body))
  | Let (decls, Some body) ->
      (* Multi-value initializer: evaluate it once, leaving one value per name
         on the stack, then store each into its local. The last value is on top,
         so the stores run in reverse declaration order. *)
      let code = instruction ret ctx body in
      let result_types = fst body.info in
      let store idx (id, ty) =
        match id with
        | Some name ->
            let ty =
              match ty with
              | Some ty -> ty
              | None -> unpack_type (Option.get result_types.(idx))
            in
            let wasm_name = Namespace.add ctx.namespace name.desc in
            ctx.locals <- StringMap.add name.desc wasm_name ctx.locals;
            ctx.allocated_locals :=
              (Some { name with desc = wasm_name }, valtype ty)
              :: !(ctx.allocated_locals);
            folded loc
              (Text.LocalSet (with_loc name.info (Text.Id wasm_name)))
              []
        | None -> folded loc Text.Drop []
      in
      code @ List.concat (List.rev (List.mapi store decls))
  | Br (l, None) ->
      (*ZZZ label should be located*)
      folded loc (Br (label ret l)) []
  | Br (l, Some expr) ->
      folded loc (Br (label ret l)) (instruction ret ctx expr)
  | Br_if (l, expr) ->
      folded loc (Br_if (label ret l)) (instruction ret ctx expr)
  | Br_table (labels, expr) -> (
      let code = instruction ret ctx expr in
      match List.rev labels with
      | default_label_name :: other_labels_rev ->
          let default_idx = label ret default_label_name in
          let other_idx =
            List.rev_map (fun l -> label ret l) other_labels_rev
          in
          folded loc (Br_table (other_idx, default_idx)) code
      | _ -> assert false)
  | Br_on_null (l, expr) ->
      folded loc (Br_on_null (label ret l)) (instruction ret ctx expr)
  | Br_on_non_null (l, expr) ->
      folded loc (Br_on_non_null (label ret l)) (instruction ret ctx expr)
  | Br_on_cast (l, target_reftype, expr) ->
      (*ZZZ LUB for now *)
      folded loc
        (Br_on_cast
           ( label ret l,
             reftype
               (Option.value ~default:target_reftype (expr_opt_reftype expr)),
             reftype target_reftype ))
        (instruction ret ctx expr)
  | Br_on_cast_fail (l, target_reftype, expr) ->
      folded loc
        (Br_on_cast_fail
           ( label ret l,
             reftype
               (Option.value ~default:target_reftype (expr_opt_reftype expr)),
             reftype target_reftype ))
        (instruction ret ctx expr)
  | Throw (tag_idx, args) ->
      let args =
        match args with None -> [] | Some args -> instruction ret ctx args
      in
      folded loc (Throw (index tag_idx)) args
  | ThrowRef expr -> folded loc ThrowRef (instruction ret ctx expr)
  | ContNew (ct, f) -> folded loc (ContNew (index ct)) (instruction ret ctx f)
  | ContBind (src, dst, l) ->
      folded loc
        (ContBind (index src, index dst))
        (List.concat_map (instruction ret ctx) l)
  | Suspend (tag, l) ->
      folded loc (Suspend (index tag)) (List.concat_map (instruction ret ctx) l)
  | Resume (ct, handlers, l) ->
      folded loc
        (Resume (index ct, List.map (on_clause ret) handlers))
        (List.concat_map (instruction ret ctx) l)
  | ResumeThrow (ct, tag, handlers, l) ->
      folded loc
        (ResumeThrow (index ct, index tag, List.map (on_clause ret) handlers))
        (List.concat_map (instruction ret ctx) l)
  | ResumeThrowRef (ct, handlers, l) ->
      folded loc
        (ResumeThrowRef (index ct, List.map (on_clause ret) handlers))
        (List.concat_map (instruction ret ctx) l)
  | Switch (ct, tag, l) ->
      folded loc
        (Switch (index ct, index tag))
        (List.concat_map (instruction ret ctx) l)
  | Return None -> folded loc Return []
  | Return (Some expr) -> folded loc Return (instruction ret ctx expr)
  | Sequence body -> List.concat_map (instruction ret ctx) body
  | Select (cond, then_, else_) ->
      let code_then = instruction ret ctx then_ in
      let code_else = instruction ret ctx else_ in
      let code_cond = instruction ret ctx cond in
      let typ =
        match expr_opt_valtype i with
        | None | Some (I32 | I64 | F32 | F64 | V128) -> None
        | Some typ ->
            ensure_type_is_defined ctx typ;
            Some [ valtype typ ]
      in
      folded loc (Select typ) (code_then @ code_else @ code_cond)
  | Char c -> folded loc (Char c) []
  | String (ty, s) ->
      folded loc (String (Option.map index ty, [ { desc = s; info = loc } ])) []
  | If_annotation { cond; then_body; else_body } ->
      let conv body = List.concat_map (instruction ret ctx) body in
      [
        with_loc loc
          (Text.If_annotation
             {
               cond;
               then_body = conv then_body;
               else_body = Option.map conv else_body;
             });
      ]

let import attributes =
  List.find_map
    (fun (k, v) ->
      match (k, v.desc) with
      | ( "import",
          Sequence
            [
              { desc = String (_, m); info = l };
              { desc = String (_, n); info = l' };
            ] ) ->
          Some ({ desc = m; info = l }, { desc = n; info = l' })
      | _ -> None)
    attributes

let exports attributes =
  List.filter_map
    (fun (k, v) ->
      match (k, v.desc) with
      | "export", String (_, n) -> Some { v with desc = n }
      | _ -> None)
    attributes

let globaltype mut t : Text.globaltype = { mut; typ = valtype t }

(* Smallest memory size (in 64KiB pages) that holds the declared active data
   segments, used when a memory omits explicit limits. Only literal offsets
   contribute; others are ignored. *)
let derive_min_pages (data : _ Wax.Ast.memdata list) =
  let extent =
    List.fold_left
      (fun acc (d : _ Wax.Ast.memdata) ->
        match d.offset.desc with
        | Wax.Ast.Int s -> (
            try
              Int64.max acc
                (Int64.add (Int64.of_string s)
                   (Int64.of_int (String.length d.init)))
            with _ -> acc)
        | _ -> acc)
      0L data
  in
  let pages = Int64.div (Int64.add extent 65535L) 65536L in
  Utils.Uint64.of_int64 (if Int64.compare pages 1L < 0 then 1L else pages)

let storagetype typ : Text.storagetype =
  match typ with Value v -> Value (valtype v) | Packed p -> Packed p

let subtype s : Text.subtype =
  let typ : Text.comptype =
    match s.typ with
    | Func typ -> Func (functype typ)
    | Struct fields ->
        Struct
          (Array.map
             (fun field ->
               let name, { mut; typ } = field.desc in
               {
                 Ast.desc =
                   (Some name, { Text.Types.mut; typ = storagetype typ });
                 info = field.info;
               })
             fields)
    | Array { mut; typ } -> Array { mut; typ = storagetype typ }
    | Cont idx -> Cont (index idx)
  in
  { typ; supertype = Option.map index s.supertype; final = s.final }

let reorder_imports lst =
  let rec traverse acc (cur : (_ Ast.Text.modulefield, _) Ast.annotated list) =
    match cur with
    | [] -> lst (* Nothing to do *)
    | ({
         Ast.desc = Import _ | Types _ | Export _ | Start _ | Elem _ | Data _;
         _;
       } as f)
      :: rem ->
        traverse (f :: acc) rem
    | {
        desc =
          ( Func _ | Memory _ | Table _ | Tag _ | Global _ | String_global _
          | Module_if_annotation _ );
        _;
      }
      :: _ ->
        let imports, others =
          List.partition
            (fun f ->
              match f.desc with Ast.Text.Import _ -> true | _ -> false)
            cur
        in
        List.rev_append acc (imports @ others)
  in
  traverse [] lst

let module_ diagnostics types fields =
  let func_refs_in_func = Hashtbl.create 16 in
  let func_refs_outside_func = Hashtbl.create 16 in
  let ctx =
    {
      globals = Hashtbl.create 16;
      functions = Hashtbl.create 16;
      memories = Hashtbl.create 16;
      tables = Hashtbl.create 16;
      elems = Hashtbl.create 16;
      locals = StringMap.empty;
      allocated_locals = ref [];
      namespace = Namespace.make ();
      type_kinds = Hashtbl.create 16;
      struct_fields = Hashtbl.create 16;
      referenced_functions = Hashtbl.create 16;
      extra_types = Hashtbl.create 16;
      types;
      diagnostics;
    }
  in
  Wax.Ast_utils.iter_fields
    (fun field ->
      match field.desc with
      | Type rectype ->
          Array.iter
            (fun rt ->
              let idx, subtype = rt.desc in
              let kind =
                match subtype.typ with
                | Func _ -> `Func
                (* Continuation types have no Wax surface syntax, so this case
                   is unreachable for Wax-native input. *)
                | Cont _ -> `Func
                | Array _ -> `Array
                | Struct fields ->
                    let field_names =
                      Array.to_list
                        (Array.map (fun field -> (fst field.desc).desc) fields)
                    in
                    Hashtbl.add ctx.struct_fields idx.desc field_names;
                    `Struct
              in
              Hashtbl.add ctx.type_kinds idx.desc kind)
            rectype
      | Func { name; _ } -> Hashtbl.replace ctx.functions name.desc ()
      | GlobalDecl { name; _ } -> Hashtbl.replace ctx.globals name.desc ()
      | Global { name; _ } -> Hashtbl.replace ctx.globals name.desc ()
      | Fundecl { name; _ } -> Hashtbl.replace ctx.functions name.desc ()
      | Memory { name; _ } -> Hashtbl.replace ctx.memories name.desc ()
      | Table { name; reftype = rt; _ } ->
          Hashtbl.replace ctx.tables name.desc rt
      | Elem { name; _ } -> Hashtbl.replace ctx.elems name.desc ()
      | Tag _ | Data _ | Group _ | Conditional _ -> ())
    fields;
  let rec convert_fields fields =
    List.concat_map
      (fun field ->
        match field.desc with
        | Group { fields = flds; _ } -> convert_fields flds
        | Memory { name; address_type; limits; data; attributes } ->
            let exports = exports attributes in
            let limits_value : Ast.limits =
              match limits with
              | Some (mi, ma) -> { mi; ma; address_type }
              | None -> { mi = derive_min_pages data; ma = None; address_type }
            in
            let memory_field =
              match import attributes with
              | Some (module_, import_name) ->
                  Text.Import
                    {
                      module_;
                      name = import_name;
                      id = Some name;
                      desc = Memory (Ast.no_loc limits_value);
                      exports;
                    }
              | None ->
                  Text.Memory
                    {
                      id = Some name;
                      limits = Ast.no_loc limits_value;
                      init = None;
                      exports;
                    }
            in
            let ictx =
              { ctx with referenced_functions = func_refs_outside_func }
            in
            let data_fields =
              List.map
                (fun (d : _ Wax.Ast.memdata) ->
                  {
                    field with
                    desc =
                      Text.Data
                        {
                          id = d.data_name;
                          init = [ { desc = d.init; info = field.info } ];
                          mode =
                            Active (index name, instruction None ictx d.offset);
                        };
                  })
                data
            in
            { field with desc = memory_field } :: data_fields
        | Data { name; mode; init; _ } ->
            let mode : _ Text.datamode =
              match mode with
              | Passive -> Passive
              | Active (mem, off) ->
                  let ictx =
                    { ctx with referenced_functions = func_refs_outside_func }
                  in
                  Active (index mem, instruction None ictx off)
            in
            [
              {
                field with
                desc =
                  Text.Data
                    {
                      id = name;
                      init = [ { desc = init; info = field.info } ];
                      mode;
                    };
              };
            ]
        | Table { name; address_type; reftype = rt; limits; init; attributes }
          ->
            let exports = exports attributes in
            let mi, ma =
              match limits with
              | Some (mi, ma) -> (mi, ma)
              | None -> (Utils.Uint64.of_int 0, None)
            in
            let typ : Text.tabletype =
              {
                limits = Ast.no_loc { Ast.mi; ma; address_type };
                reftype = reftype rt;
              }
            in
            let init_value : _ Text.tableinit =
              match init with
              | None -> Init_default
              | Some e ->
                  let ictx =
                    { ctx with referenced_functions = func_refs_outside_func }
                  in
                  Init_expr (instruction None ictx e)
            in
            let table_field =
              match import attributes with
              | Some (module_, import_name) ->
                  Text.Import
                    {
                      module_;
                      name = import_name;
                      id = Some name;
                      desc = Table typ;
                      exports;
                    }
              | None ->
                  Text.Table { id = Some name; typ; init = init_value; exports }
            in
            [ { field with desc = table_field } ]
        | Elem { name; reftype = rt; mode; init; _ } ->
            let ictx =
              { ctx with referenced_functions = func_refs_outside_func }
            in
            let mode : _ Text.elemmode =
              match mode with
              | EPassive -> Passive
              | EActive (tab, off) ->
                  Active (index tab, instruction None ictx off)
            in
            let init = List.map (fun e -> instruction None ictx e) init in
            [
              {
                field with
                desc =
                  Text.Elem { id = Some name; typ = reftype rt; init; mode };
              };
            ]
        | Conditional { cond; then_fields; else_fields } ->
            [
              {
                field with
                desc =
                  Text.Module_if_annotation
                    {
                      cond;
                      then_fields = convert_fields then_fields;
                      else_fields = Option.map convert_fields else_fields;
                    };
              };
            ]
        | _ ->
            let desc =
              match field.desc with
              | Type rectype ->
                  Text.Types
                    (Array.map
                       (fun rt ->
                         let idx, s = rt.desc in
                         Ast.no_loc (Some idx, subtype s))
                       rectype)
              | Global { name; mut; typ; def; attributes } ->
                  let typ =
                    match typ with
                    | Some typ -> typ
                    | None ->
                        (*ZZZ *)
                        let typ = expr_valtype def in
                        ensure_type_is_defined ctx typ;
                        typ
                  in
                  let init =
                    let ctx =
                      { ctx with referenced_functions = func_refs_outside_func }
                    in
                    instruction None ctx def
                  in
                  Text.Global
                    {
                      id = Some name;
                      typ = globaltype mut typ;
                      init;
                      exports = exports attributes;
                    }
              | GlobalDecl { name; mut; typ; attributes } ->
                  let module_, import_name = Option.get (import attributes) in
                  Text.Import
                    {
                      module_;
                      name = import_name;
                      id = Some name;
                      desc = Global (globaltype mut typ);
                      exports = exports attributes;
                    }
              | Fundecl { name; typ; sign; attributes } ->
                  let module_, import_name = Option.get (import attributes) in
                  Text.Import
                    {
                      module_;
                      name = import_name;
                      id = Some name;
                      desc = Func (typeuse typ sign);
                      exports = exports attributes;
                    }
              | Tag { name; typ; sign; attributes } -> (
                  let exports = exports attributes in
                  match import attributes with
                  | Some (module_, import_name) ->
                      Text.Import
                        {
                          module_;
                          name = import_name;
                          id = Some name;
                          desc = Tag (typeuse typ sign);
                          exports;
                        }
                  | None ->
                      Text.Tag
                        { id = Some name; typ = typeuse typ sign; exports })
              | Func { name; sign; typ; body = label, instrs; attributes } ->
                  let namespace = Namespace.make () in
                  let allocated_locals = ref [] in
                  let locals =
                    Array.fold_left
                      (fun locals (id, _) ->
                        match id with
                        | Some id ->
                            let wasm_name = Namespace.add namespace id.desc in
                            StringMap.add id.desc wasm_name locals
                        | None -> locals)
                      StringMap.empty
                      (match sign with
                      | Some sign -> sign.params
                      | None -> [||])
                  in
                  let ctx =
                    {
                      ctx with
                      namespace;
                      allocated_locals;
                      locals;
                      referenced_functions = func_refs_in_func;
                    }
                  in
                  let instrs =
                    List.concat_map
                      (instruction
                         (Option.map (fun label -> (label.desc, 0)) label)
                         ctx)
                      instrs
                  in
                  let func_locals = List.rev !allocated_locals in
                  Text.Func
                    {
                      id = Some name;
                      typ = typeuse typ sign;
                      locals = List.map Ast.no_loc func_locals;
                      instrs;
                      exports = exports attributes;
                    }
              | Group _ | Conditional _ | Memory _ | Data _ | Table _ | Elem _
                ->
                  assert false
            in
            [ { field with desc } ])
      fields
  in
  let wasm_fields = convert_fields fields in
  let extra_types =
    Hashtbl.fold
      (fun _ (idx, s) rem ->
        Ast.no_loc (Text.Types [| Ast.no_loc (Some idx, subtype s) |]) :: rem)
      ctx.extra_types []
  in
  let elem_declare : (_ Text.modulefield, _) Ast.annotated list =
    let funcs =
      Hashtbl.fold
        (fun k _ acc ->
          if Hashtbl.mem func_refs_outside_func k then acc else k :: acc)
        func_refs_in_func []
    in
    if funcs = [] then []
    else
      let init =
        List.map
          (fun name ->
            [ Ast.no_loc (Text.RefFunc (Ast.no_loc (Text.Id name))) ])
          funcs
      in
      [
        Ast.no_loc
          (Text.Elem
             {
               id = None;
               typ = { nullable = false; typ = Func };
               init;
               mode = Declare;
             });
      ]
  in
  let wasm_fields = wasm_fields @ extra_types @ elem_declare in
  let wasm_fields = reorder_imports wasm_fields in
  (None, wasm_fields)

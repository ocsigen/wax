(* fuzz_gen — generate a hand-written-style Wax *source* module to fuzz the Wax
   type checker (lib-wax/typing.ml).

   Usage: fuzz_gen <seed> [err]     (Wax source to stdout; [err] injects one
                                      deliberate type error)

   Why this exists: the .wax the harness otherwise type-checks comes from
   DECOMPILING wasm (the mutate-wax / diff-validate seeds), so it only ever
   contains the constructs from_wasm emits — never the surface sugar a human
   writes, which is exactly what large parts of typing.ml exist to check: infix
   operators and their signed/unsigned variants, `as` conversions, `if`/`?:`
   with inferred result types, struct/array literals, field/index access,
   `match`, and reference types. This is a type-DIRECTED generator: every
   expression is built to a chosen type, so the module type-checks and the
   checker runs its inference/checking arms in full (rather than bailing at the
   first error) — while `err` produces the opposite, a single well-placed
   mismatch, to exercise the rejection arms.

   Unlike a text generator, the module is built as a real AST and printed through
   Wax_lang.Output, so the output ALWAYS re-parses: the only rejections are
   genuine type verdicts, never a serialization bug. The paired driver is
   fuzz/type-fuzz.sh (checker soundness: an accepted module must emit a binary
   the reference validates, plus round-trip and no-crash).

   The trick that makes type-directed generation tractable: every function has
   the SAME parameter signature (a:i32 b:i64 c:f32 d:f64 p:&point r:&pair q:&ints
   s:&eq), so an expression of a given type is always formable from those names,
   and any function is callable with a uniform argument list. Three struct/array
   types are declared up front; structs are subtypes of eq, so `match` on the eq
   parameter can downcast to them (and, lowered, exercises the decompiler's
   match/br_on_cast recovery on a round-trip). *)

module Ast = Wax_lang.Ast

let seed = try int_of_string Sys.argv.(1) with _ -> 0
let err = Array.exists (fun a -> a = "err") Sys.argv
let st = Random.State.make [| seed |]
let rnd n = Random.State.int st n
let pick a = a.(rnd (Array.length a))
let nl = Ast.no_loc
let id s = nl s

(* The value types expressions are built to: four numeric, plus references to
   the two struct types, the array type, and the abstract eq supertype. *)
type ty = I32 | I64 | F32 | F64 | Point | Pair | Ints | Eq

let num_ty = [| I32; I64; F32; F64 |]
let all_params = [| I32; I64; F32; F64; Point; Pair; Ints; Eq |]

(* Result types a function may return (Eq excluded: less useful as a callee). *)
let result_ty = [| I32; I64; F32; F64; Point; Pair; Ints |]
let is_num = function I32 | I64 | F32 | F64 -> true | _ -> false
let is_int = function I32 | I64 -> true | _ -> false

let heaptype : ty -> Ast.heaptype = function
  | Point -> Ast.Type (id "point")
  | Pair -> Ast.Type (id "pair")
  | Ints -> Ast.Type (id "ints")
  | Eq -> Ast.Eq
  | _ -> assert false

let reftype t : Ast.reftype = { nullable = false; typ = heaptype t }

let valtype = function
  | I32 -> Ast.I32
  | I64 -> Ast.I64
  | F32 -> Ast.F32
  | F64 -> Ast.F64
  | t -> Ast.Ref (reftype t)

let pname = function
  | I32 -> "a"
  | I64 -> "b"
  | F32 -> "c"
  | F64 -> "d"
  | Point -> "p"
  | Pair -> "r"
  | Ints -> "q"
  | Eq -> "s"

(* Number of functions and their result types (round-robin, so a call of any
   type always has a callee). *)
let nf = 2 + rnd 4
let rtys = Array.init nf (fun k -> result_ty.(k mod Array.length result_ty))

let int_binops =
  [|
    Ast.Add;
    Ast.Sub;
    Ast.Mul;
    Ast.And;
    Ast.Or;
    Ast.Xor;
    Ast.Shl;
    Ast.Shr Ast.Signed;
    Ast.Shr Ast.Unsigned;
  |]

let flt_binops = [| Ast.Add; Ast.Sub; Ast.Mul; Ast.Div None |]

let int_cmps =
  [|
    Ast.Eq;
    Ast.Ne;
    Ast.Lt (Some Ast.Signed);
    Ast.Lt (Some Ast.Unsigned);
    Ast.Gt (Some Ast.Signed);
    Ast.Le (Some Ast.Signed);
    Ast.Ge (Some Ast.Unsigned);
  |]

let flt_cmps =
  [| Ast.Eq; Ast.Ne; Ast.Lt None; Ast.Gt None; Ast.Le None; Ast.Ge None |]

(* Method-style intrinsics: [x.m(args)] parses as Call (StructGet (x, m), args). *)
let int_umeth = [| "clz"; "ctz"; "popcnt"; "extend8_s"; "extend16_s" |]
let int_bmeth = [| "rotl"; "rotr" |]
let flt_umeth = [| "abs"; "sqrt"; "floor"; "ceil"; "trunc"; "nearest" |]
let flt_bmeth = [| "min"; "max"; "copysign" |]

(* A leaf is always the parameter of type [t] — a definite type. Bare integer
   and float literals are polymorphic in Wax (a float literal defaults to f64),
   so a literal is only unambiguous where the surrounding context forces its
   type (a binop operand, a typed assignment, a call argument) — NOT as a method
   or cast receiver, where the wrong width silently changes the result type. We
   therefore emit literals only in forced positions (see [operand]) and never as
   a bare leaf. *)
let leaf t : Ast.location Ast.instr = nl (Ast.Get (id (pname t)))

(* An operand in a type-forced position (a binop side): occasionally a literal,
   which the binop's type pins down, so its polymorphism is resolved. *)
let operand t d gen_t : Ast.location Ast.instr =
  if (not (is_num t)) || d > 0 || rnd 3 <> 0 then gen_t ()
  else if is_int t then nl (Ast.Int (string_of_int (rnd 9)))
  else nl (Ast.Float (Printf.sprintf "%d.5" (rnd 9)))

(* i32-producing accessors on the reference parameters: struct fields, an array
   element, the array length. *)
let field_get () =
  match rnd 5 with
  | 0 -> nl (Ast.StructGet (leaf Point, id "x"))
  | 1 -> nl (Ast.StructGet (leaf Point, id "y"))
  | 2 -> nl (Ast.StructGet (leaf Pair, id "a"))
  | 3 -> nl (Ast.StructGet (leaf Pair, id "b"))
  | _ -> nl (Ast.StructGet (leaf Pair, id "a"))

(* A well-typed `as`/reinterpret conversion producing [t]. *)
let rec cast t d : Ast.location Ast.instr =
  let sgn = if rnd 2 = 0 then Ast.Signed else Ast.Unsigned in
  let signedto tt src =
    nl
      (Ast.Cast
         ( gen src (d - 1),
           Ast.Signedtype { typ = tt; signage = sgn; strict = false } ))
  in
  let valto vt src = nl (Ast.Cast (gen src (d - 1), Ast.Valtype vt)) in
  match t with
  | I32 -> (
      match rnd 3 with
      | 0 -> valto Ast.I32 I64 (* wrap *)
      | 1 -> signedto `I32 F32 (* trunc *)
      | _ -> meth (gen F32 (d - 1)) "to_bits" [] (* reinterpret *))
  | I64 -> (
      match rnd 3 with
      | 0 -> signedto `I64 I32 (* extend *)
      | 1 -> signedto `I64 F64 (* trunc *)
      | _ -> meth (gen F64 (d - 1)) "to_bits" [])
  | F32 -> (
      match rnd 3 with
      | 0 -> valto Ast.F32 F64 (* demote *)
      | 1 -> signedto `F32 I32 (* convert *)
      | _ -> meth (gen I32 (d - 1)) "from_bits" [])
  | F64 -> (
      match rnd 3 with
      | 0 -> valto Ast.F64 F32 (* promote *)
      | 1 -> signedto `F64 I64 (* convert *)
      | _ -> meth (gen I64 (d - 1)) "from_bits" [])
  | _ -> assert false

and meth recv name args : Ast.location Ast.instr =
  nl (Ast.Call (nl (Ast.StructGet (recv, id name)), args))

(* A call to some function returning type [t] (falls back to a leaf if none). *)
and call t : Ast.location Ast.instr =
  let cands = List.filter (fun k -> rtys.(k) = t) (List.init nf Fun.id) in
  match cands with
  | [] -> leaf t
  | _ ->
      let k = List.nth cands (rnd (List.length cands)) in
      nl
        (Ast.Call
           ( nl (Ast.Get (id ("f" ^ string_of_int k))),
             Array.to_list (Array.map (fun pt -> gen pt 0) all_params) ))

(* An `if`-expression of type [t]. *)
and if_ t d : Ast.location Ast.instr =
  let typ = Ast.{ params = [||]; results = [| valtype t |] } in
  nl
    (Ast.If
       {
         label = None;
         typ;
         cond = gen I32 (d - 1);
         if_block = nl [ gen t (d - 1) ];
         else_block = Some (nl [ gen t (d - 1) ]);
       })

(* An expression of type [t] at depth [d]. *)
and gen t d : Ast.location Ast.instr =
  if d <= 0 then leaf t else if is_num t then gen_num t d else gen_ref t d

and gen_num t d : Ast.location Ast.instr =
  (* A bare literal is only unambiguous in a top-down type-FORCED position (a
     binop operand pinned by its sibling, an [if]/[?:] branch pinned by the
     result type). It must never reach a method/cast RECEIVER, whose type Wax
     infers bottom-up first — so those use [gen], anchored to a typed param at
     its leaves. [flit] = a literal-or-gen in a forced spot. *)
  let flit () = operand t (d - 1) (fun () -> gen t (d - 1)) in
  (* Left operand [gen] pins the binop's type; the right may be a literal. *)
  let bin ops = nl (Ast.BinOp (nl (pick ops), gen t (d - 1), flit ())) in
  let umeth ms = meth (gen t (d - 1)) (pick ms) [] in
  let bmeth ms = meth (gen t (d - 1)) (pick ms) [ gen t (d - 1) ] in
  let cmp () =
    (* a comparison over some numeric type u, yielding i32 (only when t=i32) *)
    let u = pick num_ty in
    let op = if is_int u then pick int_cmps else pick flt_cmps in
    nl (Ast.BinOp (nl op, gen u (d - 1), gen u (d - 1)))
  in
  let ternary () = nl (Ast.Select (gen I32 (d - 1), gen t (d - 1), flit ())) in
  let neg () = nl (Ast.UnOp (nl Ast.Neg, gen t (d - 1))) in
  if is_int t then
    match rnd 100 with
    | n when n < 22 -> bin int_binops
    | n when n < 32 && t = I32 -> cmp ()
    | n when n < 40 -> umeth int_umeth
    | n when n < 46 -> bmeth int_bmeth
    | n when n < 51 -> neg ()
    | n when n < 63 -> cast t d
    | n when n < 73 -> if_ t d
    | n when n < 80 -> ternary ()
    | n when n < 88 && t = I32 -> field_get ()
    | n when n < 92 && t = I32 -> nl (Ast.ArrayGet (leaf Ints, gen I32 (d - 1)))
    | n when n < 95 && t = I32 -> meth (leaf Ints) "length" []
    | _ -> call t
  else
    match rnd 100 with
    | n when n < 28 -> bin flt_binops
    | n when n < 42 -> umeth flt_umeth
    | n when n < 50 -> bmeth flt_bmeth
    | n when n < 56 -> neg ()
    | n when n < 74 -> cast t d
    | n when n < 88 -> if_ t d
    | n when n < 94 -> ternary ()
    | _ -> call t

and gen_ref t d : Ast.location Ast.instr =
  let struct_lit name fields =
    nl
      (Ast.Struct
         (Some (id name), List.map (fun f -> (id f, gen I32 (d - 1))) fields))
  in
  match t with
  | Point -> (
      match rnd 100 with
      | n when n < 34 -> struct_lit "point" [ "x"; "y" ]
      | n when n < 54 -> if_ t d
      | n when n < 72 -> nl (Ast.Cast (leaf Eq, Ast.Valtype (valtype Point)))
      | n when n < 84 -> call t
      | _ -> leaf t)
  | Pair -> (
      match rnd 100 with
      | n when n < 34 -> struct_lit "pair" [ "a"; "b" ]
      | n when n < 54 -> if_ t d
      | n when n < 72 -> nl (Ast.Cast (leaf Eq, Ast.Valtype (valtype Pair)))
      | n when n < 84 -> call t
      | _ -> leaf t)
  | Ints -> (
      match rnd 100 with
      | n when n < 34 ->
          nl (Ast.Array (Some (id "ints"), gen I32 (d - 1), nl (Ast.Int "4")))
      | n when n < 54 -> if_ t d
      | n when n < 72 -> nl (Ast.Cast (leaf Eq, Ast.Valtype (valtype Ints)))
      | n when n < 84 -> call t
      | _ -> leaf t)
  | Eq -> (
      (* Any struct/array is a subtype of eq, so a struct literal serves. *)
      match rnd 100 with
      | n when n < 30 -> gen Point (d - 1)
      | n when n < 50 -> gen Pair (d - 1)
      | n when n < 65 -> gen Ints (d - 1)
      | n when n < 80 -> if_ t d
      | _ -> leaf t)
  | _ -> assert false

(* A `match` on the eq parameter as a function TAIL: it downcasts to the struct
   types, and every arm and the default `return`s a value of the result type
   [res]. In Wax `match` is a diverging control construct (its arms return/br),
   not a value-producing expression, so this is the only well-formed shape — and
   lowered to a br_on_cast chain it exercises the decompiler's match recovery on
   a round-trip. *)
let tail_match res : Ast.location Ast.instr =
  let ret () = nl (Ast.Return (Some (gen res 1))) in
  let arm t = (Ast.MatchCast (None, reftype t), [ ret () ]) in
  nl
    (Ast.Match
       {
         scrutinee = leaf Eq;
         arms = [ arm Point; arm Pair ];
         default = [ ret () ];
       })

(* A statement (no value escapes): assign a param (fully type-constrained),
   mutate a struct field / array element, or a nested control statement. *)
let rec stmt d : Ast.location Ast.instr =
  match rnd 100 with
  | n when n < 34 ->
      let t = pick all_params in
      nl (Ast.Set (Some (id (pname t)), gen t d))
  | n when n < 46 ->
      nl (Ast.Set (None, gen (pick num_ty) (max 1 d))) (* `_ = <determined>` *)
  | n when n < 58 ->
      (* [point.x] is the one mutable struct field. *)
      nl (Ast.StructSet (leaf Point, id "x", gen I32 d))
  | n when n < 68 ->
      (* the array element type is mutable *)
      nl (Ast.ArraySet (leaf Ints, gen I32 d, gen I32 d))
  | n when n < 84 && d > 0 ->
      let void = Ast.{ params = [||]; results = [||] } in
      nl
        (Ast.If
           {
             label = None;
             typ = void;
             cond = gen I32 (d - 1);
             if_block = nl [ stmt (d - 1) ];
             else_block = Some (nl [ stmt (d - 1) ]);
           })
  | _ when d > 0 ->
      nl
        (Ast.While
           { label = None; cond = gen I32 (d - 1); block = [ stmt (d - 1) ] })
  | _ ->
      let t = pick num_ty in
      nl (Ast.Set (Some (id (pname t)), gen t d))

(* One clean type error, to reach the checker's mismatch-reporting arms. *)
let poison () : Ast.location Ast.instr =
  match rnd 4 with
  | 0 ->
      nl
        (Ast.Set
           ( None,
             nl
               (Ast.BinOp
                  (nl Ast.Add, nl (Ast.Get (id "a")), nl (Ast.Get (id "d")))) ))
      (* i32 + f64 *)
  | 1 -> nl (Ast.Set (Some (id "b"), nl (Ast.Get (id "c")))) (* f32 into i64 *)
  | 2 -> nl (Ast.StructGet (leaf Point, id "nope")) (* unknown field *)
  | _ ->
      nl
        (Ast.BinOp
           ( nl (Ast.Lt (Some Ast.Signed)),
             nl (Ast.Get (id "c")),
             nl (Ast.Get (id "d")) ))
(* signed cmp on floats *)

let ftype mut t : Ast.fieldtype = { mut; typ = Ast.Value (valtype t) }

let subtype (typ : Ast.comptype) : Ast.subtype =
  { typ; supertype = None; final = true; descriptor = None; describes = None }

let field name mut t : (Ast.ident * Ast.fieldtype, Ast.location) Ast.annotated =
  nl (id name, ftype mut t)

let type_decls : Ast.location Ast.modulefield list =
  [
    Ast.Type
      [|
        nl
          ( id "point",
            subtype (Ast.Struct [| field "x" true I32; field "y" false I32 |])
          );
      |];
    Ast.Type
      [|
        nl
          ( id "pair",
            subtype (Ast.Struct [| field "a" false I32; field "b" false I32 |])
          );
      |];
    Ast.Type [| nl (id "ints", subtype (Ast.Array (ftype true I32))) |];
  ]

let func k : Ast.location Ast.modulefield =
  let res = rtys.(k) in
  let params =
    Array.map (fun t -> nl (Some (id (pname t)), valtype t)) all_params
  in
  let sign = Ast.{ params; results = [| valtype res |] } in
  let body =
    let ns = 1 + rnd 3 in
    let stmts = List.init ns (fun _ -> stmt 2) in
    let poison = if err && k = nf - 1 then [ poison () ] else [] in
    (* Occasionally end the function with a returning [match] instead of a plain
       value expression (a match must diverge, so it is a tail, not a value). *)
    let tail =
      if poison = [] && rnd 100 < 30 then [ tail_match res ] else [ gen res 2 ]
    in
    stmts @ poison @ tail
  in
  Ast.Func
    {
      name = id ("f" ^ string_of_int k);
      typ = None;
      sign = Some sign;
      body = (None, body);
      attributes = [];
    }

let () =
  let fields = type_decls @ List.init nf func in
  let m : Ast.location Ast.module_ = List.map nl fields in
  let f = Format.std_formatter in
  Wax_utils.Printer.run ~width:Wax_lang.Output.width f (fun p ->
      Wax_lang.Output.module_ ~color:Wax_utils.Colors.Never p
        ~trivia:(Hashtbl.create 0) m);
  Format.pp_print_flush f ()

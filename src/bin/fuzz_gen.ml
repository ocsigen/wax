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

   It also emits imports in both surface forms — a singleton `import "m" <decl>;`
   and a grouped `import "m" { … }` block — covering typing's import arms
   (function/global/tag registration, the name-only `#[import = "…"]` override,
   `#[export]` re-export). Imported functions share the uniform signature so
   they join the call pool; imported globals are read and written by the bodies.

   Unlike a text generator, the module is built as a real AST and printed through
   Wax_lang.Output, so the output ALWAYS re-parses: the only rejections are
   genuine type verdicts, never a serialization bug. The paired driver is
   fuzz/type-fuzz.sh (checker soundness: an accepted module must emit a binary
   the reference validates, plus round-trip and no-crash).

   The trick that makes type-directed generation tractable: every function has
   the SAME parameter signature (a:i32 b:i64 c:f32 d:f64 p:&point r:&pair q:&ints
   cs:&chars ws:&wchars s:&eq), so an expression of a given type is always
   formable from those names, and any function is callable with a uniform
   argument list. Several struct/array types are declared up front; structs are
   subtypes of eq, so `match` on the eq parameter can downcast to them (and,
   lowered, exercises the decompiler's match/br_on_cast recovery on a
   round-trip). The [chars]/[wchars] arrays ([i8]/[i16]) are what string literals
   build — [wchars] being UTF-16-encoded — so they exercise the string arms. *)

module Ast = Wax_lang.Ast

let seed = try int_of_string Sys.argv.(1) with _ -> 0
let err = Array.exists (fun a -> a = "err") Sys.argv
let st = Random.State.make [| seed |]
let rnd n = Random.State.int st n
let pick a = a.(rnd (Array.length a))
let nl = Ast.no_loc
let id s = nl s

(* A monotonically increasing counter, for minting unique local / label names
   (see [local_while_seq]) that never collide with each other or with the fixed
   param/global/function names. *)
let fresh =
  let c = ref 0 in
  fun () ->
    incr c;
    !c

(* The value types expressions are built to: four numeric, the v128 vector,
   references to the two struct types and the array type, and the abstract eq
   supertype. *)
type ty =
  | I32
  | I64
  | F32
  | F64
  | Vec
  | Point
  | Pair
  | Ints
  | Chars
  | Wchars
  | Eq
  | I31
  | Cont
  | Fn (* a function reference of the [task] type ([&fn(i32) -> i32]) *)

let num_ty = [| I32; I64; F32; F64 |]

let all_params =
  [|
    I32; I64; F32; F64; Vec; Point; Pair; Ints; Chars; Wchars; Eq; I31; Cont; Fn;
  |]

(* Result types a function may return (Eq excluded: less useful as a callee). *)
let result_ty =
  [| I32; I64; F32; F64; Vec; Point; Pair; Ints; Chars; Wchars; I31; Cont; Fn |]

let is_num = function I32 | I64 | F32 | F64 -> true | _ -> false
let is_int = function I32 | I64 -> true | _ -> false

let heaptype : ty -> Ast.heaptype = function
  | Point -> Ast.Type (id "point")
  | Pair -> Ast.Type (id "pair")
  | Ints -> Ast.Type (id "ints")
  | Chars -> Ast.Type (id "chars")
  | Wchars -> Ast.Type (id "wchars")
  | Eq -> Ast.Eq
  | I31 -> Ast.I31
  | Cont -> Ast.Type (id "k")
  (* A reference to the declared [task] function type is a funcref [&task]. *)
  | Fn -> Ast.Type (id "task")
  | _ -> assert false

let reftype t : Ast.reftype = { nullable = false; typ = heaptype t }

let valtype = function
  | I32 -> Ast.I32
  | I64 -> Ast.I64
  | F32 -> Ast.F32
  | F64 -> Ast.F64
  | Vec -> Ast.V128
  | t -> Ast.Ref (reftype t)

let pname = function
  | I32 -> "a"
  | I64 -> "b"
  | F32 -> "c"
  | F64 -> "d"
  | Vec -> "v"
  | Point -> "p"
  | Pair -> "r"
  | Ints -> "q"
  | Chars -> "cs"
  | Wchars -> "ws"
  | Eq -> "s"
  | I31 -> "n"
  | Cont -> "kc"
  | Fn -> "fr"

(* Method call on the declared memory [m]: [m.load32(p)], [m.store32(p, v)], … *)
let mem = nl (Ast.Get (id "m"))

(* Number of functions and their result types (round-robin, so a call of any
   type always has a callee). *)
let nf = 2 + rnd 4
let rtys = Array.init nf (fun k -> result_ty.(k mod Array.length result_ty))

(* Imported functions [g0…] share the SAME uniform parameter signature as the
   defined [f] functions, so they fold into one call pool: any call site can
   target either, with the same argument list. Their result types round-robin
   like [rtys] (offset by [nf] for variety). *)
let ng = 1 + rnd 3

let gtys =
  Array.init ng (fun k -> result_ty.((k + nf) mod Array.length result_ty))

(* Every callee — defined [f<k>] and imported [g<k>] — paired with its result
   type, so [call] can draw a callee of a wanted type from the whole set. *)
let callees =
  List.init nf (fun k -> ("f" ^ string_of_int k, rtys.(k)))
  @ List.init ng (fun k -> ("g" ^ string_of_int k, gtys.(k)))

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

(* String-literal contents: all valid Unicode (so an [i16]/UTF-16 string is
   accepted) and free of control characters (so a lowered string still
   decompiles back to a literal), spanning 1–4 UTF-8 bytes per scalar including a
   non-BMP scalar that becomes a UTF-16 surrogate pair. *)
let str_pool =
  [| "hi"; "abc"; "wax"; "café"; "naïve"; "Ω≈ç"; "日本語"; "😀"; "a😀b"; "é漢😀" |]

(* Method-style intrinsics: [x.m(args)] parses as Call (StructGet (x, m), args). *)
let int_umeth = [| "clz"; "ctz"; "popcnt"; "extend8_s"; "extend16_s" |]
let int_bmeth = [| "rotl"; "rotr" |]
let flt_umeth = [| "abs"; "sqrt"; "floor"; "ceil"; "trunc"; "nearest" |]
let flt_bmeth = [| "min"; "max"; "copysign" |]

(* SIMD lane ops, named [<op>_<shape>], as methods on a v128 receiver. *)
let vec_bin =
  [|
    "add_i8x16";
    "sub_i8x16";
    "add_i16x8";
    "sub_i16x8";
    "mul_i16x8";
    "add_i32x4";
    "sub_i32x4";
    "mul_i32x4";
    "add_i64x2";
    "sub_i64x2";
    "mul_i64x2";
    "add_f32x4";
    "sub_f32x4";
    "mul_f32x4";
    "div_f32x4";
    "min_f32x4";
    "max_f32x4";
    "add_f64x2";
    "sub_f64x2";
    "mul_f64x2";
    "div_f64x2";
    "min_f64x2";
    "max_f64x2";
  |]

let vec_un =
  [|
    "abs_i8x16";
    "neg_i8x16";
    "abs_i16x8";
    "neg_i16x8";
    "abs_i32x4";
    "neg_i32x4";
    "abs_f32x4";
    "neg_f32x4";
    "sqrt_f32x4";
    "ceil_f32x4";
    "floor_f32x4";
    "abs_f64x2";
    "neg_f64x2";
    "sqrt_f64x2";
  |]

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

(* Struct field names that may be punned in a literal: each has a like-named i32
   binding in scope (the [x]/[y] globals or the i32 param [a]), so [{f}] resolves
   to a value of the field's type. [pair.b] is excluded — the i64 param [b] would
   shadow, giving a type mismatch. *)
let punnable_field = [ "x"; "y"; "a" ]

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

(* A call to some callee returning type [t] — defined or imported, since both
   share the uniform signature (falls back to a leaf if none). *)
and call t : Ast.location Ast.instr =
  let cands = List.filter (fun (_, rt) -> rt = t) callees in
  match cands with
  | [] -> leaf t
  | _ ->
      let name, _ = List.nth cands (rnd (List.length cands)) in
      nl
        (Ast.Call
           ( nl (Ast.Get (id name)),
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

(* A legacy `try_legacy`/`catch` expression of type [t] (the deprecated
   try/catch instructions). The body and each handler independently produce
   [t]; the `stop` tag carries no payload, so a handler needs nothing off the
   stack. *)
and try_ t d : Ast.location Ast.instr =
  let typ = Ast.{ params = [||]; results = [| valtype t |] } in
  nl
    (Ast.Try
       {
         label = None;
         typ;
         block = nl [ gen t (d - 1) ];
         catches = [ (id "stop", nl [ gen t (d - 1) ]) ];
         catch_all = Some (nl [ gen t (d - 1) ]);
       })

(* A structured `try`/`catch` of type [t] (try_table plus a block ladder,
   with fall-through arms). Shapes: a catch-all producing [t]; an [oops]
   payload arm consuming its i32 payload then falling through into the
   catch-all; a [&] arm dropping the delivered &exn likewise; and — for i32 —
   the payload itself passed through as the try's value (a hole completing
   the last arm). *)
and try_catch t d : Ast.location Ast.instr =
  let typ = Ast.{ params = [||]; results = [| valtype t |] } in
  let arm ?tag ?(ref_ = false) body =
    Ast.{ arm_tag = tag; arm_ref = ref_; arm_types = [||]; arm_body = nl body }
  in
  let drop = nl (Ast.Let ([ (None, None) ], Some (nl Ast.Hole))) in
  let catch_all = arm [ gen t (d - 1) ] in
  let arms =
    match rnd (if t = I32 then 4 else 3) with
    | 0 -> [ catch_all ]
    | 1 -> [ arm ~tag:(id "oops") [ drop ]; catch_all ]
    | 2 -> [ arm ~tag:(id "stop") ~ref_:true [ drop ]; catch_all ]
    | _ -> [ arm ~tag:(id "oops") [ nl Ast.Hole ] ]
  in
  nl (Ast.TryCatch { label = None; typ; block = nl [ gen t (d - 1) ]; arms })

(* An expression of type [t] at depth [d]. *)
and gen t d : Ast.location Ast.instr =
  if d <= 0 then leaf t
  else if is_num t then gen_num t d
  else if t = Vec then gen_vec d
  else gen_ref t d

(* A v128 expression: lane arithmetic, splats from a scalar, the [v128::] free
   functions (const / bitselect), a shuffle, or a call/leaf. *)
and gen_vec d : Ast.location Ast.instr =
  let path fn args = nl (Ast.Call (nl (Ast.Path (id "v128", id fn)), args)) in
  match rnd 100 with
  | n when n < 26 -> meth (gen Vec (d - 1)) (pick vec_bin) [ gen Vec (d - 1) ]
  | n when n < 42 -> meth (gen Vec (d - 1)) (pick vec_un) []
  | n when n < 56 -> (
      (* splat a scalar across the lanes *)
      match rnd 6 with
      | 0 -> meth (gen I32 (d - 1)) "splat_i8x16" []
      | 1 -> meth (gen I32 (d - 1)) "splat_i16x8" []
      | 2 -> meth (gen I32 (d - 1)) "splat_i32x4" []
      | 3 -> meth (gen I64 (d - 1)) "splat_i64x2" []
      | 4 -> meth (gen F32 (d - 1)) "splat_f32x4" []
      | _ -> meth (gen F64 (d - 1)) "splat_f64x2" [])
  | n when n < 66 ->
      path "i32x4"
        [
          nl (Ast.Int "1"); nl (Ast.Int "2"); nl (Ast.Int "3"); nl (Ast.Int "4");
        ]
  | n when n < 74 ->
      path "bitselect" [ gen Vec (d - 1); gen Vec (d - 1); gen Vec (d - 1) ]
  | n when n < 82 ->
      (* shuffle: 16 lane indices then a second v128 operand *)
      meth
        (gen Vec (d - 1))
        "shuffle_i8x16"
        (List.init 16 (fun i -> nl (Ast.Int (string_of_int i)))
        @ [ gen Vec (d - 1) ])
  | n when n < 92 -> if_ Vec d
  | _ -> call Vec

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
  (* Extract a lane of the matching shape from a v128 (produces this scalar). *)
  let extract () =
    let shp =
      match t with
      | I32 -> "i32x4"
      | I64 -> "i64x2"
      | F32 -> "f32x4"
      | _ -> "f64x2"
    in
    meth (gen Vec (d - 1)) ("extract_lane_" ^ shp) [ nl (Ast.Int "0") ]
  in
  (* A memory load of the matching width (load32 -> i32, load64 -> i64). *)
  let load () =
    meth mem (if t = I64 then "load64" else "load32") [ gen I32 (d - 1) ]
  in
  (* An atomic memory access: the width is in the method name, the i32/i64
     family resolved from the value operand's type (RMW) or the resolving
     [as iN_u] cast (narrow load). *)
  let atomic () =
    let cast_u e typ =
      nl
        (Ast.Cast
           (e, Ast.Signedtype { typ; signage = Ast.Unsigned; strict = false }))
    in
    if t = I64 then
      if rnd 2 = 0 then
        meth mem "atomic_rmw_xchg16" [ gen I32 (d - 1); gen I64 (d - 1) ]
      else cast_u (meth mem "atomic_load32" [ gen I32 (d - 1) ]) `I64
    else if rnd 2 = 0 then
      meth mem "atomic_rmw_add32" [ gen I32 (d - 1); gen I32 (d - 1) ]
    else cast_u (meth mem "atomic_load8" [ gen I32 (d - 1) ]) `I32
  in
  (* Resume a freshly wrapped worker, [k::new(worker).resume(x)]: the [task]
     type is [fn(i32) -> i32], and the resume's type immediate is inferred
     from the receiver's static type. *)
  let resume () =
    nl
      (Ast.Resume
         ( id "k",
           [],
           [
             gen I32 (d - 1);
             nl (Ast.ContNew (id "k", nl (Ast.Get (id "worker"))));
           ] ))
  in
  (* Read an i31ref back to i32 ([r as i32_s]). *)
  let i31get () =
    let sgn = if rnd 2 = 0 then Ast.Signed else Ast.Unsigned in
    nl
      (Ast.Cast
         ( gen I31 (d - 1),
           Ast.Signedtype { typ = `I32; signage = sgn; strict = false } ))
  in
  (* Test a reference against a concrete type ([e is &point]) -> i32. *)
  let reftest () =
    nl (Ast.Test (gen Eq (d - 1), reftype (pick [| Point; Pair; I31 |])))
  in
  (* [call_ref]: call the [fr] funcref ([task] = [fn(i32) -> i32]) -> i32. *)
  let callref () = nl (Ast.Call (leaf Fn, [ gen I32 (d - 1) ])) in
  if is_int t then
    match rnd 100 with
    | n when n < 20 -> bin int_binops
    | n when n < 30 && t = I32 -> cmp ()
    | n when n < 38 -> umeth int_umeth
    | n when n < 44 -> bmeth int_bmeth
    | n when n < 49 -> neg ()
    | n when n < 61 -> cast t d
    | n when n < 66 -> if_ t d
    | n when n < 68 -> try_ t d
    | n when n < 71 -> try_catch t d
    | n when n < 74 -> ternary ()
    | n when n < 78 && t = I32 -> field_get ()
    | n when n < 80 && t = I32 -> nl (Ast.ArrayGet (leaf Ints, gen I32 (d - 1)))
    | n when n < 82 && t = I32 -> meth (leaf Ints) "length" []
    | n when n < 84 && t = I32 -> i31get ()
    | n when n < 87 && t = I32 -> reftest ()
    | n when n < 89 && t = I32 -> callref ()
    | n when n < 91 && t = I32 -> resume ()
    | n when n < 93 -> extract ()
    | n when n < 95 -> load ()
    | n when n < 98 -> atomic ()
    | n when n < 99 ->
        (* Read an imported mutable global of the matching width. *)
        nl (Ast.Get (id (if t = I32 then "gi32" else "gi64")))
    | _ -> call t
  else
    match rnd 100 with
    | n when n < 26 -> bin flt_binops
    | n when n < 40 -> umeth flt_umeth
    | n when n < 48 -> bmeth flt_bmeth
    | n when n < 54 -> neg ()
    | n when n < 70 -> cast t d
    | n when n < 79 -> if_ t d
    | n when n < 82 -> try_ t d
    | n when n < 85 -> try_catch t d
    | n when n < 91 -> ternary ()
    | n when n < 95 -> extract ()
    | _ -> call t

and gen_ref t d : Ast.location Ast.instr =
  let struct_lit name fields =
    nl
      (Ast.Struct
         ( Some (id name),
           List.map
             (fun f ->
               (* Field punning [{f}]: when a like-named i32 binding is in scope
                  (the i32 globals [x]/[y] or the i32 param [a]), sometimes drop
                  the value so it is taken from that binding — [None] in the AST.
                  Other field names (e.g. [pair.b], shadowed by the i64 param [b])
                  are never punned, so the pun always type-checks. *)
               if List.mem f punnable_field && rnd 3 = 0 then (id f, None)
               else (id f, Some (gen I32 (d - 1))))
             fields ))
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
  | Chars -> (
      (* An [i8] array, built by a string literal (its raw UTF-8 bytes). *)
      match rnd 100 with
      | n when n < 44 -> nl (Ast.String (Some (id "chars"), pick str_pool))
      | n when n < 60 -> if_ t d
      | n when n < 72 -> nl (Ast.Cast (leaf Eq, Ast.Valtype (valtype Chars)))
      | n when n < 84 -> call t
      | _ -> leaf t)
  | Wchars -> (
      (* An [i16] array, built by a string literal (its UTF-16 code units). *)
      match rnd 100 with
      | n when n < 44 -> nl (Ast.String (Some (id "wchars"), pick str_pool))
      | n when n < 60 -> if_ t d
      | n when n < 72 -> nl (Ast.Cast (leaf Eq, Ast.Valtype (valtype Wchars)))
      | n when n < 84 -> call t
      | _ -> leaf t)
  | Eq -> (
      (* Any struct/array is a subtype of eq, so a struct literal serves. *)
      match rnd 100 with
      | n when n < 26 -> gen Point (d - 1)
      | n when n < 44 -> gen Pair (d - 1)
      | n when n < 58 -> gen Ints (d - 1)
      | n when n < 68 -> gen I31 (d - 1) (* i31 is an eq subtype too *)
      | n when n < 82 -> if_ t d
      | _ -> leaf t)
  | I31 -> (
      match rnd 100 with
      (* box an i32 into an i31ref: [x as &i31] *)
      | n when n < 44 ->
          nl (Ast.Cast (gen I32 (d - 1), Ast.Valtype (valtype I31)))
      | n when n < 62 -> if_ t d
      | n when n < 80 -> call t
      | _ -> leaf t)
  | Cont -> (
      match rnd 100 with
      (* wrap the fixed `worker` task into a continuation: [k::new(worker)] *)
      | n when n < 46 -> nl (Ast.ContNew (id "k", nl (Ast.Get (id "worker"))))
      | n when n < 64 -> if_ t d
      | n when n < 82 -> call t
      | _ -> leaf t)
  | Fn -> (
      match rnd 100 with
      (* [ref.func]: a function's name is a reference to it. [worker] has the
         [task] signature, so [worker] typed as a value is a [&task]. *)
      | n when n < 40 -> nl (Ast.Get (id "worker"))
      | n when n < 60 -> if_ t d
      | n when n < 80 -> call t
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
  (* For an i32 result, bind the narrowed value and return one of its fields —
     exercising the match binding's type; otherwise leave the pattern anonymous. *)
  let arm t =
    if res = I32 then
      let fld = if t = Point then "x" else "a" in
      ( Ast.MatchCast (Some (id "mv"), reftype t),
        nl
          [
            nl
              (Ast.Return
                 (Some (nl (Ast.StructGet (nl (Ast.Get (id "mv")), id fld)))));
          ] )
    else (Ast.MatchCast (None, reftype t), nl [ ret () ])
  in
  nl
    (Ast.Match
       {
         scrutinee = leaf Eq;
         arms = [ arm Point; arm Pair ];
         default = nl [ ret () ];
       })

(* A `dispatch` (jump table) as a function TAIL: an i32 selects a case label,
   with an `else` default; every arm `return`s the result type. Like `match`, a
   diverging control construct — and one the decompiler never emits (it lowers to
   a br_table). *)
let tail_dispatch res : Ast.location Ast.instr =
  let ret () = nl (Ast.Return (Some (gen res 1))) in
  let cases = [ id "c0"; id "c1"; id "c2" ] in
  let default = id "cd" in
  nl
    (Ast.Dispatch
       {
         index = gen I32 1;
         cases;
         default;
         arms = List.map (fun l -> (l, nl [ ret () ])) (cases @ [ default ]);
       })

(* Branch-hinting proposal: wrap a conditional branch in [#[likely]] (true) or
   [#[unlikely]] (false) roughly a third of the time, so generated modules
   exercise the [Hinted] wrapper end to end — the type checker descending through
   it, the wasm branch-hint section codec, and (via the round-trip oracle) that a
   hinted binary decompiles and recompiles to a reference-valid module. Only a
   statement-position [if] is hinted: a value-producing [if] carries the hint
   as a [blockinstr] (statement) only, not inside an operand, so hinting one there
   would print Wax that does not re-parse. *)
let maybe_hint i =
  match rnd 3 with
  | 0 -> nl (Ast.Hinted (true, i))
  | 1 -> nl (Ast.Hinted (false, i))
  | _ -> i

(* A statement (no value escapes): assign a param (fully type-constrained),
   mutate a struct field / array element, or a nested control statement. *)
let rec stmt d : Ast.location Ast.instr =
  match rnd 100 with
  | n when n < 28 ->
      (* Assign a param (fully type-constrained), or occasionally an imported
         mutable global — exercising [global.set] on an import. *)
      if rnd 4 = 0 then
        let t, name = if rnd 2 = 0 then (I32, "gi32") else (I64, "gi64") in
        nl (Ast.Set (id name, None, gen t d))
      else
        let t = pick all_params in
        nl (Ast.Set (id (pname t), None, gen t d))
  | n when n < 40 ->
      (* [x op= e] — a compound assignment over a numeric param, with an operator
         valid for its type. Params are always initialized, so reading [x] (which
         [x op= e] does) is well-typed. *)
      let t = pick num_ty in
      let op = pick (if is_int t then int_binops else flt_binops) in
      nl (Ast.Set (id (pname t), Some (nl op), gen t d))
  | n when n < 46 ->
      nl (Ast.Let ([ (None, None) ], Some (gen (pick num_ty) (max 1 d))))
      (* `_ = <determined>` (a drop, an anonymous [Let]) *)
  | n when n < 58 ->
      (* [point.x] is the one mutable struct field. *)
      nl (Ast.StructSet (leaf Point, id "x", gen I32 d))
  | n when n < 68 ->
      (* the array element type is mutable *)
      nl (Ast.ArraySet (leaf Ints, gen I32 d, gen I32 d))
  | n when n < 74 ->
      (* memory store: width by method, value type by argument *)
      if rnd 2 = 0 then meth mem "store32" [ gen I32 d; gen I32 d ]
      else meth mem "store64" [ gen I32 d; gen I64 d ]
  | n when n < 84 && d > 0 ->
      let void = Ast.{ params = [||]; results = [||] } in
      maybe_hint
        (nl
           (Ast.If
              {
                label = None;
                typ = void;
                cond = gen I32 (d - 1);
                if_block = nl [ stmt (d - 1) ];
                else_block = Some (nl [ stmt (d - 1) ]);
              }))
  | _ when d > 0 ->
      (* Sometimes a Zig-style continue-expression: a compound assignment on a
         numeric param (always initialised, so well-typed). Exercises the stepped
         [while] lowering and its round-trip. *)
      let step =
        if rnd 2 = 0 then None
        else
          let t = pick num_ty in
          let op = pick (if is_int t then int_binops else flt_binops) in
          Some (nl (Ast.Set (id (pname t), Some (nl op), gen t (d - 1))))
      in
      nl
        (Ast.While
           {
             label = None;
             cond = gen I32 (d - 1);
             step;
             block = nl [ stmt (d - 1) ];
           })
  | _ ->
      let t = pick num_ty in
      nl (Ast.Set (id (pname t), None, gen t d))

(* A labelled [while] whose continue-expression reads a body-scoped local that
   the body writes:
     [let v: i32; 'l: while c : (a += v) { v = e; br_if 'l c; }]
   Returned as a two-statement sequence (declaration then loop) so [v] is a real
   function-body local, in scope for both the loop and the rest of the body.

   This is the shape that drives sink_let's labelled-loop step arm: a labelled
   loop wraps its body in a block and runs the step *outside* it, so a
   declaration the body writes cannot be sunk into the body when the step reads
   it. The param-only [stmt] bodies never reach that arm — their while-steps read
   always-live params, so no *sinkable* local is ever live into a step. The [a]
   in [a += v] is the i32 param; [v] is the local, read there and written in the
   body (before the [br_if], so it is definitely assigned on every continue). *)
let local_while_seq d : Ast.location Ast.instr list =
  let n = fresh () in
  let v = "lv" ^ string_of_int n in
  let lbl = "ll" ^ string_of_int n in
  [
    nl (Ast.Let ([ (Some (id v), Some (valtype I32)) ], None));
    nl
      (Ast.While
         {
           label = Some (id lbl);
           cond = gen I32 (d - 1);
           step =
             Some
               (nl (Ast.Set (id "a", Some (nl Ast.Add), nl (Ast.Get (id v)))));
           block =
             nl
               [
                 nl (Ast.Set (id v, None, gen I32 (d - 1)));
                 nl (Ast.Br_if (id lbl, gen I32 (d - 1)));
               ];
         });
  ]

(* A body-scoped local used across a control construct — the general shape that
   drives sink_let's per-construct sink decisions. The declaration is left
   *uninitialised* ([let v: i32;]): an initialiser would be an outer-scope use
   that pins the declaration above the construct, so sink_let would never reach
   the branch decision. Instead every use assigns [v] before reading it (so it is
   definitely assigned wherever placed), and the declaration's only uses lie
   inside exactly one — or both — of an [if]'s branches, a loop body, or a
   labelled block. sink_let must then sink the declaration into the sole branch
   that uses it, leave it in place when both branches do, and respect the loop
   guard. These are the arms the param-only [stmt] bodies never reach: a param is
   live everywhere, so it is never a sink candidate. *)
let local_liveness_seq d : Ast.location Ast.instr list =
  let n = fresh () in
  let v = "lv" ^ string_of_int n in
  (* Assign then read [v] — a self-contained use, so [v] is definitely assigned
     before the read wherever this lands. *)
  let use () =
    let read =
      match rnd 3 with
      | 0 -> nl (Ast.Set (id "a", Some (nl Ast.Add), nl (Ast.Get (id v))))
      | 1 -> nl (Ast.StructSet (leaf Point, id "x", nl (Ast.Get (id v))))
      | _ -> nl (Ast.Let ([ (None, None) ], Some (nl (Ast.Get (id v)))))
    in
    [ nl (Ast.Set (id v, None, gen I32 (d - 1))); read ]
  in
  let void = Ast.{ params = [||]; results = [||] } in
  let branch then_ else_ =
    nl
      (Ast.If
         {
           label = None;
           typ = void;
           cond = gen I32 (d - 1);
           if_block = nl then_;
           else_block = Some (nl else_);
         })
  in
  let control =
    match rnd 5 with
    | 0 ->
        branch (use ()) [ stmt (d - 1) ]
        (* used in then only — sink into then *)
    | 1 ->
        branch [ stmt (d - 1) ] (use ())
        (* used in else only — sink into else *)
    | 2 -> branch (use ()) (use ()) (* used in both — must NOT sink *)
    | 3 ->
        nl
          (Ast.While
             {
               label = None;
               cond = gen I32 (d - 1);
               step = None;
               block = nl (use ());
             })
    | _ ->
        let lbl = id ("lb" ^ string_of_int n) in
        nl
          (Ast.Block
             {
               label = Some lbl;
               typ = void;
               block = nl (use () @ [ nl (Ast.Br_if (lbl, gen I32 (d - 1))) ]);
             })
  in
  [ nl (Ast.Let ([ (Some (id v), Some (valtype I32)) ], None)); control ]

(* One clean type error, to reach the checker's mismatch-reporting arms. *)
let poison () : Ast.location Ast.instr =
  match rnd 8 with
  | 0 ->
      nl
        (Ast.Let
           ( [ (None, None) ],
             Some
               (nl
                  (Ast.BinOp
                     (nl Ast.Add, nl (Ast.Get (id "a")), nl (Ast.Get (id "d")))))
           ))
      (* i32 + f64 *)
  | 1 -> nl (Ast.Set (id "b", None, nl (Ast.Get (id "c")))) (* f32 into i64 *)
  | 2 -> nl (Ast.StructGet (leaf Point, id "nope")) (* unknown field *)
  | 3 ->
      nl
        (Ast.Let
           ([ (None, None) ], Some (nl (Ast.String (Some (id "ints"), "x")))))
      (* a string on an i32 array — only i8/i16 are allowed *)
  | 4 ->
      nl
        (Ast.Let
           ( [ (None, None) ],
             Some (nl (Ast.String (Some (id "wchars"), "\xff"))) ))
      (* invalid Unicode in an i16 (UTF-16) string *)
  | 5 ->
      nl
        (Ast.BinOp
           ( nl (Ast.Lt (Some Ast.Signed)),
             nl (Ast.Get (id "c")),
             nl (Ast.Get (id "d")) ))
      (* signed cmp on floats *)
  | 6 ->
      (* [br_table] with a REPEATED target and a mismatched delivered value
         (the block wants i32, [c] is f32): the per-distinct-target check must
         report the mismatch ONCE, not once per occurrence — the diagnostics
         -shape (DIAG_DUP) case the corpus never contains. *)
      let lbl = id "bt_poison" in
      nl
        (Ast.Let
           ( [ (None, None) ],
             Some
               (nl
                  (Ast.Block
                     {
                       label = Some lbl;
                       typ = Ast.{ params = [||]; results = [| valtype I32 |] };
                       block =
                         nl
                           [
                             nl
                               (Ast.Br_table
                                  ( [ lbl; lbl; lbl ],
                                    nl
                                      (Ast.Sequence
                                         [
                                           nl (Ast.Get (id "c"));
                                           nl (Ast.Get (id "a"));
                                         ]) ));
                           ];
                     })) ))
  | _ ->
      (* An [&eq] cast to an inline function type whose signature matches no
         declared type: cross-hierarchy, so it rejects, but the target type is
         minted *while type-checking* — the case that outran the old
         subtyping-info snapshot (see [subtyping_info] in the typer). A distinctive
         signature keeps it novel regardless of the functions generated above. *)
      nl
        (Ast.Let
           ( [ (None, None) ],
             Some
               (nl
                  (Ast.Cast
                     ( leaf Eq,
                       Ast.Functype
                         {
                           nullable = false;
                           sign =
                             Ast.
                               {
                                 params =
                                   [|
                                     nl (None, valtype F64);
                                     nl (None, valtype F32);
                                   |];
                                 results = [| valtype I64 |];
                               };
                         } ))) ))

let ftype mut t : Ast.fieldtype = { mut; typ = Ast.Value (valtype t) }

let subtype (typ : Ast.comptype) : Ast.subtype =
  { typ; supertype = None; final = true; descriptor = None; describes = None }

let field name mut t : (Ast.ident * Ast.fieldtype, Ast.location) Ast.annotated =
  nl (id name, ftype mut t)

(* Attributes on an imported declaration: a name-only [#[import = "…"]] renames
   the entity in the host module, and [#[export]] re-exports it (which also
   counts as a use, so an otherwise-unreferenced import never trips
   unused-import). Both are exercised roughly a third of the time each. *)
let import_attrs base : Ast.attributes =
  let str s = Some (nl (Ast.String (None, s))) in
  (if rnd 3 = 0 then [ ("import", str (base ^ "_ext"), None) ] else [])
  @ if rnd 3 = 0 then [ ("export", str (base ^ "_x"), None) ] else []

(* One imported function [g<k>]: the uniform parameter signature (anonymous
   params, since an import has no body) and a result drawn from [gtys]. *)
let import_func_decl k : (Ast.import_decl, Ast.location) Ast.annotated =
  let name = "g" ^ string_of_int k in
  let sign =
    Ast.
      {
        params = Array.map (fun t -> nl (None, valtype t)) all_params;
        results = [| valtype gtys.(k) |];
      }
  in
  nl
    {
      Ast.id = id name;
      kind = Ast.Import_func { typ = None; sign = Some sign; exact = false };
      attributes = import_attrs name;
    }

(* An imported mutable numeric global, read (and written) by the generated
   bodies — see [gen_num] / [stmt]. *)
let import_global_decl name t : (Ast.import_decl, Ast.location) Ast.annotated =
  nl
    {
      Ast.id = id name;
      kind = Ast.Import_global { mut = true; typ = valtype t };
      attributes = import_attrs name;
    }

(* An imported tag ([tag itag(i32);]): exercises [register_import]'s tag arm.
   Left unreferenced — tags carry no unused-import lint. *)
let import_tag_decl : (Ast.import_decl, Ast.location) Ast.annotated =
  nl
    {
      Ast.id = id "itag";
      kind =
        Ast.Import_tag
          {
            typ = None;
            sign =
              Some Ast.{ params = [| nl (None, valtype I32) |]; results = [||] };
          };
      attributes = [];
    }

(* Imports exercise both module fields: a singleton [import "env2" fn g0(…);]
   ([Import]) and a grouped [import "env" { … }] block ([Import_group]) carrying
   the remaining functions, two globals and a tag. Every imported function is in
   the call pool; the globals are read/written above. *)
let import_decls : Ast.location Ast.modulefield list =
  [
    Ast.Import { module_ = nl "env2"; decl = import_func_decl 0 };
    Ast.Import_group
      {
        module_ = nl "env";
        decls =
          List.init (ng - 1) (fun k -> import_func_decl (k + 1))
          @ [
              import_global_decl "gi32" I32;
              import_global_decl "gi64" I64;
              import_tag_decl;
            ];
      };
  ]

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
    (* The two array types string literals build: [i8] (raw UTF-8 bytes) and
       [i16] (UTF-16 code units). *)
    Ast.Type
      [|
        nl (id "chars", subtype (Ast.Array { mut = true; typ = Ast.Packed I8 }));
      |];
    Ast.Type
      [|
        nl
          (id "wchars", subtype (Ast.Array { mut = true; typ = Ast.Packed I16 }));
      |];
    (* A continuation scaffold: a task function type, its continuation type, and
       a `worker` that suspends the `yield` tag — so cont_new/suspend and the
       cont typing arms are exercised. *)
    Ast.Type
      [|
        nl
          ( id "task",
            subtype
              (Ast.Func
                 Ast.{ params = [| nl (None, I32) |]; results = [| I32 |] }) );
      |];
    Ast.Type [| nl (id "k", subtype (Ast.Cont (id "task"))) |];
    (* Immutable i32 globals named after the [point] fields [x]/[y] (which have no
       like-named parameter), so a struct literal can *pun* those fields — a
       punned [x]/[y] reads these globals. The [pair] field [a] puns instead to
       the i32 parameter [a]; see [punnable_field] / [struct_lit]. *)
    Ast.Global
      {
        name = id "x";
        mut = false;
        typ = Some I32;
        def = nl (Ast.Int "0");
        attributes = [];
      };
    Ast.Global
      {
        name = id "y";
        mut = false;
        typ = Some I32;
        def = nl (Ast.Int "0");
        attributes = [];
      };
    Ast.Tag
      {
        name = id "stop";
        typ = None;
        sign = Some Ast.{ params = [||]; results = [||] };
        attributes = [];
      };
    (* An i32-payload, no-result tag, catchable by the structured try's
       payload arms (a tag with results cannot be caught by try_table). *)
    Ast.Tag
      {
        name = id "oops";
        typ = None;
        sign = Some Ast.{ params = [| nl (None, I32) |]; results = [||] };
        attributes = [];
      };
    Ast.Tag
      {
        name = id "yield";
        typ = None;
        sign = Some Ast.{ params = [| nl (None, I32) |]; results = [| I32 |] };
        attributes = [];
      };
    Ast.Memory
      {
        name = id "m";
        address_type = `I32;
        limits = Some (Wax_utils.Uint64.of_int 1, None);
        page_size_log2 = None;
        shared = false;
        data = [];
        attributes = [];
      };
    Ast.Func
      {
        name = id "worker";
        typ = None;
        sign =
          Some
            Ast.{ params = [| nl (Some (id "x"), I32) |]; results = [| I32 |] };
        body =
          (None, [ nl (Ast.Suspend (id "yield", [ nl (Ast.Get (id "x")) ])) ]);
        attributes = [];
      };
  ]

let func k : Ast.location Ast.modulefield =
  let res = rtys.(k) in
  let params =
    Array.map (fun t -> nl (Some (id (pname t)), valtype t)) all_params
  in
  let sign = Ast.{ params; results = [| valtype res |] } in
  let body =
    let ns = 1 + rnd 3 in
    (* Some statement slots expand to a two-statement sequence that declares a
       body-scoped local and reads it across a control construct, instead of a
       single statement — exercising sink_let's per-construct sink decisions. *)
    let stmts =
      List.concat
        (List.init ns (fun _ ->
             match rnd 5 with
             | 0 -> local_while_seq 2
             | 1 -> local_liveness_seq 2
             | _ -> [ stmt 2 ]))
    in
    let poison = if err && k = nf - 1 then [ poison () ] else [] in
    (* Occasionally end the function with a returning [match] instead of a plain
       value expression (a match must diverge, so it is a tail, not a value). *)
    (* Occasionally end with a diverging construct instead of a value: a
       returning [match], or a bare [throw] (which satisfies any result type,
       since it never returns). *)
    let tail =
      if poison <> [] then [ gen res 2 ]
      else
        match rnd 100 with
        | n when n < 22 -> [ tail_match res ]
        | n when n < 34 -> [ tail_dispatch res ]
        | n when n < 42 -> [ nl (Ast.Throw (id "stop", [])) ]
        | _ -> [ gen res 2 ]
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
  let fields = type_decls @ import_decls @ List.init nf func in
  let m : Ast.location Ast.module_ = List.map nl fields in
  let f = Format.std_formatter in
  Wax_utils.Printer.run ~width:Wax_lang.Output.width f (fun p ->
      Wax_lang.Output.module_ ~color:Wax_utils.Colors.Never p
        ~trivia:(Wax_utils.Trivia.empty ())
        m);
  Format.pp_print_flush f ()

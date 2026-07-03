(* fuzz_gen — generate a hand-written-style Wax *source* module to fuzz the Wax
   type checker (lib-wax/typing.ml).

   Usage: fuzz_gen <seed> [err]     (Wax source to stdout; [err] injects one
                                      deliberate type error)

   Why this exists: the .wax the harness otherwise type-checks comes from
   DECOMPILING wasm (the mutate-wax / diff-validate seeds), so it only ever
   contains the constructs from_wasm emits — never the surface sugar a human
   writes, which is exactly what large parts of typing.ml exist to check: infix
   operators and their signed/unsigned variants, `as` conversions, `if`/`?:`
   with inferred result types, calls, and nested arithmetic. This is a
   type-DIRECTED generator: every expression is built to a chosen type, so the
   module type-checks and the checker runs its inference/checking arms in full
   (rather than bailing at the first error) — while `err` produces the opposite,
   a single well-placed mismatch, to exercise the rejection arms.

   Unlike a text generator, the module is built as a real AST and printed through
   Wax_lang.Output, so the output ALWAYS re-parses: the only rejections are
   genuine type verdicts, never a serialization bug. The paired driver is
   fuzz/type-fuzz.sh (checker soundness: an accepted module must emit a binary
   the reference validates, plus round-trip and no-crash).

   The trick that makes type-directed generation tractable: every function has
   the SAME parameter signature (a:i32 b:i64 c:f32 d:f64), so an expression of a
   given type is always formable from those names, and any function is callable
   with a uniform argument list. *)

module Ast = Wax_lang.Ast

let seed = try int_of_string Sys.argv.(1) with _ -> 0
let err = Array.exists (fun a -> a = "err") Sys.argv
let st = Random.State.make [| seed |]
let rnd n = Random.State.int st n
let pick a = a.(rnd (Array.length a))
let nl = Ast.no_loc
let id s = nl s

(* The four value types expressions are built to. *)
type ty = I32 | I64 | F32 | F64

let all_ty = [| I32; I64; F32; F64 |]
let is_int = function I32 | I64 -> true | F32 | F64 -> false

let valtype = function
  | I32 -> Ast.I32
  | I64 -> Ast.I64
  | F32 -> Ast.F32
  | F64 -> Ast.F64

let pname = function I32 -> "a" | I64 -> "b" | F32 -> "c" | F64 -> "d"

(* Number of functions and their result types (round-robin, so a call of any
   type always has a callee). *)
let nf = 2 + rnd 4
let rtys = Array.init nf (fun k -> all_ty.(k mod 4))

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
  if d > 0 || rnd 3 <> 0 then gen_t ()
  else if is_int t then nl (Ast.Int (string_of_int (rnd 9)))
  else nl (Ast.Float (Printf.sprintf "%d.5" (rnd 9)))

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

(* An expression of type [t] at depth [d]. *)
and meth recv name args : Ast.location Ast.instr =
  nl (Ast.Call (nl (Ast.StructGet (recv, id name)), args))

and gen t d : Ast.location Ast.instr =
  if d <= 0 then leaf t
  else
    (* A bare literal is only unambiguous in a top-down type-FORCED position
       (a binop operand pinned by its sibling, an [if]/[?:] branch pinned by the
       result type). It must never reach a method/cast RECEIVER, whose type Wax
       infers bottom-up first — so those use [gen], which is always anchored to a
       typed param at its leaves. [flit] = a literal-or-gen in a forced spot. *)
    let flit () = operand t (d - 1) (fun () -> gen t (d - 1)) in
    (* Left operand [gen] pins the binop's type; the right may be a literal. *)
    let bin ops = nl (Ast.BinOp (nl (pick ops), gen t (d - 1), flit ())) in
    let umeth ms = meth (gen t (d - 1)) (pick ms) [] in
    let bmeth ms = meth (gen t (d - 1)) (pick ms) [ gen t (d - 1) ] in
    let cmp () =
      (* a comparison over some numeric type u, yielding i32 (only when t=i32) *)
      let u = pick all_ty in
      let op = if is_int u then pick int_cmps else pick flt_cmps in
      nl (Ast.BinOp (nl op, gen u (d - 1), gen u (d - 1)))
    in
    let if_ () =
      let typ = Ast.{ params = [||]; results = [| valtype t |] } in
      nl
        (Ast.If
           {
             label = None;
             typ;
             cond = gen I32 (d - 1);
             if_block = nl [ flit () ];
             else_block = Some (nl [ flit () ]);
           })
    in
    let ternary () =
      nl (Ast.Select (gen I32 (d - 1), gen t (d - 1), flit ()))
    in
    let call () =
      let cands = List.filter (fun k -> rtys.(k) = t) (List.init nf Fun.id) in
      match cands with
      | [] -> leaf t
      | _ ->
          let k = List.nth cands (rnd (List.length cands)) in
          nl
            (Ast.Call
               ( nl (Ast.Get (id ("f" ^ string_of_int k))),
                 [ gen I32 0; gen I64 0; gen F32 0; gen F64 0 ] ))
    in
    let neg () = nl (Ast.UnOp (nl Ast.Neg, gen t (d - 1))) in
    if is_int t then
      match rnd 100 with
      | n when n < 24 -> bin int_binops
      | n when n < 36 && t = I32 -> cmp ()
      | n when n < 44 -> umeth int_umeth
      | n when n < 50 -> bmeth int_bmeth
      | n when n < 56 -> neg ()
      | n when n < 70 -> cast t d
      | n when n < 82 -> if_ ()
      | n when n < 90 -> ternary ()
      | _ -> call ()
    else
      match rnd 100 with
      | n when n < 26 -> bin flt_binops
      | n when n < 40 -> umeth flt_umeth
      | n when n < 48 -> bmeth flt_bmeth
      | n when n < 54 -> neg ()
      | n when n < 70 -> cast t d
      | n when n < 84 -> if_ ()
      | n when n < 92 -> ternary ()
      | _ -> call ()

(* A statement (no value escapes): assign a param (fully type-constrained) or a
   nested control statement. *)
let rec stmt d : Ast.location Ast.instr =
  match rnd 100 with
  | n when n < 50 ->
      let t = pick all_ty in
      nl (Ast.Set (Some (id (pname t)), gen t d))
  | n when n < 65 ->
      nl (Ast.Set (None, gen (pick all_ty) (max 1 d))) (* `_ = <determined>` *)
  | n when n < 85 && d > 0 ->
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
      let t = pick all_ty in
      nl (Ast.Set (Some (id (pname t)), gen t d))

(* One clean type error, to reach the checker's mismatch-reporting arms. *)
let poison () : Ast.location Ast.instr =
  match rnd 3 with
  | 0 ->
      nl
        (Ast.Set
           ( None,
             nl
               (Ast.BinOp
                  (nl Ast.Add, nl (Ast.Get (id "a")), nl (Ast.Get (id "d")))) ))
      (* i32 + f64 *)
  | 1 -> nl (Ast.Set (Some (id "b"), nl (Ast.Get (id "c")))) (* f32 into i64 *)
  | _ ->
      nl
        (Ast.BinOp
           ( nl (Ast.Lt (Some Ast.Signed)),
             nl (Ast.Get (id "c")),
             nl (Ast.Get (id "d")) ))
(* signed cmp on floats *)

let func k : Ast.location Ast.modulefield =
  let res = rtys.(k) in
  let params =
    Array.map (fun t -> nl (Some (id (pname t)), valtype t)) all_ty
  in
  let sign = Ast.{ params; results = [| valtype res |] } in
  let body =
    let ns = 1 + rnd 3 in
    let stmts = List.init ns (fun _ -> stmt 2) in
    let poison = if err && k = nf - 1 then [ poison () ] else [] in
    stmts @ poison @ [ gen res 2 ]
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
  let m : Ast.location Ast.module_ = List.init nf (fun k -> nl (func k)) in
  let f = Format.std_formatter in
  Wax_utils.Printer.run ~width:Wax_lang.Output.width f (fun p ->
      Wax_lang.Output.module_ ~color:Wax_utils.Colors.Never p
        ~trivia:(Hashtbl.create 0) m);
  Format.pp_print_flush f ()

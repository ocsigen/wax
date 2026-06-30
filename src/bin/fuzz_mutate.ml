(* AST-level mutation fuzzer for Wax source.

   Reads a .wax file, parses it, applies ONE structure-preserving mutation to a
   chosen site (the site index is [seed mod number-of-sites]), and prints the
   result to stdout. Unlike text mutation, the output is printed from a real AST,
   so it always re-parses — which means a far larger fraction reaches the type
   checker, the wax->wasm compiler and the round-trip, exactly the paths a
   token-level mutator rarely exercises.

   Usage: fuzz_mutate <file.wax> [seed]

   The mutations (swap a binary/unary operator, tweak a literal, reorder the
   first two statements of a block) keep the program parseable but change its
   meaning or types, so the fuzzer hunts for what must never happen on ANY input:
   a crash in the parser/typer, or wax accepting the mutant yet emitting wasm the
   reference rejects (driven by fuzz/mutate-wax.sh's oracle). *)

module Ast = Wax_lang.Ast
open Ast

let color = Wax_utils.Colors.Never

module WaxParser =
  Wax_wasm.Parsing.Make_parser
    (struct
      type t = Wax_lang.Ast.location Wax_lang.Ast.module_
    end)
    (Wax_lang.Tokens)
    (Wax_lang.Parser)
    (Wax_lang.Fast_parser)
    (Wax_lang.Parser_messages)
    (Wax_lang.Lexer)

(* Each mutation maps a node to a different but still-parseable one. *)
let swap_binop : binop -> binop = function
  | Add -> Sub
  | Sub -> Mul
  | Mul -> Add
  | Div _ -> Rem Signed
  | Rem _ -> Div None
  | And -> Or
  | Or -> Xor
  | Xor -> And
  | Shl -> Shr Signed
  | Shr _ -> Shl
  | Eq -> Ne
  | Ne -> Eq
  | Lt _ -> Le None
  | Le _ -> Lt None
  | Gt _ -> Ge None
  | Ge _ -> Gt None

let swap_unop = function Neg -> Not | Pos -> Neg | Not -> Pos
let tweak_int s = if s = "1" then "2" else "1"
let tweak_float s = if s = "1.0" then "2.0" else "1.0"
let swap_first_two = function a :: b :: r -> b :: a :: r | l -> l

(* A single traversal serves both passes: with [target = -1] it only counts the
   mutable sites it visits (incrementing [counter]); with [target] set to a real
   index it mutates exactly the site at that index. *)
let counter = ref 0
let target = ref (-1)

let site () =
  let c = !counter in
  incr counter;
  c = !target

let rec go (i : location instr) : location instr =
  let mk d = { i with desc = d } in
  match i.desc with
  | BinOp (op, a, b) ->
      let a = go a and b = go b in
      let op = if site () then { op with desc = swap_binop op.desc } else op in
      mk (BinOp (op, a, b))
  | UnOp (op, e) ->
      let e = go e in
      let op = if site () then { op with desc = swap_unop op.desc } else op in
      mk (UnOp (op, e))
  | Int s -> mk (Int (if site () then tweak_int s else s))
  | Float s -> mk (Float (if site () then tweak_float s else s))
  | Block r -> mk (Block { r with block = go_list r.block })
  | Loop r -> mk (Loop { r with block = go_list r.block })
  | While r -> mk (While { r with cond = go r.cond; block = go_list r.block })
  | If r ->
      mk
        (If
           {
             r with
             cond = go r.cond;
             if_block = { r.if_block with desc = go_list r.if_block.desc };
             else_block =
               Option.map
                 (fun e -> { e with desc = go_list e.desc })
                 r.else_block;
           })
  | Try r ->
      mk
        (Try
           {
             r with
             block = go_list r.block;
             catches = List.map (fun (id, b) -> (id, go_list b)) r.catches;
             catch_all = Option.map go_list r.catch_all;
           })
  | TryTable r -> mk (TryTable { r with block = go_list r.block })
  | Sequence l -> mk (Sequence (go_list l))
  | Set (id, e) -> mk (Set (id, go e))
  | Tee (id, e) -> mk (Tee (id, go e))
  | Call (f, args) -> mk (Call (go f, List.map go args))
  | TailCall (f, args) -> mk (TailCall (go f, List.map go args))
  | Cast (e, t) -> mk (Cast (go e, t))
  | Test (e, t) -> mk (Test (go e, t))
  | NonNull e -> mk (NonNull (go e))
  | Return e -> mk (Return (Option.map go e))
  | Select (a, b, c) -> mk (Select (go a, go b, go c))
  | Br (l, e) -> mk (Br (l, Option.map go e))
  | Br_if (l, e) -> mk (Br_if (l, go e))
  | Br_table (ls, e) -> mk (Br_table (ls, go e))
  | StructGet (e, id) -> mk (StructGet (go e, id))
  | StructSet (e, id, v) -> mk (StructSet (go e, id, go v))
  | ArrayGet (a, idx) -> mk (ArrayGet (go a, go idx))
  | ArraySet (a, idx, v) -> mk (ArraySet (go a, go idx, go v))
  | Let (bs, e) -> mk (Let (bs, Option.map go e))
  | _ -> i

(* Reordering the first two statements of a block is itself a mutable site. *)
and go_list l =
  let l = List.map go l in
  if List.length l >= 2 && site () then swap_first_two l else l

let go_field (fld : (location modulefield, location) annotated) =
  let desc =
    match fld.desc with
    | Func r ->
        let label, body = r.body in
        Func { r with body = (label, go_list body) }
    | Global r -> Global { r with def = go r.def }
    | _ -> fld.desc
  in
  { fld with desc }

let go_module m = List.map go_field m

let () =
  let file = Sys.argv.(1) in
  let seed =
    if Array.length Sys.argv > 2 then int_of_string Sys.argv.(2) else 0
  in
  let src = In_channel.with_open_bin file In_channel.input_all in
  let m, _ctx = WaxParser.parse_from_string ~color ~filename:file src in
  (* Pass 1: count sites. Pass 2: mutate the [seed]-th of them. *)
  counter := 0;
  target := -1;
  ignore (go_module m);
  let total = !counter in
  if total = 0 then (
    print_string src;
    exit 0);
  counter := 0;
  target := seed mod total;
  let m' = go_module m in
  let f = Format.std_formatter in
  Wax_utils.Printer.run ~width:Wax_lang.Output.width f (fun p ->
      Wax_lang.Output.module_ ~color p ~trivia:(Hashtbl.create 0) m');
  Format.pp_print_flush f ()

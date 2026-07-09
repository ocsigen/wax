(* AST-level mutation fuzzer for Wax source.

   Reads a .wax file, parses it, applies ONE mutation to a chosen AST site (site
   and operator derived from a seed), and prints the result to stdout. Unlike
   text mutation, the output is printed from a real AST, so it always re-parses —
   a far larger fraction reaches the type checker, the wax->wasm compiler and the
   round-trip, exactly the paths a token-level mutator rarely exercises.

   Usage: fuzz_mutate <file.wax> [seed]

   Mutations, chosen per site by the seed:
   - graft: replace a node with another subexpression collected from the same
     program (the main diversity source: novel combinations and type mismatches);
   - swap a binary/unary operator, or a binop's two operands;
   - retype a cast target;
   - replace a numeric literal with an edge value (0, maxints, 2^31, NaN, ...);
   - on a statement list: swap two, delete one, or duplicate one.
   They keep the program parseable but change its meaning or types, so the fuzzer
   hunts for what must never happen on ANY input: a crash in the parser/typer, or
   wax accepting the mutant yet emitting wasm the reference rejects (driven by
   fuzz/mutate-wax.sh's oracle). *)

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

(* A small LCG, seeded from the command-line seed, drives every random choice so
   one (file, seed) pair is fully deterministic. *)
let state = ref 1

let next () =
  state := ((!state * 1103515245) + 12345) land max_int;
  (!state lsr 8) land max_int

let pick arr = arr.(next () mod Array.length arr)

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

(* Operators with a compound-assignment form, used to promote a plain assignment
   into a compound one. All of [swap_binop]'s outputs on these stay in the set. *)
let compound_binops = [| Ast.Add; Sub; Mul; And; Or; Xor; Shl; Shr Signed |]

(* Edge-value literal pools (strings the lexer accepts as a single token; sign is
   a separate [Neg], so these stay non-negative). *)
let int_pool =
  [|
    "0";
    "1";
    "2";
    "127";
    "128";
    "255";
    "256";
    "65535";
    "65536";
    "2147483647";
    "2147483648";
    "4294967295";
    "4294967296";
    "9223372036854775807";
    "9223372036854775808";
    "18446744073709551615";
    "18446744073709551616";
    "0xff";
    "0x100000000";
  |]

let float_pool =
  [| "0.0"; "1.0"; "0x1p0"; "inf"; "nan"; "nan:0x1"; "1e308"; "1e-308"; "0.5" |]

let valtype_pool = [| Ast.I32; Ast.I64; Ast.F32; Ast.F64 |]

(* [pool] gathers every subexpression on the counting pass; a grafted node is a
   verbatim copy of one of them dropped in elsewhere. *)
let collecting = ref true
let pool : location instr list ref = ref []
let push i = if !collecting then pool := i :: !pool
let poolarr = ref [||]
let graft () = (pick !poolarr).desc

(* Site bookkeeping: [counter] numbers every expression node and every statement
   list as it is visited; [target] is the one site to mutate (-1 = count only). *)
let counter = ref 0
let target = ref (-1)

let site () =
  let c = !counter in
  incr counter;
  c = !target

let mutate_node (i : location instr) : location instr =
  let desc =
    match i.desc with
    | BinOp (op, a, b) -> (
        match next () mod 3 with
        | 0 -> BinOp ({ op with desc = swap_binop op.desc }, a, b)
        | 1 -> BinOp (op, b, a)
        | _ -> graft ())
    | UnOp (op, e) ->
        if next () mod 2 = 0 then UnOp ({ op with desc = swap_unop op.desc }, e)
        else graft ()
    | Int _ -> if next () mod 2 = 0 then Int (pick int_pool) else graft ()
    | Float _ -> if next () mod 2 = 0 then Float (pick float_pool) else graft ()
    | Cast (e, Valtype _) ->
        if next () mod 2 = 0 then Cast (e, Valtype (pick valtype_pool))
        else graft ()
    (* Perturb a compound assignment [x op= e]: swap the operator or drop it to a
       plain [x = e]. Promote a plain assignment to a variable into a compound
       one. Either may become ill-typed — an expected rejection, not a crash. *)
    | Set (id, Some op, e) ->
        if next () mod 2 = 0 then
          Set (id, Some { op with desc = swap_binop op.desc }, e)
        else Set (id, None, e)
    | Set (id, None, e) when next () mod 2 = 0 ->
        Set (id, Some { desc = pick compound_binops; info = e.info }, e)
    | _ -> graft ()
  in
  { i with desc }

let mutate_list l =
  let n = List.length l in
  let a = Array.of_list l in
  match next () mod 3 with
  | 0 ->
      (* swap two elements *)
      let i = next () mod n and j = next () mod n in
      let t = a.(i) in
      a.(i) <- a.(j);
      a.(j) <- t;
      Array.to_list a
  | 1 ->
      (* delete one element *)
      let d = next () mod n in
      Array.to_list a |> List.filteri (fun k _ -> k <> d)
  | _ ->
      (* duplicate one element *)
      let d = next () mod n in
      Array.to_list a
      |> List.concat_map (fun e -> if e == a.(d) then [ e; e ] else [ e ])

let rec go (i : location instr) : location instr =
  push i;
  if site () then mutate_node i else { i with desc = rebuild i.desc }

and rebuild : location instr_desc -> location instr_desc = function
  | BinOp (op, a, b) -> BinOp (op, go a, go b)
  | UnOp (op, e) -> UnOp (op, go e)
  | Block r ->
      Block { r with block = { r.block with desc = go_list r.block.desc } }
  | Loop r ->
      Loop { r with block = { r.block with desc = go_list r.block.desc } }
  | While r ->
      While
        {
          r with
          cond = go r.cond;
          step = Option.map go r.step;
          block = { r.block with desc = go_list r.block.desc };
        }
  | If r ->
      If
        {
          r with
          cond = go r.cond;
          if_block = { r.if_block with desc = go_list r.if_block.desc };
          else_block =
            Option.map (fun e -> { e with desc = go_list e.desc }) r.else_block;
        }
  | Try r ->
      Try
        {
          r with
          block = { r.block with desc = go_list r.block.desc };
          catches =
            List.map
              (fun (id, b) -> (id, { b with desc = go_list b.desc }))
              r.catches;
          catch_all =
            Option.map (fun b -> { b with desc = go_list b.desc }) r.catch_all;
        }
  | TryTable r ->
      TryTable { r with block = { r.block with desc = go_list r.block.desc } }
  | Sequence l -> Sequence (go_list l)
  | Set (id, op, e) -> Set (id, op, go e)
  | Tee (id, e) -> Tee (id, go e)
  | Call (f, args) -> Call (go f, List.map go args)
  | TailCall (f, args) -> TailCall (go f, List.map go args)
  | Cast (e, t) -> Cast (go e, t)
  | Test (e, t) -> Test (go e, t)
  | NonNull e -> NonNull (go e)
  | Return e -> Return (Option.map go e)
  | Select (a, b, c) -> Select (go a, go b, go c)
  | Br (l, e) -> Br (l, Option.map go e)
  | Br_if (l, e) -> Br_if (l, go e)
  | Hinted (h, e) -> Hinted (h, go e)
  | Br_table (ls, e) -> Br_table (ls, go e)
  | StructGet (e, id) -> StructGet (go e, id)
  | StructSet (e, id, v) -> StructSet (go e, id, go v)
  | ArrayGet (a, idx) -> ArrayGet (go a, go idx)
  | ArraySet (a, idx, v) -> ArraySet (go a, go idx, go v)
  | Let (bs, e) -> Let (bs, Option.map go e)
  | desc -> desc

(* A statement list is itself a mutable site (swap/delete/duplicate). *)
and go_list l =
  let l = List.map go l in
  if l <> [] && site () then mutate_list l else l

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
  state := (seed * 2) + 1;
  let src = In_channel.with_open_bin file In_channel.input_all in
  let m, _ctx = WaxParser.parse_from_string ~color ~filename:file src in
  (* Pass 1: count sites and collect the graft pool. *)
  collecting := true;
  counter := 0;
  target := -1;
  ignore (go_module m);
  let total = !counter in
  if total = 0 then (
    print_string src;
    exit 0);
  poolarr := Array.of_list !pool;
  (* Pass 2: mutate one site (chosen from the seed). *)
  collecting := false;
  counter := 0;
  target := next () mod total;
  let m' = go_module m in
  let f = Format.std_formatter in
  Wax_utils.Printer.run ~width:Wax_lang.Output.width f (fun p ->
      Wax_lang.Output.module_ ~color p ~trivia:(Hashtbl.create 0) m');
  Format.pp_print_flush f ()

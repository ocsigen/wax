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
   - rename a [let] binding to a name its own initializer reads, manufacturing a
     shadow of an outer binding whose initializer references it (the corpus,
     decompiled from Wasm, never shadows — every name is unique — so this is the
     only way to reach the source-level scoping/renaming paths in To_wasm);
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

(* Perturb a struct literal's field list to reach the type checker's field-
   mismatch recovery (drop a declared field, add an extra one by duplicating or
   renaming, or plant a hole in a value). These are the shapes behind the
   [check_hole_order]/hole-order recovery crashes: a missing field, an extra
   field, and a hole in either. [loc] is a fabricated ident's info. *)
let mutate_fields loc (fields : (ident * location instr option) list) =
  let a = Array.of_list fields in
  let n = Array.length a in
  if n = 0 then fields
  else
    let d = next () mod n in
    match next () mod 4 with
    | 0 -> List.filteri (fun k _ -> k <> d) fields (* drop a field *)
    | 1 ->
        (* duplicate a field (an extra, count-mismatching field) *)
        List.concat_map (fun e -> if e == a.(d) then [ e; e ] else [ e ]) fields
    | 2 ->
        (* rename a field to a name the type does not declare *)
        List.mapi
          (fun k (nm, v) ->
            if k = d then ({ nm with desc = nm.desc ^ "_x" }, v) else (nm, v))
          fields
    | _ ->
        (* replace a field's value with a hole *)
        List.mapi
          (fun k (nm, v) ->
            if k = d then (nm, Some { desc = Hole; info = loc }) else (nm, v))
          fields

(* The local/global names an expression *reads* (its [Get]s), gathered so a
   [let] can be renamed to one of them — see the [Let] case in [mutate_node].
   A structural walk of the value-carrying forms; exotic ones fall through to
   [[]], which only lowers yield, never breaks the reprint. *)
let rec get_names_in (i : location instr) : string list =
  let opt = function Some e -> get_names_in e | None -> [] in
  let all l = List.concat_map get_names_in l in
  let block (b : (location instr list, location) annotated) = all b.desc in
  match i.desc with
  | Get id -> [ id.desc ]
  | BinOp (_, a, b) -> get_names_in a @ get_names_in b
  | UnOp (_, e)
  | Cast (e, _)
  | Test (e, _)
  | NonNull e
  | GetDescriptor e
  | Labelled (_, e)
  | Tee (_, e)
  | StructGet (e, _)
  | ThrowRef e
  | Hinted (_, e)
  | Br_if (_, e)
  | Br_table (_, e)
  | Br_on_null (_, e)
  | Br_on_non_null (_, e)
  | Br_on_cast (_, _, e)
  | Br_on_cast_fail (_, _, e)
  | ContNew (_, e)
  | Set (_, _, e) ->
      get_names_in e
  | Select (a, b, c) -> get_names_in a @ get_names_in b @ get_names_in c
  | Call (f, args) | TailCall (f, args) -> get_names_in f @ all args
  | Throw (_, l)
  | Suspend (_, l)
  | ContBind (_, _, l)
  | Resume (_, _, l)
  | ResumeThrow (_, _, _, l)
  | ResumeThrowRef (_, _, l)
  | Switch (_, _, l)
  | Sequence l
  | ArrayFixed (_, l) ->
      all l
  | Array (_, a, b)
  | ArraySegment (_, _, a, b)
  | Br_on_cast_desc_eq (_, _, a, b)
  | Br_on_cast_desc_eq_fail (_, _, a, b) ->
      get_names_in a @ get_names_in b
  | ArrayDefault (_, e) | StructDefaultDesc e -> get_names_in e
  | ArrayGet (a, b) -> get_names_in a @ get_names_in b
  | ArraySet (a, b, c) -> get_names_in a @ get_names_in b @ get_names_in c
  | StructSet (e, _, v) -> get_names_in e @ get_names_in v
  | Return e | Br (_, e) | Let (_, e) -> opt e
  | Struct (_, fields) -> List.concat_map (fun (_, v) -> opt v) fields
  | StructDesc (d, fields) ->
      get_names_in d @ List.concat_map (fun (_, v) -> opt v) fields
  | If { cond; if_block; else_block; _ } ->
      get_names_in cond @ block if_block
      @ Option.fold ~none:[] ~some:block else_block
  | Block { block = b; _ } | Loop { block = b; _ } | TryTable { block = b; _ }
    ->
      block b
  | While { cond; step; block = b; _ } -> get_names_in cond @ opt step @ block b
  | _ -> []

let mutate_node (i : location instr) : location instr =
  (* Replacing a value with a hole [_] feeds the type checker's hole handling in
     any position the walk reaches (a struct field, a match scrutinee, a call
     argument, …) — a recovery path the valid-only corpus never exercises. *)
  let desc =
    if next () mod 6 = 0 then Hole
    else
      match i.desc with
      | BinOp (op, a, b) -> (
          match next () mod 3 with
          | 0 -> BinOp ({ op with desc = swap_binop op.desc }, a, b)
          | 1 -> BinOp (op, b, a)
          | _ -> graft ())
      | UnOp (op, e) ->
          if next () mod 2 = 0 then
            UnOp ({ op with desc = swap_unop op.desc }, e)
          else graft ()
      | Int _ -> if next () mod 2 = 0 then Int (pick int_pool) else graft ()
      | Float _ ->
          if next () mod 2 = 0 then Float (pick float_pool) else graft ()
      | Cast (e, Valtype _) ->
          if next () mod 2 = 0 then Cast (e, Valtype (pick valtype_pool))
          else graft ()
      | Struct (name, fields) -> Struct (name, mutate_fields i.info fields)
      | StructDesc (d, fields) -> StructDesc (d, mutate_fields i.info fields)
      (* Perturb a compound assignment [x op= e]: swap the operator or drop it to
         a plain [x = e]. Promote a plain assignment to a variable into a compound
         one. Either may become ill-typed — an expected rejection, not a crash. *)
      | Set (id, Some op, e) ->
          if next () mod 2 = 0 then
            Set (id, Some { op with desc = swap_binop op.desc }, e)
          else Set (id, None, e)
      | Set (id, None, e) when next () mod 2 = 0 ->
          Set (id, Some { desc = pick compound_binops; info = e.info }, e)
      (* Rename a named [let] to an identifier its own initializer reads: the new
         binding then shadows whatever that name resolved to (a parameter or an
         enclosing local), and its initializer references it — the exact shape
         To_wasm must lower with the initializer in the *outer* scope. Keep the
         initializer verbatim (only one site mutates), so the [Get] of the
         reused name is preserved. *)
      | Let ((Some first, ty) :: rest, Some init) -> (
          match get_names_in init with
          | [] -> graft ()
          | names ->
              let n = pick (Array.of_list names) in
              Let ((Some { first with desc = n }, ty) :: rest, Some init))
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
  (* Recurse into the constructs that carry scrutinees, arm bodies and field
     values, so a mutation (a hole, a graft, a field edit) can land there and
     reach the type checker's recovery paths — not just top-level statements. *)
  | Match r ->
      Match
        {
          scrutinee = go r.scrutinee;
          arms =
            List.map
              (fun (p, b) -> (p, { b with desc = go_list b.desc }))
              r.arms;
          default = { r.default with desc = go_list r.default.desc };
        }
  | Dispatch r ->
      Dispatch
        {
          r with
          index = go r.index;
          arms =
            List.map
              (fun (l, b) -> (l, { b with desc = go_list b.desc }))
              r.arms;
        }
  | On (e, clauses) -> On (go e, clauses)
  | Struct (name, fields) ->
      Struct (name, List.map (fun (n, v) -> (n, Option.map go v)) fields)
  | StructDesc (d, fields) ->
      StructDesc (go d, List.map (fun (n, v) -> (n, Option.map go v)) fields)
  | StructDefaultDesc d -> StructDefaultDesc (go d)
  | Array (t, a, b) -> Array (t, go a, go b)
  | ArrayDefault (t, e) -> ArrayDefault (t, go e)
  | ArrayFixed (t, l) -> ArrayFixed (t, go_list l)
  | ArraySegment (t, seg, a, b) -> ArraySegment (t, seg, go a, go b)
  | ThrowRef e -> ThrowRef (go e)
  | Throw (t, l) -> Throw (t, List.map go l)
  | ContNew (t, e) -> ContNew (t, go e)
  | ContBind (s, d, l) -> ContBind (s, d, List.map go l)
  | Suspend (t, l) -> Suspend (t, List.map go l)
  | Resume (t, h, l) -> Resume (t, h, List.map go l)
  | ResumeThrow (t, tag, h, l) -> ResumeThrow (t, tag, h, List.map go l)
  | ResumeThrowRef (t, h, l) -> ResumeThrowRef (t, h, List.map go l)
  | Switch (t, tag, l) -> Switch (t, tag, List.map go l)
  | Br_on_null (l, e) -> Br_on_null (l, go e)
  | Br_on_non_null (l, e) -> Br_on_non_null (l, go e)
  | Br_on_cast (l, t, e) -> Br_on_cast (l, t, go e)
  | Br_on_cast_fail (l, t, e) -> Br_on_cast_fail (l, t, go e)
  | Br_on_cast_desc_eq (l, n, a, b) -> Br_on_cast_desc_eq (l, n, go a, go b)
  | Br_on_cast_desc_eq_fail (l, n, a, b) ->
      Br_on_cast_desc_eq_fail (l, n, go a, go b)
  | GetDescriptor e -> GetDescriptor (go e)
  | Sequence l -> Sequence (go_list l)
  | Set (id, op, e) -> Set (id, op, go e)
  | Tee (id, e) -> Tee (id, go e)
  | Call (f, args) -> Call (go f, List.map go args)
  | TailCall (f, args) -> TailCall (go f, List.map go args)
  | Labelled (l, e) -> Labelled (l, go e)
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

(* Point one member's supertype at an in-group name — its own (a self cycle) or a
   sibling — the forward/self reference that must be rejected (as unbound) rather
   than hang the subtype walk. A rec group's later members are in scope here too,
   so a plain sequence of type definitions can be made cyclic. *)
let mutate_rectype (rt : rectype) : rectype =
  let n = Array.length rt in
  if n = 0 then rt
  else
    let k = next () mod n in
    let sup = fst rt.(next () mod n).desc in
    Array.mapi
      (fun i e ->
        if i = k then
          let name, (sub : subtype) = e.desc in
          { e with desc = (name, { sub with supertype = Some sup }) }
        else e)
      rt

let go_field (fld : (location modulefield, location) annotated) =
  let desc =
    match fld.desc with
    | Func r ->
        let label, body = r.body in
        Func { r with body = (label, go_list body) }
    | Global r -> Global { r with def = go r.def }
    (* A type definition is itself a mutable site (its supertype). *)
    | Type rt -> if site () then Type (mutate_rectype rt) else Type rt
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
  Wax_utils.Printer.run_channel ~width:Wax_lang.Output.width stdout (fun p ->
      Wax_lang.Output.module_ ~color p ~trivia:(Wax_utils.Trivia.empty ()) m');
  flush stdout

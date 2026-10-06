(* Value-type alias transformer for Wax source, behind fuzz/alias-fuzz.sh.

   Reads a .wax file, replaces some of the value types written in declarations
   (signatures, locals, globals, struct and array fields, imports) by aliases of
   them, and prints the result. Which occurrences are replaced is derived from
   the seed. A type is given one alias, [fz_alias_N], defined at the top of the
   module. Cast targets are left alone: a cast is an instruction, not a
   declaration.

   Usage: fuzz_alias <file.wax> [seed] [conditional-variable]

   With a conditional variable [v], the alias definitions are placed in both
   branches of an [#[if(v)]], identically: the module means the same thing in
   either configuration, but the aliases are conditional ones, which the
   toolchain must keep and lower to a form that holds in every configuration.

   Aliasing changes nothing about the module, so the oracle compares: the binary
   must be byte-identical to the original's (after [-D] for a conditional run),
   and the unresolved text output must validate and round-trip. *)

module Ast = Wax_lang.Ast
open Ast

let color = Wax_utils.Colors.Never

module WaxParser =
  Wax_utils.Parsing.Make_parser
    (struct
      type t = Wax_lang.Ast.location Wax_lang.Ast.module_
    end)
    (Wax_lang.Tokens)
    (Wax_lang.Parser)
    (Wax_lang.Fast_parser)
    (Wax_lang.Parser_messages)
    (Wax_lang.Lexer)

(* A small LCG, seeded from the command-line seed, as in fuzz_mutate. *)
let state = ref 1

let next () =
  state := ((!state * 1103515245) + 12345) land max_int;
  (!state lsr 8) land max_int

(* The alias given to each distinct type, keyed by its printed form, in order of
   creation. *)
let aliases : (string, string * valtype) Hashtbl.t = Hashtbl.create 16
let order = ref []

let alias_of (t : valtype) : valtype =
  match t with
  | Alias _ -> t
  | I32 | I64 | F32 | F64 | V128 | Ref _ ->
      if next () mod 2 = 0 then t
      else
        let key =
          Wax_lang.Output.run_string (fun p -> Wax_lang.Output.valtype p t)
        in
        let name =
          match Hashtbl.find_opt aliases key with
          | Some (name, _) -> name
          | None ->
              let name =
                Printf.sprintf "fz_alias_%d" (Hashtbl.length aliases)
              in
              Hashtbl.add aliases key (name, t);
              order := name :: !order;
              name
        in
        Alias (no_loc name)

let param (p : (ident option * valtype, location) annotated) =
  { p with desc = (fst p.desc, alias_of (snd p.desc)) }

let functype ({ params; results } : functype) : functype =
  { params = Array.map param params; results = Array.map alias_of results }

let fieldtype (f : fieldtype) : fieldtype =
  match f.typ with
  | Value v -> { f with typ = Value (alias_of v) }
  | Packed _ -> f

let comptype (c : comptype) : comptype =
  match c with
  | Func f -> Func (functype f)
  | Struct fields ->
      Struct
        (Array.map
           (fun (f : (ident * fieldtype, location) annotated) ->
             { f with desc = (fst f.desc, fieldtype (snd f.desc)) })
           fields)
  | Array f -> Array (fieldtype f)
  | Cont _ -> c

let rec instr (i : 'a instr) : 'a instr =
  let desc =
    Wax_lang.Ast_utils.map_desc ~instr ~block:(List.map instr) i.desc
  in
  let desc =
    match desc with
    | Let (bindings, init) ->
        Let (List.map (fun (n, t) -> (n, Option.map alias_of t)) bindings, init)
    | _ -> desc
  in
  { i with desc }

let import_decl (d : (import_decl, location) annotated) =
  let kind =
    match d.desc.kind with
    | Import_func r -> Import_func { r with sign = Option.map functype r.sign }
    | Import_global r -> Import_global { r with typ = alias_of r.typ }
    | Import_tag r -> Import_tag { r with sign = Option.map functype r.sign }
    | k -> k
  in
  { d with desc = { d.desc with kind } }

let rec field (f : (_ modulefield, location) annotated) =
  let f =
    { f with desc = Wax_lang.Ast_utils.map_modulefield_instr instr f.desc }
  in
  let desc =
    match f.desc with
    | Type rt ->
        Type
          (Array.map
             (fun (m : (ident * subtype, location) annotated) ->
               let name, st = m.desc in
               { m with desc = (name, { st with typ = comptype st.typ }) })
             rt)
    | Func r -> Func { r with sign = Option.map functype r.sign }
    | Global r -> Global { r with typ = Option.map alias_of r.typ }
    | Tag r -> Tag { r with sign = Option.map functype r.sign }
    | Import r -> Import { r with decl = import_decl r.decl }
    | Import_group r ->
        Import_group { r with decls = List.map import_decl r.decls }
    | Conditional r ->
        let fields (l : (_ list, location) annotated) =
          { l with desc = List.map field l.desc }
        in
        Conditional
          {
            r with
            then_fields = fields r.then_fields;
            else_fields = Option.map fields r.else_fields;
          }
    | d -> d
  in
  { f with desc }

let () =
  let file = Sys.argv.(1) in
  let seed =
    if Array.length Sys.argv > 2 then int_of_string Sys.argv.(2) else 0
  in
  let conditional =
    if Array.length Sys.argv > 3 then Some Sys.argv.(3) else None
  in
  state := (seed * 2) + 1;
  let src = In_channel.with_open_bin file In_channel.input_all in
  let m, _ctx = WaxParser.parse_from_string ~color ~filename:file src in
  let m = List.map field m in
  let defs =
    List.rev_map
      (fun name ->
        let typ =
          Hashtbl.fold
            (fun _ (n, t) acc -> if n = name then Some t else acc)
            aliases None
          |> Option.get
        in
        no_loc (Type_alias { name = no_loc name; typ }))
      !order
  in
  let defs =
    match (conditional, defs) with
    | _, [] | None, _ -> defs
    | Some v, _ ->
        [
          no_loc
            (Conditional
               {
                 cond = Wax_wasm.Ast.Cond_var (no_loc v);
                 then_fields = no_loc defs;
                 else_fields = Some (no_loc defs);
               });
        ]
  in
  Wax_lang.Output.run_channel stdout (fun p ->
      Wax_lang.Output.module_ ~color p
        ~trivia:(Wax_utils.Trivia.empty ())
        (defs @ m));
  flush stdout

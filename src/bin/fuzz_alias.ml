(* Value-type alias transformer for Wax source, behind fuzz/alias-fuzz.sh.

   Reads a .wax file, replaces some of the value types written in declarations
   (signatures, locals, globals, struct and array fields, imports) by aliases of
   them, and prints the result. Which occurrences are replaced is derived from
   the seed. A type is given one alias, [fz_alias_N], defined at the top of the
   module. Cast targets are left alone: a cast is an instruction, not a
   declaration.

   Usage: fuzz_alias <file.wax> [seed] [conditional-variable [differ]]

   With a conditional variable [v], the alias definitions are placed in both
   branches of an [#[if(v)]], identically: the module means the same thing in
   either configuration, but the aliases are conditional ones, which the
   toolchain must keep and lower to a form that holds in every configuration.

   With [differ], the [#[else]] branch defines each alias as a neighbouring type
   instead (i32 and i64, f32 and f64; for a reference, the other nullability, a
   related struct type, or the other hierarchy), and cast targets are aliased
   too: the module then means something different in each configuration, if it
   is valid at all, and converting it unresolved must agree with converting
   each configuration (see fuzz/alias-fuzz.sh). Some statements of each
   function body are also placed in one or both branches of an [#[if(v_2)]],
   so that the configurations are combinations of two variables, and two
   field names of a struct subtype may be swapped.

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

(* Whether cast targets are aliased too (the [differ] mode). *)
let casts = ref false

(* A field's type is not aliased in the [differ] mode: a field of a subtype
   whose type differs between configurations seldom still makes it one. *)
let fieldtype (f : fieldtype) : fieldtype =
  match f.typ with
  | Value v when not !casts -> { f with typ = Value (alias_of v) }
  | Value _ | Packed _ -> f

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
    | Cast (e, Valtype t) when !casts -> Cast (e, Valtype (alias_of t))
    | _ -> desc
  in
  { i with desc }

(* The supertype of each type the module declares, by name. *)
let supertypes : (string, string) Hashtbl.t = Hashtbl.create 16

let rec collect_supertypes (f : (_ modulefield, location) annotated) =
  match f.desc with
  | Type rt ->
      Array.iter
        (fun (m : (ident * subtype, location) annotated) ->
          let name, st = m.desc in
          Option.iter
            (fun (s : ident) -> Hashtbl.replace supertypes name.desc s.desc)
            st.supertype)
        rt
  | Conditional { then_fields; else_fields; _ } ->
      List.iter collect_supertypes then_fields.desc;
      Option.iter
        (fun (l : (_ list, location) annotated) ->
          List.iter collect_supertypes l.desc)
        else_fields
  | _ -> ()

(* A type related to [t] by subtyping, its supertype or else a subtype. *)
let related t =
  match Hashtbl.find_opt supertypes t with
  | Some s -> Some s
  | None ->
      Hashtbl.fold
        (fun sub sup acc -> if acc = None && sup = t then Some sub else acc)
        supertypes None

(* A type of the same kind as [t], for the [#[else]] definition of a [differ]
   run: a reference may keep its heap type and change its nullability, or name
   a related struct type (whose fields may sit elsewhere), or move to the other
   hierarchy. *)
let neighbour (t : valtype) : valtype =
  match t with
  | I32 -> I64
  | I64 -> I32
  | F32 -> F64
  | F64 -> F32
  | Ref ({ typ = Type n | Exact n; _ } as r) when next () mod 2 = 0 -> (
      match related n.desc with
      | Some s -> Ref { r with typ = Type (no_loc s) }
      | None -> Ref { r with nullable = not r.nullable })
  | Ref ({ typ = Any | Eq | I31 | Struct | Array | None_; _ } as r)
    when next () mod 2 = 0 ->
      Ref { r with typ = Extern }
  | Ref ({ typ = Extern | NoExtern; _ } as r) when next () mod 2 = 0 ->
      Ref { r with typ = Eq }
  | Ref r -> Ref { r with nullable = not r.nullable }
  | V128 | Alias _ -> t

(* The second variable of a [differ] run, when there is one. *)
let second = ref None

(* [instrs] with some statements in both branches of an [#[if(v_2)]]: never a
   [let] that binds a name, which the rest of the body may use, nor the last
   statement when it may be the body's value: unless the body has none
   ([no_value]), or that statement is a [let], which binds nothing then. *)
let rec wrap_statements ~no_value (instrs : location instr list) =
  match (instrs, !second) with
  | [], _ | _, None -> instrs
  | ({ desc = Let (bindings, _); _ } as i) :: rest, _
    when List.exists (fun (n, _) -> Option.is_some n) bindings ->
      i :: wrap_statements ~no_value rest
  | [ ({ desc = d; _ } as i) ], _
    when (not no_value) && match d with Let _ -> false | _ -> true ->
      [ i ]
  | i :: rest, Some v ->
      let i =
        if next () mod 3 <> 0 then i
        else
          (* In both branches, or in only one: a construct then occurs in only
             some configurations, which the conversion may not all type. *)
          let then_, else_ =
            match next () mod 3 with
            | 0 -> ([ i ], [ i ])
            | 1 -> ([ i ], [])
            | _ -> ([], [ i ])
          in
          {
            i with
            desc =
              If_annotation
                {
                  cond = Wax_wasm.Ast.Cond_var (no_loc v);
                  then_body = no_loc then_;
                  else_body = Some (no_loc else_);
                };
          }
      in
      i :: wrap_statements ~no_value rest

(* For a [differ] run, a subtype's struct fields with the names of two of them
   swapped, sometimes: a field the subtype inherits may then sit elsewhere
   under the same name than in its supertype. Not across a [..] splice, which
   names no inherited field. *)
let swap_field_names (c : comptype) : comptype =
  match c with
  | Struct fields
    when Array.length fields >= 2
         && (not (Array.exists is_splice_field fields))
         && next () mod 2 = 0 ->
      let fields = Array.copy fields in
      let i = next () mod (Array.length fields - 1) in
      let a = fields.(i) and b = fields.(i + 1) in
      fields.(i) <- { a with desc = (fst b.desc, snd a.desc) };
      fields.(i + 1) <- { b with desc = (fst a.desc, snd b.desc) };
      Struct fields
  | _ -> c

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
               let st =
                 if !second <> None && st.supertype <> None then
                   { st with typ = swap_field_names st.typ }
                 else st
               in
               { m with desc = (name, { st with typ = comptype st.typ }) })
             rt)
    | Func r ->
        Func
          {
            r with
            sign = Option.map functype r.sign;
            body =
              ( fst r.body,
                wrap_statements
                  ~no_value:
                    (match r.sign with
                    | Some { results; _ } -> results = [||]
                    | None -> false)
                  (snd r.body) );
          }
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
  let differ = Array.length Sys.argv > 4 && Sys.argv.(4) = "differ" in
  casts := differ;
  if differ then second := Option.map (fun v -> v ^ "_2") conditional;
  state := (seed * 2) + 1;
  let src = In_channel.with_open_bin file In_channel.input_all in
  let m, _ctx = WaxParser.parse_from_string ~color ~filename:file src in
  List.iter collect_supertypes m;
  let m = List.map field m in
  let defs_with f =
    List.rev_map
      (fun name ->
        let typ =
          Hashtbl.fold
            (fun _ (n, t) acc -> if n = name then Some t else acc)
            aliases None
          |> Option.get
        in
        no_loc (Type_alias { name = no_loc name; typ = f typ }))
      !order
  in
  let defs = defs_with Fun.id in
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
                 else_fields =
                   Some (no_loc (if differ then defs_with neighbour else defs));
               });
        ]
  in
  Wax_lang.Output.run_channel stdout (fun p ->
      Wax_lang.Output.module_ ~color p
        ~trivia:(Wax_utils.Trivia.empty ())
        (defs @ m));
  flush stdout

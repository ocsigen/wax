(* Canonical rendering of Wasm binaries for comparison, behind fuzz/alias-fuzz.sh.

   Usage: fuzz_canon <a.wasm> <a.txt> <b.wasm> <b.txt>

   Writes each module as WAT to its text file with every type named by its
   canonical identity in a type store the two modules share, and the type
   definitions themselves left out. Structurally equal types are the same type
   in Wasm, so two modules that differ only in how they spell or duplicate a
   type render the same, while a reference to a different type (a cast to
   [fn() -> i32] where the other casts to [fn() -> i64]) still differs. *)

module Ast = Wax_wasm.Ast
module B = Ast.Binary
module Types = Wax_wasm.Types

let store = Types.create ()

(* The canonical name of each of the module's type indices, interning its rec
   groups in [store] in order. *)
let canonical_names (m : _ B.module_) =
  let ids = Hashtbl.create 16 in
  let next = ref 0 in
  List.iter
    (fun (rt : B.rectype) ->
      let start = !next in
      let module M =
        Ast.Map_types (B) (Types.Normalized)
          (struct
            type ctx = unit

            let idx () i =
              if i >= start then Types.Rec (i - start)
              else Types.Def (Hashtbl.find ids i)

            let alias () _ (a : B.alias) = match a with _ -> .
            let params () f a = Array.map f a
            let fields () f a = Array.map f a
            let members () f a = Array.map f a
          end) in
      let first = Types.add_rectype store (M.rectype () rt) in
      Array.iteri
        (fun k _ -> Hashtbl.replace ids (start + k) (Types.Id.add first k))
        rt;
      next := start + Array.length rt)
    m.types;
  Hashtbl.fold
    (fun i id map ->
      B.IntMap.add i
        (Printf.sprintf "c%d" (Types.Id.to_int_for_tests_only id))
        map)
    ids B.IntMap.empty

(* [text] with each function's locals that no instruction reads or writes left
   out. A module converted unresolved declares at the function level the locals
   of every branch of a conditional annotation, as WAT has no conditional local,
   so once specialized it may declare some its kept branches never use; an
   unused local means nothing. Only in a function whose locals are all
   referenced by name: dropping one renumbers the others. *)
let drop_unused_locals ((id, fields) : _ Ast.Text.module_) : _ Ast.Text.module_
    =
  let field (f : (_ Ast.Text.modulefield, _) Ast.annotated) =
    match f.desc with
    | Func ({ locals; instrs; _ } as func) -> (
        let used =
          List.fold_left
            (Wax_wasm.Ast_utils.fold_instr (fun acc (i : _ Ast.Text.instr) ->
                 match (acc, i.desc) with
                 | ( Some names,
                     ( LocalGet { desc = Id n; _ }
                     | LocalSet { desc = Id n; _ }
                     | LocalTee { desc = Id n; _ } ) ) ->
                     Some (n :: names)
                 | _, (LocalGet _ | LocalSet _ | LocalTee _) -> None
                 | _ -> acc))
            (Some []) instrs
        in
        match used with
        | Some used
          when List.for_all
                 (fun (l : _ Ast.annotated) -> Option.is_some (fst l.desc))
                 locals ->
            let locals =
              List.filter
                (fun (l : _ Ast.annotated) ->
                  match fst l.desc with
                  | Some (n : Ast.Text.name) -> List.mem n.desc used
                  | None -> true)
                locals
            in
            { f with desc = Ast.Text.Func { func with locals } }
        | _ -> f)
    | _ -> f
  in
  (id, List.map field fields)

(* [s] with each function's locals named [$l0], [$l1]… in declaration order. A
   module converted unresolved names apart the locals of a statement that
   occurs in both branches of a conditional ([$x] in one, [$x_2] in the
   other), so once specialized it may name a local differently than the
   configuration compiled directly does. *)
let canonical_local_names s =
  let decl = Re.Perl.compile_pat {|\(local \$([^ ()]+)|} in
  let use =
    Re.Perl.compile_pat
      {|(\(local |local\.get |local\.set |local\.tee )\$([^ ()]+)|}
  in
  (* A function's lines, renamed one by one: a name runs to a space or a
     parenthesis, or else to the end of its line. *)
  let rename lines =
    let names =
      List.concat_map (Re.all decl) lines
      |> List.mapi (fun k g -> (Re.Group.get g 1, Printf.sprintf "$l%d" k))
    in
    List.map
      (Re.replace use ~f:(fun g ->
           match List.assoc_opt (Re.Group.get g 2) names with
           | Some n -> Re.Group.get g 1 ^ n
           | None -> Re.Group.get g 0))
      lines
  in
  (* A function starts a field, at column 0 or 2. *)
  let starts_func line =
    let t = String.trim line in
    String.starts_with ~prefix:"(func" t
    && String.length line - String.length t <= 2
  in
  let chunks =
    List.fold_left
      (fun chunks line ->
        match chunks with
        | current :: rest when not (starts_func line) ->
            (line :: current) :: rest
        | _ -> [ line ] :: chunks)
      []
      (String.split_on_char '\n' s)
  in
  List.rev_map
    (fun chunk -> String.concat "\n" (rename (List.rev chunk)))
    chunks
  |> String.concat "\n"

(* The module as WAT, without its type definitions (a [(type …)] or [(rec …)]
   field, which runs to the next field). Fields start at column 0, or at column
   2 inside a [(module …)] wrapper. *)
let render (m : _ B.module_) =
  let m = { m with names = { m.names with types = canonical_names m } } in
  let text = drop_unused_locals (Wax_wasm.Binary_to_text.module_ m) in
  let s =
    Wax_utils.Printer.run_string (fun p ->
        Wax_wasm.Output.module_ p ~trivia:(Wax_utils.Trivia.empty ()) text)
  in
  let lines = String.split_on_char '\n' s in
  let indent =
    match lines with
    | first :: _ when String.starts_with ~prefix:"(module" first -> 2
    | _ -> 0
  in
  let skipping = ref false in
  lines
  |> List.filter (fun line ->
      if
        String.length line > indent
        && line.[indent] <> ' '
        && String.for_all (( = ) ' ') (String.sub line 0 indent)
      then begin
        let field = String.sub line indent (String.length line - indent) in
        skipping :=
          String.starts_with ~prefix:"(type " field
          || String.starts_with ~prefix:"(rec" field
      end;
      if line = ")" then skipping := false;
      not !skipping)
  |> String.concat "\n"
  (* Two indices of one canonical type are printed uniquified ([$c0_1]). *)
  |> Re.replace (Re.Perl.compile_pat {|\$c([0-9]+)_[0-9]+|}) ~f:(fun g ->
      "$c" ^ Re.Group.get g 1)
  |> canonical_local_names

let () =
  let d = Wax_utils.Diagnostic.collector () in
  let pair i =
    let bin = In_channel.with_open_bin Sys.argv.(i) In_channel.input_all in
    let m = Wax_wasm.Wasm_parser.module_ d ~filename:Sys.argv.(i) bin in
    Out_channel.with_open_bin
      Sys.argv.(i + 1)
      (fun oc ->
        output_string oc (render m);
        output_char oc '\n')
  in
  pair 1;
  pair 3

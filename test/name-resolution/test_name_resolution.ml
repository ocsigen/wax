(* Name resolution for go-to-definition: type-check a source with a
   [resolve_links] sink and print each resolved reference as
   "<use text>" @ use-span -> definition-span(s). Exercises module fields
   (functions, globals, types), locals (params, lets, shadowing) and labels. *)

open Wax_lang

module P =
  Wax_wasm.Parsing.Make
    (struct
      type t = Ast.location Ast.module_
    end)
    (Tokens)
    (Parser)
    (Parser_messages)
    (Lexer)

(* A location as line:col-line:col, 1-based line, 0-based byte column. *)
let span (l : Wax_utils.Ast.location) =
  let p (q : Lexing.position) =
    Printf.sprintf "%d:%d" q.pos_lnum (q.pos_cnum - q.pos_bol)
  in
  Printf.sprintf "%s-%s" (p l.loc_start) (p l.loc_end)

let slice src (l : Wax_utils.Ast.location) =
  String.sub src l.loc_start.pos_cnum (l.loc_end.pos_cnum - l.loc_start.pos_cnum)

(* The hover summary a reference carries (the editor renders it the same way). *)
let render_hover ~name = function
  | Typing.Value_type ity ->
      Format.asprintf "%a" Infer.output_inferred_type (Infer.valtype_cell ity)
  | Typing.Type_def st ->
      let field = Ast.no_loc (Ast.no_loc name, st) in
      let buf = Buffer.create 32 in
      let f = Format.formatter_of_buffer buf in
      Wax_utils.Printer.run ~width:Output.width f (fun p ->
          Output.subtype p field);
      Format.pp_print_flush f ();
      String.trim (Buffer.contents buf)

let resolve name src =
  Printf.printf "=== %s ===\n" name;
  match P.parse_diagnostics ~filename:"t.wax" src with
  | Error e -> Printf.printf "parse error: %s\n\n" (String.trim e.message)
  | Ok (ast, _ctx) ->
      let d = Wax_utils.Diagnostic.collector ~source:src () in
      let links = ref [] in
      let puns = ref [] in
      let members = ref [] in
      (try
         ignore
           (Typing.f_infer ~resolve_links:(Some links) ~pun_spans:(Some puns)
              ~member_completions:(Some members) d ast)
       with Wax_utils.Diagnostic.Aborted -> ());
      !links
      |> List.map (fun (r : Typing.reference) ->
          Printf.sprintf "%-8s @ %-9s -> %s%s"
            (Printf.sprintf "%S" (slice src r.use))
            (span r.use)
            (String.concat ", " (List.map span r.definitions))
            (match r.hover with
            | Some t ->
                Printf.sprintf "  [%s]" (render_hover ~name:(slice src r.use) t)
            | None -> ""))
      (* The typer may resolve a name more than once; a use -> def link is the
         same each time, so present the distinct ones, ordered. *)
      |> List.sort_uniq compare
      |> List.iter print_endline;
      (* Punned struct fields, which rename must expand rather than replace. *)
      List.iter
        (fun l -> Printf.printf "pun %S @ %s\n" (slice src l) (span l))
        (List.sort_uniq compare !puns);
      (* Member-completion candidates at each struct field access: name, kind
         (a struct field, or a value method) and its rendered signature. *)
      List.iter
        (fun (l, candidates) ->
          let show (c : Typing.member_candidate) =
            Printf.sprintf "%s: %s" c.member_name c.member_detail
          in
          Printf.printf "member @ %s -> %s\n" (span l)
            (String.concat ", " (List.map show candidates)))
        (List.sort_uniq compare !members);
      print_newline ()

let () =
  resolve "call, param, binop"
    "fn add(a: i32, b: i32) -> i32 { a + b; }\nfn use() -> i32 { add(1, 2); }\n";
  resolve "let shadowing"
    "fn f() -> i32 {\n  let x = 1;\n  let x = x + 1;\n  x;\n}\n";
  resolve "global and type"
    "type point = { x: i32, y: i32 };\n\
     const g: i32 = 0;\n\
     fn get_g(p: &point) -> i32 { g; }\n";
  resolve "label" "fn f() {\n  'outer: loop { br 'outer; }\n}\n";
  resolve "struct pun"
    "type point = { x: i32, y: i32 };\n\
     fn mk(x: i32, y: i32) -> &point { {point| x, y: y }; }\n";
  (* Member candidates carry each field's rendered type (mut / ref included). *)
  resolve "member access"
    "type point = { x: i32, y: mut i32, next: &point };\n\
     fn get_x(p: &point) -> i32 { p.x; }\n";
  (* A partial member access (no call yet) is what completion sees mid-edit; on
     a numeric / array receiver it records the value-method registry. *)
  resolve "value methods"
    "type arr = [i32];\n\
     fn m(x: i32, w: i64, f: f32, a: &arr) {\n\
    \  _ = x.clz; _ = w.from_bits; _ = f.sqrt; _ = a.length;\n\
     }\n";
  (* A memory receiver (a name, not a value) records that object's methods. *)
  resolve "memory receiver" "memory mem: i32 [1];\nfn f() { _ = mem.load8; }\n"

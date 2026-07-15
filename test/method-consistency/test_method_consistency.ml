(* The value methods member completion offers ([Typing.integer_methods] /
   [float_methods]) must match what the typer accepts, or completion would
   suggest a method that fails to type-check — or show it a wrong signature. The
   method dispatch is match-based and cannot be enumerated, so this test builds a
   call of each and binds its result to the type the registry claims:
   [let r: <result> = x.m(args);]. Type-checking that with no error confirms, via
   the typer itself as oracle, both that the method exists and that its arity and
   result type are what the registry records. (It does not check the reverse —
   that no accepted method is missing from the list — which the match gives no
   enumerable way to verify.) *)

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

let error_count src =
  match P.parse_diagnostics ~filename:"t.wax" src with
  | Error _ -> -1 (* a parse error means the snippet itself is wrong *)
  | Ok (ast, _ctx) ->
      let d = Wax_utils.Diagnostic.collector ~source:src () in
      (try Typing.check d ast with Wax_utils.Diagnostic.Aborted -> ());
      Wax_utils.Diagnostic.collected d
      |> List.filter (fun e ->
          Wax_utils.Diagnostic.entry_severity e = Wax_utils.Diagnostic.Error)
      |> List.length

(* The result type the registry claims for [m] on receiver [recv]. *)
let result_type recv (m : Typing.value_method) =
  match m.vm_result with
  | Typing.Same -> recv
  | Typing.Reinterpret -> (
      match recv with
      | "i32" -> "f32"
      | "i64" -> "f64"
      | "f32" -> "i32"
      | "f64" -> "i64"
      | other -> other)

let check recv (m : Typing.value_method) =
  let args = if m.vm_binary then "y" else "" in
  let src =
    Printf.sprintf "fn t(x: %s, y: %s) { let r: %s = x.%s(%s); _ = r; }\n" recv
      recv (result_type recv m) m.vm_name args
  in
  Printf.printf "%-4s.%-11s %s\n" recv m.vm_name
    (match error_count src with
    | 0 -> "ok"
    | -1 -> "PARSE ERROR"
    | n -> Printf.sprintf "FAIL (%d errors)" n)

let () =
  List.iter (check "i32") Typing.integer_methods;
  List.iter (check "i64") Typing.integer_methods;
  List.iter (check "f32") Typing.float_methods;
  List.iter (check "f64") Typing.float_methods;
  let src =
    "type arr = [i32];\nfn t(x: &arr) { let r: i32 = x.length(); _ = r; }\n"
  in
  Printf.printf "arr .length      %s\n"
    (match error_count src with 0 -> "ok" | _ -> "FAIL")

(* The value methods member completion offers ([Typing.integer_methods] /
   [float_methods]) must be ones the typer actually accepts, or completion would
   suggest a method that then fails to type-check. The method dispatch is
   match-based and cannot be enumerated, so this test type-checks a call of each
   (dropping its result, so its result type is irrelevant) and asserts no error.
   It does not check the reverse — that no accepted method is missing from the
   list — which the match gives no enumerable way to verify. *)

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

(* [rotl]/[rotr]/[min]/[max]/[copysign] take a second operand; the rest are
   unary. *)
let binary = [ "rotl"; "rotr"; "min"; "max"; "copysign" ]

let check recv m =
  let args = if List.mem m binary then "y" else "" in
  let src =
    Printf.sprintf "fn t(x: %s, y: %s) { _ = x.%s(%s); }\n" recv recv m args
  in
  Printf.printf "%-4s.%-11s %s\n" recv m
    (match error_count src with
    | 0 -> "ok"
    | -1 -> "PARSE ERROR"
    | n -> Printf.sprintf "FAIL (%d errors)" n)

let () =
  List.iter (check "i32") Typing.integer_methods;
  List.iter (check "f32") Typing.float_methods;
  let src = "type arr = [i32];\nfn t(x: &arr) { _ = x.length(); }\n" in
  Printf.printf "arr .length      %s\n"
    (match error_count src with 0 -> "ok" | _ -> "FAIL")

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

(* The [v128] methods are enumerated from the SIMD registry rather than curated,
   so completion offers exactly what the typer classifies — no drift by
   construction. This still type-checks each: a call built from the intrinsic's
   own shape (leading lane immediates, then the non-receiver operands, result
   bound to its claimed type), so a bad enumeration or a wrong rendered signature
   would surface. Since there are many, only failures are listed; a curated
   sample's rendered signature is printed to lock in the formatting. *)
let ty_name : Wax_wasm.Simd.ty -> string = function
  | TV128 -> "v128"
  | TI32 -> "i32"
  | TI64 -> "i64"
  | TF32 -> "f32"
  | TF64 -> "f64"

let ty_var : Wax_wasm.Simd.ty -> string = function
  | TV128 -> "v"
  | TI32 -> "i"
  | TI64 -> "l"
  | TF32 -> "f"
  | TF64 -> "d"

let v128_call_errors name =
  match Wax_wasm.Simd.classify name with
  | Some { operands = _receiver :: rest; result; imm; _ } ->
      let imms =
        match imm with
        | Wax_wasm.Simd.No_imm -> []
        | Lane _ -> [ "0" ]
        | Shuffle -> List.init 16 (fun _ -> "0")
      in
      let args = String.concat ", " (imms @ List.map ty_var rest) in
      let call = Printf.sprintf "v.%s(%s)" name args in
      let body =
        match result with
        | Some t -> Printf.sprintf "let r: %s = %s; _ = r;" (ty_name t) call
        | None -> call ^ ";"
      in
      error_count
        (Printf.sprintf "fn t(v: v128, i: i32, l: i64, f: f32, d: f64) { %s }\n"
           body)
  | _ -> -1

let () =
  List.iter (check "i32") Typing.integer_methods;
  List.iter (check "i64") Typing.integer_methods;
  List.iter (check "f32") Typing.float_methods;
  List.iter (check "f64") Typing.float_methods;
  let src =
    "type arr = [i32];\nfn t(x: &arr) { let r: i32 = x.length(); _ = r; }\n"
  in
  Printf.printf "arr .length      %s\n"
    (match error_count src with 0 -> "ok" | _ -> "FAIL");
  let v128 = Typing.simd_v128_methods () in
  Printf.printf "\nv128: %d methods offered\n" (List.length v128);
  let failures =
    List.filter
      (fun (c : Typing.member_candidate) -> v128_call_errors c.member_name <> 0)
      v128
  in
  (match failures with
  | [] -> Printf.printf "all type-check\n"
  | fs ->
      List.iter
        (fun (c : Typing.member_candidate) ->
          Printf.printf "  FAIL %s\n" c.member_name)
        fs);
  Printf.printf "\nsample signatures:\n";
  List.iter
    (fun name ->
      match
        List.find_opt
          (fun (c : Typing.member_candidate) -> c.member_name = name)
          v128
      with
      | Some c -> Printf.printf "  %-22s %s\n" c.member_name c.member_detail
      | None -> Printf.printf "  %-22s (not offered)\n" name)
    [
      "neg_i32x4";
      "add_i32x4";
      "shl_i32x4";
      "eq_i32x4";
      "any_true_v128";
      "bitmask_i8x16";
      "extract_lane_s_i8x16";
      "replace_lane_i32x4";
      "shuffle_i8x16";
      "splat_i32x4" (* a scalar-receiver method: must NOT be offered here *);
    ];
  (* The intrinsic-namespace free functions offered after [ns::]. Each offered
     member is type-checked with a valid call (built to the member's shape), so
     [namespace_members] cannot offer a name [type_path_intrinsic_call] rejects;
     an offered member with no known call shape prints UNCHECKED so it is
     noticed. *)
  let ns_call ns (c : Typing.member_candidate) =
    let name = c.member_name in
    match ns with
    | "atomic" -> Some "fn t() { atomic::fence(); }\n"
    | "i64" ->
        let argc = match name with "add128" | "sub128" -> 4 | _ -> 2 in
        let args = String.concat ", " (List.init argc (fun _ -> "a")) in
        Some
          (Printf.sprintf "fn t(a: i64) -> (i64, i64) { i64::%s(%s); }\n" name
             args)
    | "v128" when name = "bitselect" ->
        Some "fn t(v: v128) -> v128 { v128::bitselect(v, v, v); }\n"
    | "v128" -> (
        match
          Wax_wasm.Simd.const_shape_of_name (Wax_wasm.Simd.free_full name)
        with
        | Some sh ->
            let lane = if Wax_wasm.Simd.const_is_float sh then "0.0" else "0" in
            let args =
              String.concat ", "
                (List.init (Wax_wasm.Simd.const_arity sh) (fun _ -> lane))
            in
            Some (Printf.sprintf "fn t() -> v128 { v128::%s(%s); }\n" name args)
        | None -> None)
    | _ -> None
  in
  (* A numeric receiver can still be a flexible literal type (an unnarrowed
     literal expression, e.g. [(3)] or [(3 | 0)]) rather than a concrete valtype.
     For each, type-check every offered method on a receiver of that type: the
     counts show the family mapping ([number]/[large number] take both families,
     [int] integer only, [float] float only), and "all type-check" confirms none
     is offered that the typer would reject. *)
  let binary = [ "rotl"; "rotr"; "min"; "max"; "copysign" ] in
  Printf.printf "\nflexible receivers:\n";
  List.iter
    (fun (label, recv_expr, arg, ty) ->
      match Typing.numeric_receiver_candidates ty with
      | None -> Printf.printf "  %-14s (none)\n" label
      | Some cands ->
          let fails =
            List.filter_map
              (fun (c : Typing.member_candidate) ->
                let a = if List.mem c.member_name binary then arg else "" in
                if
                  error_count
                    (Printf.sprintf "fn t() { _ = (%s).%s(%s); }\n" recv_expr
                       c.member_name a)
                  = 0
                then None
                else Some c.member_name)
              cands
          in
          (* A [Same] method (head) and a [Reinterpret] one show the receiver
             renders by family (e.g. [-> int], not [-> i32]) and the flip. *)
          let sig_of name =
            match
              List.find_opt
                (fun (c : Typing.member_candidate) -> c.member_name = name)
                cands
            with
            | Some c -> Printf.sprintf "%s: %s" name c.member_detail
            | None -> ""
          in
          let samples =
            List.filter
              (fun s -> s <> "")
              [
                sig_of (List.hd cands).member_name;
                sig_of "from_bits";
                sig_of "to_bits";
              ]
          in
          Printf.printf "  %-14s %2d offered, %s  [%s]\n" (label ^ ":")
            (List.length cands)
            (match fails with
            | [] -> "all type-check"
            | fs -> "FAIL: " ^ String.concat " " fs)
            (String.concat ", " samples))
    [
      ("number", "3", "2", Infer.Number);
      ("int", "3 | 0", "2", Infer.Int);
      ("large number", "5000000000", "2", Infer.LargeInt);
      ("float", "3.0", "2.0", Infer.Float);
    ];
  Printf.printf "\nnamespace members:\n";
  List.iter
    (fun ns ->
      let members = Typing.namespace_members ns in
      Printf.printf "  %s:: (%d)\n" ns (List.length members);
      List.iter
        (fun (c : Typing.member_candidate) ->
          let status =
            match ns_call ns c with
            | None -> "UNCHECKED"
            | Some src -> (
                match error_count src with
                | 0 -> "ok"
                | -1 -> "PARSE ERROR"
                | n -> Printf.sprintf "FAIL(%d)" n)
          in
          Printf.printf "    %-12s %-38s %s\n" c.member_name c.member_detail
            status)
        members)
    [ "v128"; "i64"; "atomic" ]

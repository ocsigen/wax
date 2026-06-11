module StringMap = Map.Make (String)

type t = { mutable existing_names : int StringMap.t }

let build l = StringMap.of_list (List.map (fun s -> (s, 1)) l)

(* SIMD intrinsic names are reserved so a generated entity name never shadows
   an intrinsic (which would silently mis-lower the corresponding instruction). *)
let reserved =
  build
    (Wasm.Simd.all_names
    @ [
        "as";
        "become";
        "br";
        "br_if";
        "br_on_cast";
        "br_on_cast_fail";
        "br_on_non_null";
        "br_on_null";
        "br_table";
        "catch";
        "const";
        "cont_bind";
        "cont_new";
        "dispatch";
        "do";
        "else";
        "fn";
        "inf";
        "if";
        "is";
        "let";
        "loop";
        "mut";
        "nan";
        "nop";
        "null";
        "open";
        "rec";
        "resume";
        "resume_throw";
        "resume_throw_ref";
        "return";
        "suspend";
        "switch";
        "tag";
        "throw";
        "throw_ref";
        "try";
        "type";
        "unreachable";
      ])

let reserved_heap_types =
  StringMap.union
    (fun _ _ -> assert false)
    reserved
    (build
       [
         "any";
         "array";
         "cont";
         "eq";
         "exn";
         "extern";
         "func";
         "i31";
         "nocont";
         "noexn";
         "noextern";
         "nofunc";
         "none";
         "struct";
       ])

let rec add_indexed ns x i =
  let y = Printf.sprintf "%s_%d" x i in
  if StringMap.mem y ns.existing_names then add_indexed ns x (i + 1)
  else (
    ns.existing_names <-
      ns.existing_names |> StringMap.add y 1 |> StringMap.add x i;
    y)

let add ns x =
  match StringMap.find_opt x ns.existing_names with
  | Some i -> add_indexed ns x (i + 1)
  | None ->
      ns.existing_names <- ns.existing_names |> StringMap.add x 1;
      x

let reserve ns x =
  if not (StringMap.mem x ns.existing_names) then
    ns.existing_names <- ns.existing_names |> StringMap.add x 1

let dup { existing_names } = { existing_names }

let make ?(kind = `Regular) () =
  {
    existing_names =
      (match kind with
      | `Regular -> reserved
      | `Label -> StringMap.empty
      | `Type -> reserved_heap_types);
  }

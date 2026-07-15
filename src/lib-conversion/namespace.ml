module StringMap = Map.Make (String)

type t = {
  mutable existing_names : int StringMap.t;
  reserved : int StringMap.t;
      (* The reserved words seeded at creation, kept separately so [add'] can
         tell a reserved-word collision from a collision with another name. *)
  mutable locations : Wax_utils.Ast.location StringMap.t;
      (* The source location each name was claimed from (when one was given), so
         [add'] can point a conflict at the previous occurrence. *)
}

let build l = List.fold_left (fun m s -> StringMap.add s 1 m) StringMap.empty l

(* Only the Wax keywords are reserved. Intrinsics need no reservation: the
   free-function ones are spelled as [v128::]/[i64::] paths and every other is a
   receiver-based method, so no bare entity name can ever shadow one. *)
(* The Wax bare-word keywords. The single source shared by [from_wasm]'s
   reserved-name set (below), the editor's keyword completion
   ([Wax_format_js]), and the keyword-consistency test, which checks this list
   against the lexer (the source of truth) and the other keyword lists. *)
let reserved_words =
  [
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
    "cont";
    "cont_bind";
    "cont_new";
    "data";
    "dispatch";
    "do";
    "elem";
    "else";
    "fn";
    "describes";
    "descriptor";
    "inf";
    "if";
    "import";
    "is";
    "let";
    "loop";
    "match";
    "memory";
    "mut";
    "nan";
    "nop";
    "null";
    "pagesize";
    "open";
    "rec";
    "resume";
    "resume_throw";
    "resume_throw_ref";
    "return";
    "shared";
    "suspend";
    "switch";
    "table";
    "tag";
    "throw";
    "throw_ref";
    "try";
    "type";
    "unreachable";
    "while";
  ]

let reserved = build reserved_words

let reserved_heap_types =
  StringMap.union
    (fun _ _ -> assert false)
    reserved
    (build
       [
         "any";
         "array";
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

type outcome =
  | Available
  | Renamed of { reserved : bool; previous : Wax_utils.Ast.location option }

let record_location ns ?loc name =
  match loc with
  | Some loc -> ns.locations <- ns.locations |> StringMap.add name loc
  | None -> ()

let add' ?loc ns x =
  match StringMap.find_opt x ns.existing_names with
  | Some i ->
      let y = add_indexed ns x (i + 1) in
      let previous = StringMap.find_opt x ns.locations in
      record_location ns ?loc y;
      (y, Renamed { reserved = StringMap.mem x ns.reserved; previous })
  | None ->
      ns.existing_names <- ns.existing_names |> StringMap.add x 1;
      record_location ns ?loc x;
      (x, Available)

let add ns x = fst (add' ns x)
let is_reserved ns x = StringMap.mem x ns.reserved

let reserve ns x =
  if not (StringMap.mem x ns.existing_names) then
    ns.existing_names <- ns.existing_names |> StringMap.add x 1

let dup { existing_names; reserved; locations } =
  { existing_names; reserved; locations }

let make ?(kind = `Regular) () =
  let reserved =
    match kind with
    | `Regular -> reserved
    | `Label -> StringMap.empty
    | `Type -> reserved_heap_types
  in
  { existing_names = reserved; reserved; locations = StringMap.empty }

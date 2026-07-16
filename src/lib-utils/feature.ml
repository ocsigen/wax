type t = Custom_descriptors | Compact_import_section

let all = [ Custom_descriptors; Compact_import_section ]

let name = function
  | Custom_descriptors -> "custom-descriptors"
  | Compact_import_section -> "compact-import-section"

let description = function
  | Custom_descriptors ->
      "Custom Descriptors proposal: exact reference types, descriptor structs, \
       and the associated instructions."
  | Compact_import_section ->
      "Compact Import Section proposal: group a module's imports under one \
       module name in the binary import section."

(* Off by default: an experimental proposal, enabled with [--enable]. *)
let enabled_by_default = function
  | Custom_descriptors -> false
  | Compact_import_section -> false

let of_name s = List.find_opt (fun t -> String.equal (name t) s) all

type set = {
  mutable enabled : t -> bool;
  explicitly_off : t -> bool;
  mutable used : t list;
}

(* Apply [specs] over the built-in defaults; later entries win. *)
let predicate specs =
  List.fold_left
    (fun pred (t, b) x -> if x = t then b else pred x)
    enabled_by_default specs

(* Whether [specs]' final word on [x] is an explicit off — as opposed to [x]
   merely being off by default. *)
let explicitly_off specs =
  let final t =
    List.fold_left (fun acc (x, b) -> if x = t then Some b else acc) None specs
  in
  fun x -> final x = Some false

let configure specs =
  {
    enabled = predicate specs;
    explicitly_off = explicitly_off specs;
    used = [];
  }

(* The process-wide default configuration (set once from the command line, like
   the warning policy), read by [default]. *)
let global_specs = ref []
let set_config specs = global_specs := specs
let default () = configure !global_specs
let is_enabled set t = set.enabled t
let explicitly_disabled set t = set.explicitly_off t

let declare set t =
  let enabled = set.enabled in
  set.enabled <- (fun x -> x = t || enabled x)

let mark_used set t =
  if not (List.mem t set.used) then set.used <- t :: set.used

(* Return in [all] order rather than insertion order, for stable output. *)
let used set = List.filter (fun t -> List.mem t set.used) all

let parse_spec s =
  let nm, value =
    match String.index_opt s '=' with
    | None -> (s, "on")
    | Some i ->
        (String.sub s 0 i, String.sub s (i + 1) (String.length s - i - 1))
  in
  match (of_name nm, value) with
  | None, _ ->
      Stdlib.Error
        (Printf.sprintf "Unknown feature '%s'. Known features: %s." nm
           (String.concat ", " (List.map name all)))
  | Some t, ("on" | "true" | "yes") -> Ok (t, true)
  | Some t, ("off" | "false" | "no") -> Ok (t, false)
  | Some _, _ ->
      Stdlib.Error
        (Printf.sprintf
           "Malformed feature spec '%s'; expected NAME, NAME=on, or NAME=off." s)

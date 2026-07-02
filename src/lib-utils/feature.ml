type t = Custom_descriptors

let all = [ Custom_descriptors ]
let name = function Custom_descriptors -> "custom-descriptors"

let description = function
  | Custom_descriptors ->
      "Custom Descriptors proposal: exact reference types, descriptor structs, \
       and the associated instructions."

(* Off by default: an experimental proposal, enabled with [--enable]. *)
let enabled_by_default = function Custom_descriptors -> false
let of_name s = List.find_opt (fun t -> String.equal (name t) s) all

type set = { enabled : t -> bool; mutable used : t list }

(* Apply [specs] over the built-in defaults; later entries win. *)
let predicate specs =
  List.fold_left
    (fun pred (t, b) x -> if x = t then b else pred x)
    enabled_by_default specs

let configure specs = { enabled = predicate specs; used = [] }

(* The process-wide default configuration (set once from the command line, like
   the warning policy), read by [default]. *)
let global_config = ref enabled_by_default
let set_config specs = global_config := predicate specs
let default () = { enabled = !global_config; used = [] }
let is_enabled set t = set.enabled t

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

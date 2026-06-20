type t =
  | Unused_local
  | Truncated_coverage
  | Naming_conflict
  | Reserved_word_rename
  | Generated_name

let all =
  [
    Unused_local;
    Truncated_coverage;
    Naming_conflict;
    Reserved_word_rename;
    Generated_name;
  ]

let name = function
  | Unused_local -> "unused-local"
  | Truncated_coverage -> "truncated-coverage"
  | Naming_conflict -> "naming-conflict"
  | Reserved_word_rename -> "reserved-word-rename"
  | Generated_name -> "generated-name"

let description = function
  | Unused_local -> "A local that is declared but never read."
  | Truncated_coverage ->
      "Path-sensitive validation gave up after too many configurations."
  | Naming_conflict -> "A Wasm name collided with another and was renamed."
  | Reserved_word_rename -> "A Wasm name is a reserved word and was renamed."
  | Generated_name ->
      "An unnamed but used parameter was given a generated name."

(* Group name -> members. The special group "all" is handled separately by
   [set] so it need not be listed here. *)
let group_table =
  [
    ("unused", [ Unused_local ]);
    ("naming", [ Naming_conflict; Reserved_word_rename; Generated_name ]);
  ]

let groups = List.map fst group_table

type level = Hidden | Displayed | Error

(* A policy is just the level assigned to each warning; [set] returns an updated
   function, so later assignments naturally override earlier ones. *)
type policy = t -> level

(* The From_wasm renaming warnings are noisy round-trip notices, so they are
   hidden unless explicitly enabled with [-W]; everything else is shown. *)
let default_policy = function
  | Naming_conflict | Reserved_word_rename | Generated_name -> Hidden
  | Unused_local | Truncated_coverage -> Displayed

let resolve (policy : policy) w = policy w

(* The set of warnings a name refers to: the special group "all", a single
   warning name, or a named group. *)
let targets target =
  if String.equal target "all" then Some all
  else
    match List.find_opt (fun w -> String.equal target (name w)) all with
    | Some w -> Some [ w ]
    | None -> List.assoc_opt target group_table

let set (policy : policy) target level =
  match targets target with
  | Some ws ->
      Ok
        (fun w -> if List.exists (fun w' -> w = w') ws then level else policy w)
  | None ->
      Stdlib.Error
        (Printf.sprintf "Unknown warning or group '%s'. Known names: %s." target
           (String.concat ", " (List.map name all @ groups @ [ "all" ])))

let level_of_string = function
  | "hidden" -> Some Hidden
  | "warning" -> Some Displayed
  | "error" -> Some Error
  | _ -> None

let parse_spec s =
  match String.index_opt s '=' with
  | None ->
      Stdlib.Error
        (Printf.sprintf
           "Malformed warning spec '%s'; expected NAME=LEVEL (LEVEL is hidden, \
            warning, or error)."
           s)
  | Some i -> (
      let name = String.sub s 0 i in
      let level = String.sub s (i + 1) (String.length s - i - 1) in
      match level_of_string level with
      | Some level -> Ok (name, level)
      | None ->
          Stdlib.Error
            (Printf.sprintf
               "Unknown warning level '%s'; expected hidden, warning, or error."
               level))

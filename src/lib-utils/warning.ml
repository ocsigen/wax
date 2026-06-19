type t = Unused_local | Truncated_coverage

let all = [ Unused_local; Truncated_coverage ]

let name = function
  | Unused_local -> "unused-local"
  | Truncated_coverage -> "truncated-coverage"

let description = function
  | Unused_local -> "A local that is declared but never read."
  | Truncated_coverage ->
      "Path-sensitive validation gave up after too many configurations."

(* Group name -> members. The special group "all" is handled separately by
   [set] so it need not be listed here. *)
let group_table = [ ("unused", [ Unused_local ]) ]
let groups = List.map fst group_table

type level = Hidden | Displayed | Error

(* A policy is just the level assigned to each warning; [set] returns an updated
   function, so later assignments naturally override earlier ones. *)
type policy = t -> level

let default_policy _ = Displayed
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

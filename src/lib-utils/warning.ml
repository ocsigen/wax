type t =
  | Unused_local
  | Unused_field
  | Unused_import
  | Unused_label
  | Shift_overflow
  | Constant_trap
  | Tautological_comparison
  | Constant_condition
  | Unused_result
  | Dead_code
  | Cast_always_fails
  | Eager_select
  | Redundant_operation
  | Truncated_coverage
  | Naming_conflict
  | Reserved_word_rename
  | Generated_name

let all =
  [
    Unused_local;
    Unused_field;
    Unused_import;
    Unused_label;
    Shift_overflow;
    Constant_trap;
    Tautological_comparison;
    Constant_condition;
    Unused_result;
    Dead_code;
    Cast_always_fails;
    Eager_select;
    Redundant_operation;
    Truncated_coverage;
    Naming_conflict;
    Reserved_word_rename;
    Generated_name;
  ]

let name = function
  | Unused_local -> "unused-local"
  | Unused_field -> "unused-field"
  | Unused_import -> "unused-import"
  | Unused_label -> "unused-label"
  | Shift_overflow -> "shift-count-overflow"
  | Constant_trap -> "constant-trap"
  | Tautological_comparison -> "tautological-comparison"
  | Constant_condition -> "constant-condition"
  | Unused_result -> "unused-result"
  | Dead_code -> "dead-code"
  | Cast_always_fails -> "cast-always-fails"
  | Eager_select -> "eager-select"
  | Redundant_operation -> "redundant-operation"
  | Truncated_coverage -> "truncated-coverage"
  | Naming_conflict -> "naming-conflict"
  | Reserved_word_rename -> "reserved-word-rename"
  | Generated_name -> "generated-name"

let description = function
  | Unused_local -> "A local that is declared but never read."
  | Unused_field -> "A module field that is defined but never used."
  | Unused_import -> "An imported function or global that is never used."
  | Unused_label -> "A block label that is declared but never branched to."
  | Shift_overflow ->
      "A constant shift count is at least the operand's bit width (Wasm masks \
       it)."
  | Constant_trap ->
      "An operation always traps on a constant operand (integer division by \
       zero, or an out-of-range trapping conversion)."
  | Tautological_comparison ->
      "A comparison whose result is constant (an unsigned comparison against \
       zero, or identical operands)."
  | Constant_condition ->
      "A branch, loop, or select condition that is a constant."
  | Unused_result ->
      "The result of a side-effect-free expression is computed and then \
       discarded."
  | Dead_code ->
      "A statement is unreachable: it follows an unconditional branch, return, \
       or unreachable."
  | Cast_always_fails ->
      "A reference cast or test whose operand can never have the target type, \
       so it always traps (or is always false)."
  | Eager_select ->
      "A trapping or effectful operation in a branch of a '?:' (which compiles \
       to a 'select', evaluating both branches unconditionally)."
  | Redundant_operation ->
      "An operation with no effect on its result (an arithmetic identity, an \
       absorbing operand, identical operands, a self-assignment, or a \
       superfluous cast)."
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
    ("unused", [ Unused_local; Unused_field; Unused_import; Unused_label ]);
    ( "correctness",
      [
        Shift_overflow;
        Constant_trap;
        Tautological_comparison;
        Constant_condition;
        Unused_result;
        Dead_code;
        Cast_always_fails;
        Eager_select;
        Unused_field;
        Unused_import;
        Unused_label;
      ] );
    ("redundant", [ Redundant_operation ]);
    ("naming", [ Naming_conflict; Reserved_word_rename; Generated_name ]);
  ]

let groups = List.map fst group_table

type level = Hidden | Displayed | Error

(* A policy is just the level assigned to each warning; [set] returns an updated
   function, so later assignments naturally override earlier ones. *)
type policy = t -> level

(* The From_wasm renaming warnings are noisy round-trip notices, and the
   redundant-operation lints are optimisation hints that are common in generated
   code, so all of these are hidden unless explicitly enabled with [-W];
   everything else is shown. *)
let default_policy = function
  | Naming_conflict | Reserved_word_rename | Generated_name
  | Redundant_operation ->
      Hidden
  | Unused_local | Unused_field | Unused_import | Unused_label | Shift_overflow
  | Constant_trap | Tautological_comparison | Constant_condition | Unused_result
  | Dead_code | Cast_always_fails | Eager_select | Truncated_coverage ->
      Displayed

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

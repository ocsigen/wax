(* The WAT editor consumers ([Wat_editor.symbols_string] /
   [Wat_editor.check_string]) run the WAT parser under panic-mode recovery, so a broken
   buffer still yields an outline and validation errors from the intact regions.
   These cases pin that: the outline keeps the well-formed fields around a syntax
   error, and [check] reports the syntax errors while suppressing the warnings
   and stack-shape cascades a dropped / auto-closed construct would trigger — yet
   still surfaces a genuine type error in an untouched function. *)

let sev = function
  | Wax_utils.Diagnostic.Error -> "error"
  | Wax_utils.Diagnostic.Warning -> "warning"
  | Wax_utils.Diagnostic.Suggestion -> "suggestion"

let report name src =
  Printf.printf "=== %s ===\n" name;
  Printf.printf "outline:";
  List.iter
    (fun (s : Editor_common.sym) -> Printf.printf " %s/%s" s.s_kind s.s_name)
    (Wat_editor.symbols_string src);
  print_newline ();
  Printf.printf "diagnostics:\n";
  List.iter
    (fun (d : Editor_common.diag) ->
      Printf.printf "  [%s] %s\n" (sev d.severity) d.message)
    (Wat_editor.check_string src);
  print_newline ()

let () =
  (* Outline survives an unrepairable folded group: group-drop keeps the first
     func as (func) and the whole second field. *)
  report "outline survives a broken field"
    "(module (func $a (v128.const)) (func $b (nop)) (global $g i32 (i32.const \
     0)))\n";
  (* check: the syntax error shows; the unused-function warnings and the
     stack-shape cascade from the auto-closed body are suppressed. *)
  report "check suppresses cascades at EOF" "(module (func (i32.const 1)\n";
  (* check: a real type error ((i64) fed to i32.add) in an intact function still
     surfaces even though a sibling has a syntax error. *)
  report "check keeps a real error past a syntax error"
    "(module (func (v128.const)) (func (result i32) (i32.add (i64.const 1))))\n";
  (* No syntax error: recovery mode is off, so warnings and stack diagnostics are
     reported as usual. *)
  report "clean module reports normally"
    "(module (func (result i32) (i32.add (i64.const 1))))\n"

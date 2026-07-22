(* Exercises WAT panic-mode recovery (Wax_conversion.Driver.wat_parse_recover):
   each broken WAT module is recovered to a best-effort AST, re-emitted here as
   WAT so the recovered structure is visible. *)
let report name source =
  Printf.printf "=== %s ===\n" name;
  let ast, errors, ctx =
    Wax_conversion.Driver.wat_parse_recover ~filename:"t.wat" source
  in
  Printf.printf "errors: %d\n" (List.length errors);
  (match ast with
  | None -> print_string "none\n"
  | Some m ->
      let used = Wax_utils.Trivia.create_locations () in
      Wax_utils.Printer.run_discard (fun p ->
          Wax_wasm.Output.module_ p
            ~trivia:(Wax_utils.Trivia.empty ())
            ~collect:used m);
      let trivia, tail = Wax_utils.Trivia.associate ~only:used ctx in
      print_string
        (Wax_utils.Printer.run_string ~width:80 (fun p ->
             Wax_wasm.Output.module_ p ~trivia ~tail m)));
  print_newline ()

let () =
  (* Missing operand: a zero-width placeholder is inserted so the instruction
     stays in the body and the sibling function is not lost. The placeholder is
     a named index [$_] where an index is expected (so the diagnostic reads
     "Missing index"), a [0] at a numeric-literal position like a const. *)
  report "missing const operand keeps both funcs"
    "(module (func (i32.const)) (func (nop)))\n";
  report "missing branch index" "(module (func (br)))\n";
  (* Balanced junk inside a body: skipped, siblings preserved. *)
  report "junk instruction, later field survives"
    "(module (func @@@ zzz) (func (nop)))\n";
  (* Unclosed construct at end of input: auto-closed with ')'. *)
  report "unclosed func body at EOF" "(module (func (i32.const 1)\n";
  (* Missing closer mid-module: a field keyword ("func"/"global") is offered
     where an instruction was expected. The barrier closes the enclosing field
     and restarts at the new one, so paren-depth counting does not swallow the
     sibling. *)
  report "missing ')' between two funcs"
    "(module (func (i32.const 1) (func (nop)))\n";
  report "missing ')' before a global"
    "(module (func (nop) (global i32 (i32.const 0)))\n";
  (* The placeholder generalizes past plain integers: a heap type may be a type
     index (which accepts a named index), so (ref.null) is repaired to
     (ref.null $_). *)
  report "missing heap type is an index placeholder"
    "(module (func (ref.null)) (func (nop)))\n";
  (* A field keyword typed as an instruction ("memory" with no "(") must not be
     mistaken for a new field: the barrier fires only when the keyword really is
     written "( keyword", so this degrades to two functions, not a spurious
     memory field. *)
  report "bare field keyword in a body is not a barrier"
    "(module (func (nop) memory) (func (nop)))\n";
  (* Group-drop: a folded instruction whose operand needs more than one token
     ((v128.const) wants a shape and 16 lanes) cannot be repaired by inserting a
     placeholder. The broken group is dropped whole — its opener popped off the
     stack, its ")" discarded — so the enclosing "func" keeps its own closer and
     survives as "(func)", and the sibling is preserved. *)
  report "unrepairable operand drops the group, keeps the func"
    "(module (func (v128.const)) (func (nop)))\n";
  (* Group-drop when the broken group is itself the field: (import "m") lacks its
     descriptor. Dropping the group climbs all the way to the module body, so the
     following "(func …)" is not mistakenly grafted on as the import descriptor. *)
  report "unrepairable field drops without absorbing its sibling"
    "(module (import \"m\") (func (nop)))\n";
  (* Group-drop must not fire on a stray ")" after an already-complete module:
     nothing is open there (source depth 0), so it is simply dropped and the
     module's field survives, rather than popping into the finished module. *)
  report "stray ) after a complete module keeps the field"
    "(module (func (nop))) )\n";
  (* A stray ")" between fields closes the module early; the trailing field is
     lost but the fields already parsed are kept (recovery never pops a reduced
     construct off the stack, which would discard its value). *)
  report "stray ) between fields keeps the earlier fields"
    "(module (func $a (nop)) (func $b (nop)) (func $c (nop)) ) (func $d (nop)))\n";
  (* The barrier is honoured only at the enclosing level: a "(func" nested in a
     "(type … (func))" functype is content, not a new field, so an earlier error
     does not make the healthy type vanish. *)
  report "nested (func in a functype is not a barrier"
    "(module (import \"m\") (type $t (func)) (func (nop)))\n";
  (* A missing closer before a fused field opener ("(type"/"(import", lexed as one
     token) is recovered: the fused opener is a single-token barrier, so the open
     "func" is closed and the field starts fresh. *)
  report "missing closer before a fused (type field"
    "(module (func (i32.const 1) (type $t (func)))\n";
  report "missing closer before a fused (import field"
    "(module (func (i32.const 1) (import \"m\" \"n\" (func $f)))\n";
  (* The barrier reads the previously-offered token, not the raw source, so a
     comment between "(" and the field keyword does not defeat it. *)
  report "comment between ( and the keyword still triggers the barrier"
    "(module (func (i32.const 1) ( ;; c\n func (nop)))\n"

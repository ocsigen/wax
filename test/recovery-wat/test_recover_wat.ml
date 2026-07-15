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
      let used = Hashtbl.create 64 in
      let null = Format.make_formatter (fun _ _ _ -> ()) (fun () -> ()) in
      Wax_utils.Printer.run null (fun p ->
          Wax_wasm.Output.module_ p ~trivia:(Hashtbl.create 0) ~collect:used m);
      let trivia, tail = Wax_utils.Trivia.associate ~only:used ctx in
      let buf = Buffer.create 128 in
      let f = Format.formatter_of_buffer buf in
      Wax_utils.Printer.run ~width:80 f (fun p ->
          Wax_wasm.Output.module_ p ~trivia ~tail m);
      Format.pp_print_flush f ();
      print_string (Buffer.contents buf));
  print_newline ()

let () =
  (* Missing operand: a zero-width [0] is inserted so the instruction stays in
     the body and the sibling function is not lost. *)
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
  (* The "0" placeholder generalizes past plain integers: a heap type may be a
     type index, so (ref.null) is repaired to (ref.null 0). *)
  report "missing heap type is a zero index"
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
    "(module (import \"m\") (func (nop)))\n"

(* Exercises the WAT editor features ([Wat_editor.*]) that bring
   Wasm-text buffers to parity with Wax in the LSP server and VS Code extension.
   Each section drives one feature against a small module and prints a compact
   summary checked against the golden output. *)

let src =
  "(module\n\
  \  (func $add (param $a i32) (param $b i32) (result i32)\n\
  \    (local $sum i32)\n\
  \    (local.set $sum (i32.add (local.get $a) (local.get $b)))\n\
  \    (block $done\n\
  \      (br_if $done (local.get $sum))\n\
  \    )\n\
  \    (local.get $sum)\n\
  \  )\n\
  \  (func $main (result i32)\n\
  \    (call $add (i32.const 1) (i32.const 2))\n\
  \  )\n\
   )\n"

let () =
  Printf.printf "=== folding ===\n";
  List.iter
    (fun (s, e, k) -> Printf.printf "  %d-%d %s\n" s e k)
    (List.sort compare (Wat_editor.folding_string src));
  print_newline ();

  (* Selection-range at the cursor inside [local.get $a] on line 4 (0-based line
     3). The chain should grow from that identifier out to the whole module. *)
  Printf.printf "=== selection-range (in `local.get $a`, line 4) ===\n";
  List.iter
    (fun (sl, sc, el, ec) -> Printf.printf "  (%d,%d)-(%d,%d)\n" sl sc el ec)
    (Wat_editor.selection_range_string src 3 30);
  print_newline ();

  (* Hover: the type each instruction leaves on the stack. Probe a few cursors.
     Line/char are 0-based. *)
  Printf.printf "=== hover ===\n";
  let hover name line ch =
    match Wat_editor.hover_string src line ch with
    | Some h -> Printf.printf "  %s -> %s\n" name h.Editor_common.h_type
    | None -> Printf.printf "  %s -> (none)\n" name
  in
  hover "i32.add (line 4)" 3 21;
  hover "local.get $a (line 4)" 3 30;
  hover "i32.const 1 (line 11)" 10 16;
  hover "call $add (line 11)" 10 5;
  (* Whole folded span: the gap between the operator and its operands (here the
     space after `i32.add`) shows the folded expression's result. *)
  hover "gap after i32.add (line 4)" 3 28;
  (* Void instructions produce nothing: hover shows no type rather than the
     enclosing block's. *)
  hover "local.set keyword (void, line 4)" 3 6;
  hover "br_if keyword (void, line 6)" 5 8;
  print_newline ();

  let show_loc (loc : Wax_utils.Ast.location) =
    Printf.sprintf "(%d,%d)" loc.loc_start.pos_lnum
      (loc.loc_start.pos_cnum - loc.loc_start.pos_bol)
  in
  let show_rename outcome =
    match outcome with
    | Editor_common.Rename_edits edits ->
        List.iter
          (fun (loc, repl) -> Printf.printf "  %s := %s\n" (show_loc loc) repl)
          edits
    | Editor_common.Rename_conflict message ->
        Printf.printf "  conflict: %s\n" message
  in

  (* Definition / references / rename, driven from the `call $add` use on line
     11 (0-based 10) — should point back to the `$add` definition on line 2. *)
  Printf.printf "=== definition (on `$add` use, line 11) ===\n";
  List.iter
    (fun loc -> Printf.printf "  %s\n" (show_loc loc))
    (Wat_editor.definition_string src 10 11);
  Printf.printf "=== references ($add) ===\n";
  List.iter
    (fun loc -> Printf.printf "  %s\n" (show_loc loc))
    (Wat_editor.references_string src 10 11);
  Printf.printf "=== rename $add -> $sum2 ===\n";
  show_rename (Wat_editor.rename_string src 10 11 "sum2");
  Printf.printf "=== references (local $sum, line 3) ===\n";
  List.iter
    (fun loc -> Printf.printf "  %s\n" (show_loc loc))
    (Wat_editor.references_string src 2 12);
  Printf.printf "=== references (label $done, line 5) ===\n";
  List.iter
    (fun loc -> Printf.printf "  %s\n" (show_loc loc))
    (Wat_editor.references_string src 4 12);
  print_newline ();

  (* A struct type, a struct-field access, a symbolic call and a numeric call to
     the same function ($mk is function index 0). *)
  let src2 =
    "(module\n\
    \  (type $point (struct (field $x i32) (field $y i32)))\n\
    \  (func $mk (result (ref $point))\n\
    \    (struct.new $point (i32.const 1) (i32.const 2)))\n\
    \  (func (result i32)\n\
    \    (struct.get $point $x (call $mk)))\n\
    \  (func (call 0)))\n"
  in
  (* Locate the [nth] (0-based) occurrence of [sub] in [src2], as a 0-based
     (line, column), so probes need no hand-counted columns. *)
  let find sub nth =
    let rec loop from n =
      let i = Str.search_forward (Str.regexp_string sub) src2 from in
      if n = 0 then i else loop (i + 1) (n - 1)
    in
    let off = loop 0 nth in
    let line = ref 0 and bol = ref 0 in
    String.iteri
      (fun j c ->
        if j < off && c = '\n' then (
          incr line;
          bol := j + 1))
      src2;
    (!line, off - !bol)
  in
  let probe name f sub nth =
    let l, c = find sub nth in
    Printf.printf "%s:\n" name;
    List.iter (fun loc -> Printf.printf "  %s\n" (show_loc loc)) (f src2 l c)
  in
  (* $mk references: definition, the symbolic `call $mk`, and the numeric
     `call 0`. Rename rewrites only the symbolic ones. *)
  probe "=== references $mk (incl. numeric call 0) ==="
    Wat_editor.references_string "$mk" 0;
  let l, c = find "$mk" 0 in
  Printf.printf "=== rename $mk -> $make (numeric call 0 untouched) ===\n";
  show_rename (Wat_editor.rename_string src2 l c "make");
  Printf.printf
    "=== rename func $mk -> $point (type name; different space, ok) ===\n";
  show_rename (Wat_editor.rename_string src2 l c "point");
  Printf.printf "=== rename field $x -> $y (clashes with sibling field) ===\n";
  let lx, cx = find "$x" 0 in
  show_rename (Wat_editor.rename_string src2 lx cx "y");
  probe "=== references type $point ===" Wat_editor.references_string "$point" 0;
  probe "=== references field $x ===" Wat_editor.references_string "$x" 0;
  print_newline ();

  (* Type on identifiers: a call's callee shows its signature; local.set /
     global.set show the variable's type (even though the instruction itself
     leaves nothing on the stack, so its keyword shows nothing). *)
  let src3 =
    "(module\n\
    \  (global $g (mut i32) (i32.const 0))\n\
    \  (func $add (param i32) (param i32) (result i32) (local.get 0))\n\
    \  (func (local $x i32)\n\
    \    (local.set $x (call $add (i32.const 1) (i32.const 2)))\n\
    \    (global.set $g (local.get $x))))\n"
  in
  let find3 sub off =
    let i = Str.search_forward (Str.regexp_string sub) src3 0 in
    let line = ref 0 and bol = ref 0 in
    String.iteri
      (fun j c ->
        if j < i && c = '\n' then (
          incr line;
          bol := j + 1))
      src3;
    (!line, i - !bol + off)
  in
  let hov3 label sub off =
    let l, c = find3 sub off in
    match Wat_editor.hover_string src3 l c with
    | Some h -> Printf.printf "  %s -> %s\n" label h.Editor_common.h_type
    | None -> Printf.printf "  %s -> (none)\n" label
  in
  Printf.printf "=== type on identifiers ===\n";
  hov3 "$add (callee signature)" "call $add" 6;
  hov3 "call keyword (result)" "call $add" 1;
  hov3 "$x (local.set)" "local.set $x" 11;
  hov3 "local.set keyword (void)" "local.set $x" 1;
  hov3 "$g (global.set)" "global.set $g" 12;
  print_newline ();

  (* A branch-cast instruction has a single fall-through result: the validator's
     branch-target simulation ([push_results ~sink:false]) must not leak the
     branch parameters into the hover, and a block shows only its own result. *)
  let src4 =
    "(module\n\
    \  (type $t (struct))\n\
    \  (func (param anyref) (result anyref)\n\
    \    (block $l (result anyref)\n\
    \      (br_on_cast_fail $l anyref (ref $t) (local.get 0)))))\n"
  in
  let find4 sub off =
    let i = Str.search_forward (Str.regexp_string sub) src4 0 in
    let line = ref 0 and bol = ref 0 in
    String.iteri
      (fun j c ->
        if j < i && c = '\n' then (
          incr line;
          bol := j + 1))
      src4;
    (!line, i - !bol + off)
  in
  let hov4 label sub off =
    let l, c = find4 sub off in
    match Wat_editor.hover_string src4 l c with
    | Some h -> Printf.printf "  %s -> %s\n" label h.Editor_common.h_type
    | None -> Printf.printf "  %s -> (none)\n" label
  in
  Printf.printf "=== branch-cast result (single value) ===\n";
  hov4 "br_on_cast_fail keyword" "br_on_cast_fail" 2;
  hov4 "block keyword" "block $l" 1;
  print_newline ();

  (* Hover over a type identifier shows the type's source definition. $a and $b
     are structurally equal (so share a deduplicated global index), yet each
     reference must show its own source subtype — the mapping is keyed by the
     (injective) source reference, not the global index. *)
  let src5 =
    "(module\n\
    \  (type $a (struct (field i32)))\n\
    \  (type $b (struct (field i32)))\n\
    \  (func (param (ref $b)) (result (ref $a))\n\
    \    (struct.new $a (i32.const 1))))\n"
  in
  let find5 sub off =
    let i = Str.search_forward (Str.regexp_string sub) src5 0 in
    let line = ref 0 and bol = ref 0 in
    String.iteri
      (fun j c ->
        if j < i && c = '\n' then (
          incr line;
          bol := j + 1))
      src5;
    (!line, i - !bol + off)
  in
  let hov5 label sub off =
    let l, c = find5 sub off in
    match Wat_editor.hover_string src5 l c with
    | Some h -> Printf.printf "  %s -> %s\n" label h.Editor_common.h_type
    | None -> Printf.printf "  %s -> (none)\n" label
  in
  Printf.printf "=== subtype on type identifier (dedup-safe) ===\n";
  hov5 "$a in struct.new" "struct.new $a" 12;
  hov5 "$a in (ref $a)" "result (ref $a)" 13;
  hov5 "$b in (ref $b)" "param (ref $b)" 12;
  print_newline ();

  (* Semantic tokens classify each index identifier by the kind it resolves to;
     parameters and declared locals are distinct; a type reference inside a local
     declaration is a type. Labels have no token type. *)
  let src6 =
    "(module\n\
    \  (type $t (struct (field $f i32)))\n\
    \  (global $g i32 (i32.const 0))\n\
    \  (func $add (param $a i32) (result (ref $t))\n\
    \    (local $x i32)\n\
    \    (block $l (br $l))\n\
    \    (drop (global.get $g))\n\
    \    (drop (local.get $a))\n\
    \    (struct.new_default $t)))\n"
  in
  Printf.printf "=== semantic tokens ===\n";
  List.iter
    (fun (t : Editor_common.sem_token) ->
      Printf.printf "  (%d,%d)+%d %s\n" t.st_line t.st_char t.st_len t.st_type)
    (Wat_editor.semantic_tokens_string src6);
  print_newline ();

  (* Signature help inside a folded call: the callee's signature and the active
     parameter (which operand the cursor is in). *)
  let src7 =
    "(module\n\
    \  (func $add (param i32) (param i32) (result i32) (local.get 0))\n\
    \  (func (result i32)\n\
    \    (call $add (i32.const 1) (i32.const 2))))\n"
  in
  let find7 sub off =
    let i = Str.search_forward (Str.regexp_string sub) src7 0 in
    let line = ref 0 and bol = ref 0 in
    String.iteri
      (fun j c ->
        if j < i && c = '\n' then (
          incr line;
          bol := j + 1))
      src7;
    (!line, i - !bol + off)
  in
  let sig_help label sub off =
    let l, c = find7 sub off in
    match Wat_editor.signature_help_string src7 l c with
    | Some (lbl, ranges, active) ->
        Printf.printf "  %s -> %s | active=%d params=[%s]\n" label lbl active
          (String.concat ";"
             (List.map (fun (s, e) -> Printf.sprintf "%d-%d" s e) ranges))
    | None -> Printf.printf "  %s -> (none)\n" label
  in
  Printf.printf "=== signature help ===\n";
  sig_help "in first arg" "(i32.const 1)" 2;
  sig_help "in second arg" "(i32.const 2)" 2;
  print_newline ();

  (* Go-to-type-definition: from a value of a named reference type, or from a
     type identifier, to the type's definition. $t is defined on line 2. *)
  let src8 =
    "(module\n\
    \  (type $t (struct (field i32)))\n\
    \  (func (param $p (ref $t)) (result (ref $t))\n\
    \    (local $x (ref $t))\n\
    \    (local.set $x (local.get $p))\n\
    \    (local.get $x)))\n"
  in
  let find8 sub off =
    let i = Str.search_forward (Str.regexp_string sub) src8 0 in
    let line = ref 0 and bol = ref 0 in
    String.iteri
      (fun j c ->
        if j < i && c = '\n' then (
          incr line;
          bol := j + 1))
      src8;
    (!line, i - !bol + off)
  in
  let type_def label sub off =
    let l, c = find8 sub off in
    Printf.printf "  %s ->" label;
    (match Wat_editor.type_definition_string src8 l c with
    | [] -> Printf.printf " (none)"
    | ls ->
        List.iter
          (fun (loc : Wax_utils.Ast.location) ->
            Printf.printf " (%d,%d)" loc.loc_start.pos_lnum
              (loc.loc_start.pos_cnum - loc.loc_start.pos_bol))
          ls);
    print_newline ()
  in
  Printf.printf "=== type definition ($t defined at line 2) ===\n";
  type_def "on local.get $x (value of ref $t)" "local.get $x" 6;
  type_def "on local.get $p" "local.get $p" 6;
  print_newline ();

  (* Hover groups the recorded types by configuration: a call to a function
     whose signature differs across `(@if)` branches shows one alternative per
     line, while a single call to a multi-result function shows its results as
     one space-joined tuple on one line. *)
  let hover_multiline src sub off =
    let i = Str.search_forward (Str.regexp_string sub) src 0 in
    let line = ref 0 and bol = ref 0 in
    String.iteri
      (fun j c ->
        if j < i && c = '\n' then (
          incr line;
          bol := j + 1))
      src;
    match Wat_editor.hover_string src !line (i - !bol + off) with
    | Some h -> String.split_on_char '\n' h.Editor_common.h_type
    | None -> [ "(none)" ]
  in
  let config_varying =
    "(module\n\
    \  (@if $x\n\
    \    (@then (func $f (param i32) (result i32) (local.get 0)))\n\
    \    (@else (func $f (param i64) (result i64) (local.get 0))))\n\
    \  (func (result i32) (call $f (i32.const 1))))\n"
  in
  let multi_result =
    "(module\n\
    \  (func $pair (result i32 i64) (i32.const 1) (i64.const 2))\n\
    \  (func (result i32 i64) (call $pair)))\n"
  in
  Printf.printf "=== hover: config-varying signature (one line each) ===\n";
  List.iter (Printf.printf "  %s\n")
    (hover_multiline config_varying "call $f" 6);
  Printf.printf "=== hover: multi-result call (one tuple line) ===\n";
  List.iter (Printf.printf "  %s\n")
    (hover_multiline multi_result "call $pair" 1);
  print_newline ();

  (* A config-varying `$f` is defined in both the @then and @else branch. Hover
     shows both signatures; go-to-def, references and rename must reach both
     definitions, not just one. Locate the `$f` of the `call $f` use. *)
  let cv_l, cv_c =
    let i = Str.search_forward (Str.regexp_string "call $f") config_varying 0 in
    let line = ref 0 and bol = ref 0 in
    String.iteri
      (fun j c ->
        if j < i && c = '\n' then (
          incr line;
          bol := j + 1))
      config_varying;
    (!line, i - !bol + 5)
  in
  Printf.printf "=== definition (config-varying call $f) ===\n";
  List.iter
    (fun loc -> Printf.printf "  %s\n" (show_loc loc))
    (Wat_editor.definition_string config_varying cv_l cv_c);
  Printf.printf "=== references (config-varying $f) ===\n";
  List.iter
    (fun loc -> Printf.printf "  %s\n" (show_loc loc))
    (Wat_editor.references_string config_varying cv_l cv_c);
  Printf.printf "=== rename config-varying $f -> $g ===\n";
  show_rename (Wat_editor.rename_string config_varying cv_l cv_c "g");
  print_newline ();

  (* Completion: where an index operand is expected — the point a recovering
     parse repairs with a placeholder, or a partial [$id] — the in-scope names
     of that index space are offered, their kind fixed by the instruction. Each
     case is its own buffer with a single incomplete operand (the realistic
     mid-typing state; the cursor is at the end of [sub], the operand slot). *)
  let complete label src sub =
    let i = Str.search_forward (Str.regexp_string sub) src 0 in
    let line = ref 0 and bol = ref 0 in
    String.iteri
      (fun j c ->
        if j < i && c = '\n' then (
          incr line;
          bol := j + 1))
      src;
    let col = i - !bol + String.length sub in
    let items = Wat_editor.completion_string src !line col [] in
    Printf.printf "  %s -> [%s]\n" label
      (String.concat " "
         (List.map
            (fun (c : Editor_common.completion) ->
              Printf.sprintf "%s:%s" c.k_name c.k_kind)
            items))
  in
  let prelude =
    "(module\n\
    \  (type $t (struct (field i32)))\n\
    \  (global $g i32 (i32.const 0))\n\
    \  (func $helper (result i32) (i32.const 0))\n"
  in
  Printf.printf "=== completion (index kind from context) ===\n";
  complete "call (functions)"
    (prelude ^ "  (func (result i32) (call )))\n")
    "(call ";
  complete "global.get (globals)"
    (prelude ^ "  (func (result i32) (global.get )))\n")
    "(global.get ";
  complete "local.get (locals + params)"
    (prelude ^ "  (func (param $p i32) (local $x i32) (local.get )))\n")
    "(local.get ";
  complete "struct.new (types)"
    (prelude ^ "  (func (result (ref $t)) (struct.new )))\n")
    "(struct.new ";
  complete "br (labels)"
    (prelude ^ "  (func (block $lbl (loop $inner (br )))))\n")
    "(br ";
  complete "partial prefix $h (functions)"
    (prelude ^ "  (func (result i32) (call $h)))\n")
    "(call $h";
  complete "not an index position"
    (prelude ^ "  (func (result i32) (i32.const 0)))\n")
    "(i32.const 0";
  print_newline ()

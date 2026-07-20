(* Exercises the Wax editor features ([Wax_editor.*]) around conditional
   compilation. Each section drives one feature against a small module and prints
   a compact summary checked against the golden output.

   The focus is definitions that appear once per [#[if]]/[#[else]] branch: a
   name defined in both branches, with a single use shared outside the
   conditional. Renaming from that shared use, or from *either* branch's
   definition, must reach every definition and the use — otherwise the module
   would break under the configuration whose branch was left unrenamed. The
   outline must likewise list a conditional-guarded definition, not skip it. *)

let src =
  "#[if(debug)]\n\
   {\n\
  \    fn f() -> i32 { 1 }\n\
   }\n\
   #[else]\n\
   {\n\
  \    fn f() -> i32 { 2 }\n\
   }\n\n\
   fn g() -> i32 { f() }\n"

(* Locate the [nth] (0-based) occurrence of [sub] in [src] as a 0-based (line,
   column) plus an in-token [off], so probes need no hand-counted columns. *)
let find sub nth off =
  let rec loop from n =
    let i = Str.search_forward (Str.regexp_string sub) src from in
    if n = 0 then i else loop (i + 1) (n - 1)
  in
  let i = loop 0 nth in
  let line = ref 0 and bol = ref 0 in
  String.iteri
    (fun j c ->
      if j < i && c = '\n' then (
        incr line;
        bol := j + 1))
    src;
  (!line, i - !bol + off)

let show_loc (loc : Wax_utils.Ast.location) =
  Printf.sprintf "(%d,%d)-(%d,%d)" loc.loc_start.pos_lnum
    (loc.loc_start.pos_cnum - loc.loc_start.pos_bol)
    loc.loc_end.pos_lnum
    (loc.loc_end.pos_cnum - loc.loc_end.pos_bol)

let show_rename outcome =
  match outcome with
  | Editor_common.Rename_edits edits ->
      List.iter
        (fun (loc, repl) -> Printf.printf "  %s := %s\n" (show_loc loc) repl)
        edits
  | Editor_common.Rename_conflict message ->
      Printf.printf "  conflict: %s\n" message

let refs label l c =
  Printf.printf "%s:\n" label;
  List.iter
    (fun loc -> Printf.printf "  %s\n" (show_loc loc))
    (Wax_editor.references_string src l c)

let () =
  (* The [f] of the first ([#[if]]) definition, the [f] of the second ([#[else]])
     definition, and the [f] of the call [f()] outside the conditional. *)
  let if_l, if_c = find "fn f" 0 3 in
  let else_l, else_c = find "fn f" 1 3 in
  let use_l, use_c = find "f()" 0 0 in

  (* References from each occurrence must return the same three spans: both
     definitions and the use. *)
  refs "=== references (from #[if] definition)" if_l if_c;
  refs "=== references (from #[else] definition)" else_l else_c;
  refs "=== references (from the shared use)" use_l use_c;
  print_newline ();

  (* Rename from the #[if] definition (the regression: it used to rename only
     that branch's definition + the use, leaving the #[else] definition stale). *)
  Printf.printf "=== rename f -> h (from #[if] definition) ===\n";
  show_rename (Wax_editor.rename_string src if_l if_c "h");
  Printf.printf "=== rename f -> h (from #[else] definition) ===\n";
  show_rename (Wax_editor.rename_string src else_l else_c "h");
  print_newline ();

  (* The outline must list both branches' [f] and the top-level [g], descending
     into the conditional rather than dropping the guarded definitions. *)
  Printf.printf "=== symbols (outline) ===\n";
  List.iter
    (fun (s : Editor_common.sym) ->
      Printf.printf "  %s %s %s\n" s.s_kind s.s_name (show_loc s.s_selection))
    (Wax_editor.symbols_string src);
  print_newline ()

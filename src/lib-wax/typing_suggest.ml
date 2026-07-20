open Ast
open Typing_env

(* The [Suggestion] diagnostics the quick-fix pass emits (redundant annotations,
   compound assignment, field punning). Kept with their emitters; the message
   combinator is the same trivial [Wax_utils.Message] alias the typer's [Error]
   uses. *)
module Error = struct
  open Wax_utils

  (* A machine-applicable simplification (severity [Suggestion]), carrying the
     rewrite in [edit] for editor quick fixes and shown by [wax check] only when
     its [warning] is enabled. Marked [universal] so path-sensitive checking
     reports it once; suppressed in recovery mode like [warn]. *)
  let suggest ~warning ~edit context ~location message =
    if not (Wax_utils.Diagnostic.in_recovery context) then
      Diagnostic.report context ~location ~severity:Suggestion ~warning
        ~universal:true ~edit ~message ()
end

(* Locate the ': t' type annotation in the source between a binding name's end
   ([name_end]) and the boundary after it ([boundary] — the initializer, the next
   binding, or the tuple close). The AST keeps no span for the annotation, so it
   is recovered from the source: skip past the ':', then scan to the first of
   [,] [=] [;] [)] []] that terminates it. This is safe because every annotation
   position parses a [value_type] (see [value_type] in parser.mly) — an
   identifier or [&[?][!]ident] — a short token sequence that never contains any
   of those characters or a bracket (an inline [&fn(...)] type exists only in
   cast position, never here). Returns a pair: the type's own span (to underline)
   and the ': t' span to delete (from the ':' to the type's end, so a comment
   before it is kept). [None] when the annotation spans several lines or cannot
   be isolated. *)
let annotation_spans ctx (name_end : Lexing.position)
    (boundary : Lexing.position) =
  if name_end.pos_lnum <> boundary.pos_lnum then None
  else
    match source_slice ctx (span name_end boundary) with
    | None -> None
    | Some gap -> (
        (* Blank comments so a ':' or terminator inside one is not mistaken for
           the annotation's. *)
        let gap = blank_comments gap in
        match String.index_opt gap ':' with
        | None -> None
        | Some colon ->
            let n = String.length gap in
            let stop =
              let rec scan i =
                if i >= n then n
                else
                  match gap.[i] with
                  | ')' | ']' | ',' | '=' | ';' -> i
                  | _ -> scan (i + 1)
              in
              scan (colon + 1)
            in
            let is_ws c = c = ' ' || c = '\t' in
            let s = ref (colon + 1) and e = ref stop in
            while !s < !e && is_ws gap.[!s] do
              incr s
            done;
            while !e > !s && is_ws gap.[!e - 1] do
              decr e
            done;
            if !s >= !e then None
            else
              let at off =
                { name_end with pos_cnum = name_end.pos_cnum + off }
              in
              Some (span (at !s) (at !e), span (at colon) (at !e)))

(* Suggest dropping a binding's redundant type annotation — the ': t' that the
   initializer's inferred type already pins ([let x: t = e] -> [let x = e], and
   likewise for each binding of a tuple [let] and a redundant global annotation).
   The span is recovered by [annotation_spans]; the edit deletes the ': t',
   underlining just the type. *)
let suggest_redundant_annotation ctx ~name_end ~boundary =
  match annotation_spans ctx name_end boundary with
  | Some (type_span, delete_span) ->
      Error.suggest ~warning:Wax_utils.Warning.Redundant_annotation
        ~edit:(deletion_edit delete_span)
        ctx.diagnostics ~location:type_span
        (Wax_utils.Message.text
           "This type annotation is redundant; the initializer's type is \
            inferred.")
  | None -> ()

(* The binary operators that have a compound-assignment form [x op= e] (the
   arithmetic and bitwise ones); comparisons are excluded. Mirrors the parser's
   [compound_assign_op]. *)
let compound_assignable = function
  | Add | Sub | Mul | Div _ | Rem _ | And | Or | Xor | Shl | Shr _ -> true
  | Eq | Ne | Lt _ | Gt _ | Le _ | Ge _ -> false

(* Suggest rewriting a plain assignment [x = x op e] as the compound form
   [x op= e]. Only fires when the left operand is [x] itself (so [x = e - x] is
   left alone, since it is not [x -= e]). The replacement is spliced from the
   source: the target, the operator's own span (which already excludes the '='),
   and the right operand — so any comment or spacing inside [e] is preserved. *)
let suggest_compound_assignment ctx ~location idx (rhs_expr : _ instr) =
  match rhs_expr.desc with
  | BinOp (op, lhs, rhs)
    when compound_assignable op.desc
         && match lhs.desc with Get g -> g.desc = idx.desc | _ -> false -> (
      match
        ( source_slice ctx idx.info,
          source_slice ctx op.info,
          source_slice ctx rhs.info )
      with
      | Some target, Some opstr, Some rhs_src ->
          Error.suggest ~warning:Wax_utils.Warning.Compound_assignment
            ~edit:
              {
                Wax_utils.Diagnostic.edit_location = location;
                new_text = Printf.sprintf "%s %s= %s" target opstr rhs_src;
              }
            ctx.diagnostics ~location
            (Wax_utils.Message.text
               (Printf.sprintf
                  "This assignment can use the compound form '%s %s= …'." target
                  opstr))
      | _ -> ())
  | _ -> ()

(* Suggest the punning shorthand [{x}] for a field written explicitly as [x: x]
   (its value is [Get x] for the like-named local/global). Deletes the ': x' that
   runs from the field name's end to the value's end. *)
let suggest_punning ctx (name : ident) written =
  match written with
  | Some ({ desc = Get g; _ } as value) when g.desc = name.desc ->
      Error.suggest ~warning:Wax_utils.Warning.Field_punning
        ~edit:(deletion_edit (span name.info.loc_end value.info.loc_end))
        ctx.diagnostics ~location:name.info
        (Wax_utils.Message.text
           (Printf.sprintf "This field can use the punning shorthand '%s'."
              name.desc))
  | _ -> ()

(* Suggest dropping a construction's redundant type name — the [T] in a struct
   [{T| …}] or array [{T| …}] literal that the fields / expected type already
   pin. The name-less surface form omits the [T|] separator, so the edit deletes
   from the name's start through the following [|] (found by a short source scan,
   bailing out if a newline intervenes). *)
let suggest_drop_type_name ctx (name : ident) =
  match Wax_utils.Diagnostic.source ctx.diagnostics with
  | None -> ()
  | Some src ->
      let n = String.length src in
      let i = ref name.info.loc_end.pos_cnum in
      while !i < n && (src.[!i] = ' ' || src.[!i] = '\t') do
        incr i
      done;
      if !i < n && src.[!i] = '|' then
        let after = { name.info.loc_end with pos_cnum = !i + 1 } in
        Error.suggest ~warning:Wax_utils.Warning.Redundant_annotation
          ~edit:(deletion_edit (span name.info.loc_start after))
          ctx.diagnostics ~location:name.info
          (Wax_utils.Message.text
             "This type name is redundant; it is inferred here.")

(* Suggest dropping a block's redundant result type — the [t] in [do t { … }] /
   [loop t { … }] / [try t { … }] that the context already pins. A block
   expression takes no params, so the result is a single bare type between the
   keyword and the [{]. The AST keeps no span for it, so it is found in the
   source: locate the (reserved, hence unambiguous) keyword as a whole word, then
   take the type up to the brace. Comments are blanked first (so a keyword inside
   one is not matched), and it bails unless keyword and brace are on one line, so
   a wrong edit is never produced. *)
let suggest_block_result ctx ~keyword (block_start : Lexing.position)
    (brace_start : Lexing.position) =
  match
    if block_start.pos_lnum <> brace_start.pos_lnum then None
    else
      Option.map blank_comments
        (source_slice ctx (span block_start brace_start))
  with
  | None -> ()
  | Some prefix -> (
      let is_id c =
        (c >= 'a' && c <= 'z')
        || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9')
        || c = '_'
      in
      let m = String.length keyword and n = String.length prefix in
      let rec find i =
        if i + m > n then None
        else if
          String.sub prefix i m = keyword
          && (i = 0 || not (is_id prefix.[i - 1]))
          && (i + m = n || not (is_id prefix.[i + m]))
        then Some i
        else find (i + 1)
      in
      match find 0 with
      | None -> ()
      | Some k ->
          let is_ws c = c = ' ' || c = '\t' in
          let s = ref (k + m) and e = ref n in
          while !s < n && is_ws prefix.[!s] do
            incr s
          done;
          while !e > !s && is_ws prefix.[!e - 1] do
            decr e
          done;
          if !s < !e then
            let at off =
              { block_start with pos_cnum = block_start.pos_cnum + off }
            in
            Error.suggest
              ~warning:Wax_utils.Warning.Redundant_annotation
                (* Delete just the type token, so a comment before the [{] is kept;
                 the formatter tidies the leftover spacing. *)
              ~edit:(deletion_edit (span (at !s) (at !e)))
              ctx.diagnostics
              ~location:(span (at !s) (at !e))
              (Wax_utils.Message.text
                 "This result type is redundant; it is inferred from the \
                  context."))

(* Suggest dropping an [if]'s redundant result type — the [=> t] between the
   condition and the [{] that the context already pins (the [if]-expression
   analogue of [suggest_block_result]). The AST keeps no span for it, so it is
   found in the source between the condition's end and the brace: locate the
   [=>], then take the type up to the brace. Comments are blanked first and it
   bails unless [=>] and brace are on one line. The edit deletes the whole
   [=> t]. *)
let suggest_if_result ctx (cond_end : Lexing.position)
    (brace_start : Lexing.position) =
  match
    if cond_end.pos_lnum <> brace_start.pos_lnum then None
    else
      Option.map blank_comments (source_slice ctx (span cond_end brace_start))
  with
  | None -> ()
  | Some gap -> (
      let n = String.length gap in
      let rec find i =
        if i + 1 >= n then None
        else if gap.[i] = '=' && gap.[i + 1] = '>' then Some i
        else find (i + 1)
      in
      match find 0 with
      | None -> ()
      | Some arrow ->
          let is_ws c = c = ' ' || c = '\t' in
          let s = ref (arrow + 2) and e = ref n in
          while !s < n && is_ws gap.[!s] do
            incr s
          done;
          while !e > !s && is_ws gap.[!e - 1] do
            decr e
          done;
          if !s < !e then
            let at off = { cond_end with pos_cnum = cond_end.pos_cnum + off } in
            Error.suggest
              ~warning:Wax_utils.Warning.Redundant_annotation
                (* Delete the whole '=> t'; the formatter tidies the spacing. *)
              ~edit:(deletion_edit (span (at arrow) (at !e)))
              ctx.diagnostics
              ~location:(span (at !s) (at !e))
              (Wax_utils.Message.text
                 "This result type is redundant; it is inferred from the \
                  context."))

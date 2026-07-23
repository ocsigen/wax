module type ENGINE = sig
  type 'a env
  type element

  val get : int -> 'a env -> element option
  val positions : element -> Lexing.position * Lexing.position
end

module Make (E : ENGINE) = struct
  type label = {
    loc_start : Lexing.position;
    loc_end : Lexing.position;
    text : string;
  }

  module R = MenhirLib.ErrorReports

  (* A source slice for a Menhir [$i] reference: extract, sanitize, compress
     whitespace, and cap the width (max 43 chars, as [E.shorten 20] gives). *)
  let show source positions =
    R.extract source positions |> R.sanitize |> R.compress |> R.shorten 20

  let resolve ~source ~env message =
    (* Expand Menhir [$i] source-slice references first (a no-op for a message
       with none), reaching stack cell [i] via the engine. *)
    let get_slice i =
      match E.get i env with
      | Some el -> show source (E.positions el)
      | None -> "???"
    in
    let message = R.expand get_slice message in
    let lines = String.split_on_char '\n' message in
    let related = ref [] in
    let main_message = ref [] in
    List.iter
      (fun line ->
        let len = String.length line in
        if len > 2 && line.[0] = '<' then
          try
            let i = String.index line '>' in
            let tag = String.sub line 1 (i - 1) in
            let msg = String.trim (String.sub line (i + 1) (len - i - 1)) in
            (* Two marker kinds share the [<…>text] shape. A bare number [<N>]
               is a delimiter hint: underline the single opening delimiter of
               the construct at stack cell [N]. A caret-tagged number [<^N>] is
               the *subject* of a hedge ("Assuming that the X is complete, …"):
               underline the whole construct that cell [N] produced. A consumer
               that only understands [<N>] fails [int_of_string "^N"] and leaves
               the line inline in the message — graceful degradation. *)
            let is_subject = String.length tag > 0 && tag.[0] = '^' in
            let depth =
              int_of_string
                (if is_subject then String.sub tag 1 (String.length tag - 1)
                 else tag)
            in
            match E.get (depth - 1) env with
            | Some el ->
                let pos1, pos2 = E.positions el in
                if is_subject then
                  if
                    (* The subject label spans the construct's true start..end,
                     however many source lines it crosses — the diagnostic
                     renderer draws a multi-line span as a spine, so the whole
                     construct is underlined. An empty (epsilon) reduction — "the
                     exports are complete" with zero exports assumed complete —
                     leaves a zero-width span; underlining nothing is noise, so
                     drop the label and let the hedge sentence stand on its
                     own. *)
                    pos1.Lexing.pos_cnum >= pos2.Lexing.pos_cnum
                  then ()
                  else
                    related :=
                      { loc_start = pos1; loc_end = pos2; text = msg }
                      :: !related
                else
                  (* This hint points at an opening delimiter. The delimiter is
                     normally the cell's start — a compound opener
                     ([(then]/[(param]/…) reports the '(' as its start — but a
                     spurious reduction can surface a plain token (e.g. ELEM)
                     sitting just past the '('; in that case walk the source back
                     over blanks to the delimiter.

                     The underline spans the FULL alias the label names, not a
                     fixed single character (move 3): a multi-character opener
                     like [\[|] underlines both of its characters. The width is
                     read from the alias the label quotes ([This '[|' opens …] ->
                     2, [This '(' opens …] -> 1), so the [<N>] marker itself
                     carries no width and stays interchangeable with older
                     output; a label with no quoted alias falls back to one
                     character. *)
                  let cnum = pos1.Lexing.pos_cnum in
                  let is_delim c = c = '(' || c = '[' || c = '{' in
                  let blank c = c = ' ' || c = '\t' in
                  let dcnum =
                    if cnum < String.length source && is_delim source.[cnum]
                    then cnum
                    else
                      let rec back i =
                        if i < 0 || not (blank source.[i]) then
                          if i >= 0 && is_delim source.[i] then i else cnum
                        else back (i - 1)
                      in
                      back (cnum - 1)
                  in
                  let width =
                    match String.index_opt msg '\'' with
                    | Some i -> (
                        match String.index_from_opt msg (i + 1) '\'' with
                        | Some j -> max 1 (j - i - 1)
                        | None -> 1)
                    | None -> 1
                  in
                  let start = { pos1 with Lexing.pos_cnum = dcnum } in
                  related :=
                    {
                      loc_start = start;
                      loc_end = { start with Lexing.pos_cnum = dcnum + width };
                      text = msg;
                    }
                    :: !related
            | None -> main_message := line :: !main_message
          with _ -> main_message := line :: !main_message
        else main_message := line :: !main_message)
      lines;
    let main_message = List.rev !main_message in
    let related_labels = List.rev !related in
    (* Remove a trailing empty line left by a trailing newline when there are
       related labels. *)
    let main_message =
      match List.rev main_message with
      | "" :: rest when related_labels <> [] -> List.rev rest
      | _ -> main_message
    in
    (String.concat "\n" main_message, related_labels)
end

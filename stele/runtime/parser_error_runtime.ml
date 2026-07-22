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
            let depth = int_of_string (String.sub line 1 (i - 1)) in
            let msg = String.trim (String.sub line (i + 1) (len - i - 1)) in
            match E.get (depth - 1) env with
            | Some el ->
                (* This hint points at a single opening delimiter, so underline
                   one character. The delimiter is normally the cell's start —
                   a compound opener ([(then]/[(param]/…) reports the '(' as its
                   start — but a spurious reduction can surface a plain token
                   (e.g. ELEM) sitting just past the '('; in that case walk the
                   source back over blanks to the delimiter. *)
                let pos1, _pos2 = E.positions el in
                let cnum = pos1.Lexing.pos_cnum in
                let is_delim c = c = '(' || c = '[' || c = '{' in
                let blank c = c = ' ' || c = '\t' in
                let dcnum =
                  if cnum < String.length source && is_delim source.[cnum] then
                    cnum
                  else
                    let rec back i =
                      if i < 0 || not (blank source.[i]) then
                        if i >= 0 && is_delim source.[i] then i else cnum
                      else back (i - 1)
                    in
                    back (cnum - 1)
                in
                let start = { pos1 with Lexing.pos_cnum = dcnum } in
                related :=
                  {
                    loc_start = start;
                    loc_end = { start with Lexing.pos_cnum = dcnum + 1 };
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

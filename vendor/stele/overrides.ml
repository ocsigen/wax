open Util

(* --- Hand-written overrides (the sanctioned escape hatch) --- *)

(* A per-grammar [.overrides] file supplies hand-written messages for the states
   heuristics cannot serve — chiefly the structurally immovable over-5
   "enumeration" fallbacks (the dot at the start of a construct whose FIRST set
   overflows the readable cap, so the generated message degrades to a bare
   "Syntax error"). It is keyed by the *sentence* (`entry_point: sentence`, the
   stable key — state numbers renumber on any grammar change, sentences do not)
   and merged after generation. The file mirrors the [.messages] shape: blocks
   separated by blank lines; within a block, lines beginning with '#' (after
   optional leading whitespace) are rationale comments, the first surviving line
   is the `entry_point: sentence` header, and the remaining lines are the
   replacement message body (a single line, or a message plus a [<N>] delimiter-
   hint line). *)
let load_overrides file =
  let lines = Parse_messages.read_lines file in
  let blocks =
    (* Same blank-line block split as the [.messages] parser. *)
    let rec aux cur acc = function
      | [] -> List.rev (if cur = [] then acc else List.rev cur :: acc)
      | line :: rest ->
          if String.trim line = "" then
            if cur = [] then aux [] acc rest
            else aux [] (List.rev cur :: acc) rest
          else aux (line :: cur) acc rest
    in
    aux [] [] lines
  in
  List.fold_left
    (fun map block ->
      let is_comment l =
        let t = String.trim l in
        String.length t > 0 && t.[0] = '#'
      in
      match List.filter (fun l -> not (is_comment l)) block with
      | [] -> map
      | header :: body ->
          let header = String.trim header in
          (* A second block for the same state would silently replace the
             first, and an empty body would compile to an empty message. *)
          if StringMap.mem header map then
            failwith
              (Printf.sprintf "overrides %s: duplicate entry for %S" file header);
          if body = [] then
            failwith
              (Printf.sprintf "overrides %s: entry %S has no message" file
                 header);
          StringMap.add header (String.concat "\n" body) map)
    StringMap.empty blocks

(* The location markers of a message: each line that starts with [<N>] (a
   delimiter hint) or [<^N>] (a hedge subject), as ([`Hint] or [`Subject], N).
   These are the only lines the runtime resolves, so a ['<'] anywhere else is
   just prose. A depth too large for an [int] reads as [max_int], so it fails
   any range check. *)
let markers body =
  let re = Str.regexp "<\\(\\^?\\)\\([0-9]+\\)>" in
  String.split_on_char '\n' body
  |> List.filter_map (fun line ->
      if Str.string_match re line 0 then
        let kind = if Str.matched_group 1 line = "" then `Hint else `Subject in
        let n =
          match int_of_string_opt (Str.matched_group 2 line) with
          | Some n -> n
          | None -> max_int
        in
        Some (kind, n)
      else None)

(* Validate the [<N>] and [<^N>] markers an override carries the same way a
   generated hint is bounded: [N] is a 1-based stack-cell index the runtime resolves with
   [MenhirInterpreter.get (N-1)], so it must fall within the state's known stack
   suffix (a marker past the suffix would point the underline at the wrong cell
   — or off the stack). A bad marker is a hard build error. Claim-soundness of
   the *prose* itself (that the listed continuations are the ones the state
   actually accepts) is the override author's responsibility — the oracle checks
   symbols, not sentences, so it cannot vet free text. *)
let validate_override_depths ~header body stack_suffix =
  let n_cells =
    String.concat " " stack_suffix
    |> String.split_on_char ' '
    |> List.filter (fun s -> String.trim s <> "")
    |> List.length
  in
  List.iter
    (fun (kind, n) ->
      if n < 1 || n > n_cells then
        failwith
          (Printf.sprintf "override for %S: marker <%s%s> is out of range: %s"
             header
             (match kind with `Hint -> "" | `Subject -> "^")
             (if n = max_int then "..." else string_of_int n)
             (match n_cells with
             | 0 -> "this state knows nothing of the parser's stack"
             | 1 ->
                 "this state only knows the top position of the parser's stack"
             | k ->
                 Printf.sprintf
                   "this state only knows the top %d positions of the parser's \
                    stack"
                   k)))
    (markers body)

(* Report an override whose sentence matches no generated entry: the file must
   never drift silently, so a stale key fails the build. Called once the full
   entry set is known. *)
let check_override_rot overrides entries =
  let headers =
    List.fold_left
      (fun acc e -> StringSet.add (header_of e) acc)
      StringSet.empty entries
  in
  StringMap.iter
    (fun key _ ->
      if not (StringSet.mem key headers) then
        failwith
          (Printf.sprintf
             "override for %S matches no error state (stale entry — remove or \
              fix it)"
             key))
    overrides

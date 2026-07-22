type lr1_item = {
  lhs : string;
  rhs_before : string list;
  rhs_after : string list;
  lookaheads : string list;
}

type spurious_reduction = { symbol : string; production : string }

type comment_data = {
  state : int;
  lr1_items : lr1_item list;
  stack_suffix : string list;
  spurious_reductions : spurious_reduction list;
}

type entry = {
  entry_point : string;
  sentence : string;
  data : comment_data;
  message : string;
  original_comments : string list;
}

(* Utilities *)

let read_lines filename =
  let lines = ref [] in
  let chan = open_in filename in
  try
    while true do
      let line = input_line chan in
      let len = String.length line in
      let line =
        if len > 0 && line.[len - 1] = '\r' then String.sub line 0 (len - 1)
        else line
      in
      lines := line :: !lines
    done;
    List.rev !lines
  with End_of_file ->
    close_in chan;
    List.rev !lines

let is_blank line = String.trim line = ""

let split_into_blocks lines =
  let rec aux current_block blocks = function
    | [] ->
        if current_block = [] then List.rev blocks
        else List.rev (List.rev current_block :: blocks)
    | line :: rest ->
        if is_blank line then
          if current_block = [] then aux [] blocks rest
          else aux [] (List.rev current_block :: blocks) rest
        else aux (line :: current_block) blocks rest
  in
  aux [] [] lines

(* Regex Parsing *)

let re_state = Str.regexp "## Ends in an error in state: \\([0-9]+\\)\\."

let re_stack_start =
  Str.regexp "## The known suffix of the stack is as follows:"

let re_spurious =
  Str.regexp "## WARNING: This example involves spurious reductions\\."

let re_spurious_item =
  Str.regexp
    "## In state [0-9]+, spurious reduction of production \\(.*\\) -> \\(.*\\)"

let parse_lr1_item line =
  let line = String.trim line in
  if String.length line < 3 || String.sub line 0 3 <> "## " then
    failwith ("Invalid LR1 item line format: " ^ line)
  else
    let content = String.sub line 3 (String.length line - 3) |> String.trim in

    let arrow_re = Str.regexp "->" in
    let arrow_idx =
      try Str.search_forward arrow_re content 0
      with Not_found -> failwith ("Missing arrow in LR1 item: " ^ content)
    in

    let lhs = String.sub content 0 arrow_idx |> String.trim in
    let rhs_start = arrow_idx + 2 in
    let remainder =
      String.sub content rhs_start (String.length content - rhs_start)
    in

    let bracket_idx =
      try String.index remainder '['
      with Not_found -> failwith ("Missing lookahead bracket in: " ^ content)
    in
    let rhs_part = String.sub remainder 0 bracket_idx |> String.trim in
    let closing_bracket_idx =
      try String.index remainder ']'
      with Not_found ->
        failwith ("Missing closing lookahead bracket in: " ^ content)
    in

    let lookaheads_str =
      String.sub remainder (bracket_idx + 1)
        (closing_bracket_idx - bracket_idx - 1)
      |> String.trim
    in
    let lookaheads =
      lookaheads_str |> String.split_on_char ' '
      |> List.filter (fun s -> s <> "")
    in

    let dot_idx =
      try String.index rhs_part '.'
      with Not_found -> failwith ("Missing dot in LR1 item RHS: " ^ rhs_part)
    in

    let before_str = String.sub rhs_part 0 dot_idx |> String.trim in
    let after_str =
      String.sub rhs_part (dot_idx + 1) (String.length rhs_part - dot_idx - 1)
      |> String.trim
    in

    let split_trim s =
      s |> String.split_on_char ' ' |> List.filter (fun x -> x <> "")
    in

    {
      lhs;
      rhs_before = split_trim before_str;
      rhs_after = split_trim after_str;
      lookaheads;
    }

let parse_comment lines =
  let state = ref (-1) in
  let items = ref [] in
  let stack = ref [] in
  let spurious_items = ref [] in
  let in_stack = ref false in

  let in_spurious_text = ref false in

  List.iter
    (fun line ->
      let trimmed = String.trim line in
      let is_marker line re = Str.string_match re line 0 in

      if is_marker line re_state then (
        state := int_of_string (Str.matched_group 1 line);
        in_stack := false;
        in_spurious_text := false)
      else if is_marker line re_spurious then (
        in_stack := false;
        in_spurious_text := true)
      else if is_marker line re_stack_start then (
        in_stack := true;
        in_spurious_text := false)
      else if !in_stack then
        if
          (* Processing stack suffix *)
          String.length line > 3 && String.sub line 0 3 = "## "
        then
          if trimmed = "##" then in_stack := false (* End of stack block *)
          else
            let content =
              String.sub line 3 (String.length line - 3) |> String.trim
            in
            if content = "" then in_stack := false
            else stack := content :: !stack
        else in_stack := false (* Malformed or end *)
      else if !in_spurious_text then
        if
          (* Processing spurious reduction text *)
          String.length line > 3 && String.sub line 0 3 = "## "
        then
          if trimmed = "##" then in_spurious_text := false
          else if Str.string_match re_spurious_item line 0 then
            let symbol = String.trim (Str.matched_group 1 line) in
            let production = String.trim (Str.matched_group 2 line) in
            spurious_items := { symbol; production } :: !spurious_items
          else () (* Ignore other warning text *)
        else in_spurious_text := false
      else if
        (* Processing LR1 items or empty comments *)
        String.length line > 3 && String.sub line 0 3 = "## "
      then if trimmed = "##" then () else items := parse_lr1_item line :: !items)
    lines;

  if !state = -1 then failwith "Failed to parse state number from comment block";

  {
    state = !state;
    lr1_items = List.rev !items;
    stack_suffix = List.rev !stack;
    spurious_reductions = List.rev !spurious_items;
  }

let parse_entry sentence_block message_block =
  match sentence_block with
  | [] -> failwith "Empty sentence block"
  | sentence_line :: comment_lines ->
      let entry_point, sentence =
        match String.split_on_char ':' sentence_line with
        | fn :: rest -> (fn, String.trim (String.concat ":" rest))
        | [] -> ("parse", sentence_line)
      in
      let data = parse_comment comment_lines in
      let message = String.concat "\n" message_block in
      {
        entry_point;
        sentence;
        data;
        message;
        original_comments = comment_lines;
      }

(* The input is always the output of [menhir --list-errors]: a strict
   alternation of a sentence block (the entry-point sentence plus [##] comment
   lines describing the error state) and a message block, separated by blank
   lines. Hand-curated files that group several sentences under one message are
   NOT supported — [pair_blocks] assumes one sentence block per message block. *)
let parse_file filename =
  let lines = read_lines filename in
  let blocks = split_into_blocks lines in

  (* Blocks come in format: SentenceBlock, MessageBlock, SentenceBlock, MessageBlock... *)
  let rec pair_blocks acc = function
    | s :: m :: rest ->
        let entry = parse_entry s m in
        pair_blocks (entry :: acc) rest
    | [] -> List.rev acc
    | [ _ ] -> failwith "Orphan sentence block at end of file"
    (* Printf.eprintf "Warning: Orphan sentence block at end of file\n";
        List.rev acc *)
  in

  pair_blocks [] blocks

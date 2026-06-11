type theme = {
  error_header : string;
  warning_header : string;
  hint_header : string;
  error_label : string;
  warning_label : string;
  secondary_label : string;
  line_numbers : string;
}

let get_theme ?(color = Colors.Auto) () =
  let use_color = Colors.should_use_color ~color ~out_channel:(Some stderr) in
  let open Colors in
  if use_color then
    {
      error_header = Ansi.bold ^ Ansi.high_red;
      warning_header = Ansi.bold ^ Ansi.high_yellow;
      hint_header = Ansi.bold ^ Ansi.cyan;
      error_label = Ansi.red;
      warning_label = Ansi.yellow;
      secondary_label = Ansi.bold ^ Ansi.blue;
      line_numbers = Ansi.cyan;
    }
  else
    {
      error_header = "";
      warning_header = "";
      hint_header = "";
      error_label = "";
      warning_label = "";
      secondary_label = "";
      line_numbers = "";
    }

let with_style color g f x =
  let pr_color f c = Format.pp_print_as f 0 c in
  Format.fprintf f "%a%a%a" pr_color color g x pr_color
    (if color = "" then "" else Colors.Ansi.reset)

type label = {
  location : Ast.location;
  message : Format.formatter -> unit -> unit;
}

type severity = Error | Warning

type t = {
  location : Ast.location;
  severity : severity;
  message : Format.formatter -> unit -> unit;
  hint : (Format.formatter -> unit -> unit) option;
  related : label list;
}

let print_hint ?(output = Format.err_formatter) ~theme hint =
  match hint with
  | None -> ()
  | Some pp ->
      Format.fprintf output "@[<2>%a:@ %a@]@."
        (with_style theme.hint_header (fun f () -> Format.fprintf f "Hint"))
        () pp ()

let output_error_no_loc ?(output = Format.err_formatter) ~theme ~severity ~hint
    msg =
  Format.fprintf output "@[<2>%a:@ %a@]@."
    (match severity with
    | Error ->
        with_style theme.error_header (fun f () -> Format.fprintf f "Error")
    | Warning ->
        with_style theme.warning_header (fun f () -> Format.fprintf f "Warning"))
    () msg ();
  print_hint ~output ~theme hint

let output_error_no_source ?(output = Format.err_formatter) ~theme
    ~location:{ Ast.loc_start; loc_end } ~severity ?hint msg =
  let start_line = loc_start.Lexing.pos_lnum in
  let end_line = loc_end.Lexing.pos_lnum in
  let filename = loc_start.Lexing.pos_fname in
  let s_bol = loc_start.Lexing.pos_bol in
  let s_cnum = loc_start.Lexing.pos_cnum in
  let start_col = s_cnum - s_bol in
  let e_bol = loc_end.Lexing.pos_bol in
  let e_cnum = loc_end.Lexing.pos_cnum in
  let end_col = e_cnum - e_bol in
  if start_line = end_line then
    Format.fprintf output "File \"%s\", line %d, characters %d-%d:@." filename
      start_line start_col end_col
  else
    Format.fprintf output
      "File \"%s\", line %d, character %d to line %d, character %d:@." filename
      start_line start_col end_line end_col;
  output_error_no_loc ~output ~theme ~severity ~hint msg

type annotation = {
  start_line : int;
  end_line : int;
  start_col : int;
  end_col : int;
  color : string;
  label : (Format.formatter -> unit -> unit) option;
}

let get_annotations ~theme ~severity ~location ~related =
  let main =
    let { Ast.loc_start; loc_end } = location in
    let start_line = loc_start.Lexing.pos_lnum in
    let end_line = loc_end.Lexing.pos_lnum in
    let start_col = loc_start.Lexing.pos_cnum - loc_start.Lexing.pos_bol in
    let end_col = loc_end.Lexing.pos_cnum - loc_end.Lexing.pos_bol in
    let color =
      match severity with
      | Error -> theme.error_label
      | Warning -> theme.warning_label
    in
    { start_line; end_line; start_col; end_col; color; label = None }
  in
  let secondary =
    List.map
      (fun ({ location; message } : label) ->
        let { Ast.loc_start; loc_end } = location in
        let start_line = loc_start.Lexing.pos_lnum in
        let end_line = loc_end.Lexing.pos_lnum in
        let start_col = loc_start.Lexing.pos_cnum - loc_start.Lexing.pos_bol in
        let end_col = loc_end.Lexing.pos_cnum - loc_end.Lexing.pos_bol in
        {
          start_line;
          end_line;
          start_col;
          end_col;
          color = theme.secondary_label;
          label = Some message;
        })
      related
  in
  main :: secondary

let get_hunks annotations =
  let context = 2 in
  let ranges =
    List.concat_map
      (fun a ->
        [
          (a.start_line - context, a.start_line + context);
          (a.end_line - context, a.end_line + context);
        ])
      annotations
  in
  let ranges = List.sort (fun (s1, _) (s2, _) -> compare s1 s2) ranges in
  let rec merge = function
    | [] -> []
    | [ r ] -> [ r ]
    | (s1, e1) :: (s2, e2) :: rest ->
        if s2 <= e1 + 1 then merge ((min s1 s2, max e1 e2) :: rest)
        else (s1, e1) :: merge ((s2, e2) :: rest)
  in
  merge ranges |> List.map (fun (s, e) -> (max 1 s, e))

let modern = true

let output_error_with_source ?(output = Format.err_formatter) ~theme ~source
    ~location ~severity ?hint ?(related = []) msg =
  let annotations = get_annotations ~theme ~severity ~location ~related in
  let hunks = get_hunks annotations in
  let rec count_lines s i acc =
    try
      let j = String.index_from s i '\n' in
      count_lines s (j + 1) (acc + 1)
    with Not_found -> acc + 1
  in
  let total_lines = count_lines source 0 0 in
  let max_line =
    List.fold_left (fun acc (_, e) -> max acc e) 0 hunks |> min total_lines
  in
  let gutter_width = max 1 (String.length (string_of_int max_line)) in
  let gutter_padding = String.make gutter_width ' ' in
  let filename = location.Ast.loc_start.Lexing.pos_fname in
  let start_line = location.Ast.loc_start.Lexing.pos_lnum in
  let start_col =
    location.Ast.loc_start.Lexing.pos_cnum
    - location.Ast.loc_start.Lexing.pos_bol
  in
  output_error_no_loc ~output ~theme ~severity ~hint:None msg;
  if modern then
    Format.fprintf output "%a %a@."
      (with_style theme.line_numbers (fun f () ->
           Format.fprintf f "%s──➤" gutter_padding))
      ()
      (fun f () ->
        Format.fprintf f " %s:%d:%d" filename start_line (start_col + 1))
      ();
  let find_eol text start_pos =
    try String.index_from text start_pos '\n'
    with Not_found -> String.length text
  in
  let get_line_info text pos_bol =
    if pos_bol >= String.length text then ("", pos_bol)
    else
      let line_end = find_eol text pos_bol in
      let content = String.sub text pos_bol (line_end - pos_bol) in
      (content, line_end)
  in
  let print_line ?(gutter_char = "│") header contents =
    Format.fprintf output "%a %a@."
      (with_style theme.line_numbers (fun f () ->
           Format.fprintf f "%a %a" header ()
             (fun f () -> Format.pp_print_as f 1 gutter_char)
             ()))
      () contents ()
  in
  let curr_pos = ref 0 in
  let curr_line = ref 1 in
  let seek line =
    while !curr_line < line do
      let eol = find_eol source !curr_pos in
      curr_pos := min (String.length source) (eol + 1);
      incr curr_line
    done
  in
  let total_hunks = List.length hunks in
  List.iteri
    (fun i (s_line, e_line) ->
      if i > 0 then
        Format.fprintf output "%a %s@."
          (with_style theme.line_numbers (fun f () ->
               Format.fprintf f "%s %a" gutter_padding
                 (fun f () -> Format.pp_print_as f 1 "·")
                 ()))
          () "...";
      seek s_line;
      while !curr_line <= min e_line total_lines do
        let is_last_line =
          !curr_line = min e_line total_lines && i = total_hunks - 1
        in
        let raw_content, next_eol = get_line_info source !curr_pos in
        let display_content = Unicode.expand_tabs raw_content in
        print_line
          (fun f () -> Format.fprintf f "%*d" gutter_width !curr_line)
          (fun f () -> Format.fprintf f "%s" display_content);
        let line_annotations =
          List.filter
            (fun a -> !curr_line >= a.start_line && !curr_line <= a.end_line)
            annotations
        in
        let num_annots = List.length line_annotations in
        List.iteri
          (fun j a ->
            let is_last_annot = is_last_line && j = num_annots - 1 in
            let gutter_char = if is_last_annot then " " else "·" in
            let is_start = !curr_line = a.start_line in
            let is_end = !curr_line = a.end_line in
            let visual_start, visual_len =
              if is_start && is_end then
                let start_col = min (String.length raw_content) a.start_col in
                let end_col = min (String.length raw_content) a.end_col in
                let prefix = String.sub raw_content 0 start_col in
                let visual_start = Unicode.terminal_width prefix in
                let len_bytes = max 0 (end_col - start_col) in
                let part = String.sub raw_content start_col len_bytes in
                (visual_start, Unicode.terminal_width part)
              else if is_start then
                let start_col = min (String.length raw_content) a.start_col in
                let prefix = String.sub raw_content 0 start_col in
                let visual_start = Unicode.terminal_width prefix in
                let len_bytes = String.length raw_content - start_col in
                let part = String.sub raw_content start_col len_bytes in
                (visual_start, Unicode.terminal_width part + 1)
              else if is_end then
                let end_col = min (String.length raw_content) a.end_col in
                let part = String.sub raw_content 0 end_col in
                (0, Unicode.terminal_width part)
              else (0, Unicode.terminal_width raw_content + 1)
            in
            print_line ~gutter_char
              (fun f () -> Format.fprintf f "%s" gutter_padding)
              (fun f () ->
                Format.fprintf f "%*s%a" visual_start ""
                  (with_style a.color (fun f () ->
                       let underline = String.make (max 1 visual_len) '^' in
                       Format.fprintf f "%s" underline))
                  ();
                match a.label with
                | Some pp when is_end ->
                    Format.fprintf f " ";
                    with_style a.color pp f ()
                | _ -> ()))
          line_annotations;
        curr_pos := min (String.length source) (next_eol + 1);
        incr curr_line
      done)
    hunks;
  print_hint ~output ~theme hint

let output_error ?(output = Format.err_formatter) ~theme ~source ~location
    ~severity ?hint ?(related = []) msg =
  if location.Ast.loc_start = Lexing.dummy_pos then
    output_error_no_loc ~output ~theme ~severity ~hint msg
  else
    match source with
    | None ->
        output_error_no_source ~output ~theme ~location ~severity ?hint msg
    | Some source ->
        output_error_with_source ~output ~theme ~source ~location ~severity
          ?hint ~related msg

type context = {
  max : int;
  queue : t Queue.t;
  source : string option;
  theme : theme;
  related : label list;
  exit_on_error : bool;
  output : Format.formatter;
  collecting : bool;
      (* A collecting context buffers warnings in its queue (like errors)
         instead of printing them immediately, so they can be inspected with
         [collected] and re-reported. *)
}

let make ?color ~source ?(related = []) ?(exit_on_error = true) ?(max = 1)
    ?(output = Format.err_formatter) ?(collecting = false) () =
  let theme = get_theme ?color () in
  {
    max;
    queue = Queue.create ();
    source;
    theme;
    related;
    exit_on_error;
    output;
    collecting;
  }

(* A formatter that discards everything, used by collecting contexts. *)
let null_formatter = Format.make_formatter (fun _ _ _ -> ()) (fun () -> ())

(* A context that accumulates errors in its queue without ever printing or
   exiting, so they can be inspected with [collected]. Output parameters
   ([source], [color], …) are irrelevant since nothing is rendered. *)
let collector () =
  make ~source:None ~exit_on_error:false ~max:max_int ~output:null_formatter
    ~collecting:true ()

type entry = t

let collected context = List.of_seq (Queue.to_seq context.queue)
let entry_location (e : entry) = e.location
let entry_severity (e : entry) = e.severity
let entry_message (e : entry) = e.message
let entry_hint (e : entry) = e.hint
let entry_related (e : entry) = e.related

let output_errors ?exit_on_error context =
  let exit_on_error =
    match exit_on_error with Some b -> b | None -> context.exit_on_error
  in
  if not (Queue.is_empty context.queue) then (
    Queue.iter
      (fun ({ location; severity; hint; message; related } : t) ->
        output_error ~output:context.output ~theme:context.theme
          ~source:context.source ~location ~severity ?hint ~related message)
      context.queue;
    Queue.clear context.queue;
    if exit_on_error then exit 128)

let report context ~location ~severity ?hint ?(related = []) ~message () =
  let all_related = context.related @ related in
  match severity with
  | Warning when context.collecting ->
      (* Buffer the warning so [collected] can surface it; never triggers the
         early flush or the exit-on-error path. *)
      Queue.push
        { location; severity; message; hint; related = all_related }
        context.queue
  | Warning ->
      output_error ~output:context.output ~theme:context.theme
        ~source:context.source ~location ~severity ?hint ~related:all_related
        message
  | Error ->
      Queue.push
        { location; severity; message; hint; related = all_related }
        context.queue;
      if Queue.length context.queue = context.max then output_errors context

exception Aborted

let abort () = raise Aborted

let run ?color ~source ?related ?(exit = true) ?output f =
  let d = make ?color ~source ?related ~exit_on_error:exit ?output () in
  match f d with
  | res ->
      output_errors d;
      res
  | exception Aborted ->
      (* Flush the queued diagnostics (which exits the process when
         [exit_on_error]); only re-raised in a non-exiting context. *)
      output_errors d;
      raise Aborted

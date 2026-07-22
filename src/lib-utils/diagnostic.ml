type theme = {
  error_header : string;
  warning_header : string;
  hint_header : string;
  error_label : string;
  warning_label : string;
  secondary_label : string;
  line_numbers : string;
  body : Colors.theme;
      (* The theme for message bodies: identifiers, types and other emphasized
         atoms embedded in a message (see [Message]). Coloured or [no_color] in
         lockstep with the header colours above, both from the one [color] flag. *)
}

let get_theme ?(color = Colors.Auto) ?(palette = Colors.wax_theme) () =
  let use_color = Colors.should_use_color ~color ~out_channel:(Some stderr) in
  let body = if use_color then palette else Colors.no_color in
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
      body;
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
      body;
    }

(* A destination for rendered diagnostics. Replaces the [Format.formatter] the
   renderer used to write into: two consumers need a non-stderr sink (the
   spec-test harness captures into a [Buffer]; the diagnostics test writes
   stdout). *)
type sink = { write : string -> unit; flush : unit -> unit }

let channel_sink oc = { write = output_string oc; flush = (fun () -> flush oc) }
let buffer_sink b = { write = Buffer.add_string b; flush = (fun () -> ()) }

(* Emit one physical line and flush. The old renderer ended every [Format.fprintf]
   in [@.] (newline + flush); flushing per line here preserves that granularity,
   so stdout/stderr interleaving in cram tests and child-process capture is
   unchanged. *)
let line sink s =
  sink.write (s ^ "\n");
  sink.flush ()

(* Wrap [s] in [color]'s ANSI escape (reset after), or return it unchanged when
   the theme is uncoloured ([color = ""]). Pure string composition: a header's
   colour contributes no display width, matching the old zero-width
   [Format.pp_print_as f 0] emission, since every alignment is computed from the
   plain text. *)
let with_style color s = if color = "" then s else color ^ s ^ Colors.Ansi.reset

type label = { location : Ast.location; message : Message.t }
type severity = Error | Warning | Suggestion
type edit = { edit_location : Ast.location; new_text : string }

type t = {
  location : Ast.location;
  severity : severity;
  warning : Warning.t option;
      (* The named warning this diagnostic came from, if any, so the policy can
         be applied when it is finally reported (see [report]). *)
  message : Message.t;
  hint : Message.t option;
  edit : edit option;
      (* A machine-applicable rewrite carried by a [Suggestion] (see [report]'s
         [edit] parameter). Surfaced through [entry_edit]. *)
  related : label list;
  universal : bool;
      (* Reported during path-sensitive exploration only if it holds in every
         reachable configuration (see [report]'s [universal] parameter). *)
}

(* Machine-readable diagnostic output. When the global output format is [Json],
   each diagnostic is emitted as one JSON object on its own line (JSON Lines),
   as rustc/cargo do, so a CI job or an editor can parse diagnostics
   mechanically. Set once from the command line via [set_format], mirroring
   [set_policy]. The default is [Human], so nothing changes unless requested. *)
type output_format = Human | Json | Short

let global_format = ref Human
let set_format f = global_format := f

(* Emit one diagnostic as a single-line JSON object. Line/column are the usual
   1-based line / 0-based column; byte offsets ([pos_cnum]) index into the
   source, for an agent that rewrites the raw bytes. [warning]/[hint] are null
   when absent; [related] is always an array. A machine-applicable [edit], when
   present, is an object with the same span fields plus its ["newText"]. *)
let output_error_json ~output ~location ~severity ?warning ?hint ?(related = [])
    ?edit msg =
  let col (p : Lexing.position) = p.pos_cnum - p.pos_bol in
  let span { Ast.loc_start; loc_end } : (string * Yojson.Safe.t) list =
    [
      ("startLine", `Int loc_start.Lexing.pos_lnum);
      ("startColumn", `Int (col loc_start));
      ("endLine", `Int loc_end.Lexing.pos_lnum);
      ("endColumn", `Int (col loc_end));
      ("startOffset", `Int loc_start.Lexing.pos_cnum);
      ("endOffset", `Int loc_end.Lexing.pos_cnum);
    ]
  in
  let obj : Yojson.Safe.t =
    `Assoc
      ([
         ( "severity",
           `String
             (match severity with
             | Error -> "error"
             | Warning -> "warning"
             | Suggestion -> "suggestion") );
         ("file", `String location.Ast.loc_start.Lexing.pos_fname);
       ]
      @ span location
      @ [
          ("message", `String (Message.to_plain_string msg));
          ( "warning",
            match warning with
            | Some w -> `String (Warning.name w)
            | None -> `Null );
          ( "hint",
            match hint with
            | Some m -> `String (Message.to_plain_string m)
            | None -> `Null );
          ( "related",
            `List
              (List.map
                 (fun (l : label) : Yojson.Safe.t ->
                   `Assoc
                     (span l.location
                     @ [
                         ("message", `String (Message.to_plain_string l.message));
                       ]))
                 related) );
        ]
      @
      match edit with
      | Some { edit_location; new_text } ->
          [
            ( "edit",
              `Assoc (span edit_location @ [ ("newText", `String new_text) ]) );
          ]
      | None -> [])
  in
  line output (Yojson.Safe.to_string obj)

(* Emit one diagnostic as a single [file:line:col: severity: message] line
   (gcc/rustc "short" style), for editors whose error parser is line-based
   (Vim's errorformat, Emacs Flymake, …). The column is 1-based, matching the
   human location line. A named warning's name is appended as [ [name]], as
   clang/eslint do. The message is flattened to one physical line. *)
let output_error_short ~output ~location ~severity ?warning msg =
  let one_line m =
    String.trim
      (String.map
         (fun c -> if c = '\n' then ' ' else c)
         (Message.to_plain_string m))
  in
  let sev =
    match severity with
    | Error -> "error"
    | Warning -> "warning"
    | Suggestion -> "suggestion"
  in
  let suffix =
    match warning with
    | Some w -> Printf.sprintf " [%s]" (Warning.name w)
    | None -> ""
  in
  let p = location.Ast.loc_start in
  if p = Lexing.dummy_pos then
    line output (Printf.sprintf "%s: %s%s" sev (one_line msg) suffix)
  else
    line output
      (Printf.sprintf "%s:%d:%d: %s: %s%s" p.Lexing.pos_fname p.Lexing.pos_lnum
         (p.Lexing.pos_cnum - p.Lexing.pos_bol + 1)
         sev (one_line msg) suffix)

let render_body ~theme p m = Message.render ~theme:theme.body p m

(* Lay out a headed diagnostic as a Printer [hvbox]: the styled header (emitted
   at its plain text's width — the colour is zero-width), a soft break, then the
   [body] emitter. A body that fits joins the header on one line; anything else
   (too wide, or containing a hard break) puts the header on its own line with
   the body under the box's 2-column hanging indent. The laid-out block is
   re-emitted through [line], keeping the flush-per-line granularity. *)
let headed sink ~header_plain ~header_styled body =
  let rendered =
    Printer.run_string (fun p ->
        Printer.hvbox p ~indent:2 (fun () ->
            Printer.string_as p (String.length header_plain) header_styled;
            Printer.space p ();
            body p))
  in
  List.iter (line sink) (String.split_on_char '\n' rendered)

let print_hint ?(output = channel_sink stderr) ~theme hint =
  match hint with
  | None -> ()
  | Some m ->
      headed output ~header_plain:"Hint:"
        ~header_styled:(with_style theme.hint_header "Hint" ^ ":")
        (fun p -> render_body ~theme p m)

(* Render a machine-applicable [edit] as a "help"-style line, describing the
   rewrite in prose (e.g. [Help: insert ';']). Only shown for an unnamed [Error]
   — i.e. a syntax error: it says what is wrong, not how to repair it, so the
   derived quick fix (a recovery insertion, see [Wax_wasm.Parsing]) is worth
   spelling out. A [Suggestion] or [Warning] carrying an edit — even one promoted
   to [Error] severity by [-W name=error], which is why the guard also checks
   [warning = None] — already states its fix in its own message (see [suggest_*]
   in typing.ml), so surfacing the raw edit text there would be redundant. The
   machine form travels in JSON for every severity regardless (see
   [output_error_json]). *)
let print_fix ?(output = channel_sink stderr) ~theme ~severity ?warning edit =
  match (severity, warning, edit) with
  | Error, None, Some { edit_location; new_text } ->
      let action =
        if
          edit_location.Ast.loc_start.Lexing.pos_cnum
          = edit_location.loc_end.Lexing.pos_cnum
        then Printf.sprintf "insert '%s'" new_text
        else if new_text = "" then "remove this"
        else Printf.sprintf "replace with '%s'" new_text
      in
      headed output ~header_plain:"Help:"
        ~header_styled:(with_style theme.hint_header "Help" ^ ":")
        (fun p -> Printer.string p action)
  | _ -> ()

let output_error_no_loc ?(output = channel_sink stderr) ~theme ~severity
    ?warning ~hint msg =
  (* A named warning's name is appended to the header as [ [name]], as in the
     "short" format and as clang/eslint do — including a warning promoted to
     [Error] severity by [-W name=error], which still carries its [warning]. *)
  let name_suffix =
    match warning with
    | Some w -> Printf.sprintf " [%s]" (Warning.name w)
    | None -> ""
  in
  let word, color =
    match severity with
    | Error -> ("Error", theme.error_header)
    | Warning -> ("Warning", theme.warning_header)
    | Suggestion -> ("Suggestion", theme.hint_header)
  in
  headed output
    ~header_plain:(word ^ name_suffix ^ ":")
    ~header_styled:(with_style color word ^ name_suffix ^ ":")
    (fun p -> render_body ~theme p msg);
  print_hint ~output ~theme hint

let output_error_no_source ?(output = channel_sink stderr) ~theme
    ~location:{ Ast.loc_start; loc_end } ~severity ?warning ?hint msg =
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
    line output
      (Printf.sprintf "File \"%s\", line %d, characters %d-%d:" filename
         start_line start_col end_col)
  else
    line output
      (Printf.sprintf
         "File \"%s\", line %d, character %d to line %d, character %d:" filename
         start_line start_col end_line end_col);
  output_error_no_loc ~output ~theme ~severity ?warning ~hint msg

type annotation = {
  start_line : int;
  end_line : int;
  start_col : int;
  end_col : int;
  color : string;
  label : Message.t option;
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
      | Suggestion -> theme.secondary_label
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
let line_starts_cache = ref ("", [||])

let get_line_starts source =
  let cached_source, cached_array = !line_starts_cache in
  if source == cached_source then cached_array
  else
    let len = String.length source in
    let starts = ref [ 0 ] in
    let i = ref 0 in
    while !i < len do
      match String.index_from source !i '\n' with
      | j ->
          starts := (j + 1) :: !starts;
          i := j + 1
      | exception Not_found -> i := len
    done;
    let array = Array.of_list (List.rev !starts) in
    line_starts_cache := (source, array);
    array

let output_error_with_source ?(output = channel_sink stderr) ~theme ~source
    ~location ~severity ?warning ?hint ?edit ?(related = []) msg =
  match !global_format with
  | Json ->
      output_error_json ~output ~location ~severity ?hint ~related ?edit msg
  | Short -> output_error_short ~output ~location ~severity msg
  | Human ->
      let annotations = get_annotations ~theme ~severity ~location ~related in
      let hunks = get_hunks annotations in
      let line_starts = get_line_starts source in
      let total_lines = Array.length line_starts in
      let max_hunk_line =
        List.fold_left (fun acc (_, e) -> max acc e) 0 hunks
      in
      let max_line = min max_hunk_line total_lines in
      let gutter_width = max 1 (String.length (string_of_int max_line)) in
      let gutter_padding = String.make gutter_width ' ' in
      let filename = location.Ast.loc_start.Lexing.pos_fname in
      let start_line = location.Ast.loc_start.Lexing.pos_lnum in
      let start_col =
        location.Ast.loc_start.Lexing.pos_cnum
        - location.Ast.loc_start.Lexing.pos_bol
      in
      output_error_no_loc ~output ~theme ~severity ?warning ~hint:None msg;
      if modern then
        line output
          (with_style theme.line_numbers (gutter_padding ^ "──➤")
          ^ Printf.sprintf "  %s:%d:%d" filename start_line (start_col + 1));
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
        line output
          (with_style theme.line_numbers (header ^ " " ^ gutter_char)
          ^ " " ^ contents)
      in
      let curr_pos = ref 0 in
      let curr_line = ref 1 in
      let seek line =
        if line <= total_lines then (
          curr_pos := line_starts.(line - 1);
          curr_line := line)
        else (
          curr_pos := String.length source;
          curr_line := total_lines + 1)
      in
      let total_hunks = List.length hunks in
      List.iteri
        (fun i (s_line, e_line) ->
          if i > 0 then
            line output
              (with_style theme.line_numbers (gutter_padding ^ " ·") ^ " ...");
          seek s_line;
          while !curr_line <= min e_line total_lines do
            let is_last_line =
              !curr_line = min e_line total_lines && i = total_hunks - 1
            in
            let raw_content, next_eol = get_line_info source !curr_pos in
            let display_content = Unicode.expand_tabs raw_content in
            print_line
              (Printf.sprintf "%*d" gutter_width !curr_line)
              display_content;
            let line_annotations =
              List.filter
                (fun a ->
                  !curr_line >= a.start_line && !curr_line <= a.end_line)
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
                    let start_col =
                      min (String.length raw_content) a.start_col
                    in
                    let end_col = min (String.length raw_content) a.end_col in
                    let prefix = String.sub raw_content 0 start_col in
                    let visual_start = Unicode.terminal_width prefix in
                    let len_bytes = max 0 (end_col - start_col) in
                    let part = String.sub raw_content start_col len_bytes in
                    (visual_start, Unicode.terminal_width part)
                  else if is_start then
                    let start_col =
                      min (String.length raw_content) a.start_col
                    in
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
                let underline =
                  with_style a.color (String.make (max 1 visual_len) '^')
                in
                let label =
                  match a.label with
                  | Some m when is_end ->
                      (* Labels are short; render flattened (no colour of their
                         own) so they sit on the caret's line in the caret
                         colour, not nested inside body ANSI. *)
                      " " ^ with_style a.color (Message.to_plain_string m)
                  | _ -> ""
                in
                print_line ~gutter_char gutter_padding
                  (String.make visual_start ' ' ^ underline ^ label))
              line_annotations;
            curr_pos := min (String.length source) (next_eol + 1);
            incr curr_line
          done)
        hunks;
      print_hint ~output ~theme hint;
      print_fix ~output ~theme ~severity ?warning edit

let output_error ?(output = channel_sink stderr) ~theme ~source ~location
    ~severity ?warning ?hint ?edit ?(related = []) msg =
  match !global_format with
  | Json ->
      output_error_json ~output ~location ~severity ?warning ?hint ~related
        ?edit msg
  | Short -> output_error_short ~output ~location ~severity ?warning msg
  | Human -> (
      if location.Ast.loc_start = Lexing.dummy_pos then
        output_error_no_loc ~output ~theme ~severity ?warning ~hint msg
      else
        match source with
        | None ->
            output_error_no_source ~output ~theme ~location ~severity ?warning
              ?hint msg
        | Some source ->
            output_error_with_source ~output ~theme ~source ~location ~severity
              ?warning ?hint ?edit ~related msg)

(* Where and how a context renders. Held only by a rendering context; a
   [collector] has none — it merely accumulates entries (see [collected]) for a
   rendering context to re-report, so it needs no theme or output at all. *)
type render = { theme : theme; output : sink; exit_on_error : bool }

type context = {
  max : int;
  queue : t Queue.t;
  source : string option;
  related : label list;
  policy : Warning.policy;
      (* The level — hidden, displayed, or error — of each named warning. *)
  render : render option;
      (* [None] in a collecting context: it buffers every reported entry (errors
         and warnings alike, with [policy] unapplied) for [collected] to read
         back and re-report to a rendering context. [Some] otherwise: warnings
         are resolved against [policy] and printed immediately, and errors are
         queued and flushed (see [output_errors]) once [max] accumulate. *)
  mutable recovery : bool;
      (* Error-recovery mode: the input had syntax errors and a best-effort AST
         was recovered past them (see [Wax_wasm.Parsing.parse_recover]). Name
         resolution is then unreliable — a construct dropped at a sync boundary
         leaves its bindings absent — so the "not bound" diagnostics are
         suppressed (see [unbound_name] in lib-wax/typing.ml) as likely cascades
         while genuine type errors in the intact regions still surface. Set by
         the caller before type-checking a recovered module. *)
}

(* The default warning policy, set once from the command line (mirroring
   [Wax_wasm.Validation.validate_refs]). [make]'s [policy] defaults to it, so every
   context picks it up without threading the policy through each call site; an
   explicit [?policy] still overrides it. *)
let global_policy = ref Warning.default_policy
let set_policy policy = global_policy := policy
let source context = context.source

let make ~source ?(related = []) ?(max = 1) ?(policy = !global_policy) ?render
    () =
  {
    max;
    queue = Queue.create ();
    source;
    related;
    policy;
    render;
    recovery = false;
  }

(* A context that accumulates errors in its queue without ever printing or
   exiting, so they can be inspected with [collected]. It has no rendering
   config ([render = None]) — nothing is printed — but [source] is still worth
   threading: a lint that inspects the original text via {!source} (e.g. the
   [precedence] lint) runs against this context and needs it. *)
let collector ?parent ?source () =
  let c = make ~source ~max:max_int () in
  (* A collector created to check part of a larger run inherits the parent's
     error-recovery mode, so the [unbound_name] cascade suppression carries into
     it — e.g. the per-configuration sub-contexts of the path-sensitive checker
     (see [Cond_explore.check_all]). Inheriting it here, rather than at each call
     site, keeps the propagation correct as more recovery-sensitive state is
     added. *)
  Option.iter (fun p -> c.recovery <- p.recovery) parent;
  c

let in_recovery context = context.recovery
let set_recovery context v = context.recovery <- v

type entry = t

let collected context = List.of_seq (Queue.to_seq context.queue)
let entry_location (e : entry) = e.location
let entry_severity (e : entry) = e.severity
let entry_warning (e : entry) = e.warning
let entry_universal (e : entry) = e.universal
let entry_message (e : entry) = e.message
let entry_hint (e : entry) = e.hint
let entry_edit (e : entry) = e.edit
let entry_related (e : entry) = e.related

let output_errors ?exit_on_error context =
  match context.render with
  | None ->
      () (* a collector renders nothing; use [collected] to read entries *)
  | Some render ->
      let exit_on_error =
        match exit_on_error with Some b -> b | None -> render.exit_on_error
      in
      if not (Queue.is_empty context.queue) then (
        Queue.iter
          (fun ({
                  location;
                  severity;
                  hint;
                  message;
                  related;
                  warning;
                  edit;
                  universal = _;
                } :
                 t) ->
            output_error ~output:render.output ~theme:render.theme
              ~source:context.source ~location ~severity ?warning ?hint ?edit
              ~related message)
          context.queue;
        Queue.clear context.queue;
        if exit_on_error then (
          (* [Format.err_formatter]'s at-exit flush used to cover this; make it
             explicit now that the sink is a plain channel. *)
          render.output.flush ();
          exit 128))

let report context ~location ~severity ?warning ?(universal = false) ?hint ?edit
    ?(related = []) ~message () =
  let all_related = context.related @ related in
  let entry severity =
    {
      location;
      severity;
      warning;
      message;
      hint;
      edit;
      related = all_related;
      universal;
    }
  in
  match context.render with
  | None ->
      (* A collecting context buffers everything raw (with its [edit], so
         [collected] can surface it); the policy is applied later, when the
         buffered entries are re-reported to a rendering context. *)
      Queue.push (entry severity) context.queue
  | Some render -> (
      (* Resolve a named warning's (or suggestion's) level now: hide it, leave
         it as-is, or promote it to an error. A displayed suggestion stays a
         [Suggestion]. *)
      let severity =
        match (severity, warning) with
        | (Warning | Suggestion), Some w -> (
            match Warning.resolve context.policy w with
            | Warning.Hidden -> None
            | Warning.Displayed -> Some severity
            | Warning.Error -> Some Error)
        | _ -> Some severity
      in
      match severity with
      | None -> ()
      | Some ((Warning | Suggestion) as severity) ->
          output_error ~output:render.output ~theme:render.theme
            ~source:context.source ~location ~severity ?warning ?hint ?edit
            ~related:all_related message
      | Some Error ->
          Queue.push (entry Error) context.queue;
          if Queue.length context.queue = context.max then output_errors context
      )

exception Aborted

let abort () = raise Aborted

let run ~color ~palette ~source ?related ?(exit = true) ?output ?policy f =
  let render =
    {
      theme = get_theme ~color ~palette ();
      output = Option.value output ~default:(channel_sink stderr);
      exit_on_error = exit;
    }
  in
  let d = make ~source ?related ?policy ~render () in
  match f d with
  | res ->
      output_errors d;
      res
  | exception Aborted ->
      (* Flush the queued diagnostics (which exits the process when
         [exit_on_error]); only re-raised in a non-exiting context. *)
      output_errors d;
      raise Aborted

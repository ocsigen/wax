(* The pretty-printer has two interchangeable engines behind one API:

   - [Fmt]: the original engine built on OCaml's [Format]. Kept verbatim.
   - [Doc]: a self-contained document-IR engine. It builds a tree of text and
     breaks via the same imperative API, then renders it with its own layout
     algorithm — giving genuine hard breaks (no [pp_print_break 1000] hack),
     column awareness, and break coalescing we control.

   The engine is chosen once per [run] from the [WAX_PRINTER] environment
   variable (default: the Format engine). Call sites are unaware of the choice. *)

type break_strength = No_break | Cut | Space | Newline | Blank_line

let strength = function
  | No_break -> 0
  | Cut -> 1
  | Space -> 2
  | Newline -> 3
  | Blank_line -> 4

let debug = false

(* ===================================================================== *)
(* Format engine (original implementation, unchanged behaviour)          *)
(* ===================================================================== *)

module Fmt = struct
  type state = {
    fmt : Format.formatter;
    mutable started : bool;
    mutable pending_break : break_strength;
    mutable has_emitted : bool;
        (* Any output has been generated on the current line *)
    mutable indent : int; (* Current indentation level (for breaks) *)
    mutable indent_stack : int list;
    mutable pending_eol : (unit -> unit) option;
        (* A trailing line comment to emit at the end of the current line,
           after any list separator that follows it (see [defer_eol]). *)
    mutable holding_eol : bool;
        (* While set, a pending end-of-line comment is not flushed before the
           next token, so a list separator can be printed on the comment's
           line. *)
  }

  let create fmt =
    {
      fmt;
      started = false;
      pending_break = No_break;
      has_emitted = false;
      indent = 0;
      indent_stack = [];
      pending_eol = None;
      holding_eol = false;
    }

  let indent ctx indent f =
    let prev_indent = ctx.indent in
    ctx.indent <- indent;
    f ();
    ctx.indent <- prev_indent

  let flush ?(skip_space = false) ctx =
    (match ctx.pending_break with
    | No_break -> ()
    | Cut ->
        if not skip_space then (
          if debug then prerr_endline "CUT";
          Format.pp_print_cut ctx.fmt ())
    | Space ->
        if not skip_space then (
          if debug then prerr_endline "SPACE";
          Format.pp_print_break ctx.fmt 1 ctx.indent)
    | Newline ->
        if debug then prerr_endline "NEWLINE";
        if ctx.started then Format.pp_print_break ctx.fmt 1000 ctx.indent
    | Blank_line ->
        if debug then prerr_endline "BLANK LINE";
        if ctx.started then Format.pp_print_as ctx.fmt 0 "\n";
        Format.pp_print_break ctx.fmt 1000 ctx.indent);
    ctx.pending_break <- No_break

  let force_eol ctx =
    match ctx.pending_eol with
    | None -> ()
    | Some emit ->
        ctx.pending_eol <- None;
        ctx.pending_break <- No_break;
        emit ();
        if ctx.started then Format.pp_print_break ctx.fmt 1000 ctx.indent;
        ctx.pending_break <- No_break;
        ctx.has_emitted <- false

  let defer_eol ctx emit =
    force_eol ctx;
    ctx.pending_eol <- Some emit

  let string ctx s =
    if not ctx.holding_eol then force_eol ctx;
    flush ctx;
    if debug then Format.eprintf "STRING %s@." s;
    ctx.started <- true;
    ctx.has_emitted <- true;
    Format.pp_print_string ctx.fmt s

  let string_as ctx len s =
    if not ctx.holding_eol then force_eol ctx;
    flush ctx;
    if debug then Format.eprintf "STRING %s@." s;
    ctx.started <- true;
    ctx.has_emitted <- true;
    Format.pp_print_as ctx.fmt len s

  let with_held_eol ctx f =
    let prev = ctx.holding_eol in
    ctx.holding_eol <- true;
    f ();
    ctx.holding_eol <- prev

  let register_break ctx s =
    if strength s > strength ctx.pending_break then ctx.pending_break <- s

  let space ctx = if ctx.has_emitted then register_break ctx Space
  let newline ctx = register_break ctx Newline
  let blank_line ctx = register_break ctx Blank_line
  let cut ctx = register_break ctx Cut

  let generic_box ~name pp_open_box ctx skip_space indent f =
    if not ctx.holding_eol then force_eol ctx;
    flush ~skip_space ctx;
    if debug then Format.eprintf "OPEN %s@." name;
    pp_open_box ctx.fmt indent;
    ctx.indent_stack <- ctx.indent :: ctx.indent_stack;
    ctx.indent <- 0;
    f ();
    (* We don't flush spaces/newlines here, so that they are moved
         outside of the box *)
    if debug then prerr_endline "CLOSE";
    Format.pp_close_box ctx.fmt ();
    match ctx.indent_stack with
    | [] -> assert false (* Should not happen if boxes are balanced *)
    | h :: t ->
        ctx.indent <- h;
        ctx.indent_stack <- t

  let box ctx ~skip_space ~indent f =
    generic_box ~name:"BOX" Format.pp_open_box ctx skip_space indent f

  let hvbox ctx ~skip_space ~indent f =
    generic_box ~name:"HVBOX" Format.pp_open_hvbox ctx skip_space indent f

  let hbox ctx ~skip_space f =
    generic_box ~name:"HBOX"
      (fun fmt _ -> Format.pp_open_hbox fmt ())
      ctx skip_space 0 f

  let hovbox ctx ~skip_space ~indent f =
    generic_box ~name:"HOVBOX" Format.pp_open_hovbox ctx skip_space indent f

  let vbox ctx ~skip_space ~indent f =
    generic_box ~name:"VBOX" Format.pp_open_vbox ctx skip_space indent f

  let finish ctx =
    force_eol ctx;
    flush ctx
end

(* ===================================================================== *)
(* Doc engine (document IR + imperative builder + renderer)              *)
(* ===================================================================== *)

module Doc = struct
  type gkind =
    | GBox (* fill: each soft break wraps independently as needed *)
    | GHov (* same fill semantics, kept distinct for parity with Format *)
    | GHv (* all-or-nothing: whole group flat, or every soft break wraps *)
    | GV (* every soft break wraps *)
    | GH (* soft breaks never wrap (hard/blank still break) *)

  (* A break carries one [break_strength] (No_break unused). Cut/Space are soft
     (flatten in a fitting group); Newline/Blank_line always break. *)
  type doc =
    | Empty
    | Text of int * string (* display width, payload *)
    | Brk of break_strength
    | Cat of doc * doc
    | Nest of int * doc
    | Group of gkind * doc

  type frame = { wrap : doc -> doc; mutable items : doc list (* reversed *) }

  type state = {
    fmt : Format.formatter;
    width : int;
    mutable stack : frame list;
    mutable has_emitted : bool; (* content since last forced end-of-line *)
    mutable pending_eol : (unit -> unit) option;
    mutable holding_eol : bool;
  }

  let create fmt ~width =
    {
      fmt;
      width;
      stack = [ { wrap = (fun d -> d); items = [] } ];
      has_emitted = false;
      pending_eol = None;
      holding_eol = false;
    }

  let top st = List.hd st.stack

  (* Append, coalescing a break that immediately follows another break (within
     this frame) into the stronger of the two — the analogue of the Format
     engine's [register_break]. Cross-frame coalescing is the renderer's job. *)
  let append st d =
    let fr = top st in
    match (d, fr.items) with
    | Brk s2, Brk s1 :: tl ->
        fr.items <- Brk (if strength s2 >= strength s1 then s2 else s1) :: tl
    | _ -> fr.items <- d :: fr.items

  let push st wrap = st.stack <- { wrap; items = [] } :: st.stack

  let pop st =
    match st.stack with
    | fr :: rest ->
        (* items are most-recent-first; fold_left rebuilds source order. *)
        let body = List.fold_left (fun acc d -> Cat (d, acc)) Empty fr.items in
        st.stack <- rest;
        append st (fr.wrap body)
    | [] -> assert false

  (* Drop a trailing soft/hard break at this frame's head: the analogue of
     [pending_break <- No_break] when draining a deferred end-of-line comment. *)
  let drop_trailing_break st =
    let fr = top st in
    match fr.items with Brk _ :: tl -> fr.items <- tl | _ -> ()

  let force_eol st =
    match st.pending_eol with
    | None -> ()
    | Some emit ->
        st.pending_eol <- None;
        drop_trailing_break st;
        emit ();
        append st (Brk Newline);
        st.has_emitted <- false

  let defer_eol st emit =
    force_eol st;
    st.pending_eol <- Some emit

  let with_held_eol st f =
    let prev = st.holding_eol in
    st.holding_eol <- true;
    f ();
    st.holding_eol <- prev

  let text st len s =
    if not st.holding_eol then force_eol st;
    st.has_emitted <- true;
    append st (Text (len, s))

  let string st s = text st (String.length s) s
  let string_as st len s = text st len s
  let space st = if st.has_emitted then append st (Brk Space)
  let cut st = append st (Brk Cut)
  let newline st = append st (Brk Newline)
  let blank_line st = append st (Brk Blank_line)

  let indent st n f =
    push st (fun d -> Nest (n, d));
    f ();
    pop st

  let group_wrap kind indent d =
    Group (kind, if indent = 0 then d else Nest (indent, d))

  let scoped st kind ~skip_space ~indent f =
    if not st.holding_eol then force_eol st;
    (if skip_space then
       let fr = top st in
       match fr.items with Brk (Cut | Space) :: tl -> fr.items <- tl | _ -> ());
    push st (group_wrap kind indent);
    f ();
    pop st

  let box st ~skip_space ~indent f = scoped st GBox ~skip_space ~indent f
  let hvbox st ~skip_space ~indent f = scoped st GHv ~skip_space ~indent f
  let hovbox st ~skip_space ~indent f = scoped st GHov ~skip_space ~indent f
  let vbox st ~skip_space ~indent f = scoped st GV ~skip_space ~indent f
  let hbox st ~skip_space f = scoped st GH ~skip_space ~indent:0 f

  (* --- renderer --- *)

  type mode = Flat | Brkm | Fill

  (* Does the upcoming content fit in [avail] columns up to the next line break?
     Trailing context is included (the worklist [rest] beyond the immediate
     item), so a group is laid flat only when what follows it on the line also
     fits — matching Format, not a local "does this group alone fit" check.

     A break decides line-end based on the carried mode: a break in a breaking
     context ([Brkm]/[Fill]) ends the line, so we have fit so far ([true]); a
     break in [Flat] is the flat-spacing of a unit being measured. Groups are
     always entered [Flat] — measured as atomic units — so a group that cannot
     be flat (a hard break inside) forces the preceding break to break. *)
  let rec fits avail items =
    if avail < 0 then false
    else
      match items with
      | [] -> true
      | (i, m, d) :: rest -> (
          match d with
          | Empty -> fits avail rest
          | Text (w, _) -> fits (avail - w) rest
          | Cat (a, b) -> fits avail ((i, m, a) :: (i, m, b) :: rest)
          | Nest (n, d) -> fits avail ((i + n, m, d) :: rest)
          | Group (_, d) -> fits avail ((i, Flat, d) :: rest)
          | Brk b -> (
              match m with
              | Brkm | Fill -> true
              | Flat -> (
                  match b with
                  | Newline | Blank_line -> false
                  | Space -> fits (avail - 1) rest
                  | No_break | Cut -> fits avail rest)))

  let render ~width doc =
    let b = Buffer.create 4096 in
    let col = ref 0 in
    let emitted = ref false in
    (* A pending line break (indent + blank?) and/or a pending flat separator.
       Deferred until the next text and coalesced — across group boundaries —
       by max strength; a line break supersedes a flat separator. *)
    let pend_line = ref None in
    let pend_flat = ref None in
    let flush () =
      (match !pend_line with
      | Some (ind, blank) ->
          (* Suppress a leading break before any output, like [if started]. *)
          if !emitted then (
            Buffer.add_char b '\n';
            if blank then Buffer.add_char b '\n';
            Buffer.add_string b (String.make ind ' ');
            col := ind)
      | None -> (
          match !pend_flat with
          | Some s when strength s >= strength Space ->
              Buffer.add_char b ' ';
              incr col
          | _ -> ()));
      pend_line := None;
      pend_flat := None
    in
    let break_line ind blank =
      (match !pend_line with
      | Some (_, b0) -> pend_line := Some (ind, b0 || blank)
      | None -> pend_line := Some (ind, blank));
      pend_flat := None
    in
    let flat_sep s =
      if !pend_line = None then
        pend_flat :=
          Some
            (match !pend_flat with
            | Some s0 -> if strength s >= strength s0 then s else s0
            | None -> s)
    in
    let eff_col () =
      match !pend_line with
      | Some (ind, _) -> ind
      | None -> !col + if !pend_flat <> None then 1 else 0
    in
    let rec go = function
      | [] -> () (* drop any trailing pending break: no trailing whitespace *)
      | (i, m, d) :: rest -> (
          match d with
          | Empty -> go rest
          | Text (w, s) ->
              flush ();
              Buffer.add_string b s;
              emitted := true;
              col := !col + w;
              go rest
          | Cat (a, c) -> go ((i, m, a) :: (i, m, c) :: rest)
          | Nest (n, d) -> go ((i + n, m, d) :: rest)
          | Group (k, d) ->
              (* A box's break-indentation is measured from the column where the
                 box opens (Format semantics), not from the inherited nesting —
                 they differ when a box starts mid-line (e.g. a WAT s-expression
                 after its [(]). Rebase the group's indent to the open column. *)
              let base = eff_col () in
              let m' =
                match k with
                | GV -> Brkm
                | GH -> Flat
                | GHv ->
                    if fits (width - base) ((base, Flat, d) :: rest) then Flat
                    else Brkm
                | GBox | GHov -> Fill
              in
              go ((base, m', d) :: rest)
          | Brk str ->
              (match (str, m) with
              | No_break, _ -> ()
              | Newline, _ -> break_line i false
              | Blank_line, _ -> break_line i true
              | (Cut | Space), Flat -> flat_sep str
              | (Cut | Space), Brkm -> break_line i false
              | (Cut | Space), Fill ->
                  (* If kept flat this separator itself occupies a column, so
                     the following content starts one column further right;
                     account for it or a unit that just fits would overflow. *)
                  let sep = match str with Space -> 1 | _ -> 0 in
                  if fits (width - eff_col () - sep) rest then flat_sep str
                  else break_line i false);
              go rest)
    in
    go [ (0, Brkm, doc) ];
    Buffer.contents b

  let finish st =
    force_eol st;
    let body =
      List.fold_left (fun acc d -> Cat (d, acc)) Empty (top st).items
    in
    let s = render ~width:st.width body in
    Format.pp_print_string st.fmt s
end

(* ===================================================================== *)
(* Public API: dispatch on the selected engine                          *)
(* ===================================================================== *)

type t = Fmt_engine of Fmt.state | Doc_engine of Doc.state

let indent t n f =
  match t with
  | Fmt_engine s -> Fmt.indent s n f
  | Doc_engine s -> Doc.indent s n f

let string t s =
  match t with Fmt_engine c -> Fmt.string c s | Doc_engine c -> Doc.string c s

let string_as t len s =
  match t with
  | Fmt_engine c -> Fmt.string_as c len s
  | Doc_engine c -> Doc.string_as c len s

let space t () =
  match t with Fmt_engine c -> Fmt.space c | Doc_engine c -> Doc.space c

let cut t () =
  match t with Fmt_engine c -> Fmt.cut c | Doc_engine c -> Doc.cut c

let newline t () =
  match t with Fmt_engine c -> Fmt.newline c | Doc_engine c -> Doc.newline c

let blank_line t () =
  match t with
  | Fmt_engine c -> Fmt.blank_line c
  | Doc_engine c -> Doc.blank_line c

let defer_eol t emit =
  match t with
  | Fmt_engine c -> Fmt.defer_eol c emit
  | Doc_engine c -> Doc.defer_eol c emit

let with_held_eol t f =
  match t with
  | Fmt_engine c -> Fmt.with_held_eol c f
  | Doc_engine c -> Doc.with_held_eol c f

let box t ?(skip_space = false) ?(indent = 0) f =
  match t with
  | Fmt_engine c -> Fmt.box c ~skip_space ~indent f
  | Doc_engine c -> Doc.box c ~skip_space ~indent f

let hvbox t ?(skip_space = false) ?(indent = 0) f =
  match t with
  | Fmt_engine c -> Fmt.hvbox c ~skip_space ~indent f
  | Doc_engine c -> Doc.hvbox c ~skip_space ~indent f

let hbox t ?(skip_space = false) f =
  match t with
  | Fmt_engine c -> Fmt.hbox c ~skip_space f
  | Doc_engine c -> Doc.hbox c ~skip_space f

let hovbox t ?(skip_space = false) ?(indent = 0) f =
  match t with
  | Fmt_engine c -> Fmt.hovbox c ~skip_space ~indent f
  | Doc_engine c -> Doc.hovbox c ~skip_space ~indent f

let vbox t ?(skip_space = false) ?(indent = 0) f =
  match t with
  | Fmt_engine c -> Fmt.vbox c ~skip_space ~indent f
  | Doc_engine c -> Doc.vbox c ~skip_space ~indent f

let run ?(width = 78) fmt f =
  match Sys.getenv_opt "WAX_PRINTER" with
  | Some "format" ->
      let c = Fmt.create fmt in
      f (Fmt_engine c);
      Fmt.finish c
  | _ ->
      let c = Doc.create fmt ~width in
      f (Doc_engine c);
      Doc.finish c

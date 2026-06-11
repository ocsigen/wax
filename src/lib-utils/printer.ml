(* A document-IR pretty-printer. The imperative builder API (string, space,
   box, …) records a tree of text and breaks; [run] then renders it with our
   own layout algorithm, which gives genuine hard breaks, column awareness and
   break coalescing we control — unlike a thin layer over OCaml's [Format]. *)

type break_strength = Cut | Space | Newline | Blank_line

let strength = function Cut -> 0 | Space -> 1 | Newline -> 2 | Blank_line -> 3

(* ===================================================================== *)
(* Document IR + imperative builder + renderer                           *)
(* ===================================================================== *)

module Doc = struct
  type gkind =
    | GBox (* fill: each soft break wraps independently as needed *)
    | GHov (* same fill semantics, kept distinct for parity with Format *)
    | GHv (* all-or-nothing: whole group flat, or every soft break wraps *)
    | GV (* every soft break wraps *)
    | GH (* soft breaks never wrap (hard/blank still break) *)

  (* A break carries one [break_strength]: Cut/Space are soft (flatten in a
     fitting group); Newline/Blank_line always break. *)
  type doc =
    | Empty
    | Text of int * string (* display width, payload *)
    | Brk of break_strength
    | Cat of doc * doc
    | Nest of int * doc
    | Group of gkind * doc
    | If_broken of doc
  (* Emit [doc] only when the enclosing group is laid out broken (not flat): a
     trailing comma after the last element of a list that wraps. It never counts
     toward the fit decision (a flat list has no trailing comma). *)

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

  (* Drop a trailing break at this frame's head, so a deferred end-of-line
     comment hugs the preceding token instead of being pushed past a break. *)
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

  let has_pending_eol st = st.pending_eol <> None

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

  let if_broken st f =
    push st (fun d -> If_broken d);
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
          | If_broken _ -> fits avail rest
          (* A trailing comma never counts toward the fit: a flat list omits it
             outright, and when measured inside an already-broken list a break
             has ended the line before reaching it. *)
          | Brk b -> (
              match m with
              | Brkm | Fill -> true
              | Flat -> (
                  match b with
                  | Newline | Blank_line -> false
                  | Space -> fits (avail - 1) rest
                  | Cut -> fits avail rest)))

  let render ~width doc =
    let b = Buffer.create 4096 in
    let col = ref 0 in
    let emitted = ref false in
    (* Cap how far breaks indent, so deeply nested code does not march off to
       the right margin (the analogue of Format's [max_indent]); deeper levels
       then pile up at the cap rather than each pushing further right. *)
    let max_indent = max 0 (width - 10) in
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
      let ind = min ind max_indent in
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
          | If_broken d ->
              (* Shown only when the surrounding all-or-nothing box broke
                 ([Brkm]); a one-line ([Flat]) or greedily-packed ([Fill]) list
                 has no trailing comma. *)
              go (match m with Brkm -> (i, m, d) :: rest | _ -> rest)
          | Brk str ->
              (match (str, m) with
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
    (* Emit line by line through the formatter's own newline, so that when [run]
       is called inside an enclosing Format box (e.g. an [@[<2>…@]] wrapping the
       snippet), every line — not just the first — picks up that box's
       indentation. A bare [pp_print_string] of the multi-line string would
       leave the embedded newlines at column 0. *)
    match String.split_on_char '\n' s with
    | [] -> ()
    | first :: rest ->
        Format.pp_print_string st.fmt first;
        List.iter
          (fun line ->
            Format.pp_force_newline st.fmt ();
            Format.pp_print_string st.fmt line)
          rest
end

(* ===================================================================== *)
(* Public API                                                            *)
(* ===================================================================== *)

type t = Doc.state

let indent = Doc.indent
let string = Doc.string
let string_as = Doc.string_as
let space t () = Doc.space t
let cut t () = Doc.cut t
let newline t () = Doc.newline t
let blank_line t () = Doc.blank_line t
let defer_eol = Doc.defer_eol
let with_held_eol = Doc.with_held_eol
let has_pending_eol = Doc.has_pending_eol
let if_broken = Doc.if_broken

let box t ?(skip_space = false) ?(indent = 0) f =
  Doc.box t ~skip_space ~indent f

let hvbox t ?(skip_space = false) ?(indent = 0) f =
  Doc.hvbox t ~skip_space ~indent f

let hbox t ?(skip_space = false) f = Doc.hbox t ~skip_space f

let hovbox t ?(skip_space = false) ?(indent = 0) f =
  Doc.hovbox t ~skip_space ~indent f

let vbox t ?(skip_space = false) ?(indent = 0) f =
  Doc.vbox t ~skip_space ~indent f

let run ?(width = 78) fmt f =
  let c = Doc.create fmt ~width in
  f c;
  Doc.finish c

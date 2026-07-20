(* A streaming pretty-printer. The imperative builder API (string, space, box, …)
   emits a flat token stream straight into a layout engine; nothing is ever
   materialized as a document tree. The engine gives genuine hard breaks, column
   awareness and break coalescing we control — unlike a thin layer over OCaml's
   [Format] — with bounded memory (the engine buffers only the ~[width] of
   lookahead a break/group decision needs). *)

type break_strength = Cut | Space | Newline | Blank_line

let strength = function Cut -> 0 | Space -> 1 | Newline -> 2 | Blank_line -> 3

(* ===================================================================== *)
(* Token stream + layout engine + imperative builder                     *)
(* ===================================================================== *)

module Doc = struct
  type gkind =
    | GBox (* fill: each soft break wraps independently as needed *)
    | GHov (* same fill semantics, kept distinct for parity with Format *)
    | GHv (* all-or-nothing: whole group flat, or every soft break wraps *)
    | GV (* every soft break wraps *)
    | GH (* soft breaks never wrap (hard/blank still break) *)

  (* --- token stream (the builder's output, the engine's input) --- *)

  (* The document is streamed as a flat token sequence. A group / nest /
     if-broken opens with its own token and closes with a matching [TEnd]. A
     [TBreak] carries one [break_strength]: Cut/Space are soft (flatten in a
     fitting group); Newline/Blank_line always break. *)
  type token =
    | TText of int * string (* display width, payload *)
    | TBreak of break_strength
    | TBegin of gkind
    | TNest of int
    | TIfBroken
      (* Content emitted only when the enclosing group is laid out broken (a
           trailing comma after the last element of a list that wraps). It never
           counts toward the fit decision. *)
    | TEnd

  (* --- layout engine --- *)

  type mode = Flat | Brkm | Fill

  (* A live layout frame — the streaming analogue of the old tree renderer's
     per-worklist-item [(indent, mode)] pair. *)
  type eframe = { findent : int; fmode : mode }

  (* The outcome of a fit scan. Nullary (so returning it never allocates): the
     scan parks its resumable state in [scan_state], not a boxed payload. *)
  type sres = Fits | Nofit | Susp

  (* A front decision whose fit scan ran out of buffered input and suspended,
     resumed on the next [feed] so each buffered token is scanned once. One
     record, mutated in place — no per-suspend allocation. [active] flags a live
     suspension; [ghv] distinguishes a [GHv] open (uses [base]) from a [Fill]
     break (uses [str]); the rest are the parked [scan_go] loop variables. *)
  type scan_state = {
    mutable active : bool;
    mutable ghv : bool;
    mutable base : int;
    mutable str : break_strength;
    mutable avail : int;
    mutable sstack : mode list;
    mutable fr : eframe list;
    mutable ib : int;
    mutable i : int;
  }

  (* A stateful token consumer with bounded lookahead. A decision that needs to
     look ahead ([GHv] open, [Fill] break) waits until enough tokens are buffered
     in [queue] to resolve it; because [scan] short-circuits once the available
     column is exhausted, the FIFO stays bounded by ~[width]. Everything else is
     laid out immediately. Returns [(feed, finish)]: [feed] pushes one token,
     [finish] signals end of input (and drains the tail). *)
  let make_engine ~width ~add_string ~add_char ~add_substring =
    let col = ref 0 in
    let emitted = ref false in
    (* Cap how far breaks indent, so deeply nested code does not march off to the
       right margin (the analogue of Format's [max_indent]). *)
    let max_indent = max 0 (width - 10) in
    (* A break's indentation is always [<= max_indent] (see [break_line]), so one
       string of that many spaces covers every indent: emit a slice of it. *)
    let spaces = String.make max_indent ' ' in
    (* A pending line break (indent + blank?) and/or a pending flat separator,
       deferred until the next text and coalesced — across group boundaries — by
       max strength; a line break supersedes a flat separator. *)
    let pend_line = ref None in
    let pend_flat = ref None in
    let frames = ref [ { findent = 0; fmode = Brkm } ] in
    let cur () = List.hd !frames in
    (* The pending-token FIFO: a growable ring buffer, so [scan] can index the
       lookahead without allocating (a [Queue]+[Seq] scan allocated a node per
       token scanned, on every re-scan). [qn] tokens live at [qhd .. qhd+qn) mod
       capacity. *)
    (* Capacity is always a power of two, so index wrap-around is [land mask]
       (cheaper than [mod]); [qmask] is [capacity - 1]. *)
    let qbuf = ref (Array.make 32 TEnd) in
    let qmask = ref 31 in
    let qhd = ref 0 in
    let qn = ref 0 in
    let qget i = !qbuf.((!qhd + i) land !qmask) in
    let qpush x =
      if !qn = Array.length !qbuf then (
        let old = !qbuf and omask = !qmask and ohd = !qhd in
        let ncap = 2 * Array.length old in
        let nb = Array.make ncap TEnd in
        for i = 0 to !qn - 1 do
          nb.(i) <- old.((ohd + i) land omask)
        done;
        qbuf := nb;
        qmask := ncap - 1;
        qhd := 0);
      !qbuf.((!qhd + !qn) land !qmask) <- x;
      incr qn
    in
    let qpop () =
      let x = !qbuf.(!qhd) in
      qhd := (!qhd + 1) land !qmask;
      decr qn;
      x
    in
    (* >0 while dropping the content of an [if_broken] whose enclosing group is
       not broken (the trailing comma of a flat list). *)
    let skip_depth = ref 0 in
    (* The suspended-scan state (see [scan_state]). *)
    let sc =
      {
        active = false;
        ghv = false;
        base = 0;
        str = Space;
        avail = 0;
        sstack = [];
        fr = [];
        ib = 0;
        i = 0;
      }
    in
    let scan_at_end = ref false in
    let flush () =
      (match !pend_line with
      | Some (ind, blank) ->
          (* Suppress a leading break before any output, like [if started]. *)
          if !emitted then (
            add_char '\n';
            if blank then add_char '\n';
            add_substring spaces 0 ind;
            col := ind)
      | None -> (
          match !pend_flat with
          | Some s when strength s >= strength Space ->
              add_char ' ';
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
    (* Does the content fit in [avail] columns up to the next line-ending break?
       Trailing context beyond the immediate group is included (matching the old
       tree renderer's [fits], not a local "does this group alone fit" check).
       [sstack] is the mode stack of groups entered during the scan (innermost
       first), all [Flat]; beneath them [fr] is the enclosing frame stack, read
       directly (no copy). The current mode is the head of [sstack], else the
       innermost [fr]; a break there ends the line iff that mode is breaking
       ([Brkm]/[Fill]). [i] indexes the lookahead in the ring buffer. Returns
       [Ok] once decided ([false] when [avail] is exhausted, [true] at the first
       line-ending break); [Error] with the state to resume from when the buffer
       runs out before deciding (unless [!scan_at_end]). *)
    let rec scan_go avail sstack fr ib i =
      if avail < 0 then Nofit
      else if i >= !qn then
        if !scan_at_end then Fits
        else (
          (* out of buffered input: park the loop state for the next [feed] *)
          sc.avail <- avail;
          sc.sstack <- sstack;
          sc.fr <- fr;
          sc.ib <- ib;
          sc.i <- i;
          Susp)
      else
        let tok = qget i in
        if ib > 0 then
          (* dropping if_broken content: measure nothing *)
          let ib =
            match tok with
            | TBegin _ | TNest _ | TIfBroken -> ib + 1
            | TEnd -> ib - 1
            | _ -> ib
          in
          scan_go avail sstack fr ib (i + 1)
        else
          match tok with
          | TText (w, _) -> scan_go (avail - w) sstack fr ib (i + 1)
          | TBegin _ -> scan_go avail (Flat :: sstack) fr ib (i + 1)
          | TNest _ ->
              (* the current mode (head of [sstack], else innermost [fr]) *)
              let m =
                match sstack with
                | m :: _ -> m
                | [] -> ( match fr with f :: _ -> f.fmode | [] -> Brkm)
              in
              scan_go avail (m :: sstack) fr ib (i + 1)
          | TIfBroken -> scan_go avail sstack fr 1 (i + 1)
          | TEnd -> (
              match sstack with
              | _ :: tl -> scan_go avail tl fr ib (i + 1)
              | [] -> (
                  match fr with
                  | _ :: (_ :: _ as ftl) -> scan_go avail [] ftl ib (i + 1)
                  | _ -> Fits (* popped past outermost frame = [] *)))
          | TBreak b -> (
              let m =
                match sstack with
                | m :: _ -> m
                | [] -> ( match fr with f :: _ -> f.fmode | [] -> Brkm)
              in
              match m with
              | Brkm | Fill -> Fits
              | Flat -> (
                  match b with
                  | Newline | Blank_line -> Nofit
                  | Space -> scan_go (avail - 1) sstack fr ib (i + 1)
                  | Cut -> scan_go avail sstack fr ib (i + 1)))
    in
    (* Commit a resolved decision ([fit]: does it fit flat?) and pop its front
       token. *)
    let resolve_decision fit =
      sc.active <- false;
      ignore (qpop ());
      if sc.ghv then
        frames :=
          { findent = sc.base; fmode = (if fit then Flat else Brkm) } :: !frames
      else if fit then flat_sep sc.str
      else break_line (cur ()).findent false
    in
    (* Lay out a token that needs no lookahead, updating the print state exactly
       as the old tree renderer did for the corresponding [doc] node. *)
    let process tok =
      match tok with
      | TText (w, s) ->
          flush ();
          add_string s;
          emitted := true;
          col := !col + w
      | TNest n ->
          let c = cur () in
          frames := { findent = c.findent + n; fmode = c.fmode } :: !frames
      | TBegin k ->
          (* A box's break-indentation is measured from the column where the box
             opens (Format semantics), not from the inherited nesting — they
             differ when a box starts mid-line (e.g. a WAT s-expression after its
             [(]). Rebase the group's indent to the open column. *)
          let base = eff_col () in
          let m =
            match k with
            | GV -> Brkm
            | GH -> Flat
            | GBox | GHov -> Fill
            | GHv -> assert false (* resolved with lookahead in [advance] *)
          in
          frames := { findent = base; fmode = m } :: !frames
      | TIfBroken ->
          (* only reached when the enclosing group is broken; the flat case is
             skipped in [advance] *)
          let c = cur () in
          frames := { findent = c.findent; fmode = c.fmode } :: !frames
      | TEnd -> (
          match !frames with _ :: (_ :: _ as tl) -> frames := tl | _ -> ())
      | TBreak str -> (
          let c = cur () in
          match (str, c.fmode) with
          | Newline, _ -> break_line c.findent false
          | Blank_line, _ -> break_line c.findent true
          | (Cut | Space), Flat -> flat_sep str
          | (Cut | Space), Brkm -> break_line c.findent false
          | (Cut | Space), Fill -> assert false (* resolved in [advance] *))
    in
    (* Drain the queue front while each front token is resolvable. A decision
       ([GHv] open, [Fill] break) scans the lookahead from index 1 (past the
       front token); if it cannot yet decide it is left [pending] and resumed on
       the next [feed]. *)
    let advance ~at_end () =
      scan_at_end := at_end;
      let go_on = ref true in
      while !go_on do
        if !skip_depth > 0 then
          if !qn = 0 then go_on := false
          else
            match qpop () with
            | TBegin _ | TNest _ | TIfBroken -> incr skip_depth
            | TEnd -> decr skip_depth
            | _ -> ()
        else if !qn = 0 then go_on := false
        else if sc.active then
          (* resume the suspended front decision from its parked state *)
          match scan_go sc.avail sc.sstack sc.fr sc.ib sc.i with
          | Susp -> go_on := false
          | Fits -> resolve_decision true
          | Nofit -> resolve_decision false
        else
          match qget 0 with
          | TBegin GHv -> (
              let base = eff_col () in
              (* [sc.ghv]/[sc.base] are read by [resolve_decision] on resolve —
                 set them before the scan so the immediate case sees them too. *)
              sc.ghv <- true;
              sc.base <- base;
              match scan_go (width - base) [ Flat ] !frames 0 1 with
              | Susp ->
                  sc.active <- true;
                  go_on := false
              | Fits -> resolve_decision true
              | Nofit -> resolve_decision false)
          | TBreak ((Cut | Space) as str) when (cur ()).fmode = Fill -> (
              (* If kept flat this separator itself occupies a column, so what
                 follows starts one column further right; account for it. *)
              let sep = match str with Space -> 1 | _ -> 0 in
              (* [sc.ghv]/[sc.str] are read by [resolve_decision] on resolve. *)
              sc.ghv <- false;
              sc.str <- str;
              match scan_go (width - eff_col () - sep) [] !frames 0 1 with
              | Susp ->
                  sc.active <- true;
                  go_on := false
              | Fits -> resolve_decision true
              | Nofit -> resolve_decision false)
          | TIfBroken when (cur ()).fmode <> Brkm ->
              ignore (qpop ());
              skip_depth := 1
          | tok ->
              ignore (qpop ());
              process tok
      done
    in
    let feed tok =
      qpush tok;
      advance ~at_end:false ()
    in
    let finish_stream () = advance ~at_end:true () in
    (feed, finish_stream)

  (* --- imperative builder (streams tokens into an engine) --- *)

  type state = {
    feed : token -> unit;
    finish_stream : unit -> unit;
    mutable pending_break : break_strength option;
        (* The most recent break not yet emitted, held so a following break can
           coalesce with it (by max strength) and so [force_eol]/[skip_space] can
           drop it — the streaming analogue of the old frame-head lookback. *)
    mutable has_emitted : bool; (* content since last forced end-of-line *)
    mutable pending_eol : (unit -> unit) option;
    mutable holding_eol : bool;
  }

  let create ~feed ~finish_stream =
    {
      feed;
      finish_stream;
      pending_break = None;
      has_emitted = false;
      pending_eol = None;
      holding_eol = false;
    }

  (* Emit a non-break token, first flushing any pending break so a break always
     precedes the following text/group and follows the preceding group's content
     (the token order the old tree fold produced). *)
  let emit st tok =
    (match st.pending_break with
    | Some s ->
        st.pending_break <- None;
        st.feed (TBreak s)
    | None -> ());
    st.feed tok

  (* Record a break, coalescing with a pending one into the stronger of the two —
     the analogue of the old [append]'s break-after-break merge and of the Format
     engine's [register_break]. *)
  let push_break st s =
    st.pending_break <-
      Some
        (match st.pending_break with
        | Some s0 -> if strength s >= strength s0 then s else s0
        | None -> s)

  (* Drop a pending break, so a deferred end-of-line comment hugs the preceding
     token instead of being pushed past a break. *)
  let drop_trailing_break st =
    match st.pending_break with
    | Some s ->
        st.pending_break <- None;
        Some s
    | None -> None

  let force_eol st =
    match st.pending_eol with
    | None -> ()
    | Some emit_comment ->
        st.pending_eol <- None;
        let dropped = drop_trailing_break st in
        emit_comment ();
        let next_brk =
          match dropped with Some Blank_line -> Blank_line | _ -> Newline
        in
        push_break st next_brk;
        st.has_emitted <- false

  let defer_eol st emit_comment =
    force_eol st;
    st.pending_eol <- Some emit_comment

  let with_held_eol st f =
    let prev = st.holding_eol in
    st.holding_eol <- true;
    f ();
    st.holding_eol <- prev

  let has_pending_eol st = st.pending_eol <> None

  let text st len s =
    if not st.holding_eol then force_eol st;
    st.has_emitted <- true;
    emit st (TText (len, s))

  let string st s = text st (String.length s) s
  let string_as st len s = text st len s
  let space st = if st.has_emitted then push_break st Space
  let cut st = push_break st Cut
  let newline st = push_break st Newline
  let blank_line st = push_break st Blank_line

  let indent st n f =
    emit st (TNest n);
    f ();
    emit st TEnd

  let if_broken st f =
    emit st TIfBroken;
    f ();
    emit st TEnd

  let scoped st kind ~skip_space ~indent f =
    if not st.holding_eol then force_eol st;
    (if skip_space then
       match st.pending_break with
       | Some (Cut | Space) -> st.pending_break <- None
       | _ -> ());
    emit st (TBegin kind);
    (* The group's own indent is a nest wrapping its whole body, so every break
       in the body indents from [base + indent] (see the old [group_wrap]). *)
    if indent <> 0 then emit st (TNest indent);
    f ();
    if indent <> 0 then emit st TEnd;
    emit st TEnd

  let box st ~skip_space ~indent f = scoped st GBox ~skip_space ~indent f
  let hvbox st ~skip_space ~indent f = scoped st GHv ~skip_space ~indent f
  let hovbox st ~skip_space ~indent f = scoped st GHov ~skip_space ~indent f
  let vbox st ~skip_space ~indent f = scoped st GV ~skip_space ~indent f
  let hbox st ~skip_space f = scoped st GH ~skip_space ~indent:0 f

  (* Flush a trailing deferred end-of-line comment, then drain the engine. A
     trailing break is left pending and never fed, so it is dropped (no trailing
     whitespace). *)
  let finalize st =
    force_eol st;
    st.finish_stream ()
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
  (* Lay out into a buffer, then relay line by line through the formatter's own
     newline, so that when [run] is called inside an enclosing Format box (e.g.
     an [@[<2>…@]] wrapping a snippet), every line — not just the first — picks
     up that box's indentation. A bare [pp_print_string] of the multi-line string
     would leave the embedded newlines at column 0. *)
  let b = Buffer.create 256 in
  let feed, finish_stream =
    Doc.make_engine ~width ~add_string:(Buffer.add_string b)
      ~add_char:(Buffer.add_char b) ~add_substring:(Buffer.add_substring b)
  in
  let c = Doc.create ~feed ~finish_stream in
  f c;
  Doc.finalize c;
  match String.split_on_char '\n' (Buffer.contents b) with
  | [] -> ()
  | first :: rest ->
      Format.pp_print_string fmt first;
      List.iter
        (fun line ->
          Format.pp_force_newline fmt ();
          Format.pp_print_string fmt line)
        rest

let run_channel ?(width = 78) oc f =
  (* Lay out straight into the channel — no intermediate string, no Format
     buffering. The hot output path. *)
  let feed, finish_stream =
    Doc.make_engine ~width ~add_string:(output_string oc)
      ~add_char:(output_char oc) ~add_substring:(output_substring oc)
  in
  let c = Doc.create ~feed ~finish_stream in
  f c;
  Doc.finalize c

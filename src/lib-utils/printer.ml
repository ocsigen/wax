type break_strength = No_break | Cut | Space | Newline | Blank_line

let strength = function
  | No_break -> 0
  | Cut -> 1
  | Space -> 2
  | Newline -> 3
  | Blank_line -> 4

type t = {
  fmt : Format.formatter;
  mutable started : bool;
  mutable pending_break : break_strength;
  mutable has_emitted : bool;
      (* Any output has been generated on the current line *)
  mutable indent : int; (* Current indentation level (for breaks) *)
  mutable indent_stack : int list;
  mutable pending_eol : (unit -> unit) option;
      (* A trailing line comment to emit at the end of the current line, after
         any list separator that follows it (see [defer_eol]). *)
  mutable holding_eol : bool;
      (* While set, a pending end-of-line comment is not flushed before the next
         token, so a list separator can be printed on the comment's line. *)
}

(* --- PRIMITIVES --- *)

let debug = false

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

(* End-of-line (trailing) comments. A trailing line comment must end its line,
   yet a list separator that follows it in the token stream (e.g. a comma)
   should stay on that line, before the comment. So such a comment is deferred:
   [defer_eol] records it, separators are printed while [holding_eol] is set
   (which suppresses the flush), and the next ordinary token or box — or the end
   of output — flushes it with [force_eol], emitting the comment and ending the
   line. *)

let force_eol ctx =
  match ctx.pending_eol with
  | None -> ()
  | Some emit ->
      ctx.pending_eol <- None;
      (* Clear the pending break so [emit]'s own output stays on this line. *)
      ctx.pending_break <- No_break;
      emit ();
      (* End the comment's line. Use a wide break (like [Newline]) so the indent
         offset is honoured. *)
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

let space ctx () = if ctx.has_emitted then register_break ctx Space
let newline ctx () = register_break ctx Newline
let blank_line ctx () = register_break ctx Blank_line
let cut ctx () = register_break ctx Cut

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

let box ctx ?(skip_space = false) ?(indent = 0) f =
  generic_box ~name:"BOX" Format.pp_open_box ctx skip_space indent f

let hvbox ctx ?(skip_space = false) ?(indent = 0) f =
  generic_box ~name:"HVBOX" Format.pp_open_hvbox ctx skip_space indent f

let hovbox ctx ?(skip_space = false) ?(indent = 0) f =
  generic_box ~name:"HOVBOX" Format.pp_open_hovbox ctx skip_space indent f

let vbox ctx ?(skip_space = false) ?(indent = 0) f =
  generic_box ~name:"VBOX" Format.pp_open_vbox ctx skip_space indent f

let run fmt f =
  let p =
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
  in
  f p;
  force_eol p;
  flush p

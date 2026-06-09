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

let string ctx s =
  flush ctx;
  if debug then Format.eprintf "STRING %s@." s;
  ctx.started <- true;
  ctx.has_emitted <- true;
  Format.pp_print_string ctx.fmt s

let string_as ctx len s =
  flush ctx;
  if debug then Format.eprintf "STRING %s@." s;
  ctx.started <- true;
  ctx.has_emitted <- true;
  Format.pp_print_as ctx.fmt len s

let register_break ctx s =
  if strength s > strength ctx.pending_break then ctx.pending_break <- s

let space ctx () = if ctx.has_emitted then register_break ctx Space
let newline ctx () = register_break ctx Newline
let blank_line ctx () = register_break ctx Blank_line
let cut ctx () = register_break ctx Cut

let generic_box ~name pp_open_box ctx skip_space indent f =
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
    }
  in
  f p;
  flush p

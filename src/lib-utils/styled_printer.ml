type t = {
  printer : Printer.t;
  theme : Colors.theme;
  mutable style_override : Colors.style option;
  trivia : Trivia.t;
  seen : Trivia.locations;
  collect : Trivia.locations option;
}

let create ~printer ~theme ?collect ~trivia () =
  {
    printer;
    theme;
    style_override = None;
    trivia;
    seen = Trivia.create_locations ();
    collect;
  }

let print_styled t style ?(len = None) text =
  let style = Option.value ~default:style t.style_override in
  let seq = Colors.escape_sequence t.theme style in
  if seq <> "" then Printer.string_as t.printer 0 seq;
  (match len with
  | None -> Printer.string t.printer text
  | Some len -> Printer.string_as t.printer len text);
  if seq <> "" then Printer.string_as t.printer 0 t.theme.reset

let comment t s = print_styled t Comment s

(* Emit a list of trivia entries (comments, blank lines), styling comment text
   with the theme and laying out spacing with the printer. The empty case is by
   far the most common (every atom is probed for before/within/after trivia), so
   short-circuit it before allocating the [List.iter] closure. *)
let print_trivia t lst =
  let open Trivia in
  if lst = [] then ()
  else
    List.iter
      (fun e ->
        match (e.trivia, e.position) with
        | Item { kind = Block_comment; content; _ }, _ ->
            Printer.space t.printer ();
            comment t content;
            Printer.space t.printer ()
        | Item { kind = Line_comment; content; _ }, Inline ->
            (* Trailing comment: defer it past a following separator (e.g. a list
             comma) so the separator stays on this line, ahead of the comment. *)
            Printer.defer_eol t.printer (fun () ->
                Printer.string t.printer " ";
                comment t (String.trim content))
        | Item { kind = Line_comment; content; _ }, Line_start ->
            Printer.newline t.printer ();
            comment t (String.trim content);
            Printer.newline t.printer ()
        | Item { kind = Annotation; _ }, _ -> ()
        | Blank_line, _ -> Printer.blank_line t.printer ())
      lst

let get_trivia t loc = Trivia.get ?collect:t.collect t.trivia ~seen:t.seen loc

let atomic_node t loc f =
  let assoc = get_trivia t loc in
  print_trivia t assoc.before;
  f ();
  print_trivia t assoc.within;
  print_trivia t assoc.after

let with_style t style f =
  match t.style_override with
  | Some _ -> f ()
  | None ->
      t.style_override <- Some style;
      f ();
      t.style_override <- None

type t = {
  printer : Printer.t;
  theme : Colors.theme;
  mutable style_override : Colors.style option;
  trivia : Trivia.t;
  seen : (Ast.location, unit) Hashtbl.t;
  collect : (Ast.location, unit) Hashtbl.t option;
}

let create ~printer ~theme ?collect ~trivia () =
  {
    printer;
    theme;
    style_override = None;
    trivia;
    seen = Hashtbl.create 16;
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
let print_trivia t lst = Trivia.print t.printer ~comment:(comment t) lst
let get_trivia t loc = Trivia.get ?collect:t.collect t.trivia ~seen:t.seen loc

let atomic_node t loc f =
  Trivia.around ?collect:t.collect t.printer ~comment:(comment t) t.trivia
    ~seen:t.seen loc f

let with_style t style f =
  match t.style_override with
  | Some _ -> f ()
  | None ->
      t.style_override <- Some style;
      f ();
      t.style_override <- None

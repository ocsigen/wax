type t = {
  printer : Printer.t;
  theme : Colors.theme;
  mutable style_override : Colors.style option;
  trivia : Trivia.t;
  seen : (Ast.location, unit) Hashtbl.t;
  hoisted : (Ast.location, unit) Hashtbl.t;
      (* Locations whose leading ([before]) trivia has already been emitted out
         of order by {!hoist_before}; their {!atomic_node} skips the [before]
         pass but still emits [within]/[after]. *)
  collect : (Ast.location, unit) Hashtbl.t option;
}

let create ~printer ~theme ?collect ~trivia () =
  {
    printer;
    theme;
    style_override = None;
    trivia;
    seen = Hashtbl.create 16;
    hoisted = Hashtbl.create 16;
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
   with the theme and laying out spacing with the printer. *)
let print_trivia t lst =
  let open Trivia in
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
  (* A [before] comment already emitted by {!hoist_before} (e.g. a leading
     comment pulled out to an enclosing breaking position) must not be printed
     again here; [within]/[after] are still owned by this node. *)
  if not (match loc with Some l -> Hashtbl.mem t.hoisted l | None -> false)
  then print_trivia t assoc.before;
  f ();
  print_trivia t assoc.within;
  print_trivia t assoc.after

(* Emit the leading ([before]) trivia attached to [loc] at the current position,
   ahead of where the node itself prints, and remember [loc] so {!atomic_node}
   does not print it a second time. Used to lift a leading comment out of the
   packing boxes of an expression (where a forced break would otherwise leak as
   spaces) up to an enclosing position that breaks cleanly. Peeks the trivia
   table directly so it does not consume the entry [atomic_node] still needs for
   [within]/[after]. *)
let hoist_before t loc =
  match loc with
  | None -> ()
  | Some l ->
      if not (Hashtbl.mem t.hoisted l || Hashtbl.mem t.seen l) then (
        (match t.collect with
        | Some set -> Hashtbl.replace set l ()
        | None -> ());
        match Hashtbl.find_opt t.trivia l with
        | None -> ()
        | Some assoc ->
            Hashtbl.add t.hoisted l ();
            print_trivia t assoc.before)

let with_style t style f =
  match t.style_override with
  | Some _ -> f ()
  | None ->
      t.style_override <- Some style;
      f ();
      t.style_override <- None

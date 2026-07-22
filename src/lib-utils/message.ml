(* A structured diagnostic message. See message.mli. The tree carries the
   message's structure; the theme and layout are supplied only at render time
   ([render]/[to_plain_string]), so one value renders three ways (themed
   terminal, JSON, short). *)

type t =
  | Empty
  | Words of string (* prose, reflowed on spaces / hard-broken on newlines *)
  | Atom of
      Colors.style * bool * string (* style, quote when uncoloured?, text *)
  | Raw of (Styled_printer.t -> unit)
  | Seq of t * t (* juxtapose, no space *)
  | Sep of t * t (* juxtapose, soft space between *)
  | Group of t

let text s = Words s
let ident s = Atom (Colors.Identifier, true, s)
let code s = Atom (Colors.Keyword, true, s)
let type_ s = Atom (Colors.Type, true, s)
let styled style s = Atom (style, false, s)
let int n = Atom (Colors.Constant, false, string_of_int n)
let int64 n = Atom (Colors.Constant, false, Int64.to_string n)
let uint64 n = Atom (Colors.Constant, false, Printf.sprintf "%Lu" n)
let bool b = Atom (Colors.Constant, false, string_of_bool b)
let raw f = Raw f
let empty = Empty
let ( ^^ ) a b = Seq (a, b)
let ( ++ ) a b = Sep (a, b)
let concat l = List.fold_left ( ^^ ) empty l
let group t = Group t

let enumerate ?(conj = "or") items =
  match List.rev items with
  | [] -> empty
  | [ x ] -> x
  | last :: rev_init ->
      let init = List.rev rev_init in
      let commad =
        List.fold_left
          (fun acc x ->
            match acc with
            | None -> Some x
            | Some a -> Some (a ^^ (text "," ++ x)))
          None init
        |> Option.get
      in
      commad ++ text conj ++ last

(* Emit prose: lines separated by hard breaks ([\n]) and, within a line, words
   separated by soft breaks (so an enclosing fill box reflows them). Runs of
   spaces (incl. leading/trailing) collapse to one soft break. A trailing
   newline is dropped rather than emitting a dangling blank line. *)
let render_words sp s =
  let p = sp.Styled_printer.printer in
  let lines = String.split_on_char '\n' s in
  let lines =
    match List.rev lines with "" :: rest -> List.rev rest | _ -> lines
  in
  List.iteri
    (fun li line ->
      if li > 0 then Printer.newline p ();
      List.iteri
        (fun i tok ->
          if i > 0 then Printer.space p ();
          if tok <> "" then Printer.string p tok)
        (String.split_on_char ' ' line))
    lines

let rec render_doc sp d =
  let p = sp.Styled_printer.printer in
  match d with
  | Empty -> ()
  | Words s -> render_words sp s
  | Atom (style, quote, s) ->
      if quote && Colors.escape_sequence sp.theme style = "" then
        Printer.string p ("'" ^ s ^ "'")
      else
        Styled_printer.print_styled sp style
          ~len:(Some (Unicode.terminal_width s))
          s
  | Raw f -> f sp
  | Seq (a, b) ->
      render_doc sp a;
      render_doc sp b
  | Sep (a, b) ->
      render_doc sp a;
      Printer.space p ();
      render_doc sp b
  | Group d -> Printer.box p ~indent:2 (fun () -> render_doc sp d)

(* Wrap the whole message in a greedy fill box so prose reflows at the width. *)
let render_top sp d =
  Printer.hovbox sp.Styled_printer.printer (fun () -> render_doc sp d)

let styled_printer ~theme printer =
  Styled_printer.create ~printer ~theme ~trivia:(Trivia.empty ()) ()

let render ~theme p t = render_top (styled_printer ~theme p) t

(* A wide margin so a hard-broken message still emits one physical line per
   break (a stray break is harmless — yojson escapes it, keeping one JSON object
   per physical line). *)
let flat_margin = 1_000_000

let to_plain_string t =
  Printer.run_string ~width:flat_margin (fun p ->
      render_top (styled_printer ~theme:Colors.no_color p) t)

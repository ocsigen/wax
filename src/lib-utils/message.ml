(* A structured diagnostic message. See message.mli. The tree carries the
   message's structure; the theme and width are supplied only at render time
   ([render_into]/[to_plain_string]), so one value renders three ways (themed
   terminal, JSON, short). The [Format] leaf is a migration shim reproducing the
   old Format-based rendering byte-for-byte. *)

type doc =
  | Empty
  | Words of string (* prose, reflowed on spaces *)
  | Atom of
      Colors.style * bool * string (* style, quote when uncoloured?, text *)
  | Raw of (Styled_printer.t -> unit)
  | Seq of doc * doc (* juxtapose, no space *)
  | Sep of doc * doc (* juxtapose, soft space between *)
  | Group of doc

type t = Format of (Format.formatter -> unit -> unit) | Doc of doc

let text s = Doc (Words s)
let ident s = Doc (Atom (Colors.Identifier, true, s))
let code s = Doc (Atom (Colors.Keyword, true, s))
let styled style s = Doc (Atom (style, false, s))
let int n = Doc (Atom (Colors.Constant, false, string_of_int n))
let int64 n = Doc (Atom (Colors.Constant, false, Int64.to_string n))
let bool b = Doc (Atom (Colors.Constant, false, string_of_bool b))
let raw f = Doc (Raw f)
let empty = Doc Empty

(* Extract the underlying [doc] of a combinator-built message. The combinators
   only ever produce [Doc], so the [Format] arm is unreachable in practice; fall
   back to running the legacy printer into an atom string. *)
let as_doc = function
  | Doc d -> d
  | Format f ->
      Raw
        (fun sp ->
          Printer.string sp.Styled_printer.printer (Format.asprintf "%a" f ()))

let ( ^^ ) a b = Doc (Seq (as_doc a, as_doc b))
let ( ++ ) a b = Doc (Sep (as_doc a, as_doc b))
let concat l = List.fold_left ( ^^ ) empty l
let group t = Doc (Group (as_doc t))

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

let of_format f = Format f

(* Emit prose: words separated by soft breaks, so an enclosing fill box reflows
   them. Runs of spaces (incl. leading/trailing) collapse to one soft break. *)
let render_words sp s =
  let toks = String.split_on_char ' ' s in
  List.iteri
    (fun i tok ->
      if i > 0 then Printer.space sp.Styled_printer.printer ();
      if tok <> "" then Printer.string sp.Styled_printer.printer tok)
    toks

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
  Styled_printer.create ~printer ~theme ~trivia:(Hashtbl.create 0) ()

let render_into ~theme ~width fmt t =
  match t with
  | Format f -> f fmt ()
  | Doc d ->
      Printer.run ~width fmt (fun p -> render_top (styled_printer ~theme p) d)

(* A wide margin so the legacy printer inserts no line breaks (a stray one is
   harmless — yojson escapes it, keeping one JSON object per physical line). *)
let flat_margin = 1_000_000

let to_plain_string t =
  let b = Buffer.create 128 in
  let fmt = Format.formatter_of_buffer b in
  (match t with
  | Format f ->
      Format.pp_set_margin fmt flat_margin;
      f fmt ()
  | Doc d ->
      Printer.run ~width:flat_margin fmt (fun p ->
          render_top (styled_printer ~theme:Colors.no_color p) d));
  Format.pp_print_flush fmt ();
  Buffer.contents b

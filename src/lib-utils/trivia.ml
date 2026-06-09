let debug_report = false

type position = Line_start | Inline
type kind = Line_comment | Block_comment | Annotation
type trivia = Item of { content : string; kind : kind } | Blank_line
type entry = { anchor : int; trivia : trivia; position : position }

type associated = {
  before : entry list;
  within : entry list;
  after : entry list;
}

type t = (Ast.location, associated) Hashtbl.t

type context = {
  mutable comments : entry list;
  mutable at_start_of_line : bool;
  mutable last_loc : Ast.location option;
  mutable prev_token_end : int;
  mutable locations : Ast.location list;
}

let make () =
  {
    comments = [];
    at_start_of_line = true;
    last_loc = None;
    prev_token_end = 0;
    locations = [];
  }

let add_entry ctx entry = ctx.comments <- entry :: ctx.comments

let report_item ctx kind content =
  if debug_report then
    Format.eprintf "ITEM %b %s@." ctx.at_start_of_line
      (match kind with
      | Line_comment -> "line comment"
      | Block_comment -> "block comment"
      | Annotation -> "annotation");
  add_entry ctx
    {
      anchor = ctx.prev_token_end;
      trivia = Item { content; kind };
      position = (if ctx.at_start_of_line then Line_start else Inline);
    };
  ctx.at_start_of_line <- kind = Line_comment

let report_newline ctx =
  if debug_report then Format.eprintf "NEWLINE %b@." ctx.at_start_of_line;
  if ctx.at_start_of_line then
    add_entry ctx
      {
        anchor = ctx.prev_token_end;
        trivia = Blank_line;
        position = Line_start;
      };
  ctx.at_start_of_line <- true

let report_token ctx pos =
  if debug_report then Format.eprintf "TOKEN@.";
  ctx.at_start_of_line <- false;
  ctx.prev_token_end <- pos

let check_loc ctx (loc : Ast.location) =
  if false then
    let start_pos = loc.loc_start in
    let end_pos = loc.loc_end in
    match ctx.last_loc with
    | None -> ()
    | Some last ->
        let last_start = last.loc_start in
        let last_end = last.loc_end in
        let strictly_before =
          last_end.Lexing.pos_cnum <= start_pos.Lexing.pos_cnum
        in
        let within =
          start_pos.Lexing.pos_cnum <= last_start.Lexing.pos_cnum
          && last_end.Lexing.pos_cnum <= end_pos.Lexing.pos_cnum
        in
        if not (strictly_before || within) then
          Printf.eprintf
            "Location check failed: previous (%d-%d), current (%d-%d)\n%!"
            last_start.Lexing.pos_cnum last_end.Lexing.pos_cnum
            start_pos.Lexing.pos_cnum end_pos.Lexing.pos_cnum

let with_pos ctx info desc =
  (if false then
     let loc = info in
     Format.eprintf "%d--%d@." loc.Ast.loc_start.pos_cnum loc.loc_end.pos_cnum);
  check_loc ctx info;
  ctx.last_loc <- Some info;
  ctx.locations <- info :: ctx.locations;
  { Ast.desc; info }

let associate ctx =
  let tbl = Hashtbl.create (List.length ctx.locations) in
  let comments = List.rev ctx.comments in
  if false then (
    List.iter (fun c -> Format.eprintf "%d " c.anchor) comments;
    Format.eprintf "@.");
  let locs =
    List.sort
      (fun a b ->
        let c =
          compare a.Ast.loc_start.Lexing.pos_cnum
            b.Ast.loc_start.Lexing.pos_cnum
        in
        if c <> 0 then c
        else compare b.Ast.loc_end.Lexing.pos_cnum a.Ast.loc_end.Lexing.pos_cnum)
      ctx.locations
  in
  let pos_of_entry e = e.anchor in
  let split_before threshold comments =
    let rec aux acc = function
      | c :: rest when pos_of_entry c < threshold -> aux (c :: acc) rest
      | rest -> (List.rev acc, rest)
    in
    aux [] comments
  in
  let get_after parent_end comments =
    let rec aux acc = function
      | ({ anchor; trivia = Item { kind = Line_comment; _ }; position = Inline }
         as c)
        :: rest
        when anchor = parent_end ->
          (List.rev (c :: acc), rest)
      | ({
           anchor;
           trivia = Item { kind = Line_comment; _ };
           position = Line_start;
         } as c)
        :: rest
        when anchor = parent_end ->
          (List.rev acc, c :: rest)
      | ({ anchor; trivia = Item _; _ } as c) :: rest when anchor = parent_end
        ->
          aux (c :: acc) rest
      | ({ anchor; trivia = Blank_line; _ } as c) :: rest
        when anchor = parent_end ->
          (List.rev acc, c :: rest)
      | l -> (List.rev acc, l)
    in
    aux [] comments
  in
  let rec process locs comments =
    match locs with
    | [] -> comments
    | loc :: rest_locs ->
        let is_child l =
          l.Ast.loc_end.Lexing.pos_cnum <= loc.Ast.loc_end.Lexing.pos_cnum
        in
        let rec span acc = function
          | l :: rs when is_child l -> span (l :: acc) rs
          | rs -> (List.rev acc, rs)
        in
        let children, siblings = span [] rest_locs in
        let before, rem1 =
          split_before loc.Ast.loc_start.Lexing.pos_cnum comments
        in
        let rem2 = process children rem1 in
        let within_candidates, rem3 =
          split_before loc.Ast.loc_end.Lexing.pos_cnum rem2
        in
        let steal_candidate =
          match List.rev children with
          | last_child :: _
            when last_child.Ast.loc_end.Lexing.pos_cnum
                 = loc.Ast.loc_end.Lexing.pos_cnum ->
              Some last_child
          | _ -> None
        in
        let final_after, rem4 =
          match steal_candidate with
          | Some last_child -> (
              match Hashtbl.find_opt tbl last_child with
              | Some assoc ->
                  let stolen = assoc.after in
                  Hashtbl.replace tbl last_child { assoc with after = [] };
                  (stolen, rem3)
              | None -> get_after loc.Ast.loc_end.Lexing.pos_cnum rem3)
          | None -> get_after loc.Ast.loc_end.Lexing.pos_cnum rem3
        in
        if false then
          Format.eprintf "%d--%d %d %d %d@." loc.loc_start.pos_cnum
            loc.loc_end.pos_cnum (List.length before)
            (List.length within_candidates)
            (List.length final_after);
        Hashtbl.add tbl loc
          { before; within = within_candidates; after = final_after };
        process siblings rem4
  in
  if false then
    List.iter
      (fun loc ->
        Format.eprintf "%d--%d@." loc.Ast.loc_start.pos_cnum
          loc.loc_end.pos_cnum)
      locs;
  let leftover = process locs comments in
  (* [leftover] holds comments that no location owns: trailing comments after
     the last node, or — when the module has no locations at all (e.g. an empty
     [(module)]) — the whole file. The caller prints them as tail trivia. *)
  (tbl, leftover)

(* Rendering. Shared by the Wax and WebAssembly printers; the comment styling is
   provided by the [comment] callback. *)

let print pp ~comment lst =
  List.iter
    (fun e ->
      match (e.trivia, e.position) with
      | Item { kind = Block_comment; content; _ }, _ ->
          Printer.space pp ();
          comment content;
          Printer.space pp ()
      | Item { kind = Line_comment; content; _ }, Inline ->
          Printer.space pp ();
          comment (String.trim content);
          Printer.newline pp ()
      | Item { kind = Line_comment; content; _ }, Line_start ->
          Printer.newline pp ();
          comment (String.trim content);
          Printer.newline pp ()
      | Item { kind = Annotation; _ }, _ -> ()
      | Blank_line, _ -> Printer.blank_line pp ())
    lst

let dummy_assoc = { before = []; within = []; after = [] }

let get trivia ~seen loc =
  match loc with
  | None -> dummy_assoc
  | Some loc -> (
      match Hashtbl.find_opt trivia loc with
      | None -> dummy_assoc
      | Some assoc ->
          if Hashtbl.mem seen loc then dummy_assoc
          else (
            Hashtbl.add seen loc ();
            assoc))

let around pp ~comment trivia ~seen loc f =
  let assoc = get trivia ~seen loc in
  print pp ~comment assoc.before;
  f ();
  print pp ~comment assoc.within;
  print pp ~comment assoc.after

(* Cross-format delimiter translation. *)

type comment_syntax = {
  line : string;
  block_open : string;
  block_close : string;
}

let wax_syntax = { line = "//"; block_open = "/*"; block_close = "*/" }
let wat_syntax = { line = ";;"; block_open = "(;"; block_close = ";)" }

let replace_all ~sub ~by s =
  let sl = String.length sub in
  if sl = 0 then s
  else
    let n = String.length s in
    let buf = Buffer.create n in
    let rec aux i =
      if i >= n then Buffer.contents buf
      else if i + sl <= n && String.sub s i sl = sub then (
        Buffer.add_string buf by;
        aux (i + sl))
      else (
        Buffer.add_char buf s.[i];
        aux (i + 1))
    in
    aux 0

let retarget_content ~src ~dst kind content =
  match kind with
  | Line_comment ->
      if String.starts_with ~prefix:src.line content then
        dst.line
        ^ String.sub content (String.length src.line)
            (String.length content - String.length src.line)
      else content
  | Block_comment ->
      content
      |> replace_all ~sub:src.block_open ~by:dst.block_open
      |> replace_all ~sub:src.block_close ~by:dst.block_close
  | Annotation -> content

let retarget_entry ~src ~dst e =
  match e.trivia with
  | Item { content; kind } ->
      {
        e with
        trivia =
          Item { content = retarget_content ~src ~dst kind content; kind };
      }
  | Blank_line -> e

let retarget ~src ~dst tbl tail =
  let conv = retarget_entry ~src ~dst in
  let conv_assoc a =
    {
      before = List.map conv a.before;
      within = List.map conv a.within;
      after = List.map conv a.after;
    }
  in
  let tbl' = Hashtbl.create (Hashtbl.length tbl) in
  Hashtbl.iter (fun k v -> Hashtbl.add tbl' k (conv_assoc v)) tbl;
  (tbl', List.map conv tail)

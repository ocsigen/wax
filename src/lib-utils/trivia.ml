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
  mutable prev_token_end : int;
  mutable locations : Ast.location list;
}

let make () =
  { comments = []; at_start_of_line = true; prev_token_end = 0; locations = [] }

let add_entry ctx entry = ctx.comments <- entry :: ctx.comments

let report_item ctx kind content =
  add_entry ctx
    {
      anchor = ctx.prev_token_end;
      trivia = Item { content; kind };
      position = (if ctx.at_start_of_line then Line_start else Inline);
    };
  ctx.at_start_of_line <- kind = Line_comment

let report_newline ctx =
  if ctx.at_start_of_line then
    add_entry ctx
      {
        anchor = ctx.prev_token_end;
        trivia = Blank_line;
        position = Line_start;
      };
  ctx.at_start_of_line <- true

let report_token ctx pos =
  ctx.at_start_of_line <- false;
  ctx.prev_token_end <- pos

let with_pos ctx info desc =
  ctx.locations <- info :: ctx.locations;
  { Ast.desc; info }

let drop_in_ranges ctx ranges =
  match ranges with
  | [] -> ()
  | _ ->
      let ranges =
        List.sort (fun (a, _) (b, _) -> compare (a : int) b) ranges
      in
      (* [ctx.comments] is built in reverse (most recent first); [List.rev] puts
         it back in lexing order. A stable sort by anchor then keeps the lexing
         order of comments sharing an anchor (consecutive line comments anchor
         at the same preceding token). Sweep the ascending comments alongside
         the ascending ranges in one pass, dropping any comment whose anchor
         lies in a deleted range [\[start, end)], and restore the reverse order
         {!associate} expects. *)
      let comments =
        List.stable_sort
          (fun a b -> compare a.anchor b.anchor)
          (List.rev ctx.comments)
      in
      let rec sweep ranges = function
        | [] -> []
        | (c : entry) :: rest -> (
            let rec skip = function
              | (_, e) :: rs when e <= c.anchor -> skip rs
              | rs -> rs
            in
            let ranges = skip ranges in
            match ranges with
            | (s, _) :: _ when s <= c.anchor -> sweep ranges rest
            | _ -> c :: sweep ranges rest)
      in
      ctx.comments <- List.rev (sweep ranges comments)

let associate ?only ctx =
  (* Only consider locations the caller will actually look up while printing
     (when [only] is given). A comment otherwise risks being attached to a node
     that the printer never emits trivia for — e.g. a struct-field label printed
     via its [.desc] only — and would then be silently dropped. Restricting to
     emitted locations makes every comment bubble up to a location that prints. *)
  let locations =
    match only with
    | None -> ctx.locations
    | Some set -> List.filter (fun l -> Hashtbl.mem set l) ctx.locations
  in
  let tbl = Hashtbl.create (List.length locations) in
  let comments = List.rev ctx.comments in
  let locs =
    List.sort
      (fun a b ->
        let c =
          compare a.Ast.loc_start.Lexing.pos_cnum
            b.Ast.loc_start.Lexing.pos_cnum
        in
        if c <> 0 then c
        else compare b.Ast.loc_end.Lexing.pos_cnum a.Ast.loc_end.Lexing.pos_cnum)
      locations
  in
  (* Collapse identical spans: a single source range is often recorded by more
     than one node (e.g. a [Get] instruction and the identifier it wraps both
     span the same name), and the printer looks each up but, via [seen], only
     the first carries the trivia. Two same-range entries would otherwise make
     [process] treat one as the other's child, and the "steal the last child's
     trailing comments" path then hands the parent the child's (empty) [after]
     instead of computing the gap up to the next sibling — silently dropping a
     trailing comment anchored just past the span. *)
  let locs =
    let same a b =
      a.Ast.loc_start.Lexing.pos_cnum = b.Ast.loc_start.Lexing.pos_cnum
      && a.Ast.loc_end.Lexing.pos_cnum = b.Ast.loc_end.Lexing.pos_cnum
    in
    let rec dedup = function
      | a :: (b :: _ as rest) when same a b -> dedup rest
      | a :: rest -> a :: dedup rest
      | [] -> []
    in
    dedup locs
  in
  let pos_of_entry e = e.anchor in
  let split_before threshold comments =
    let rec aux acc = function
      | c :: rest when pos_of_entry c < threshold -> aux (c :: acc) rest
      | rest -> (List.rev acc, rest)
    in
    aux [] comments
  in
  (* Trailing comments of a node: those anchored in [\[parent_end, upto)], where
     [upto] is the next sibling's start (so a comment separated from the node by
     a punctuation token — e.g. a list comma — still trails it rather than
     leading the next sibling). An inline line comment ends the node's line and
     is its trailing comment; a line-start comment or blank line begins the next
     sibling and is left in place. *)
  let get_after parent_end ~upto comments =
    let in_gap anchor = anchor >= parent_end && anchor < upto in
    let rec aux acc = function
      | ({ anchor; trivia = Item { kind = Line_comment; _ }; position = Inline }
         as c)
        :: rest
        when in_gap anchor ->
          (List.rev (c :: acc), rest)
      | ({
           anchor;
           trivia = Item { kind = Line_comment; _ };
           position = Line_start;
         } as c)
        :: rest
        when in_gap anchor ->
          (List.rev acc, c :: rest)
      | ({ anchor; trivia = Item _; _ } as c) :: rest when in_gap anchor ->
          aux (c :: acc) rest
      | ({ anchor; trivia = Blank_line; _ } as c) :: rest when in_gap anchor ->
          (List.rev acc, c :: rest)
      | l -> (List.rev acc, l)
    in
    aux [] comments
  in
  (* Rebuild the nesting from the flat, sorted (start asc, end desc — i.e.
     preorder) location list in one linear pass. [subtree_end.(i)] is the last
     index whose node is contained in [arr.(i)]: the maximal run of nodes right
     after [i] whose end does not exceed [arr.(i)]'s. That run is exactly the
     prefix the old recursive [span] recomputed at every nesting level, which
     made the whole pass O(n^2) in depth. A monotonic stack of still-open
     ancestors yields it in O(n): a node's subtree ends at [i-1] the moment we
     meet an [i] whose end exceeds it (a strictly greater end means [i] is not
     contained, so [i] is a sibling/uncle); equal ends keep it open, since an
     equal-end node with a later start nests inside — matching [is_child]'s
     [<=]. Any node never popped spans to the end. *)
  let arr = Array.of_list locs in
  let n = Array.length arr in
  let ecnum i = arr.(i).Ast.loc_end.Lexing.pos_cnum in
  let scnum i = arr.(i).Ast.loc_start.Lexing.pos_cnum in
  let subtree_end = Array.make (max n 1) 0 in
  let stack = ref [] in
  for i = 0 to n - 1 do
    let rec pop = function
      | t :: tl when ecnum t < ecnum i ->
          subtree_end.(t) <- i - 1;
          pop tl
      | s -> s
    in
    stack := i :: pop !stack
  done;
  List.iter (fun t -> subtree_end.(t) <- n - 1) !stack;
  (* Partition the comments over that tree. Semantics unchanged from the old
     [process]: [before] = comments anchored before the node; [within] = those
     between its children and its own end; [after] = trailing comments up to the
     next sibling's start ([upto]) — or, when the node's last flat descendant
     ([arr.(child_hi)]) ends exactly where the node does, that descendant's
     [after] (the [steal] path, preserving shared-span comment attachment).
     Comments thread left to right through [rem]; each index is visited once as
     a node, so the pass is O(n + #comments). The sibling tail call recurses in
     width, the child call in depth — the same recursion depth (tree height) as
     the old code. *)
  let rec process_range lo hi comments =
    if lo > hi then comments
    else
      let child_lo = lo + 1 and child_hi = subtree_end.(lo) in
      let next_sib = child_hi + 1 in
      let upto = if next_sib <= hi then scnum next_sib else ecnum lo + 1 in
      let before, rem1 = split_before (scnum lo) comments in
      let rem2 = process_range child_lo child_hi rem1 in
      let within_candidates, rem3 = split_before (ecnum lo) rem2 in
      let steal_candidate =
        if child_hi >= child_lo && ecnum child_hi = ecnum lo then
          Some arr.(child_hi)
        else None
      in
      let final_after, rem4 =
        match steal_candidate with
        | Some last_child -> (
            match Hashtbl.find_opt tbl last_child with
            | Some assoc ->
                let stolen = assoc.after in
                Hashtbl.replace tbl last_child { assoc with after = [] };
                (stolen, rem3)
            | None -> get_after (ecnum lo) ~upto rem3)
        | None -> get_after (ecnum lo) ~upto rem3
      in
      Hashtbl.add tbl arr.(lo)
        { before; within = within_candidates; after = final_after };
      process_range next_sib hi rem4
  in
  let leftover = process_range 0 (n - 1) comments in
  (* [leftover] holds comments that no location owns: trailing comments after
     the last node, or — when the module has no locations at all (e.g. an empty
     [(module)]) — the whole file. The caller prints them as tail trivia. *)
  (tbl, leftover)

let drop_trailing_blank_lines entries =
  let rec drop = function
    | { trivia = Blank_line; _ } :: rest -> drop rest
    | rest -> rest
  in
  List.rev (drop (List.rev entries))

let dummy_assoc = { before = []; within = []; after = [] }

let get ?collect trivia ~seen loc =
  (* A dry pass records every looked-up location into [collect]; the real pass
     then restricts {!associate} to that set. *)
  (match (collect, loc) with
  | Some set, Some loc -> Hashtbl.replace set loc ()
  | _ -> ());
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

type item =
  | Cond of {
      key : Ast.location;
      cond : Ast.cond;
      then_ : item list;
      else_ : item list option;
    }
  | Body of { rank : int; items : item list }

type run = int

(* A conditional's identity: the byte span of its own node. *)
type key = int * int

let key_of (l : Ast.location) : key = (l.loc_start.pos_cnum, l.loc_end.pos_cnum)

module Bdd_tbl = Hashtbl.Make (struct
  type t = Cond_solver.t

  let equal = Cond_solver.equal
  let hash = Cond_solver.hash
end)

type t = {
  decisions : (run * key, bool) Hashtbl.t;
      (* Every decision each run made at every conditional it reached. *)
  owners : (key * bool, run) Hashtbl.t;
      (* The run that owns each branch (the first to select it). *)
  node_owner : (key, run) Hashtbl.t;
      (* The run owning the branch a conditional sits directly in; the primary
         run for a top-level one. *)
  n_runs : int;
}

(* The conditionals directly inside a branch, through the bodies it holds. *)
let rec direct items =
  List.concat_map
    (function
      | Cond { key; _ } -> [ key_of key ] | Body { items; _ } -> direct items)
    items

(* Every branch the shape holds, outermost first. *)
let rec branches items =
  List.concat_map
    (function
      | Cond { key; then_; else_; _ } ->
          let k = key_of key in
          ((k, true) :: branches then_)
          @ Option.fold ~none:[] ~some:(fun e -> (k, false) :: branches e) else_
      | Body { items; _ } -> branches items)
    items

let make diagnostics items =
  let env = Cond_solver.create () in
  (* Translate each condition once. *)
  let formulas = Hashtbl.create 16 in
  let formula location cond =
    let k = key_of location in
    match Hashtbl.find_opt formulas k with
    | Some f -> f
    | None ->
        let f = Cond_solver.of_cond env diagnostics ~location cond in
        Hashtbl.replace formulas k f;
        f
  in
  let decisions = Hashtbl.create 16 in
  let owners = Hashtbl.create 16 in
  let node_owner = Hashtbl.create 16 in
  let n_runs = ref 0 in
  List.iter (fun k -> Hashtbl.replace node_owner k 0) (direct items);
  (* One run: [decide] is called at each conditional reached, in stream order,
     and returns the selected side; [asm] accumulates the assumption. *)
  let walk r ~seed ~decide =
    let asm = ref seed in
    let bodies = ref [] in
    let claim k side inside =
      if not (Hashtbl.mem owners (k, side)) then begin
        Hashtbl.replace owners (k, side) r;
        List.iter (fun k' -> Hashtbl.replace node_owner k' r) (direct inside)
      end
    in
    let rec conds items =
      List.iter
        (function
          | Cond { key; cond; then_; else_ } ->
              let k = key_of key in
              let f = formula key cond in
              let d = decide k ~asm:!asm f ~has_else:(else_ <> None) in
              Hashtbl.replace decisions (r, k) d;
              asm := Cond_solver.and_ !asm (if d then f else Cond_solver.not_ f);
              let inside = if d then Some then_ else else_ in
              Option.iter
                (fun inside ->
                  claim k d inside;
                  conds inside)
                inside
          | Body { rank; items } -> bodies := (rank, items) :: !bodies)
        items
    in
    conds items;
    let bodies =
      List.stable_sort (fun (a, _) (b, _) -> compare a b) (List.rev !bodies)
    in
    List.iter (fun (_, items) -> conds items) bodies
  in
  (* Phase A: the worlds that exist. Each unselected branch nobody owns or has a
     run queued for gets a run seeded with the assumption that selects it; the
     queued run replays the same path (its seed entails every decision on it)
     and so selects that branch. Seeds are deduplicated by formula: an equal
     seed makes equal decisions. *)
  let queue = Queue.create () in
  Queue.push Cond_solver.true_ queue;
  let seen = Bdd_tbl.create 16 in
  let pending = Hashtbl.create 16 in
  while not (Queue.is_empty queue) do
    let seed = Queue.pop queue in
    if not (Bdd_tbl.mem seen seed) then begin
      Bdd_tbl.add seen seed ();
      let r = !n_runs in
      incr n_runs;
      walk r ~seed ~decide:(fun k ~asm f ~has_else ->
          let d = Cond_solver.is_satisfiable (Cond_solver.and_ asm f) in
          let other = not d in
          if
            (other || has_else)
            && (not (Hashtbl.mem owners (k, other)))
            && not (Hashtbl.mem pending (k, other))
          then begin
            let seed' =
              Cond_solver.and_ asm (if other then f else Cond_solver.not_ f)
            in
            if Cond_solver.is_satisfiable seed' then begin
              Hashtbl.replace pending (k, other) ();
              Queue.push seed' queue
            end
          end;
          d)
    end
  done;
  (* Phase B: the branches no world reaches. Outermost first (a dead branch's
     own nested branches become forceable once it is owned): replay the owner
     of the enclosing branch and force the selection; under the resulting
     inconsistent assumption every further conditional takes its else-branch,
     the one side that always exists. *)
  let all = branches items in
  let progress = ref true in
  while !progress do
    progress := false;
    List.iter
      (fun (k, side) ->
        if not (Hashtbl.mem owners (k, side)) then
          match Hashtbl.find_opt node_owner k with
          | None -> ()
          | Some parent ->
              progress := true;
              let r = !n_runs in
              incr n_runs;
              walk r ~seed:Cond_solver.false_
                ~decide:(fun k' ~asm:_ _f ~has_else:_ ->
                  if k' = k then side
                  else
                    match Hashtbl.find_opt decisions (parent, k') with
                    | Some d -> d
                    | None -> false))
      all
  done;
  { decisions; owners; node_owner; n_runs = !n_runs }

let runs t = List.init t.n_runs Fun.id
let primary _ = 0

let select t r (location : Ast.location) =
  match Hashtbl.find_opt t.decisions (r, key_of location) with
  | Some d -> d
  | None ->
      failwith
        (Printf.sprintf
           "Cond_plan.select: run %d never reaches the conditional at %d-%d" r
           location.loc_start.pos_cnum location.loc_end.pos_cnum)

let owner t location side = Hashtbl.find_opt t.owners (key_of location, side)

let select_owned t (location : Ast.location) =
  let k = key_of location in
  match Hashtbl.find_opt t.node_owner k with
  | Some r -> select t r location
  | None ->
      failwith
        (Printf.sprintf "Cond_plan.select_owned: unplanned conditional at %d-%d"
           location.loc_start.pos_cnum location.loc_end.pos_cnum)

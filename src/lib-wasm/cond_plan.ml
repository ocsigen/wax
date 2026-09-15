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
  assumptions : (run, Cond_solver.t) Hashtbl.t;
      (* Each run's full assumption: the conjunction of the literals of every
         decision it made ([false_] for a forced run). *)
  env : Cond_solver.env;
  n_runs : int;
  truncated : bool;
}

let max_runs = 4096

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

let make ?(exhaustive = false) diagnostics items =
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
  let assumptions = Hashtbl.create 16 in
  let n_runs = ref 0 in
  let truncated = ref false in
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
    List.iter (fun (_, items) -> conds items) bodies;
    Hashtbl.replace assumptions r !asm
  in
  (* Phase A: the worlds that exist. Each unselected branch nobody owns or has a
     run queued for gets a run seeded with the assumption that selects it; the
     queued run replays the same path (its seed entails every decision on it)
     and so selects that branch. Seeds are deduplicated by formula: an equal
     seed makes equal decisions. An [exhaustive] plan queues EVERY reachable
     other side, ownership or not, so it visits every reachable configuration
     (up to [max_runs]). *)
  let queue = Queue.create () in
  Queue.push Cond_solver.true_ queue;
  let seen = Bdd_tbl.create 16 in
  let pending = Hashtbl.create 16 in
  while (not (Queue.is_empty queue)) && not !truncated do
    let seed = Queue.pop queue in
    if not (Bdd_tbl.mem seen seed) then
      if !n_runs >= max_runs then truncated := true
      else begin
        Bdd_tbl.add seen seed ();
        let r = !n_runs in
        incr n_runs;
        walk r ~seed ~decide:(fun k ~asm f ~has_else ->
            let d = Cond_solver.is_satisfiable (Cond_solver.and_ asm f) in
            let other = not d in
            (* An exhaustive plan explores the other side even when it is no
               branch at all (a conditional without [else]): the world where
               the then-branch is absent is a configuration to check too. A
               covering plan needs only the branches that exist typed. *)
            if
              exhaustive
              || (other || has_else)
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
     the one side that always exists. An exhaustive plan explores only what is
     reachable, as the checking it serves reports nothing about dead code. *)
  let all = if exhaustive then [] else branches items in
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
  {
    decisions;
    owners;
    node_owner;
    assumptions;
    env;
    n_runs = !n_runs;
    truncated = !truncated;
  }

let runs t = List.init t.n_runs Fun.id
let truncated t = t.truncated
let assumption t r = Hashtbl.find t.assumptions r
let explain t ?style f = Cond_solver.explain t.env ?style f
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

(* The shape of a Wasm-text module's conditionals: the mirror, over the source
   text, of the Wax typer's [Typing.plan_shape] over the Wax tree the Wasm→Wax
   conversion emits — the same nodes at the same spans (each emitted node keeps
   its source location), the field-level ones in order with their nested ones,
   the bodies (initializers at rank 0, function bodies at rank 1) holding the
   statement-level ones in stream order, a folded instruction's operands before
   its head, as they unfold. Also what the WAT validator explores. *)
let text_shape fields =
  let rec instrs l = List.concat_map instr l
  and instr (i : _ Ast.Text.instr) =
    match i.desc with
    | If_annotation { cond; then_body; else_body } ->
        [
          Cond
            {
              key = i.info;
              cond;
              then_ = instrs then_body.desc;
              else_ =
                Option.map
                  (fun (b : (_ list, _) Ast.annotated) -> instrs b.desc)
                  else_body;
            };
        ]
    | Block { block; _ } | Loop { block; _ } | TryTable { block; _ } ->
        instrs block.desc
    | If { if_block; else_block; _ } ->
        instrs if_block.desc @ instrs else_block.desc
    | Try { block; catches; catch_all; _ } ->
        instrs block.desc
        @ List.concat_map
            (fun (_, (b : (_ list, _) Ast.annotated)) -> instrs b.desc)
            catches
        @ Option.fold ~none:[]
            ~some:(fun (b : (_ list, _) Ast.annotated) -> instrs b.desc)
            catch_all
    | Folded (h, operands) -> instrs operands @ instr h
    | _ -> []
  in
  let body rank l =
    match instrs l with [] -> [] | items -> [ Body { rank; items } ]
  in
  let rec fields_ l =
    List.concat_map
      (fun (f : (_ Ast.Text.modulefield, _) Ast.annotated) ->
        match f.desc with
        | Module_if_annotation { cond; then_fields; else_fields } ->
            [
              Cond
                {
                  key = f.info;
                  cond;
                  then_ = fields_ then_fields.desc;
                  else_ =
                    Option.map
                      (fun (e : (_ list, _) Ast.annotated) -> fields_ e.desc)
                      else_fields;
                };
            ]
        | Func { instrs = l; _ } -> body 1 l
        | Global { init; _ } -> body 0 init
        | Data { mode = Active (_, off); _ } -> body 0 off
        | Elem { init; mode; _ } ->
            body 0
              (List.concat init
              @
              match mode with
              | Active (_, off) -> off
              | Passive | Declare -> [])
        | Table { init = Init_expr e; _ } -> body 0 e
        | Table { init = Init_segment exprs; _ } -> body 0 (List.concat exprs)
        | _ -> [])
      l
  in
  fields_ fields

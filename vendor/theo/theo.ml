let combine x y = (y * 1000003) + x

module type Theory = sig
  type _ t

  val equal : _ t -> _ t -> bool
  val compare : _ t -> _ t -> int
  val hash : _ t -> int
  val to_string : _ t -> string
end

type _ category = Bool | Leq | Eq

(** Global variable management. *)
module Var = struct
  type 'kind t = int

  let equal = Int.equal
  let compare = Int.compare
  let hash = Hashtbl.hash
  let counter = ref 0

  let fresh () =
    incr counter;
    !counter
end

module Make (T : Theory) = struct
  module Var = Var

  (*** Atoms ***)

  type 'kind desc = 'kind T.t

  type 'kind payload =
    | Bool : bool payload
    | Theory : 'kind desc -> 'kind payload

  type atom =
    | Atom : {
        var : 'kind Var.t;
        category : 'kind category;
        payload : 'kind payload;
        id : int;
      }
        -> atom

  module Atom = struct
    module WeakTbl = Weak.Make (struct
      type nonrec t = atom

      let equal (Atom t) (Atom t') =
        (* Two atoms are equal iff they have the same variable and payload. *)
        if t.var <> t'.var then false
        else
          match (t.payload, t'.payload) with
          | Bool, Bool -> true
          | Theory d, Theory d' -> T.equal d d'
          | _ -> false

      let hash (Atom t : t) =
        match t.payload with Bool -> t.var | Theory d -> t.var lxor T.hash d
    end)

    let equal a a' = a == a'

    let to_string (Atom { var; payload; _ }) =
      match payload with
      | Bool -> Printf.sprintf "$%d" var
      | Theory d -> Printf.sprintf "$%d %s" var (T.to_string d)

    let next_atom_id = ref 0
    let atom_tbl = WeakTbl.create 512

    let make var category payload =
      let id = !next_atom_id in
      let atom = Atom { var; category; payload; id } in
      let (Atom { id = id'; _ } as atom') = WeakTbl.merge atom_tbl atom in
      if Int.equal id id' then incr next_atom_id;
      atom'

    let sentinel =
      Atom { var = max_int; category = Bool; payload = Bool; id = max_int }

    (* Atom ordering is crucial for correctness: theory simplification relies on
     atoms of the same variable being clustered, and version comparison further
     requires atoms to be ordered by their version bounds. *)
    let compare (Atom a) (Atom a') =
      let c = Int.compare a.var a'.var in
      if c <> 0 then c
      else
        match (a.payload, a'.payload) with
        | Bool, Bool -> 0
        | Bool, _ -> -1
        | _, Bool -> 1
        | Theory v, Theory v' -> T.compare v v'

    let min a a' =
      let c = compare a a' in
      if c < 0 then a else a'
  end

  type atomic_constraint = { atom : atom; value : bool }

  type constraint_view =
    | Constraint : {
        var : 'kind Var.t;
        payload : 'kind payload;
        value : bool;
      }
        -> constraint_view

  let view_constraint { atom = Atom { var; payload; _ }; value } =
    Constraint { var; payload; value }

  module Constraint = struct
    type t = atomic_constraint list
    type nonrec 'kind desc = 'kind desc

    let atom var category desc =
      [
        {
          atom = Atom { var; category; payload = Theory desc; id = 0 };
          value = true;
        };
      ]

    let bool var value =
      [
        { atom = Atom { var; category = Bool; payload = Bool; id = 0 }; value };
      ]

    let not l =
      match l with
      | [ { atom; value } ] -> [ { atom; value = Stdlib.not value } ]
      | _ -> invalid_arg "Cannot negate complex constraints"

    let and_ x y = x @ y
    let or_ _ _ = invalid_arg "Cannot take the conjunction of two constraints"
  end

  type positive
  type negative

  (* BDD nodes are ordered by Atom.compare. *)

  type _ u =
    (* False is our unique positive terminal node. *)
    | False : positive u
    (* If-then-else node. The low branch is always positive (no complemented
     edge), ensuring a canonical form where negations appear only on
     the high branch or at the root. *)
    | If : {
        atom : atom;
        high : positive u;
        negate_high : bool;
        low : positive u;
        id : int;
      }
        -> positive u
    | Not : positive u -> negative u

  type t = Bdd : _ u -> t [@@unboxed]

  (* BDD operations. Hash-consing guarantees that structurally equal
     BDDs are physically equal, so equality is O(1). *)
  module Bdd = struct
    let rec equal t t' =
      match (t, t') with
      | Bdd (Not t), Bdd (Not t') -> equal (Bdd t) (Bdd t')
      | Bdd (Not _), Bdd _ | Bdd _, Bdd (Not _) -> false
      | _ -> t == t'

    let are_complement (Bdd u) (Bdd v) =
      match (u, v) with
      | Not x, y -> equal (Bdd x) (Bdd y)
      | x, Not y -> equal (Bdd x) (Bdd y)
      | _ -> false

    let rec id t =
      match t with
      | Bdd False -> 0
      | Bdd (If { id; _ }) -> id
      | Bdd (Not t) -> lnot (id (Bdd t))

    let compare t t' = Int.compare (id t) (id t')
  end

  let equal = Bdd.equal
  let compare = Bdd.compare
  let hash = Bdd.id

  module IdTbl = Hashtbl.Make (struct
    type t = int

    let equal = Int.equal
    let hash x = x
  end)

  let size t =
    (* Use a hash table to track visited nodes and count unique ones *)
    let visited = IdTbl.create 16 in
    let rec count : type a. a u -> int =
     fun u ->
      let id = Bdd.id (Bdd u) in
      if IdTbl.mem visited id then 0
      else (
        IdTbl.add visited id ();
        match u with
        | False -> 1
        | Not u' -> count u'
        | If { high; low; _ } -> 1 + count high + count low)
    in
    match t with Bdd u -> count u

  (*** Core Logic ***)

  let false_ = Bdd False
  let true_ = Bdd (Not False)

  let not u =
    match u with
    | Bdd (Not u) -> Bdd u
    | Bdd False -> true_
    | Bdd (If _ as f) -> Bdd (Not f)

  let with_polarity negate t = if negate then Bdd (Not t) else Bdd t

  (* split: Decomposes a BDD into (is_negated, positive_core).
   This allows treating Not as a flag rather than a node. *)
  let[@inline] split (Bdd u) =
    match u with
    | Not n -> (true, n)
    | If _ as n -> (false, n)
    | False as n -> (false, n)

  (*** Debugging ***)

  (* View type helper for pattern matching logical structure *)
  type view = Zero | One | Node of atom * t * t

  let view (Bdd u) =
    match u with
    | False -> Zero (* False *)
    | Not False -> One (* True *)
    | If { atom; high; negate_high; low; _ } ->
        (* if v then (high ^ neg) else low *)
        let h = with_polarity negate_high high in
        let l = Bdd low in
        Node (atom, l, h)
    | Not (If { atom; high; negate_high; low; _ }) ->
        (* not (if v then (high ^ neg) else low) *)
        (* = if v then not (high ^ neg) else not low *)
        let h = with_polarity (Stdlib.not negate_high) high in
        let l = with_polarity true low in
        Node (atom, l, h)

  let to_string t =
    let buf = Buffer.create 128 in
    let rec print prec t =
      match view t with
      | Zero -> Buffer.add_string buf "⊥"
      | One -> Buffer.add_string buf "⊤"
      | Node (v, l, h) -> (
          let atom_s = Atom.to_string v in
          match (view l, view h) with
          | Zero, One -> Buffer.add_string buf atom_s
          | One, Zero ->
              Buffer.add_string buf "¬";
              Buffer.add_string buf atom_s
          | Zero, _ ->
              (* v /\ h *)
              if prec > 2 then Buffer.add_char buf '(';
              Buffer.add_string buf atom_s;
              Buffer.add_string buf " ∧ ";
              print 2 h;
              if prec > 2 then Buffer.add_char buf ')'
          | One, _ ->
              (* !v \/ h *)
              if prec > 1 then Buffer.add_char buf '(';
              Buffer.add_string buf "¬";
              Buffer.add_string buf atom_s;
              Buffer.add_string buf " ∨ ";
              print 1 h;
              if prec > 1 then Buffer.add_char buf ')'
          | _, Zero ->
              (* !v /\ l *)
              if prec > 2 then Buffer.add_char buf '(';
              Buffer.add_string buf "¬";
              Buffer.add_string buf atom_s;
              Buffer.add_string buf " ∧ ";
              print 2 l;
              if prec > 2 then Buffer.add_char buf ')'
          | _, One ->
              (* v \/ l *)
              if prec > 1 then Buffer.add_char buf '(';
              Buffer.add_string buf atom_s;
              Buffer.add_string buf " ∨ ";
              print 1 l;
              if prec > 1 then Buffer.add_char buf ')'
          | _ ->
              if prec > 0 then Buffer.add_char buf '(';
              Buffer.add_string buf "if ";
              Buffer.add_string buf atom_s;
              Buffer.add_string buf " then ";
              print 0 h;
              Buffer.add_string buf " else ";
              print 0 l;
              if prec > 0 then Buffer.add_char buf ')')
    in
    print 0 t;
    Buffer.contents buf

  let print_dot (chan : out_channel) (t : t) : unit =
    let visited = IdTbl.create 16 in
    Printf.fprintf chan "digraph G {\n";
    let rec traverse : type a. a u -> unit =
     fun u ->
      let id = Bdd.id (Bdd u) in
      if Stdlib.not (IdTbl.mem visited id) then (
        IdTbl.add visited id ();
        match u with
        | False -> Printf.fprintf chan "  %d [label=\"⊥\", shape=box];\n" id
        | Not False -> Printf.fprintf chan "  %d [label=\"⊤\", shape=box];\n" id
        | Not u' ->
            Printf.fprintf chan "  %d [label=\"¬\", shape=circle];\n" id;
            Printf.fprintf chan "  %d -> %d;\n" id (Bdd.id (Bdd u'));
            traverse u'
        | If { atom; high = False; negate_high = true; low; id } ->
            Printf.fprintf chan "  %d [label=\"%s\"];\n" id
              (Atom.to_string atom);
            let low_id = Bdd.id (Bdd low) in
            let true_ = Not False in
            Printf.fprintf chan "  %d -> %d [style=solid];\n" id
              (Bdd.id (Bdd true_));
            traverse true_;
            Printf.fprintf chan "  %d -> %d [style=solid];\n" id low_id;
            traverse low
        | If { atom; high; negate_high; low; id } ->
            Printf.fprintf chan "  %d [label=\"%s\"];\n" id
              (Atom.to_string atom);
            let high_id = Bdd.id (Bdd high) in
            let low_id = Bdd.id (Bdd low) in
            Printf.fprintf chan "  %d -> %d [style=%s];\n" id high_id
              (if negate_high then "dashed" else "solid");
            Printf.fprintf chan "  %d -> %d [style=solid];\n" id low_id;
            traverse high;
            traverse low)
    in
    match t with
    | Bdd u ->
        traverse u;
        Printf.fprintf chan "}\n"

  module Node = struct
    type t = positive u

    let id (u : positive u) = match u with False -> 0 | If { id; _ } -> id

    module WeakTbl = Weak.Make (struct
      type t = positive u

      let equal (t : positive u) (t' : positive u) =
        match (t, t') with
        | ( If { atom; high; negate_high; low; _ },
            If
              {
                atom = atom';
                high = high';
                negate_high = negate_high';
                low = low';
                _;
              } ) ->
            Atom.equal atom atom' && high == high' && negate_high = negate_high'
            && low == low'
        | False, False -> true
        | If _, _ | _, If _ -> false

      let hash (t : positive u) =
        match t with
        | False -> 0
        | If { atom = Atom atom; high; negate_high; low; _ } ->
            let h =
              atom.id
              |> combine (id high)
              |> combine (if negate_high then 1 else 0)
              |> combine (id low)
            in
            h lxor (h lsr 17)
    end)

    let equal (t : positive u) (t' : positive u) = t == t'
    let hash = id
    let weak_tbl = WeakTbl.create 2048
    let next_id = ref 1

    (* Hash-consing constructor: ensures each unique node has exactly one
     representation in memory. Returns existing node if found. *)
    let ite atom high negate_high low =
      let id = !next_id in
      let node =
        WeakTbl.merge weak_tbl (If { atom; high; negate_high; low; id })
      in
      match node with
      | If { id = id'; _ } when Int.equal id id' ->
          next_id := !next_id + 1;
          node
      | If _ | False -> node
  end

  (*** Theory Simplification ***)

  module Simplify_cache = struct
    module Table = Ephemeron.K1.Make (Node)

    let cache = Table.create 128
    let find t = Table.find_opt cache t
    let add t res = Table.add cache t res
  end

  (* Theory simplification: when an atom like "v = A" is true, it implies
   "v != B" for any B != A. These functions propagate such implications
   through the BDD to simplify redundant nodes. *)
  let simplify_node (Atom a) (u : positive u) =
    let rec find_cached (Atom a) u =
      match u with
      | If { atom = Atom atom; low; _ } when atom.var = a.var -> (
          match Simplify_cache.find u with
          | Some res -> res
          | None ->
              let res = find_cached (Atom a) low in
              Simplify_cache.add u res;
              res)
      | _ -> u
    in
    let rec skip (Atom a) count u =
      match u with
      | If { atom = Atom atom; low; _ } when atom.var = a.var ->
          if count > 0 then skip (Atom a) (count - 1) low
          else find_cached (Atom a) u
      | _ -> u
    in
    skip (Atom a) 10 u

  (* prune: Simplifies 'u' assuming atom 'v' is true. *)
  let prune (Atom a) (u : positive u) (Atom atom) (high : positive u)
      (negate_high : bool) (low : positive u) negate_result : t =
    if a.var <> atom.var then with_polarity negate_result u
    else
      match a.category with
      | Bool -> with_polarity negate_result u
      | Leq -> with_polarity (negate_result <> negate_high) high
      | Eq -> with_polarity negate_result (simplify_node (Atom a) low)

  let check_simplification (Atom a) (Atom atom) (high : positive u)
      (negate_high : bool) (low : positive u) (target : t) : bool =
    if a.var <> atom.var then false
    else
      match a.category with
      | Bool -> false
      | Leq -> Bdd.equal (with_polarity negate_high high) target
      | Eq -> Bdd.equal (Bdd (simplify_node (Atom a) low)) target

  (* make_node: Constructs a BDD node, applying simplifications. Given
   the normalizations perform by [ite], [low] is always positive. *)
  let make_node atom (high : t) (low : t) : t =
    if Bdd.equal high low then high
    else
      match low with
      | Bdd
          (If
             {
               atom = l_atom;
               high = l_high;
               negate_high = l_neg;
               low = l_low;
               _;
             } as l_pos) ->
          if check_simplification atom l_atom l_high l_neg l_low high then low
          else
            let negate_high, h_node = split high in
            Bdd (Node.ite atom h_node negate_high l_pos)
      | Bdd (False as l_pos) ->
          let negate_high, h_node = split high in
          Bdd (Node.ite atom h_node negate_high l_pos)
      | Bdd (Not (False as l_inner)) ->
          let negate_high, h_node = split high in
          Bdd (Not (Node.ite atom h_node (Stdlib.not negate_high) l_inner))
      | Bdd
          (Not
             (If
                {
                  atom = l_atom;
                  high = l_high;
                  negate_high = l_neg;
                  low = l_low;
                  _;
                } as l_inner)) ->
          let (Bdd h_neg_inner) = not high in
          if
            check_simplification atom l_atom l_high l_neg l_low
              (Bdd h_neg_inner)
          then low
          else
            let negate_high, h_node = split high in
            Bdd (Not (Node.ite atom h_node (Stdlib.not negate_high) l_inner))
  (*** Core Computation ***)

  let top_atom t =
    let _, u = split t in
    match u with If { atom; _ } -> atom | False -> Atom.sentinel

  (* Theory-Aware Cofactors *)
  let[@inline] cofactors v (t : t) =
    let negate_t, u = split t in
    match u with
    | If { atom; high; negate_high; low; _ } ->
        if atom == v then
          let eff_neg_high =
            if negate_t then Stdlib.not negate_high else negate_high
          in
          let h = with_polarity eff_neg_high high in
          let l = with_polarity negate_t low in
          (h, l)
        else
          let simplified = prune v u atom high negate_high low negate_t in
          (simplified, t)
    | False -> (t, t)

  (* ITE cache: memoizes ite(f, g, h) results. Since g can be positive or
   negated, we store both polarities in the same cell keyed by (f, |g|, h). *)
  module ITE_cache = struct
    type 'a polarity_cell = { mutable pos : 'a option; mutable neg : 'a option }

    let empty_cell () = { pos = None; neg = None }

    module Store = Ephemeron.Kn.Make (Node)

    let cache = Store.create 4096

    let find u g w =
      let is_neg, v = split g in
      let keys = [| u; v; w |] in
      match Store.find_opt cache keys with
      | None -> None
      | Some cell -> if is_neg then cell.neg else cell.pos

    let add u g w res =
      let is_neg, v = split g in
      let keys = [| u; v; w |] in
      let cell =
        match Store.find_opt cache keys with
        | Some c -> c
        | None ->
            let c = empty_cell () in
            Store.add cache keys c;
            c
      in
      if is_neg then cell.neg <- Some res else cell.pos <- Some res
  end

  (* Binary cache: stores results of binary operations (AND) for all polarity
   combinations of (u, v). Key is (|u|, |v|).
   We store:
     pp: |u| & |v|
     pn: |u| & !|v|
     np: !|u| & |v|
     nn: !|u| & !|v|
   This allows deriving 'or' via DeMorgan (!(!a & !b)) from the same cache. *)
  module Binary_cache = struct
    type cell = {
      mutable pp : t option;
      mutable pn : t option;
      mutable np : t option;
      mutable nn : t option;
    }

    let empty_cell () = { pp = None; pn = None; np = None; nn = None }

    module Store = Ephemeron.K2.Make (Node) (Node)

    let cache = Store.create 4096

    let find u_pos v_pos u_neg v_neg =
      match Store.find_opt cache (u_pos, v_pos) with
      | None -> None
      | Some c -> (
          match (u_neg, v_neg) with
          | false, false -> c.pp
          | false, true -> c.pn
          | true, false -> c.np
          | true, true -> c.nn)

    let add u_pos v_pos u_neg v_neg res =
      let c =
        match Store.find_opt cache (u_pos, v_pos) with
        | Some c -> c
        | None ->
            let c = empty_cell () in
            Store.add cache (u_pos, v_pos) c;
            c
      in
      match (u_neg, v_neg) with
      | false, false -> c.pp <- Some res
      | false, true -> c.pn <- Some res
      | true, false -> c.np <- Some res
      | true, true -> c.nn <- Some res
  end

  (* ite f g h: computes "if f then g else h".

   Normalization rules for canonical form:
   - f is always positive (otherwise swap g and h)
   - h is always positive (otherwise negate the entire result)
   - Commutative cases use id ordering to break symmetry *)
  let rec ite f g h =
    let compute u g w =
      let f = Bdd u in
      let h = Bdd w in
      if Bdd.equal f g then ite f true_ h
      else if Bdd.are_complement f g then ite f false_ h
      else if Bdd.equal f h then ite f g false_
      else
        match ITE_cache.find u g w with
        | Some res -> res
        | None ->
            let v_f = top_atom f in
            let v_g = top_atom g in
            let v_h = top_atom h in
            let top = Atom.min v_f (Atom.min v_g v_h) in

            let f_high, f_low = cofactors top f in
            let g_high, g_low = cofactors top g in
            let h_high, h_low = cofactors top h in

            let r_high = ite f_high g_high h_high in
            let r_low = ite f_low g_low h_low in

            let res = make_node top r_high r_low in
            ITE_cache.add u g w res;
            res
    in
    match (f, g, h) with
    (* Terminal cases *)
    | _ when Bdd.equal g h -> g
    | Bdd (Not False), _, _ -> g
    | Bdd False, _, _ -> h
    | _, Bdd False, Bdd (Not False) -> not f
    | _, Bdd (Not False), Bdd False -> f
    (* Enforce f is positive *)
    | Bdd (Not f'), _, _ -> ite (Bdd f') h g
    (* Enforce h is positive *)
    | _, _, Bdd (Not h') -> not (ite f (not g) (Bdd h'))
    (* f \/ h *)
    | _, Bdd (Not False), _ when Bdd.compare f h > 0 -> ite h g f
    (* f /\ g *)
    | _, _, Bdd False when Bdd.compare f g > 0 -> ite g f h
    (* Recursion *)
    | Bdd (If _ as u), _, Bdd (False as w) -> compute u g w
    | Bdd (If _ as u), _, Bdd (If _ as w) -> compute u g w

  type constant_result = Constant of bool | NonConstant

  (* Constant_cache: Memoization for ite_constant checks.
   Keys are (f, g, h). Stores constant_result. *)
  module ITE_constant_cache = struct
    module Store = Ephemeron.Kn.Make (Node)

    let cache = Store.create 1024

    let find u g w =
      let _, v = split g in
      let keys = [| u; v; w |] in
      Store.find_opt cache keys

    let add u g w res =
      let _, v = split g in
      let keys = [| u; v; w |] in
      Store.add cache keys res
  end

  let rec ite_constant f g h =
    let check u g w =
      (* Check if full result is already cached in ITE_cache *)
      match ITE_cache.find u g w with
      | Some res -> (
          match res with
          | Bdd False -> Constant false
          | Bdd (Not False) -> Constant true
          | Bdd _ -> NonConstant)
      | None -> (
          (* Check Constant_cache *)
          match ITE_constant_cache.find u g w with
          | Some res -> res
          | None ->
              let v_f = top_atom f in
              let v_g = top_atom g in
              let v_h = top_atom h in
              let top = Atom.min v_f (Atom.min v_g v_h) in

              let f_high, f_low = cofactors top f in
              let g_high, g_low = cofactors top g in
              let h_high, h_low = cofactors top h in

              (* Short-circuiting recursion *)
              let res =
                match ite_constant f_high g_high h_high with
                | NonConstant -> NonConstant
                | Constant high_val -> (
                    match ite_constant f_low g_low h_low with
                    | NonConstant -> NonConstant
                    | Constant low_val ->
                        if high_val = low_val then Constant high_val
                        else NonConstant)
              in
              ITE_constant_cache.add u g w res;
              res)
    in
    match (f, g, h) with
    (* Trivial identity cases *)
    | Bdd False, _, Bdd False
    | Bdd (Not False), Bdd False, _
    | _, Bdd False, Bdd False ->
        Constant false
    | Bdd False, _, Bdd (Not False)
    | Bdd (Not False), Bdd (Not False), _
    | _, Bdd (Not False), Bdd (Not False) ->
        Constant true
    | Bdd False, _, _ | Bdd (Not False), _, _ | _, Bdd (Not False), Bdd False ->
        NonConstant
    | _, g, h when Bdd.equal g h -> NonConstant
    (* Normalization to match ITE structure/invariants *)
    | Bdd (Not u), g, h -> ite_constant (Bdd u) h g
    | f, g, h when Bdd.equal f g ->
        ite_constant f true_ h (* If f then f else h -> if f then true else h *)
    | f, g, h when Bdd.are_complement f g -> ite_constant f false_ h
    | f, g, h when Bdd.equal f h -> ite_constant f g false_
    (* Canonical ordering for commutativity *)
    | f, Bdd (Not False), h when Bdd.compare f h > 0 ->
        ite_constant h true_ f (* f \/ h -> h \/ f *)
    | f, g, Bdd False when Bdd.compare f g > 0 ->
        ite_constant g f false_ (* f /\ g -> g /\ f *)
    (* Normalize h to be positive *)
    | f, g, Bdd (Not u) -> (
        match ite_constant f (not g) (Bdd u) with
        | Constant b -> Constant (Stdlib.not b)
        | NonConstant -> NonConstant)
    (* General decomposition *)
    | Bdd (If _ as u), _, Bdd (False as w) -> check u g w
    | Bdd (If _ as u), _, Bdd (If _ as w) -> check u g w

  (*** Constructors ***)

  let make_atom i = Bdd (Node.ite i False true False)
  let atom v c d = make_atom (Atom.make v c (Theory d))
  let bool x = make_atom (Atom.make x Bool Bool)

  let check (category : _ category) (v : 'kind T.t) b (v' : 'kind' T.t) =
    match category with
    | Bool -> assert false
    | Leq ->
        if b then if T.compare v v' <= 0 then Some true else None
        else if T.compare v v' >= 0 then Some false
        else None
    | Eq ->
        if b then if T.equal v v' then Some true else Some false
        else if T.equal v v' then Some false
        else None

  let eval_atom (Atom atom) b (Atom atom') =
    if atom.var == atom'.var then
      match (atom.payload, atom'.payload) with
      | Bool, _ -> Some b
      | Theory t, Theory t' -> check atom.category t b t'
      | _ -> assert false
    else None

  module Constraints = struct
    module Desc = struct
      type t = Desc : _ desc -> t

      let compare (Desc d) (Desc d') = T.compare d d'
    end

    module DescSet = Set.Make (Desc)

    type t = {
      bools : (int, bool) Hashtbl.t;
      eq : (int, Desc.t) Hashtbl.t;
      ne : (int, DescSet.t) Hashtbl.t;
      lower : (int, Desc.t) Hashtbl.t; (* >= bound *)
      upper : (int, Desc.t) Hashtbl.t; (* < bound *)
      mutable max_var : int;
    }

    let create constraints =
      let store =
        {
          bools = Hashtbl.create 16;
          eq = Hashtbl.create 16;
          ne = Hashtbl.create 16;
          lower = Hashtbl.create 16;
          upper = Hashtbl.create 16;
          max_var = -1;
        }
      in
      let update_lower v new_bound =
        match Hashtbl.find_opt store.lower v with
        | Some (Desc current) ->
            if T.compare new_bound current > 0 then
              Hashtbl.replace store.lower v (Desc new_bound)
        | None -> Hashtbl.replace store.lower v (Desc new_bound)
      in
      let update_upper v new_bound =
        match Hashtbl.find_opt store.upper v with
        | Some (Desc current) ->
            if T.compare new_bound current < 0 then
              Hashtbl.replace store.upper v (Desc new_bound)
        | None -> Hashtbl.replace store.upper v (Desc new_bound)
      in
      try
        List.iter
          (fun { atom = Atom atom; value } ->
            let var = atom.var in
            match (atom.category, atom.payload) with
            | Bool, _ -> (
                if var > store.max_var then store.max_var <- var;
                match Hashtbl.find_opt store.bools var with
                | Some value' when value <> value' ->
                    raise Exit (* Contradiction *)
                | _ -> Hashtbl.replace store.bools var value)
            | Leq, Theory desc -> (
                if var > store.max_var then store.max_var <- var;
                match value with
                | true -> update_upper var desc
                | false -> update_lower var desc)
            | Eq, Theory desc -> (
                if var > store.max_var then store.max_var <- var;
                match value with
                | true -> (
                    (* Check against existing NE constraints *)
                    (match Hashtbl.find_opt store.ne var with
                    | Some set when DescSet.mem (Desc desc) set -> raise Exit
                    | _ -> ());
                    (* Check against existing EQ constraints *)
                    match Hashtbl.find_opt store.eq var with
                    | Some (Desc desc') when Stdlib.not (T.equal desc desc') ->
                        raise Exit
                    | _ -> Hashtbl.replace store.eq var (Desc desc))
                | false ->
                    (* Check against existing EQ constraint *)
                    (match Hashtbl.find_opt store.eq var with
                    | Some (Desc desc') when T.equal desc desc' -> raise Exit
                    | _ -> ());
                    let set =
                      match Hashtbl.find_opt store.ne var with
                      | Some set -> set
                      | None -> DescSet.empty
                    in
                    Hashtbl.replace store.ne var (DescSet.add (Desc desc) set))
            | (Leq | Eq), Bool -> assert false)
          constraints;
        (* Final consistency check for versions *)
        Hashtbl.iter
          (fun var (Desc.Desc lower) ->
            match Hashtbl.find_opt store.upper var with
            | Some (Desc upper) -> if T.compare lower upper >= 0 then raise Exit
            | None -> ())
          store.lower;
        Some store
      with Exit -> None

    let find_bool t v = Hashtbl.find_opt t.bools v
    let find_eq t v = Hashtbl.find_opt t.eq v

    let check_ne t v s =
      match Hashtbl.find_opt t.ne v with
      | Some set -> DescSet.mem s set
      | None -> false

    let find_lower_bound t v = Hashtbl.find_opt t.lower v
    let find_upper_bound t v = Hashtbl.find_opt t.upper v
  end

  let restrict_impl t max_var eval_atom =
    let visited = IdTbl.create 1024 in
    let rec visit u =
      let id = Node.id u in
      match IdTbl.find_opt visited id with
      | Some res -> res
      | None ->
          let res =
            match u with
            | False -> false_
            | If { atom = Atom atom; high; negate_high; low; _ } -> (
                if atom.var > max_var then Bdd u
                else
                  match eval_atom (Atom atom) with
                  | Some true ->
                      let h = visit high in
                      if negate_high then not h else h
                  | Some false -> visit low
                  | None ->
                      let h = visit high in
                      let l = visit low in
                      make_node (Atom atom) (if negate_high then not h else h) l
                )
          in
          IdTbl.add visited id res;
          res
    in
    match t with
    | Bdd False -> false_
    | Bdd (Not u) -> not (visit u)
    | Bdd (If _ as u) -> visit u

  let restrict t constraints =
    match t with
    | Bdd False -> false_
    | _ -> (
        match constraints with
        | [] -> t
        | [ { atom = Atom atom; value } ] ->
            let v = atom.var in
            let eval_atom atom' = eval_atom (Atom atom) value atom' in
            restrict_impl t v eval_atom
        | _ when List.compare_length_with constraints 5 <= 0 ->
            let rec no_contradiction atom' value' l =
              match l with
              | [] -> true
              | { atom; value } :: r ->
                  eval_atom atom' (value <> value') atom <> Some false
                  && no_contradiction atom' value' r
            in
            let rec validate_constraints l =
              match l with
              | [] -> true
              | { atom; value } :: r ->
                  no_contradiction atom value r && validate_constraints r
            in
            let valid =
              if true then Constraints.create constraints <> None
              else validate_constraints constraints
            in
            if Stdlib.not valid then false_
            else
              let max_var =
                List.fold_left
                  (fun acc { atom = Atom { var; _ }; _ } -> max acc var)
                  (-1) constraints
              in
              let rec find_map atom' l =
                match l with
                | [] -> None
                | { atom; value } :: r -> (
                    match eval_atom atom value atom' with
                    | Some _ as res -> res
                    | None -> find_map atom' r)
              in
              let eval_atom atom = find_map atom constraints in
              restrict_impl t max_var eval_atom
        | _ -> (
            match Constraints.create constraints with
            | None ->
                false_ (* Contradiction in constraints -> empty set -> false *)
            | Some store ->
                let eval_atom (Atom atom) =
                  match (atom.category, atom.payload) with
                  | Bool, _ -> Constraints.find_bool store atom.var
                  | Leq, Theory desc ->
                      (* Check implications from range *)
                      (* Atom is: var < v_atom (if !inc) or var <= v_atom (if inc) *)
                      let implies_true =
                        match Constraints.find_upper_bound store atom.var with
                        | Some (Desc desc') -> T.compare desc' desc <= 0
                        | None -> false
                      in
                      if implies_true then Some true
                      else
                        let implies_false =
                          match Constraints.find_lower_bound store atom.var with
                          | Some (Desc desc') -> T.compare desc desc' <= 0
                          | None -> false
                        in
                        if implies_false then Some false else None
                  | Eq, Theory desc -> (
                      match Constraints.find_eq store atom.var with
                      | Some (Desc desc') ->
                          if T.equal desc desc' then Some true else Some false
                      | None ->
                          if Constraints.check_ne store atom.var (Desc desc)
                          then Some false
                          else None)
                  | (Leq | Eq), Bool -> assert false
                in
                restrict_impl t store.max_var eval_atom))

  let rec and_rec u v =
    match (u, v) with
    | Bdd (Not False), w | w, Bdd (Not False) -> w
    | Bdd False, _ | _, Bdd False -> false_
    | (Bdd (Not u'), Bdd (Not v') | Bdd (If _ as u'), Bdd (If _ as v'))
      when u' == v' ->
        u
    | (Bdd (Not u), Bdd (If _ as v) | Bdd (If _ as u), Bdd (Not v)) when u == v
      ->
        false_
    | u, v -> (
        (* Canonical ordering: ensure u < v by ID *)
        let u, v = if Bdd.compare u v < 0 then (u, v) else (v, u) in
        let u_neg, u_pos = split u in
        let v_neg, v_pos = split v in
        match Binary_cache.find u_pos v_pos u_neg v_neg with
        | Some res -> res
        | None ->
            let tu = top_atom u in
            let tv = top_atom v in
            let top = Atom.min tu tv in
            let uh, ul = cofactors top u in
            let vh, vl = cofactors top v in
            let h = and_rec uh vh in
            let l = and_rec ul vl in
            let res = make_node top h l in
            Binary_cache.add u_pos v_pos u_neg v_neg res;
            res)

  let and_ = and_rec

  let or_ u v =
    match (u, v) with
    | Bdd (Not False), _ | _, Bdd (Not False) -> true_
    | Bdd False, w | w, Bdd False -> w
    | (Bdd (Not u'), Bdd (Not v') | Bdd (If _ as u'), Bdd (If _ as v'))
      when u' == v' ->
        u
    | (Bdd (Not u), Bdd (If _ as v) | Bdd (If _ as u), Bdd (Not v)) when u == v
      ->
        true_
    | u, v -> not (and_rec (not u) (not v))

  let xor a b = ite a (not b) b
  let iff a b = not (xor a b)
  let implies a b = ite a b true_

  let logical_implies a b =
    match ite_constant a b true_ with Constant true -> true | _ -> false

  let is_disjoint a b =
    match ite_constant a b false_ with Constant false -> true | _ -> false

  let is_exhaustive a b =
    match ite_constant a true_ b with Constant true -> true | _ -> false

  (* Quantifier elimination: removes all atoms mentioning the given variable *)
  let quantify combine_op (type a) (v : a Var.t) (t : t) : t =
    let target_var = v in
    (* Cache: keyed by (id, polarity) *)
    let visited = IdTbl.create 1024 in
    let rec visit negate u =
      let id = Node.id u in
      let key = (id lsl 1) lor if negate then 1 else 0 in
      match IdTbl.find_opt visited key with
      | Some res -> res
      | None ->
          let res =
            match u with
            | False -> if negate then true_ else false_
            | If { atom = Atom atom; high; negate_high; low; _ } -> (
                if atom.var > target_var then with_polarity negate u
                else
                  (* Effective polarity for high branch *)
                  let h_negate = negate_high <> negate in
                  let h = visit h_negate high in
                  let l = visit negate low in
                  if atom.var = target_var then
                    (* Quantify: combine high and low branches *)
                    combine_op h l
                  else
                    (* Keep node, recurse on children *)
                    match l with
                    | Bdd (Not l_inner) ->
                        let res = make_node (Atom atom) (not h) (Bdd l_inner) in
                        not res
                    | _ -> make_node (Atom atom) h l)
          in
          IdTbl.add visited key res;
          res
    in
    let negate, u = split t in
    visit negate u

  let exists (type a) (v : a Var.t) (t : t) : t = quantify or_ v t
  let forall (type a) (v : a Var.t) (t : t) : t = quantify and_ v t

  let balanced_reduce op base l =
    let cmp a b =
      let va = top_atom a in
      let vb = top_atom b in
      let c = Atom.compare vb va in
      if c <> 0 then c else Bdd.compare a b
    in
    let l = List.sort cmp l in
    let rec reduce op base l =
      match l with [] -> base | [ x ] -> x | _ -> aux op base [] l
    and aux op base acc l =
      match l with
      | [] -> reduce op base (List.rev acc)
      | [ x ] -> reduce op base (List.rev (x :: acc))
      | x :: y :: t -> aux op base (op x y :: acc) t
    in
    reduce op base l

  let and_list exprs = balanced_reduce and_ true_ exprs
  let or_list exprs = balanced_reduce or_ false_ exprs
  let is_tautology t = Bdd.equal t true_
  let is_satisfiable t = Stdlib.not (Bdd.equal t false_)
  let equivalent a b = Bdd.equal a b

  (*** Syntax ***)

  module Syntax = struct
    let bool = bool
    let ( && ) = and_
    let ( || ) = or_
    let not = not
    let ( ==> ) = implies
    let ( <=> ) = iff
    let ( <+> ) = xor
  end

  (*** Solvers ***)

  let sat (t : t) : atomic_constraint list option =
    let rec solve u target =
      match u with
      | False -> [] (* Only reached if valid, so return empty constraints *)
      | If { atom; high; negate_high; low; _ } ->
          (* Prefer high branch. Check if high is capable of satisfying
            eff_target. *)
          let eff_target = if negate_high then Stdlib.not target else target in
          let high_satisfiable =
            match (high, eff_target) with False, true -> false | _, _ -> true
          in
          if high_satisfiable then
            { atom; value = true } :: solve high eff_target
          else { atom; value = false } :: solve low target
    in
    match t with
    | Bdd False -> None
    | Bdd (If _ as u) -> Some (solve u true)
    | Bdd (Not u) -> Some (solve u false)

  let shortest_sat (t : t) : atomic_constraint list option =
    let dist_cache = IdTbl.create 128 in
    let rec get_dist u target =
      let id = Bdd.id (Bdd u) in
      let key = (id lsl 1) lor if target then 1 else 0 in
      match IdTbl.find_opt dist_cache key with
      | Some d -> d
      | None ->
          let d =
            match (u, target) with
            | False, true -> max_int (* Impossible *)
            | False, false -> 0 (* Reached! *)
            | If { high; negate_high; low; _ }, _ ->
                let eff_target_high =
                  if negate_high then Stdlib.not target else target
                in
                let d_high = get_dist high eff_target_high in
                if d_high = 0 then 1
                else
                  let d_low = get_dist low target in
                  let min_d =
                    if d_high = max_int && d_low = max_int then max_int
                    else 1 + min d_high d_low
                  in
                  min_d
          in
          IdTbl.add dist_cache key d;
          d
    in
    (* Trace back *)
    let rec trace u target =
      match (u, target) with
      | False, false -> []
      | False, true -> assert false
      | If { atom; high; negate_high; low; _ }, _ ->
          let eff_target_high =
            if negate_high then Stdlib.not target else target
          in
          let d_high = get_dist high eff_target_high in
          if
            (* If d_high is 0, we know it's optimal (local cost 1). *)
            d_high = 0
            ||
            let d_low = get_dist low target in
            d_high <= d_low
          then { atom; value = true } :: trace high eff_target_high
          else { atom; value = false } :: trace low target
    in
    match t with
    | Bdd False -> None
    | Bdd (Not u) -> Some (trace u false)
    | Bdd (If _ as u) -> Some (trace u true)

  let print_stats () =
    Printf.printf "Cache Statistics:\n";
    let print_ephemeron name stats alive =
      Printf.printf "  %s:\n" name;
      Printf.printf "    Bindings: %d (Alive: %d)\n" stats.Hashtbl.num_bindings
        alive.Hashtbl.num_bindings;
      Printf.printf "    Buckets : %d\n" stats.Hashtbl.num_buckets;
      Printf.printf "    Max Len : %d\n" stats.Hashtbl.max_bucket_length
    in
    let print_weak name (len, entries, _, _, _, _) =
      Printf.printf "  %s:\n" name;
      Printf.printf "    Entries : %d\n" entries;
      Printf.printf "    Length  : %d\n" len
    in
    print_weak "Atom Hashcons" (Atom.WeakTbl.stats Atom.atom_tbl);
    print_weak "Node Node Hashcons" (Node.WeakTbl.stats Node.weak_tbl);
    print_ephemeron "Simplify Cache"
      (Simplify_cache.Table.stats Simplify_cache.cache)
      (Simplify_cache.Table.stats_alive Simplify_cache.cache);
    print_ephemeron "ITE Constant Cache"
      (ITE_constant_cache.Store.stats ITE_constant_cache.cache)
      (ITE_constant_cache.Store.stats_alive ITE_constant_cache.cache);
    print_ephemeron "ITE Cache"
      (ITE_cache.Store.stats ITE_cache.cache)
      (ITE_cache.Store.stats_alive ITE_cache.cache);
    print_ephemeron "Binary Cache"
      (Binary_cache.Store.stats Binary_cache.cache)
      (Binary_cache.Store.stats_alive Binary_cache.cache);
    flush stdout
end

module type Formula = sig
  type t
  type _ desc

  val not : t -> t
  val and_ : t -> t -> t
  val or_ : t -> t -> t
  val atom : 'kind Var.t -> 'kind category -> 'kind desc -> t
end

(** Theory combinator *)

module Combine (A : Theory) (B : Theory) = struct
  type 'a t = Left : 'a A.t -> 'a t | Right : 'a B.t -> 'a t

  module Left (F : Formula with type 'kind desc = 'kind t) = struct
    include F

    type 'kind desc = 'kind A.t

    let atom var cat desc = atom var cat (Left desc)
  end

  module Right (F : Formula with type 'kind desc = 'kind t) = struct
    include F

    type 'kind desc = 'kind B.t

    let atom var cat desc = atom var cat (Right desc)
  end

  let equal d d' =
    match (d, d') with
    | Left d, Left d' -> A.equal d d'
    | Right d, Right d' -> B.equal d d'
    | _ -> false

  let compare d d' =
    match (d, d') with
    | Left d, Left d' -> A.compare d d'
    | Left _, Right _ -> -1
    | Right _, Left _ -> 1
    | Right d, Right d' -> B.compare d d'

  let hash d =
    match d with
    | Left d -> combine 0 (A.hash d)
    | Right d -> combine 1 (B.hash d)

  let to_string d =
    match d with Left d -> A.to_string d | Right d -> B.to_string d
end

module Void = struct
  type _ t = unit

  let equal _ _ = true
  let compare _ _ = 0
  let hash _ = 0
  let to_string _ = ""
end

(** Primitive theories *)

module type Comparable = sig
  type t

  val equal : t -> t -> bool
  val compare : t -> t -> int
  val hash : t -> int
  val to_string : t -> string
end

module type Primitive_theory = sig
  include Theory

  type elt
  type kind

  val category : kind category
end

module Leq (C : Comparable) = struct
  type elt = C.t
  type kind
  type _ t = Bound : { limit : elt; inclusive : bool } -> kind t

  let category = Leq

  let equal (type kind) (Bound b : kind t) (type kind') (Bound b' : kind' t) =
    C.equal b.limit b'.limit && b.inclusive = b'.inclusive

  let compare (type kind) (Bound b : kind t) (type kind') (Bound b' : kind' t) =
    let c = C.compare b.limit b'.limit in
    if c <> 0 then c else Bool.compare b.inclusive b'.inclusive

  let hash (type kind) (Bound b : kind t) =
    combine (Bool.to_int b.inclusive) (C.hash b.limit)

  let to_string (type kind) (Bound b : kind t) =
    Printf.sprintf "%s %s"
      (if b.inclusive then "<=" else "<")
      (C.to_string b.limit)

  module Syntax (F : Formula with type 'kind desc = 'kind t) = struct
    let lt var limit = F.atom var category (Bound { limit; inclusive = false })
    let le var limit = F.atom var category (Bound { limit; inclusive = true })
    let ( <= ) = le
    let ( < ) = lt
    let ( >= ) v x = F.not (v < x)
    let ( > ) v x = F.not (v <= x)
    let ( = ) v x = F.and_ (v <= x) (v >= x)
    let ( <> ) v x = F.or_ (v < x) (v > x)
  end
end

module Eq (C : Comparable) = struct
  type elt = C.t
  type kind
  type _ t = Const : elt -> kind t

  let category = Eq

  let equal (type kind) (Const v : kind t) (type kind') (Const v' : kind' t) =
    C.equal v v'

  let compare (type kind) (Const v : kind t) (type kind') (Const v' : kind' t) =
    C.compare v v'

  let hash (type kind) (Const v : kind t) = C.hash v

  let to_string (type kind) (Const v : kind t) =
    Printf.sprintf "= %s" (C.to_string v)

  module Syntax (F : Formula with type 'kind desc = 'kind t) = struct
    let eq v x = F.atom v category (Const x)
    let ( = ) = eq
    let ( <> ) v x = F.not (v = x)
  end
end

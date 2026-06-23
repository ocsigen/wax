module Diagnostic = Wax_utils.Diagnostic

(* Theory atoms. *)

module Version = struct
  type t = int * int * int

  let equal (a : t) (b : t) = a = b
  let compare (a : t) (b : t) = compare a b
  let hash = Hashtbl.hash
  let to_string (a, b, c) = Printf.sprintf "%d.%d.%d" a b c
end

module Str = struct
  type t = string

  let equal = String.equal
  let compare = String.compare
  let hash = Hashtbl.hash
  let to_string s = Printf.sprintf "%S" s
end

module VLeq = Theo.Leq (Version)
module SEq = Theo.Eq (Str)
module Theory = Theo.Combine (VLeq) (SEq)
module Bdd = Theo.Make (Theory)
module V = VLeq.Syntax (Theory.Left (Bdd))
module S = SEq.Syntax (Theory.Right (Bdd))

type t = Bdd.t

let true_ = Bdd.true_
let false_ = Bdd.false_
let and_ = Bdd.and_
let or_ = Bdd.or_
let not_ = Bdd.not
let is_satisfiable = Bdd.is_satisfiable
let logical_implies = Bdd.logical_implies
let equal = Bdd.equal
let hash = Bdd.hash

(* Per-module state: variable interning (by name and kind), the kind each name
   is used at (to flag inconsistent uses), and deduplication of ill-formed
   condition diagnostics (by source location). One [env] is used to process a
   single module, so nothing leaks between modules. (The underlying BDD engine
   {!Theo} keeps its own global hash-consing/memoization, which is
   correctness-safe across modules.) *)
type env = {
  bool_vars : (string, bool Theo.Var.t) Hashtbl.t;
  version_vars : (string, VLeq.kind Theo.Var.t) Hashtbl.t;
  string_vars : (string, SEq.kind Theo.Var.t) Hashtbl.t;
  bool_names : (bool Theo.Var.t * string) list ref;
  version_names : (VLeq.kind Theo.Var.t * string) list ref;
  string_names : (SEq.kind Theo.Var.t * string) list ref;
  reported : (Lexing.position * Lexing.position, unit) Hashtbl.t;
  var_kind : (string, string) Hashtbl.t;
}

let create () =
  {
    bool_vars = Hashtbl.create 16;
    version_vars = Hashtbl.create 16;
    string_vars = Hashtbl.create 16;
    bool_names = ref [];
    version_names = ref [];
    string_names = ref [];
    reported = Hashtbl.create 16;
    var_kind = Hashtbl.create 16;
  }

let intern tbl names name =
  match Hashtbl.find_opt tbl name with
  | Some v -> v
  | None ->
      let v = Theo.Var.fresh () in
      Hashtbl.add tbl name v;
      names := (v, name) :: !names;
      v

let lookup names var =
  match List.find_opt (fun (v, _) -> Theo.Var.equal v var) !names with
  | Some (_, name) -> name
  | None -> "?"

let report_ill_formed env ctx (location : Ast.location) msg =
  let key = (location.loc_start, location.loc_end) in
  if not (Hashtbl.mem env.reported key) then (
    Hashtbl.add env.reported key ();
    Diagnostic.report ctx ~location ~severity:Error
      ~message:(fun f () -> Format.pp_print_string f msg)
      ())

let check_kind env ctx location name kind =
  match Hashtbl.find_opt env.var_kind name with
  | Some k when not (String.equal k kind) ->
      report_ill_formed env ctx location
        (Printf.sprintf "Variable $%s is used with inconsistent types." name)
  | _ -> Hashtbl.replace env.var_kind name kind

let swap_op : Ast.cmp_op -> Ast.cmp_op = function
  | Le -> Ge
  | Ge -> Le
  | Lt -> Gt
  | Gt -> Lt
  | Eq -> Eq
  | Ne -> Ne

let bool_const b = if b then true_ else false_

let apply_order (op : Ast.cmp_op) c =
  match op with
  | Eq -> c = 0
  | Ne -> c <> 0
  | Lt -> c < 0
  | Le -> c <= 0
  | Gt -> c > 0
  | Ge -> c >= 0

let version_atom var (op : Ast.cmp_op) ver =
  let open V in
  match op with
  | Le -> var <= ver
  | Lt -> var < ver
  | Ge -> var >= ver
  | Gt -> var > ver
  | Eq -> var = ver
  | Ne -> var <> ver

let string_atom env ctx location var (op : Ast.cmp_op) s =
  match op with
  | Eq -> S.(var = s)
  | Ne -> S.(var <> s)
  | Lt | Gt | Le | Ge ->
      report_ill_formed env ctx location
        "Strings can only be compared with = or <> in a condition.";
      Bdd.bool (Theo.Var.fresh ())

let is_literal = function
  | Ast.Cond_version _ | Ast.Cond_string _ -> true
  | _ -> false

let rec to_bdd env ctx ~location (c : Ast.cond) : t =
  match c with
  | Cond_var v ->
      check_kind env ctx v.info v.desc "boolean";
      Bdd.bool (intern env.bool_vars env.bool_names v.desc)
  | Cond_and l -> Bdd.and_list (List.map (to_bdd env ctx ~location) l)
  | Cond_or l -> Bdd.or_list (List.map (to_bdd env ctx ~location) l)
  | Cond_not e -> Bdd.not (to_bdd env ctx ~location e)
  | Cond_cmp (op, a, b) -> cmp env ctx ~location op a b
  | Cond_string _ | Cond_version _ ->
      report_ill_formed env ctx location "This condition should be a boolean.";
      Bdd.bool (Theo.Var.fresh ())

and cmp env ctx ~location op (a : Ast.cond) (b : Ast.cond) =
  let version_var loc name =
    check_kind env ctx loc name "version";
    intern env.version_vars env.version_names name
  in
  let string_var loc name =
    check_kind env ctx loc name "string";
    intern env.string_vars env.string_names name
  in
  match (a, b) with
  | Cond_var v, Cond_version (x, y, z) ->
      version_atom (version_var v.info v.desc) op (x, y, z)
  | Cond_version (x, y, z), Cond_var v ->
      version_atom (version_var v.info v.desc) (swap_op op) (x, y, z)
  | Cond_var v, Cond_string s ->
      string_atom env ctx location (string_var v.info v.desc) op s.desc
  | Cond_string s, Cond_var v ->
      string_atom env ctx location (string_var v.info v.desc) (swap_op op)
        s.desc
  | Cond_version (x1, y1, z1), Cond_version (x2, y2, z2) ->
      bool_const (apply_order op (Version.compare (x1, y1, z1) (x2, y2, z2)))
  | Cond_string x, Cond_string y -> (
      match op with
      | Eq -> bool_const (String.equal x.desc y.desc)
      | Ne -> bool_const (not (String.equal x.desc y.desc))
      | _ ->
          report_ill_formed env ctx location
            "Strings can only be compared with = or <> in a condition.";
          Bdd.bool (Theo.Var.fresh ()))
  | _ -> (
      match op with
      | (Eq | Ne) when (not (is_literal a)) && not (is_literal b) ->
          let ba = to_bdd env ctx ~location a
          and bb = to_bdd env ctx ~location b in
          if op = Ast.Eq then Bdd.iff ba bb else Bdd.xor ba bb
      | _ ->
          report_ill_formed env ctx location
            "This comparison in a condition is not supported.";
          Bdd.bool (Theo.Var.fresh ()))

let of_cond env ctx ~location c = to_bdd env ctx ~location c

(* The two surface syntaxes render conditions differently: WAT uses
   [$]-prefixed variables, dotted versions and [<>]; Wax uses bare variables,
   version tuples and [!=]. *)
let version_string style (a, b, c) =
  match style with
  | `Wat -> Printf.sprintf "%d.%d.%d" a b c
  | `Wax -> Printf.sprintf "(%d, %d, %d)" a b c

let render_constraint env style (c : Bdd.atomic_constraint) =
  let prefix = match style with `Wat -> "$" | `Wax -> "" in
  match Bdd.view_constraint c with
  | Bdd.Constraint { var; payload = Bool; value } ->
      let name = lookup env.bool_names var in
      if value then prefix ^ name else "not " ^ prefix ^ name
  | Bdd.Constraint { var; payload = Theory desc; value } -> (
      match desc with
      | Theory.Left (VLeq.Bound { limit; inclusive }) ->
          let name = lookup env.version_names var in
          let op =
            match (inclusive, value) with
            | true, true -> "<="
            | true, false -> ">"
            | false, true -> "<"
            | false, false -> ">="
          in
          Printf.sprintf "%s%s %s %s" prefix name op
            (version_string style limit)
      | Theory.Right (SEq.Const s) ->
          let name = lookup env.string_names var in
          let op =
            match (value, style) with
            | true, _ -> "="
            | false, `Wat -> "<>"
            | false, `Wax -> "!="
          in
          Printf.sprintf "%s%s %s %s" prefix name op (Str.to_string s))

let explain env ?(style = `Wat) (f : t) =
  match Bdd.shortest_sat f with
  | None | Some [] -> None
  | Some constraints ->
      Some
        (String.concat " and "
           (List.map (render_constraint env style) constraints))

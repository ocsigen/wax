type 'a hint = { value : 'a; loc : Wax_utils.Ast.location }
type freq = int

type 'idx t = {
  branch : bool hint option;
  freq : freq hint option;
  targets : ('idx * int) list hint option;
}

let none = { branch = None; freq = None; targets = None }

(* Field by field rather than [t = none]: ['idx] is abstract here, so structural
   equality on a non-empty [targets] would reach into it. *)
let is_empty { branch; freq; targets } =
  branch = None && freq = None && targets = None

let branch loc value t = { t with branch = Some { value; loc } }

let map_targets f t =
  match t.targets with
  | None -> { t with targets = None }
  | Some h ->
      {
        t with
        targets =
          Some { h with value = List.map (fun (x, pct) -> (f x, pct)) h.value };
      }

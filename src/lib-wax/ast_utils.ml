open Ast

let rec map_instr f instr =
  let desc =
    match instr.desc with
    | Block { label; typ; block } ->
        Block
          {
            label;
            typ;
            block = { block with desc = List.map (map_instr f) block.desc };
          }
    | Loop { label; typ; block } ->
        Loop
          {
            label;
            typ;
            block = { block with desc = List.map (map_instr f) block.desc };
          }
    | While { label; cond; step; block } ->
        While
          {
            label;
            cond = map_instr f cond;
            step = Option.map (map_instr f) step;
            block = { block with desc = List.map (map_instr f) block.desc };
          }
    | If { label; typ; cond; if_block; else_block } ->
        If
          {
            label;
            typ;
            cond = map_instr f cond;
            if_block =
              { if_block with desc = List.map (map_instr f) if_block.desc };
            else_block =
              Option.map
                (fun b -> { b with desc = List.map (map_instr f) b.desc })
                else_block;
          }
    | TryTable { label; typ; block; catches } ->
        TryTable
          {
            label;
            typ;
            block = { block with desc = List.map (map_instr f) block.desc };
            catches;
          }
    | Try { label; typ; block; catches; catch_all } ->
        Try
          {
            label;
            typ;
            block = { block with desc = List.map (map_instr f) block.desc };
            catches =
              List.map
                (fun (tag, block) ->
                  (tag, { block with desc = List.map (map_instr f) block.desc }))
                catches;
            catch_all =
              Option.map
                (fun b -> { b with desc = List.map (map_instr f) b.desc })
                catch_all;
          }
    | ( Unreachable | Nop | Hole | Null | Get _ | Path _ | Char _ | String _
      | Int _ | Float _ | StructDefault _ ) as x ->
        x
    | Set (idx, op, v) -> Set (idx, op, map_instr f v)
    | Tee (idx, v) -> Tee (idx, map_instr f v)
    | Labelled (l, v) -> Labelled (l, map_instr f v)
    | Call (target, args) ->
        Call (map_instr f target, List.map (map_instr f) args)
    | TailCall (target, args) ->
        TailCall (map_instr f target, List.map (map_instr f) args)
    | Cast (v, t) -> Cast (map_instr f v, t)
    | CastDesc (v, t, d) -> CastDesc (map_instr f v, t, map_instr f d)
    | Test (v, t) -> Test (map_instr f v, t)
    | NonNull v -> NonNull (map_instr f v)
    | Struct (idx, fields) ->
        Struct
          (idx, List.map (fun (i, v) -> (i, Option.map (map_instr f) v)) fields)
    | StructDesc (d, fields) ->
        StructDesc
          ( map_instr f d,
            List.map (fun (i, v) -> (i, Option.map (map_instr f) v)) fields )
    | StructDefaultDesc d -> StructDefaultDesc (map_instr f d)
    | StructGet (v, idx) -> StructGet (map_instr f v, idx)
    | GetDescriptor v -> GetDescriptor (map_instr f v)
    | StructSet (v, idx, w) -> StructSet (map_instr f v, idx, map_instr f w)
    | Array (idx, len, init) -> Array (idx, map_instr f len, map_instr f init)
    | ArrayDefault (idx, len) -> ArrayDefault (idx, map_instr f len)
    | ArrayFixed (idx, elems) -> ArrayFixed (idx, List.map (map_instr f) elems)
    | ArraySegment (idx, seg, off, len) ->
        ArraySegment (idx, seg, map_instr f off, map_instr f len)
    | ArrayGet (arr, idx) -> ArrayGet (map_instr f arr, map_instr f idx)
    | ArraySet (arr, idx, val_) ->
        ArraySet (map_instr f arr, map_instr f idx, map_instr f val_)
    | BinOp (op, l, r) -> BinOp (op, map_instr f l, map_instr f r)
    | UnOp (op, v) -> UnOp (op, map_instr f v)
    | Let (bindings, body) -> Let (bindings, Option.map (map_instr f) body)
    | Br (label, v) -> Br (label, Option.map (map_instr f) v)
    | Br_if (label, v) -> Br_if (label, map_instr f v)
    | Hinted (h, i) -> Hinted (h, map_instr f i)
    | On (i, h) -> On (map_instr f i, h)
    | Br_table (labels, v) -> Br_table (labels, map_instr f v)
    | Dispatch { index; cases; default; arms } ->
        Dispatch
          {
            index = map_instr f index;
            cases;
            default;
            arms =
              List.map
                (fun (l, body) ->
                  (l, { body with desc = List.map (map_instr f) body.desc }))
                arms;
          }
    | Match { scrutinee; arms; default } ->
        Match
          {
            scrutinee = map_instr f scrutinee;
            arms =
              List.map
                (fun (pat, body) ->
                  (pat, { body with desc = List.map (map_instr f) body.desc }))
                arms;
            default =
              { default with desc = List.map (map_instr f) default.desc };
          }
    | Br_on_null (label, v) -> Br_on_null (label, map_instr f v)
    | Br_on_non_null (label, v) -> Br_on_non_null (label, map_instr f v)
    | Br_on_cast (label, t, v) -> Br_on_cast (label, t, map_instr f v)
    | Br_on_cast_fail (label, t, v) -> Br_on_cast_fail (label, t, map_instr f v)
    | Br_on_cast_desc_eq (label, t, v, d) ->
        Br_on_cast_desc_eq (label, t, map_instr f v, map_instr f d)
    | Br_on_cast_desc_eq_fail (label, t, v, d) ->
        Br_on_cast_desc_eq_fail (label, t, map_instr f v, map_instr f d)
    | Throw (idx, args) -> Throw (idx, List.map (map_instr f) args)
    | ThrowRef v -> ThrowRef (map_instr f v)
    | ContNew (ct, v) -> ContNew (ct, map_instr f v)
    | ContBind (src, dst, args) ->
        ContBind (src, dst, List.map (map_instr f) args)
    | Suspend (tag, args) -> Suspend (tag, List.map (map_instr f) args)
    | Resume (ct, handlers, args) ->
        Resume (ct, handlers, List.map (map_instr f) args)
    | ResumeThrow (ct, tag, handlers, args) ->
        ResumeThrow (ct, tag, handlers, List.map (map_instr f) args)
    | ResumeThrowRef (ct, handlers, args) ->
        ResumeThrowRef (ct, handlers, List.map (map_instr f) args)
    | Switch (ct, tag, args) -> Switch (ct, tag, List.map (map_instr f) args)
    | Return v -> Return (Option.map (map_instr f) v)
    | Sequence instrs -> Sequence (List.map (map_instr f) instrs)
    | Select (cond, t, e) ->
        Select (map_instr f cond, map_instr f t, map_instr f e)
    | If_annotation { cond; then_body; else_body } ->
        If_annotation
          {
            cond;
            then_body =
              { then_body with desc = List.map (map_instr f) then_body.desc };
            else_body =
              Option.map
                (fun b -> { b with desc = List.map (map_instr f) b.desc })
                else_body;
          }
  in
  { desc; info = f instr.info }

(* The instructions immediately nested within [i] (its operands and block
   bodies), in no particular evaluation order. A punned struct field ([None]) is
   a leaf and contributes nothing. *)
let sub_instrs (i : (_ Ast.instr_desc, _) Ast.annotated) =
  match i.desc with
  | Block { block; _ } | Loop { block; _ } | TryTable { block; _ } -> block.desc
  | While { cond; step; block; _ } -> (cond :: Option.to_list step) @ block.desc
  | If { cond; if_block; else_block; _ } ->
      (cond :: if_block.desc)
      @ Option.fold ~none:[] ~some:(fun b -> b.desc) else_block
  | Try { block; catches; catch_all; _ } ->
      block.desc
      @ List.concat_map (fun (_, b) -> b.desc) catches
      @ Option.fold ~none:[] ~some:(fun b -> b.desc) catch_all
  | If_annotation { then_body; else_body; _ } -> (
      then_body.desc @ match else_body with Some b -> b.desc | None -> [])
  | Sequence l | ArrayFixed (_, l) -> l
  | Dispatch { index; arms; _ } ->
      index :: List.concat_map (fun (_, b) -> b.desc) arms
  | Match { scrutinee; arms; default } ->
      (scrutinee :: List.concat_map (fun (_, b) -> b.desc) arms) @ default.desc
  | ContBind (_, _, l)
  | Suspend (_, l)
  | Resume (_, _, l)
  | ResumeThrow (_, _, _, l)
  | ResumeThrowRef (_, _, l)
  | Switch (_, _, l)
  | Throw (_, l) ->
      l
  | Call (a, l) | TailCall (a, l) -> a :: l
  | Struct (_, l) -> List.filter_map snd l
  | StructDesc (d, l) -> List.filter_map snd l @ [ d ]
  | CastDesc (a, _, b)
  | Br_on_cast_desc_eq (_, _, a, b)
  | Br_on_cast_desc_eq_fail (_, _, a, b)
  | BinOp (_, a, b)
  | Array (_, a, b)
  | ArraySegment (_, _, a, b)
  | ArrayGet (a, b)
  | StructSet (a, _, b) ->
      [ a; b ]
  | ArraySet (a, b, c) | Select (a, b, c) -> [ a; b; c ]
  | Set (_, _, i)
  | Tee (_, i)
  | Labelled (_, i)
  | Cast (i, _)
  | Test (i, _)
  | NonNull i
  | UnOp (_, i)
  | StructGet (i, _)
  | GetDescriptor i
  | StructDefaultDesc i
  | ArrayDefault (_, i)
  | Br_if (_, i)
  | Hinted (_, i)
  | On (i, _)
  | Br_table (_, i)
  | Br_on_null (_, i)
  | Br_on_non_null (_, i)
  | Br_on_cast (_, _, i)
  | Br_on_cast_fail (_, _, i)
  | ThrowRef i
  | ContNew (_, i) ->
      [ i ]
  | Let (_, o) | Br (_, o) | Return o -> Option.to_list o
  | Unreachable | Nop | Hole | Null | Get _ | Path _ | Char _ | String _ | Int _
  | Float _ | StructDefault _ ->
      []

let rec iter_instr f i =
  f i;
  List.iter (iter_instr f) (sub_instrs i)

(* Lower a [dispatch] to the conventional dense-switch shape: one nested void
   block per case, the [br_table] in the innermost block, and each case body
   placed just after its block. Branching to case [cᵢ] exits its block and runs
   [cᵢ]'s body, then falls through into the enclosing cases.

   Arms are listed in fall-through order — the first arm innermost, falling
   through into the next, and so on — which is the reverse of the block nesting:
   the *last* arm is outermost and its body trails the whole structure (hence
   the result is an instruction *list*: the outermost block followed by that
   trailing body). So we build from the reversed arm list, outermost first.

   This is the exact inverse of {!Recover_dispatch}, so a recovered dispatch
   re-lowers to the original blocks byte-for-byte. Every synthesised block and
   the [br_table] carry [block_info]; the index and case bodies keep their own. *)
let lower_dispatch ~block_info ~index ~cases ~default ~arms =
  let mk desc = { desc; info = block_info } in
  let void = { params = [||]; results = [||] } in
  let br = mk (Br_table (cases @ [ default ], index)) in
  let rec build = function
    | [ (c, _) ] ->
        (* innermost case block holds just the [br_table] *)
        mk (Block { label = Some c; typ = void; block = no_loc [ br ] })
    | (c, _) :: ((_, next_body) :: _ as rest) ->
        mk
          (Block
             {
               label = Some c;
               typ = void;
               block = no_loc (build rest :: next_body.desc);
             })
    | [] -> br
  in
  match List.rev arms with
  | [] -> [ br ]
  | (_, outer_body) :: _ as rev_arms -> build rev_arms :: outer_body.desc

(* Label of the [loop] a label-less [while]/[do]-[while] lowers to during type
   checking. The [#] is not a Wax identifier character, so it can never clash
   with a source label nor be the target of a user [br], keeping the body's
   branches well resolved. (Wasm conversion instead resolves the label to a
   readable [loop]/[loopN] before lowering — that name is what reaches emitted
   Wat — so this synthetic one only ever labels the discarded type-check
   lowering; see [To_wasm].) *)
let synthetic_loop_label = "#loop"

(* Lower a leading-test [while C { B }] to ['L: loop { if C { B; br 'L; } }]:
   each iteration re-tests [C] and, while it holds, runs the body and branches
   back; a false test falls out of the loop. Exact inverse of the [while] case
   of {!Recover_loops}. *)
(* With a Zig-style continue-expression [step] the step must run at the end of
   every iteration, including when the body branches to the loop label
   ([continue]). When the loop is labelled — so a [continue] can target it — the
   body is wrapped in a block carrying the user's label: [br 'L] then exits the
   block, runs the step, and takes the back-edge, so a [continue] runs the step
   before re-testing. This uses one fresh loop label ([fresh_loop]) for the
   back-edge. An unlabelled stepped loop cannot be continued, so the step is
   simply appended to the body (byte-identical to a trailing-step [while]). *)
let lower_while ~block_info ~fresh_loop ~label ~cond ~step ~block =
  let mk desc = { desc; info = block_info } in
  let void = { params = [||]; results = [||] } in
  let if_ cond body =
    mk
      (If
         {
           label = None;
           typ = void;
           cond;
           if_block = no_loc body;
           else_block = None;
         })
  in
  match (step, label) with
  | Some step, Some blk_l ->
      let body_block =
        mk (Block { label = Some blk_l; typ = void; block = no_loc block })
      in
      [
        mk
          (Loop
             {
               label = Some fresh_loop;
               typ = void;
               block =
                 no_loc
                   [ if_ cond [ body_block; step; mk (Br (fresh_loop, None)) ] ];
             });
      ]
  | _ ->
      let l = Option.value label ~default:fresh_loop in
      let tail = Option.to_list step @ [ mk (Br (l, None)) ] in
      [
        mk
          (Loop
             {
               label = Some l;
               typ = void;
               block = no_loc [ if_ cond (block @ tail) ];
             });
      ]

(* Lower a [match] to the conventional nested type-test ladder that compilers
   emit (and that hand-written GC code uses): one nested block per arm, plus an
   outer void [escape] block. The scrutinee is evaluated *once* and threaded
   through a chain of [br_on_cast] (or [br_on_null] for a [null] arm) sitting in
   the innermost block — each test, on success, branches *out* to its arm's block
   carrying the narrowed value, and on failure leaves the (progressively
   narrowed) value for the next test. The first arm is innermost: branching to it
   exits one block and runs its body (placed just after the block), so arm [i]'s
   body sits in arm [i+1]'s block — and the last arm's body sits in the [escape]
   block.

   A bound cast arm binds its block's result ([let x = …]); an unbound cast arm
   drops it; a [null] arm's block is void. After every test fails the innermost
   block drops the final value and [br escape]s past all the arm bodies; the
   [default] then follows the (void) [escape] block as trailing code. So, as
   before, each arm body must leave the [match] (diverge) while the default /
   no-match path falls through after the [match] — and its stack effect (in
   particular, divergence) propagates, exactly as the trailing first-arm body
   does for {!lower_dispatch}.

   [labels] supplies [n+1] fresh block labels: one per arm (in order) then the
   [escape] label. This is the exact inverse of {!Recover_match}: a recovered
   match re-lowers to the original blocks. *)
let lower_match ~block_info ~labels ~scrutinee ~arms ~default =
  let mk desc = { desc; info = block_info } in
  let void = { params = [||]; results = [||] } in
  let res = function
    | MatchCast (_, rt) -> { params = [||]; results = [| Ref rt |] }
    | MatchNull -> void
  in
  (* Consume a wrapped block's result for arm [pat], then run [body]. *)
  let consume blk pat body =
    match pat with
    | MatchCast ((Some _ as bind), rt) ->
        mk (Let ([ (bind, Some (Ref rt)) ], Some blk)) :: body
    | MatchCast (None, _) -> mk (Let ([ (None, None) ], Some blk)) :: body
    | MatchNull -> blk :: body
  in
  match arms with
  | [] -> default.desc
  | (p0, b0) :: rest_arms ->
      let rec unsnoc = function
        | [ x ] -> ([], x)
        | x :: r ->
            let init, last = unsnoc r in
            (x :: init, last)
        | [] -> assert false
      in
      let arm_labels, escape = unsnoc labels in
      let l0, rest_labels =
        match arm_labels with x :: r -> (x, r) | [] -> assert false
      in
      (* Threaded test chain (innermost operand the scrutinee, first test
         innermost): [br_on_cast L0; br_on_cast L1; …]. *)
      let chain =
        List.fold_left2
          (fun operand lbl (pat, _) ->
            match pat with
            | MatchCast (_, rt) -> mk (Br_on_cast (lbl, rt, operand))
            | MatchNull -> mk (Br_on_null (lbl, operand)))
          scrutinee arm_labels arms
      in
      (* Innermost block drops the final fall-through value then escapes; the
         default follows the [escape] block as trailing code. *)
      let inner =
        [ mk (Let ([ (None, None) ], Some chain)); mk (Br (escape, None)) ]
      in
      let block_l0 =
        mk (Block { label = Some l0; typ = res p0; block = no_loc inner })
      in
      (* Wrap outward: each block holds the previous block (its result consumed
         for the previous arm) followed by that arm's body. *)
      let rec wrap prev_block prev_pat prev_body labels arms =
        match (labels, arms) with
        | [], [] ->
            mk
              (Block
                 {
                   label = Some escape;
                   typ = void;
                   block = no_loc (consume prev_block prev_pat prev_body);
                 })
            :: default.desc
        | lbl :: labels', (pat, body) :: arms' ->
            let blk =
              mk
                (Block
                   {
                     label = Some lbl;
                     typ = res pat;
                     block = no_loc (consume prev_block prev_pat prev_body);
                   })
            in
            wrap blk pat body.desc labels' arms'
        | _ -> assert false
      in
      wrap block_l0 p0 b0.desc rest_labels rest_arms

let rec map_modulefield f field =
  match field with
  | Type t -> Type t
  | Module_annotation a -> Module_annotation a
  (* Imports carry no instructions, so the info type is free to change. *)
  | Import { module_; decl } -> Import { module_; decl }
  | Import_group { module_; decls } -> Import_group { module_; decls }
  | Tag t -> Tag t
  | Func ({ body = s, instrs; _ } as func) ->
      Func { func with body = (s, List.map (map_instr f) instrs) }
  | Global g -> Global { g with def = map_instr f g.def }
  | Memory m ->
      Memory
        {
          m with
          data =
            List.map (fun d -> { d with offset = map_instr f d.offset }) m.data;
        }
  | Data ({ mode; _ } as d) ->
      Data
        {
          d with
          mode =
            (match mode with
            | Passive -> Passive
            | Active (mem, off) -> Active (mem, map_instr f off));
        }
  | Table ({ init; _ } as t) ->
      Table { t with init = Option.map (map_instr f) init }
  | Elem ({ mode; init; _ } as e) ->
      Elem
        {
          e with
          mode =
            (match mode with
            | EPassive -> EPassive
            | EActive (tab, off) -> EActive (tab, map_instr f off));
          init = List.map (map_instr f) init;
        }
  | Conditional { cond; then_fields; else_fields } ->
      let map_fields b =
        {
          b with
          desc =
            List.map
              (fun a -> { a with desc = map_modulefield f a.desc })
              b.desc;
        }
      in
      Conditional
        {
          cond;
          then_fields = map_fields then_fields;
          else_fields = Option.map map_fields else_fields;
        }

let rec iter_fields f l =
  List.iter
    (fun field ->
      f field;
      match field.desc with
      | Conditional { then_fields; else_fields; _ } ->
          iter_fields f then_fields.desc;
          Option.iter (fun b -> iter_fields f b.desc) else_fields
      | _ -> ())
    l

let iter_module_instr f m =
  iter_fields
    (fun field ->
      let roots =
        match field.desc with
        | Func { body = _, instrs; _ } -> instrs
        | Global { def; _ } -> [ def ]
        | Memory { data; _ } -> List.map (fun d -> d.offset) data
        | Data { mode = Active (_, off); _ } -> [ off ]
        | Table { init; _ } -> Option.to_list init
        | Elem { mode; init; _ } -> (
            init
            @ match mode with EActive (_, off) -> [ off ] | EPassive -> [])
        (* No instructions of their own; a [Conditional]'s nested fields reach
           [f] via [iter_fields]' own recursion. *)
        | Data { mode = Passive; _ }
        | Type _ | Tag _ | Import _ | Import_group _ | Module_annotation _
        | Conditional _ ->
            []
      in
      List.iter (iter_instr f) roots)
    m

(* The precedence class of a binary operator. Shared by the [precedence] lint
   (see [Typing.lint_precedence]) and the Wax printer (see [Output]), so the
   parentheses the printer adds match exactly the mixes the lint would flag. *)
type binop_kind = [ `Shift | `Arith | `Bitwise | `Comparison ]

let binop_kind : Ast.binop -> binop_kind = function
  | Shl | Shr _ -> `Shift
  | Add | Sub | Mul | Div _ | Rem _ -> `Arith
  | And | Or | Xor -> `Bitwise
  | Eq | Ne | Lt _ | Gt _ | Le _ | Ge _ -> `Comparison

(* Whether a binary operator of kind [outer] applied to an operand that is
   itself a binary operator of kind [inner] is a precedence footgun: a shift
   mixed with arithmetic, or a comparison mixed with a bitwise operator. In such
   a mix the inner (operand) operator is the tighter-binding one, and a reader
   coming from C (whose table differs — see docs/src/language.md) may misgroup
   it. The relation is symmetric. *)
let confusing_precedence (outer : binop_kind) (inner : binop_kind) =
  match (outer, inner) with
  | `Shift, `Arith | `Arith, `Shift -> true
  | `Comparison, `Bitwise | `Bitwise, `Comparison -> true
  | _ -> false

(* The name an imported entity is bound to in Wasm: the name-only
   [#[import = "name"]] override if present, else the Wax name [id]. *)
let import_name (decl : import_decl) =
  let override =
    List.find_map
      (fun (k, v, _) ->
        if k <> "import" then None
        else
          match v with
          | Some { desc = String (_, s); info } -> Some { desc = s; info }
          | _ -> None)
      decl.attributes
  in
  Option.value override ~default:decl.id

open Ast
open Infer
open Typing_env

(* The diagnostics the lint checks emit. Kept with their emitters (rather than in
   the typer's [Error] module) since these warnings fire only from this pass; the
   message-building combinators are the same trivial [Wax_utils.Message] aliases
   the typer's [Error] uses. *)
module Error = struct
  open Wax_utils

  let text = Message.text
  let ( ++ ) = Message.( ++ )
  let ( ^^ ) = Message.( ^^ )

  let warn ?warning ?universal ?hint ?edit ?related context ~location message =
    if not (Wax_utils.Diagnostic.in_recovery context) then
      Diagnostic.report context ~location ~severity:Warning ?warning ?universal
        ?hint ?edit ?related ~message ()

  (* An operation with no effect on its result, or a constant result. *)
  let redundant_operation context ~location message =
    warn ~warning:Wax_utils.Warning.Redundant_operation ~universal:true context
      ~location message

  (* A shift whose constant count is at least the operand's bit width. Wasm
     shifts mask the count modulo the width, so the result is very likely not
     what was intended. *)
  (* [count] is the shift count as an unsigned 64-bit value (a hex literal such
     as [0xffff_ffff_ffff_ffff] is a large positive count, not [-1]), so print
     and reduce it unsigned. *)
  let shift_overflow context ~location ~width count =
    warn ~warning:Wax_utils.Warning.Shift_overflow ~universal:true context
      ~location
      ~hint:
        ((text "Wasm masks the count modulo" ++ Message.int width)
        ^^ text "," ++ text "shifting by"
           ++ Message.uint64 (Int64.unsigned_rem count (Int64.of_int width))
           ++ text "instead.")
      (text "The shift count" ++ Message.uint64 count
       ++ text "is at least the operand width ("
      ^^ Message.int width ^^ text " bits).")

  (* An integer division or remainder by a constant zero: it always traps. *)
  let division_by_zero context ~location =
    warn ~warning:Wax_utils.Warning.Constant_trap ~universal:true context
      ~location
      (text "This integer division or remainder by zero always traps.")

  (* A comparison whose result does not depend on its variable operand. *)
  let tautological_comparison context ~location ~value =
    warn ~warning:Wax_utils.Warning.Tautological_comparison ~universal:true
      context ~location
      ((text "This comparison is always" ++ Message.bool value) ^^ text ".")

  (* A branch, loop, or [select] condition that is a constant. *)
  let constant_condition context ~location ~value =
    warn ~warning:Wax_utils.Warning.Constant_condition ~universal:true context
      ~location
      ((text "This condition is always" ++ Message.bool value) ^^ text ".")

  (* A side-effect-free expression whose result is computed and then dropped. *)
  let unused_result context ~location =
    warn ~warning:Wax_utils.Warning.Unused_result ~universal:true context
      ~location
      (text
         "The result of this expression is discarded, and computing it has no \
          effect.")

  (* A trapping float-to-integer conversion of a constant that lies outside the
     target type's range (or is NaN/infinite): it always traps. *)
  let conversion_out_of_range context ~location =
    warn ~warning:Wax_utils.Warning.Constant_trap ~universal:true context
      ~location
      (text
         "This conversion always traps: the constant is out of the target \
          type's range.")

  (* A trapping or effectful operation inside a branch of a [?:]. Because [?:]
     compiles to a [select], which evaluates both branches, the operation runs
     even when the condition selects the other branch — unlike the [?:] of most
     languages, which is lazy. [select] points at the whole [?:]. *)
  let eager_select context ~location ~select =
    warn ~warning:Wax_utils.Warning.Eager_select ~universal:true context
      ~location
      ~related:
        [
          {
            Wax_utils.Diagnostic.location = select;
            message =
              text
                "This '?:' evaluates both branches (it compiles to a 'select').";
          };
        ]
      ~hint:(text "Use an 'if' expression to evaluate only the chosen branch.")
      (text
         "This operation is evaluated even when the condition selects the \
          other branch.")

  (* Two operators whose relative precedence is easy to misremember are mixed
     without parentheses (see {!lint_precedence}). [location] is the outer
     operator, [inner] the tighter-binding one; the [kind]s name the two
     operator classes ("shift", "arithmetic", "comparison", "bitwise"). *)
  let precedence ?edit context ~location ~inner ~outer_kind ~inner_kind =
    warn ?edit ~warning:Wax_utils.Warning.Precedence ~universal:true context
      ~location
      ~related:
        [
          {
            Wax_utils.Diagnostic.location = inner;
            message =
              text "This" ++ text inner_kind
              ++ text "operator binds tighter than the"
              ++ text outer_kind ++ text "operator.";
          };
        ]
      ~hint:(text "Add parentheses to make the grouping explicit.")
      (text "Operator precedence here is easy to misread.")
end

let is_pure_unary_method = function
  | "clz" | "ctz" | "popcnt" | "extend8_s" | "extend16_s" | "abs" | "ceil"
  | "floor" | "trunc" | "nearest" | "sqrt" | "to_bits" | "from_bits" ->
      true
  | _ -> false

let is_pure_binary_method = function
  | "rotl" | "rotr" | "min" | "max" | "copysign" -> true
  | _ -> false

(* Whether a cast is total (never traps), so discarding its result is pointless.
   A [strict] float-to-int conversion lowers to [trunc] (traps out of range); its
   saturating form and every numeric widen/narrow/convert is total. A reference
   cast ([as &T]) may trap and is conservatively treated as non-total (the
   never-trapping [extern.convert_any] is spelled the same way but not
   distinguished here). Mirrors the Wasm validator's [classify]. *)
let cast_is_total = function
  | Ast.Signedtype { typ; strict; _ } -> (
      match typ with `F32 | `F64 -> true | `I32 | `I64 -> not strict)
  | Valtype (I32 | I64 | F32 | F64) -> true
  | Valtype (V128 | Ref _) | Functype _ -> false

let rec is_effectless (e : _ Ast.instr) =
  (* A field value; the punning shorthand [{x}] reads a local/global. *)
  let field (_, v) = match v with Some e -> is_effectless e | None -> true in
  match e.desc with
  | Get _ | Int _ | Float _ | Char _ | String _ | Null | StructDefault _ -> true
  | UnOp (_, a) -> is_effectless a
  | Call ({ desc = StructGet (recv, m); _ }, [])
    when is_pure_unary_method m.desc ->
      is_effectless recv
  | Call ({ desc = StructGet (recv, m); _ }, [ a ])
    when is_pure_binary_method m.desc ->
      is_effectless recv && is_effectless a
  (* A SIMD vector method on a value ([v.add_i32x4(w)], [v.trunc_sat_f32x4_u()]):
     every vector op is pure and non-trapping (the trapping SIMD accesses are the
     [mem.]-path loads/stores, classified separately by [Simd.mem_method]). *)
  | Call ({ desc = StructGet (recv, m); _ }, args)
    when Wax_wasm.Simd.classify m.desc <> None ->
      is_effectless recv && List.for_all is_effectless args
  (* A [v128::…] SIMD constructor or vector op ([v128::i8x16(…)], a lane build)
     is effect-free and non-trapping when its operands are — the trapping SIMD
     memory accesses use the [mem.] path, not [v128::]. *)
  | Call ({ desc = Path ({ desc = "v128"; _ }, _); _ }, args) ->
      List.for_all is_effectless args
  (* [memory.size] / [table.size] ([m.size()]) reads the current size: pure and
     non-trapping, unlike the effectful grow/fill/copy/init on the same path. *)
  | Call
      ({ desc = StructGet ({ desc = Get _; _ }, { desc = "size"; _ }); _ }, [])
    ->
      true
  (* A typed null [null as &?t] is [ref.null] (a constant), not a trapping ref
     cast, so it is effect-free like a bare [null]. *)
  | Cast ({ desc = Null; _ }, Valtype (Ref { nullable = true; _ })) -> true
  | Cast (a, ct) when cast_is_total ct -> is_effectless a
  | BinOp ({ desc = Div _ | Rem _; _ }, _, _) -> false
  | BinOp (_, a, b) -> is_effectless a && is_effectless b
  | Select (a, b, c) -> is_effectless a && is_effectless b && is_effectless c
  | Test (a, _) -> is_effectless a
  | Struct (_, fields) -> List.for_all field fields
  | StructDesc (d, fields) -> is_effectless d && List.for_all field fields
  | StructDefaultDesc d -> is_effectless d
  | Array (_, elt, len) -> is_effectless elt && is_effectless len
  | ArrayDefault (_, len) -> is_effectless len
  | ArrayFixed (_, elts) -> List.for_all is_effectless elts
  | _ -> false

(* Accumulate into [acc] the local names assigned ([Set]/[Tee] targets) anywhere
   in [i], recursing through every sub-instruction. Mirrors the case coverage of
   {!Sink_let.occurs}: only [Set]/[Tee] write a local, every other case just
   recurses. A drop ([_ = e], an anonymous [Let]) names no local, so it just
   recurses via the [Let] case. Wasm-derived locals are uniquely named within a
   function, so the
   resulting by-name set is exact; a stray name collision could only keep an
   annotation, never wrongly drop one. *)
let rec collect_assigned_locals acc i =
  match i.desc with
  | Set (id, _, e) | Tee (id, e) ->
      collect_assigned_locals (StringSet.add id.desc acc) e
  | Block { block; _ } | Loop { block; _ } | TryTable { block; _ } ->
      collect_assigned_locals_list acc block.desc
  | While { cond; step; block; _ } ->
      let acc = collect_assigned_locals acc cond in
      let acc =
        Option.fold ~none:acc ~some:(collect_assigned_locals acc) step
      in
      collect_assigned_locals_list acc block.desc
  | If { cond; if_block; else_block; _ } ->
      let acc =
        collect_assigned_locals_list
          (collect_assigned_locals acc cond)
          if_block.desc
      in
      Option.fold ~none:acc
        ~some:(fun b -> collect_assigned_locals_list acc b.desc)
        else_block
  | Try { block; catches; catch_all; _ } ->
      let acc = collect_assigned_locals_list acc block.desc in
      let acc =
        List.fold_left
          (fun acc (_, b) -> collect_assigned_locals_list acc b.desc)
          acc catches
      in
      Option.fold ~none:acc
        ~some:(fun b -> collect_assigned_locals_list acc b.desc)
        catch_all
  | TryCatch { block; arms; _ } ->
      let acc = collect_assigned_locals_list acc block.desc in
      List.fold_left
        (fun acc a -> collect_assigned_locals_list acc a.arm_body.desc)
        acc arms
  | Call (t, args) | TailCall (t, args) ->
      collect_assigned_locals_list (collect_assigned_locals acc t) args
  | Cast (e, _)
  | Test (e, _)
  | NonNull e
  | StructGet (e, _)
  | GetDescriptor e
  | StructDefaultDesc e
  | UnOp (_, e)
  | Br_if (_, e)
  | Hinted (_, e)
  | On (e, _)
  | Labelled (_, e)
  | Br_table (_, e)
  | Br_on_null (_, e)
  | Br_on_non_null (_, e)
  | Br_on_cast (_, _, e)
  | Br_on_cast_fail (_, _, e)
  | ThrowRef e
  | ArrayDefault (_, e)
  | ContNew (_, e) ->
      collect_assigned_locals acc e
  (* A punned field ([None]) is a [Get] and assigns nothing. *)
  | Struct (_, fields) ->
      List.fold_left
        (fun acc (_, e) ->
          Option.fold ~none:acc ~some:(collect_assigned_locals acc) e)
        acc fields
  | StructDesc (d, fields) ->
      List.fold_left
        (fun acc (_, e) ->
          Option.fold ~none:acc ~some:(collect_assigned_locals acc) e)
        (collect_assigned_locals acc d)
        fields
  | CastDesc (e1, _, e2)
  | Br_on_cast_desc_eq (_, _, e1, e2)
  | Br_on_cast_desc_eq_fail (_, _, e1, e2)
  | StructSet (e1, _, e2)
  | Array (_, e1, e2)
  | ArraySegment (_, _, e1, e2)
  | ArrayGet (e1, e2)
  | BinOp (_, e1, e2) ->
      collect_assigned_locals (collect_assigned_locals acc e1) e2
  | ArraySet (e1, e2, e3) | Select (e1, e2, e3) ->
      collect_assigned_locals
        (collect_assigned_locals (collect_assigned_locals acc e1) e2)
        e3
  | ArrayFixed (_, l)
  | ContBind (_, _, l)
  | Suspend (_, l)
  | Resume (_, _, l)
  | ResumeThrow (_, _, _, l)
  | ResumeThrowRef (_, _, l)
  | Switch (_, _, l)
  | Throw (_, l)
  | Sequence l ->
      collect_assigned_locals_list acc l
  | Dispatch { index; arms; _ } ->
      List.fold_left
        (fun acc (_, b) -> collect_assigned_locals_list acc b.desc)
        (collect_assigned_locals acc index)
        arms
  | Match { scrutinee; arms; default } ->
      let acc = collect_assigned_locals acc scrutinee in
      let acc =
        List.fold_left
          (fun acc (_, b) -> collect_assigned_locals_list acc b.desc)
          acc arms
      in
      collect_assigned_locals_list acc default.desc
  | Let (_, body) -> collect_assigned_locals_opt acc body
  | Br (_, o) | Return o -> collect_assigned_locals_opt acc o
  | If_annotation { then_body; else_body; _ } ->
      let acc = collect_assigned_locals_list acc then_body.desc in
      Option.fold ~none:acc
        ~some:(fun b -> collect_assigned_locals_list acc b.desc)
        else_body
  | Get _ | Path _ | Unreachable | Nop | Hole | Null | Char _ | String _ | Int _
  | Float _ | StructDefault _ ->
      acc

(* Accumulate into [acc] the block labels declared anywhere in [i], from the
   source AST (before any lowering, so synthesized labels from [while]/[dispatch]/
   [match] desugaring are never collected). Every case recurses; the labelled
   constructs also contribute their own label. The [dispatch]/[match] arm labels
   are branch targets, not declarations, so they are not collected. Mirrors the
   case coverage of {!collect_assigned_locals}. *)

and collect_assigned_locals_list acc l =
  List.fold_left collect_assigned_locals acc l

and collect_assigned_locals_opt acc o =
  match o with Some i -> collect_assigned_locals acc i | None -> acc

let rec collect_labels acc (i : _ Ast.instr) =
  let add acc label = match label with Some l -> l :: acc | None -> acc in
  match i.desc with
  | Block { label; block; _ }
  | Loop { label; block; _ }
  | TryTable { label; block; _ } ->
      collect_labels_list (add acc label) block.desc
  | While { label; cond; step; block; _ } ->
      let acc = collect_labels (add acc label) cond in
      let acc = Option.fold ~none:acc ~some:(collect_labels acc) step in
      collect_labels_list acc block.desc
  | If { label; cond; if_block; else_block; _ } ->
      let acc =
        collect_labels_list (collect_labels (add acc label) cond) if_block.desc
      in
      Option.fold ~none:acc
        ~some:(fun b -> collect_labels_list acc b.desc)
        else_block
  | Try { label; block; catches; catch_all; _ } ->
      let acc = collect_labels_list (add acc label) block.desc in
      let acc =
        List.fold_left
          (fun acc (_, b) -> collect_labels_list acc b.desc)
          acc catches
      in
      Option.fold ~none:acc
        ~some:(fun b -> collect_labels_list acc b.desc)
        catch_all
  | TryCatch { label; block; arms; _ } ->
      let acc = collect_labels_list (add acc label) block.desc in
      List.fold_left
        (fun acc a -> collect_labels_list acc a.arm_body.desc)
        acc arms
  | Call (t, args) | TailCall (t, args) ->
      collect_labels_list (collect_labels acc t) args
  | Set (_, _, e)
  | Tee (_, e)
  | Labelled (_, e)
  | Cast (e, _)
  | Test (e, _)
  | NonNull e
  | StructGet (e, _)
  | GetDescriptor e
  | StructDefaultDesc e
  | UnOp (_, e)
  | Br_if (_, e)
  | Hinted (_, e)
  | On (e, _)
  | Br_table (_, e)
  | Br_on_null (_, e)
  | Br_on_non_null (_, e)
  | Br_on_cast (_, _, e)
  | Br_on_cast_fail (_, _, e)
  | ThrowRef e
  | ArrayDefault (_, e)
  | ContNew (_, e) ->
      collect_labels acc e
  | Struct (_, fields) ->
      List.fold_left (fun acc (_, e) -> collect_labels_opt acc e) acc fields
  | StructDesc (d, fields) ->
      List.fold_left
        (fun acc (_, e) -> collect_labels_opt acc e)
        (collect_labels acc d) fields
  | CastDesc (e1, _, e2)
  | Br_on_cast_desc_eq (_, _, e1, e2)
  | Br_on_cast_desc_eq_fail (_, _, e1, e2)
  | StructSet (e1, _, e2)
  | Array (_, e1, e2)
  | ArraySegment (_, _, e1, e2)
  | ArrayGet (e1, e2)
  | BinOp (_, e1, e2) ->
      collect_labels (collect_labels acc e1) e2
  | ArraySet (e1, e2, e3) | Select (e1, e2, e3) ->
      collect_labels (collect_labels (collect_labels acc e1) e2) e3
  | ArrayFixed (_, l)
  | ContBind (_, _, l)
  | Suspend (_, l)
  | Resume (_, _, l)
  | ResumeThrow (_, _, _, l)
  | ResumeThrowRef (_, _, l)
  | Switch (_, _, l)
  | Throw (_, l)
  | Sequence l ->
      collect_labels_list acc l
  | Dispatch { index; arms; _ } ->
      List.fold_left
        (fun acc (_, b) -> collect_labels_list acc b.desc)
        (collect_labels acc index) arms
  | Match { scrutinee; arms; default } ->
      let acc = collect_labels acc scrutinee in
      let acc =
        List.fold_left
          (fun acc (_, b) -> collect_labels_list acc b.desc)
          acc arms
      in
      collect_labels_list acc default.desc
  | Let (_, body) -> collect_labels_opt acc body
  | Br (_, o) | Return o -> collect_labels_opt acc o
  | If_annotation { then_body; else_body; _ } ->
      let acc = collect_labels_list acc then_body.desc in
      Option.fold ~none:acc
        ~some:(fun b -> collect_labels_list acc b.desc)
        else_body
  | Get _ | Path _ | Unreachable | Nop | Hole | Null | Char _ | String _ | Int _
  | Float _ | StructDefault _ ->
      acc

(* The location of a trapping or effectful operation reached on the eagerly-
   evaluated spine of a [?:] branch [e], or [None] if the branch only reads
   locals/globals and computes pure arithmetic. Descends through pure operators
   (into the operands that are always evaluated) but stops at any nested control
   construct (an inner [if], [?:], block, loop, …): the sub-expressions guarded
   by it are not evaluated unconditionally, and a nested [?:] is linted in its
   own right. The hazard set matches the Wasm validator's ([lint_eager_select]
   in [Validation]): integer division/remainder, field and element accesses,
   [!], the descriptor cast, [array.new_data]/[array.new_elem], [unreachable],
   calls, assignments, throws, and stack-switching — but not plain casts (a
   [ref.cast] is diagnosed by [cast-always-fails] instead). *)

and collect_labels_list acc l = List.fold_left collect_labels acc l

and collect_labels_opt acc o =
  match o with Some i -> collect_labels acc i | None -> acc

let rec find_eager_hazard (e : _ Ast.instr) =
  let ( <|> ) o f = match o with Some _ -> o | None -> f () in
  let descend l =
    List.fold_left (fun acc e -> acc <|> fun () -> find_eager_hazard e) None l
  in
  match e.desc with
  (* Trapping or effectful operations: report the operation itself. *)
  | ArrayGet _ | ArraySet _ | StructGet _ | StructSet _ | GetDescriptor _
  | NonNull _ | CastDesc _ | ArraySegment _ | Unreachable | Call _ | TailCall _
  | Set _ | Tee _ | Throw _ | ThrowRef _ | ContNew _ | ContBind _ | Suspend _
  | Resume _ | ResumeThrow _ | ResumeThrowRef _ | Switch _ ->
      Some e.info
  | BinOp ({ desc = Div (Some _) | Rem _; _ }, _, _) -> Some e.info
  (* Pure operators: descend into their eagerly-evaluated operands. *)
  | BinOp (_, a, b) -> descend [ a; b ]
  | UnOp (_, a)
  | Cast (a, _)
  | Test (a, _)
  | Labelled (_, a)
  | ArrayDefault (_, a)
  | StructDefaultDesc a
  (* An [on]-clause only ever wraps a resume-family call — itself a hazard — so
     descend into it rather than treating it as a nested control construct. *)
  | On (a, _) ->
      find_eager_hazard a
  | Array (_, a, b) -> descend [ a; b ]
  | ArrayFixed (_, l) | Sequence l -> descend l
  | Struct (_, fields) -> descend (List.filter_map (fun (_, v) -> v) fields)
  | StructDesc (d, fields) ->
      find_eager_hazard d <|> fun () ->
      descend (List.filter_map (fun (_, v) -> v) fields)
  | Let (_, init) -> (
      match init with Some e -> find_eager_hazard e | None -> None)
  (* Constants, reads, and allocations of default values never trap; nested
     control constructs guard their sub-expressions, so stop there. *)
  | Get _ | Path _ | Int _ | Float _ | Char _ | String _ | Null | Nop | Hole
  | StructDefault _ | Block _ | Loop _ | While _ | If _ | TryTable _ | Try _
  | TryCatch _ | Br _ | Br_if _ | Br_table _ | Dispatch _ | Match _
  | Br_on_null _ | Br_on_non_null _ | Br_on_cast _ | Br_on_cast_fail _
  | Br_on_cast_desc_eq _ | Br_on_cast_desc_eq_fail _ | Hinted _ | Return _
  | Select _ | If_annotation _ ->
      None

(*** Lint checks on constant operands ***)

(* Parse a Wax integer literal (decimal or [0x] hex, with [_] separators) to an
   [int64], or [None] if it is malformed or does not fit. *)
let int_literal_value s =
  Int64.of_string_opt (String.concat "" (String.split_on_char '_' s))

(* Whether [e] is the integer literal equal to [n]. *)
let int_literal_value_is n (e : _ Ast.instr) =
  match e.desc with Ast.Int s -> int_literal_value s = Some n | _ -> false

(* Whether [e] is the integer literal zero. *)
let int_literal_value_is_zero e = int_literal_value_is 0L e

(* The [int64] value of a constant integer operand, looking through a leading
   sign. A negative literal is [UnOp (Neg, Int …)], not a bare [Int], so the
   constant-condition and shift lints below miss it unless they look through the
   [Neg] — the Wasm validator sees the folded [i32.const] directly. *)
let rec int_operand_value (e : _ Ast.instr) =
  match e.desc with
  | Ast.Int s -> int_literal_value s
  | UnOp ({ desc = Neg; _ }, a) -> Option.map Int64.neg (int_operand_value a)
  | UnOp ({ desc = Pos; _ }, a) -> int_operand_value a
  | _ -> None

(* [x << n] / [x >> n] with a constant [n] at least the operand's bit width:
   Wasm masks [n] modulo the width, so the shift is almost certainly not what
   was meant. The operand width comes from the result cell: a concrete i32/i64,
   or a still-flexible integer at its default width (Number/Int -> i32,
   LargeInt -> i64). This is deferred (see [ctx.deferred_lints]) until typing
   finishes, so a literal a later context pins to a wider type is already
   concrete here — [1 << 40] typed [i64] is fine, typed [i32] is not — and only a
   genuinely unconstrained operand falls back to a default. *)
let lint_shift ctx op result rhs =
  (* Parse a constant shift count unsigned: a hex literal past [2^63] wraps to a
     negative [int64] under a signed parse, so compare unsigned. Look through a
     leading sign, as [lint_condition] does — a negative count (masked modulo the
     width, so still surprising) is [UnOp (Neg, Int …)], not a bare [Int]. A
     literal exceeding [u64] ([None]) is left alone (astronomically large, and
     beyond what the message can render). *)
  let rec shift_count (e : _ Ast.instr) =
    match e.desc with
    | Ast.Int s ->
        let bits = String.concat "" (String.split_on_char '_' s) in
        if String.starts_with ~prefix:"0x" bits then Int64.of_string_opt bits
        else Int64.of_string_opt ("0u" ^ bits)
    | UnOp ({ desc = Neg; _ }, a) -> Option.map Int64.neg (shift_count a)
    | UnOp ({ desc = Pos; _ }, a) -> shift_count a
    | _ -> None
  in
  match op.desc with
  | Shl | Shr _ -> (
      match
        match Cell.get result with
        | Valtype { internal = I32; _ } | Number | Int -> Some 32
        | Valtype { internal = I64; _ } | LargeInt -> Some 64
        | _ -> None
      with
      | None -> ()
      | Some width -> (
          match shift_count rhs with
          | Some n when Int64.unsigned_compare n (Int64.of_int width) >= 0 ->
              Error.shift_overflow ctx.diagnostics ~location:op.info ~width n
          | _ -> ()))
  | _ -> ()

(* Run and clear the lints deferred until their result cells were pinned (see
   [ctx.deferred_lints]). Called once each per-body scope (global initializers,
   then each function body) finishes typing, so the diagnostics stay in source
   order rather than all landing at the end of the module. *)
let flush_deferred_lints ctx =
  List.iter (fun f -> f ()) (List.rev !(ctx.deferred_lints));
  ctx.deferred_lints := []

(* Integer [/] or [%] by a constant zero always traps. [Div (Some _)] and
   [Rem _] are the integer forms ([Div None] is float division, which does not
   trap on a zero divisor). *)
let lint_division ctx op rhs =
  match op.desc with
  | (Div (Some _) | Rem _) when int_literal_value_is_zero rhs ->
      Error.division_by_zero ctx.diagnostics ~location:op.info
  | _ -> ()

(* Parse a Wax float literal (decimal or hex float with [_] separators, or the
   [nan:0x…] form) to an OCaml float, or [None] if it is malformed. *)
let float_literal_value s =
  if String.length s >= 3 && String.equal (String.sub s 0 3) "nan" then
    Some Float.nan
  else float_of_string_opt (String.concat "" (String.split_on_char '_' s))

(* Round an [f64] to the nearest representable [f32] (the demote the runtime
   applies), via the single-precision bit layout. *)
let round_to_f32 f = Int32.float_of_bits (Int32.bits_of_float f)

(* The float value of a constant operand, looking through a leading sign and a
   demote/promote to a float type. The latter matters because a constant [f32]
   has no literal suffix, so the decompiler prints it as [<lit> as f32] — a
   trapping conversion's constant operand ([<big> as f32 as i32_u_strict]) then
   hides behind that [as f32]. Round through the demote so the folded value is
   the one the conversion actually sees. *)
let rec float_operand_value i =
  match i.desc with
  | Ast.Float s -> float_literal_value s
  | UnOp ({ desc = Neg; _ }, e) -> Option.map Float.neg (float_operand_value e)
  | UnOp ({ desc = Pos; _ }, e) -> float_operand_value e
  | Cast (e, Valtype F32) -> Option.map round_to_f32 (float_operand_value e)
  | Cast (e, Valtype F64) -> float_operand_value e
  | _ -> None

(* Whether a trapping (toward-zero) float-to-integer conversion of [f] to the
   given target/signage would trap: [f] is NaN or infinite, or its truncation
   lies outside the target range. Bounds are the exact powers of two, so a value
   is flagged only when it is definitely out of range (no false positives near a
   boundary the float type cannot represent exactly). *)
let float_conversion_traps target signage f =
  if not (Float.is_finite f) then true
  else
    let t = Float.trunc f in
    let pow2 n = Float.ldexp 1. n in
    match (target, signage) with
    | `I32, Signed -> t < -.pow2 31 || t >= pow2 31
    | `I32, Unsigned -> t < 0. || t >= pow2 32
    | `I64, Signed -> t < -.pow2 63 || t >= pow2 63
    | `I64, Unsigned -> t < 0. || t >= pow2 64

(* A trapping float-to-integer conversion ([e as i32_s] and the like — the
   [strict] cast forms lower to [trunc], which traps, rather than [trunc_sat])
   of a constant float that is out of the target range: it always traps. *)
let lint_conversion ctx ~location typ operand =
  match typ with
  | Signedtype { typ = (`I32 | `I64) as target; signage; strict = true } -> (
      match float_operand_value operand with
      | Some f when float_conversion_traps target signage f ->
          Error.conversion_out_of_range ctx.diagnostics ~location
      | _ -> ())
  | _ -> ()

(* Whether two operands are the same pure read (a local or global [get]), so the
   two evaluations yield the same value with no side effect. Restricted to [get]
   to stay conservative — no calls, no field/array reads that could trap. *)
let identical_operands (l : _ Ast.instr) (r : _ Ast.instr) =
  match (l.desc, r.desc) with
  | Get a, Get b -> String.equal a.desc b.desc
  | _ -> false

(* A comparison whose result is constant regardless of its variable operand: an
   unsigned comparison against zero ([a <u 0] is false, [a >=u 0] is true), or a
   comparison of two identical operands ([a < a] is false, [a == a] is true).
   The signed/unsigned option marks an integer comparison; [Eq]/[Ne] carry no
   signage, so a self-comparison is only flagged for a concrete integer operand
   (a float [a == a] is false on NaN, and reference identity is a separate
   concern). *)
let lint_comparison ctx op l r =
  let is_int e =
    match expression_type_opt e with
    | Some c -> (
        match Cell.get c with
        | Valtype { internal = I32 | I64; _ } -> true
        | _ -> false)
    | None -> false
  in
  let tautology =
    match op.desc with
    | Lt (Some Unsigned) when int_literal_value_is_zero r -> Some false
    | Ge (Some Unsigned) when int_literal_value_is_zero r -> Some true
    | Gt (Some Unsigned) when int_literal_value_is_zero l -> Some false
    | Le (Some Unsigned) when int_literal_value_is_zero l -> Some true
    | (Lt (Some _) | Gt (Some _)) when identical_operands l r -> Some false
    | (Le (Some _) | Ge (Some _)) when identical_operands l r -> Some true
    | Eq when identical_operands l r && is_int l -> Some true
    | Ne when identical_operands l r && is_int l -> Some false
    | _ -> None
  in
  match tautology with
  | Some value ->
      Error.tautological_comparison ctx.diagnostics ~location:op.info ~value
  | None -> ()

(* An arithmetic operation with no effect on its result (an identity operand or
   two identical operands), or whose result is a constant regardless of the
   variable operand (an absorbing operand). Off by default. *)
let lint_redundant ctx op l r =
  (* Look through a leading sign so a signed identity literal — [x + -0],
     [x * +1] — is recognised, as the Wasm validator does (it sees the folded
     [iNN.const]; [-0] is [UnOp (Neg, Int 0)], not a bare [Int], on this side). *)
  let is0 e = int_operand_value e = Some 0L in
  let is1 e = int_operand_value e = Some 1L in
  let is_int e =
    match expression_type_opt e with
    | Some c -> (
        match Cell.get c with
        | Valtype { internal = I32 | I64; _ } -> true
        | _ -> false)
    | None -> false
  in
  (* A concrete float operand, or a float literal not yet pinned to a width.
     These identities and absorptions hold only for integer arithmetic — a float
     [0.0 * x] is NaN when [x] is NaN or an infinity, and [-0.0 + 0.0] is [+0.0],
     so neither result is constant or effect-free. The Wasm validator likewise
     runs these checks only for integer binops ([check_int_binop] is reached only
     from [BinOp (I32 _)]/[BinOp (I64 _)]), so gating on non-float here keeps the
     two linters in parity. *)
  let is_float e =
    match expression_type_opt e with
    | Some c -> (
        match Cell.get c with
        | Valtype { internal = F32 | F64; _ } | Float -> true
        | _ -> false)
    | None -> false
  in
  let no_effect () =
    Error.redundant_operation ctx.diagnostics ~location:op.info
      (Wax_utils.Message.text "This operation has no effect on its result.")
  in
  let always v =
    Error.redundant_operation ctx.diagnostics ~location:op.info
      Wax_utils.Message.(
        (text "This operation always yields" ++ int64 v) ^^ text ".")
  in
  if is_float l || is_float r then ()
  else
    match op.desc with
    | Add when is0 l || is0 r -> no_effect () (* x + 0 *)
    | (Sub | Shl | Shr _) when is0 r -> no_effect () (* x - 0, x << 0 *)
    | Mul when is1 l || is1 r -> no_effect () (* x * 1 *)
    | Div (Some _) when is1 r -> no_effect () (* x / 1 *)
    | (Or | Xor) when is0 l || is0 r -> no_effect () (* x | 0, x ^ 0 *)
    | (And | Or) when identical_operands l r -> no_effect () (* x & x, x | x *)
    | Mul when is0 l || is0 r -> always 0L (* x * 0 *)
    | And when is0 l || is0 r -> always 0L (* x & 0 *)
    | Rem _ when is1 r -> always 0L (* x % 1 *)
    | Xor when identical_operands l r -> always 0L (* x ^ x (integer bitwise) *)
    (* [x - x] is 0 only for integers: a float [x - x] is NaN when [x] is NaN or
     an infinity, so the result is not a constant. *)
    | Sub when identical_operands l r && is_int l -> always 0L
    | _ -> ()

(* A branch, loop, or [select] condition that is a constant literal, so it
   always takes the same path. [is_while] excludes the idiomatic infinite loop
   [while <nonzero>] (only [while 0], a loop that never runs, is flagged). *)
let lint_condition ctx ?(is_while = false) (cond : _ Ast.instr) =
  match int_operand_value cond with
  | Some n ->
      let value = n <> 0L in
      if not (is_while && value) then
        Error.constant_condition ctx.diagnostics ~location:cond.info ~value
  | None -> ()

(* Report an eager-evaluation hazard in the [?:] branch [arm]; [select] is the
   location of the whole [?:] (for the secondary caret). *)
let lint_eager_select ctx ~select arm =
  match find_eager_hazard arm with
  | Some location -> Error.eager_select ctx.diagnostics ~location ~select
  | None -> ()

(* Human-readable name of a binary operator's precedence class, for the
   [precedence] lint's message. The classification and the confusing-mix table
   are shared with the Wax printer — see {!Ast_utils.binop_kind} and
   {!Ast_utils.confusing_precedence}. *)
let binop_kind_name = function
  | `Shift -> "shift"
  | `Arith -> "arithmetic"
  | `Bitwise -> "bitwise"
  | `Comparison -> "comparison"

(* Whether the operand [child] of a binary operator was written parenthesized.
   Parentheses are erased by the grammar ([1 << (n - 1)] and [1 << n - 1] parse
   to the same tree), so this is decided from the source text: a parenthesized
   operand is immediately preceded by [(] (a right operand) or followed by [)]
   (a left operand), skipping whitespace. With no source available, assume it is
   parenthesized (so the lint stays silent rather than risk a false positive). *)
let operand_parenthesized ctx ~op ~side (child : _ Ast.instr) =
  match Wax_utils.Diagnostic.source ctx.diagnostics with
  | None -> true
  | Some src ->
      let is_space = function ' ' | '\t' | '\n' | '\r' -> true | _ -> false in
      let n = String.length src in
      (* Index of the next significant (non-trivia) character at or after [i],
         skipping whitespace and comments — line ([//…]) and nesting block
         ([/*…*/]) — so a comment between an operand and its bracket does not
         hide the parenthesis (a whitespace-only skip used to warn spuriously). *)
      let rec skip_fwd i =
        if i >= n then i
        else if is_space src.[i] then skip_fwd (i + 1)
        else if i + 1 < n && src.[i] = '/' && src.[i + 1] = '/' then
          let rec eol j = if j >= n || src.[j] = '\n' then j else eol (j + 1) in
          skip_fwd (eol (i + 2))
        else if i + 1 < n && src.[i] = '/' && src.[i + 1] = '*' then
          let rec blk depth j =
            if j + 1 >= n then n
            else if src.[j] = '/' && src.[j + 1] = '*' then
              blk (depth + 1) (j + 2)
            else if src.[j] = '*' && src.[j + 1] = '/' then
              if depth = 1 then j + 2 else blk (depth - 1) (j + 2)
            else blk depth (j + 1)
          in
          skip_fwd (blk 1 (i + 2))
        else i
      in
      let significant_is c from = from < n && src.[from] = c in
      (* Both operands are tested by scanning forward, since a parenthesised
         operand always has a bracket downstream: the right operand's [(] follows
         the operator, the left operand's [)] follows the operand. *)
      let from =
        match side with
        | `Right -> skip_fwd op.info.loc_end.pos_cnum
        | `Left -> skip_fwd child.info.loc_end.pos_cnum
      in
      significant_is (match side with `Right -> '(' | `Left -> ')') from

(* The [precedence] lint: flag a binary operator [op] one of whose operands is
   itself a binary operator of a confusingly-related class (see
   {!Ast_utils.confusing_precedence}), written without disambiguating
   parentheses. The Wax printer parenthesises exactly these mixes (see
   [Output]), so re-printed / decompiled Wax stays quiet under the lint. *)
let lint_precedence ctx (op : (binop, location) annotated) e1 e2 =
  let outer = Ast_utils.binop_kind op.desc in
  List.iter
    (fun (child, side) ->
      match child.desc with
      | BinOp (inner_op, _, _)
        when Ast_utils.confusing_precedence outer
               (Ast_utils.binop_kind inner_op.desc)
             && not (operand_parenthesized ctx ~op ~side child) ->
          (* The fix is to parenthesise the tighter-binding sub-expression the
             lint identifies ([child]). An edit is one contiguous replacement, so
             it replaces [child]'s span with '(' ^ its source slice ^ ')'. *)
          let edit =
            match Wax_utils.Diagnostic.source ctx.diagnostics with
            | Some src ->
                let s = child.info.loc_start.pos_cnum
                and e = child.info.loc_end.pos_cnum in
                if 0 <= s && s <= e && e <= String.length src then
                  Some
                    {
                      Wax_utils.Diagnostic.edit_location = child.info;
                      new_text = "(" ^ String.sub src s (e - s) ^ ")";
                    }
                else None
            | None -> None
          in
          Error.precedence ?edit ctx.diagnostics ~location:op.info
            ~inner:inner_op.info ~outer_kind:(binop_kind_name outer)
            ~inner_kind:(binop_kind_name (Ast_utils.binop_kind inner_op.desc))
      | _ -> ())
    [ (e1, `Left); (e2, `Right) ]

(* Walk the source AST (before any lowering, so [while] keeps its own condition
   rather than the [if] it desugars to) and report the purely-syntactic lints: a
   constant branch/loop/select condition, and a drop ([_ = e]) of a
   side-effect-free expression. Runs once over the source rather than in the type
   checker's expression handling. Mirrors the case coverage of
   {!collect_labels}. *)
let rec lint_source ctx (i : _ Ast.instr) =
  let list l = List.iter (lint_source ctx) l in
  let opt o = Option.iter (lint_source ctx) o in
  match i.desc with
  | If { cond; if_block; else_block; _ } ->
      lint_condition ctx cond;
      lint_source ctx cond;
      list if_block.desc;
      Option.iter (fun b -> list b.desc) else_block
  | While { cond; step; block; _ } ->
      lint_condition ctx ~is_while:true cond;
      lint_source ctx cond;
      opt step;
      list block.desc
  | Select (c, t, e) ->
      lint_condition ctx c;
      lint_eager_select ctx ~select:i.info t;
      lint_eager_select ctx ~select:i.info e;
      lint_source ctx c;
      lint_source ctx t;
      lint_source ctx e
  | Br_if (_, c) ->
      (* A br_if that carries a value has operand [Sequence [values…; cond]], so
         the condition is the last element; a bare br_if's operand is the
         condition itself. *)
      let cond =
        match c.desc with
        | Sequence (_ :: _ as seq) -> List.nth seq (List.length seq - 1)
        | _ -> c
      in
      lint_condition ctx cond;
      lint_source ctx c
  | Block { block; _ } | Loop { block; _ } | TryTable { block; _ } ->
      list block.desc
  | Try { block; catches; catch_all; _ } ->
      list block.desc;
      List.iter (fun (_, b) -> list b.desc) catches;
      Option.iter (fun b -> list b.desc) catch_all
  | TryCatch { block; arms; _ } ->
      list block.desc;
      List.iter (fun a -> list a.arm_body.desc) arms
  | Call (t, args) | TailCall (t, args) ->
      lint_source ctx t;
      list args
  | Set (id, op, e) ->
      (* A plain self-assignment [x = x] has no effect. A compound assignment
         [x op= x] is not redundant (e.g. [x += x] doubles it). The pointless-
         drop check lives in the [Let] case, since a drop [_ = e] is an anonymous
         binding. *)
      (match (op, e.desc) with
      | None, Get id' when String.equal id.desc id'.desc ->
          Error.redundant_operation ctx.diagnostics ~location:i.info
            (Wax_utils.Message.text
               "This assignment writes the variable back to itself.")
      | _ -> ());
      lint_source ctx e
  | Tee (_, e)
  | Labelled (_, e)
  | Cast (e, _)
  | Test (e, _)
  | NonNull e
  | StructGet (e, _)
  | GetDescriptor e
  | StructDefaultDesc e
  | UnOp (_, e)
  | Hinted (_, e)
  | On (e, _)
  | Br_table (_, e)
  | Br_on_null (_, e)
  | Br_on_non_null (_, e)
  | Br_on_cast (_, _, e)
  | Br_on_cast_fail (_, _, e)
  | ThrowRef e
  | ArrayDefault (_, e)
  | ContNew (_, e) ->
      lint_source ctx e
  | Struct (_, fields) ->
      List.iter (fun (_, e) -> Option.iter (lint_source ctx) e) fields
  | StructDesc (d, fields) ->
      lint_source ctx d;
      List.iter (fun (_, e) -> Option.iter (lint_source ctx) e) fields
  | BinOp (op, e1, e2) ->
      lint_precedence ctx op e1 e2;
      lint_source ctx e1;
      lint_source ctx e2
  | CastDesc (e1, _, e2)
  | Br_on_cast_desc_eq (_, _, e1, e2)
  | Br_on_cast_desc_eq_fail (_, _, e1, e2)
  | StructSet (e1, _, e2)
  | Array (_, e1, e2)
  | ArraySegment (_, _, e1, e2)
  | ArrayGet (e1, e2) ->
      lint_source ctx e1;
      lint_source ctx e2
  | ArraySet (e1, e2, e3) ->
      lint_source ctx e1;
      lint_source ctx e2;
      lint_source ctx e3
  | ArrayFixed (_, l)
  | ContBind (_, _, l)
  | Suspend (_, l)
  | Resume (_, _, l)
  | ResumeThrow (_, _, _, l)
  | ResumeThrowRef (_, _, l)
  | Switch (_, _, l)
  | Throw (_, l)
  | Sequence l ->
      list l
  | Dispatch { index; arms; _ } ->
      lint_source ctx index;
      List.iter (fun (_, b) -> list b.desc) arms
  | Match { scrutinee; arms; default } ->
      lint_source ctx scrutinee;
      List.iter (fun (_, b) -> list b.desc) arms;
      list default.desc
  | Let (bindings, body) ->
      (* A drop [_ = e] is a single anonymous binding; if [e] is effect-free,
         computing it only to discard the result is pointless. *)
      (match (bindings, body) with
      | [ (None, _) ], Some e when is_effectless e ->
          Error.unused_result ctx.diagnostics ~location:e.info
      | _ -> ());
      opt body
  | Br (_, o) | Return o -> opt o
  | If_annotation { then_body; else_body; _ } ->
      list then_body.desc;
      Option.iter (fun b -> list b.desc) else_body
  | Get _ | Path _ | Unreachable | Nop | Hole | Null | Char _ | String _ | Int _
  | Float _ | StructDefault _ ->
      ()

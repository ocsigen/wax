open Wax
module Src = Wasm.Ast.Text
module Simd = Wasm.Simd
module Uint32 = Utils.Uint32
module Cond = Wasm.Cond_solver
module StringMap = Map.Make (String)

(* Raised by [Sequence.get] for a numeric field reference in a module with
   conditional annotations: the field's index depends on which branch is taken,
   so it cannot be resolved to a single Wax name. Caught in [module_] and
   reported as a located diagnostic. *)
exception Numeric_ref_in_conditional of Wasm.Ast.location

(* Raised when an index or label reference resolves to nothing — it is out of
   range, or names an undeclared entity. This only happens on a module that
   validation would reject (with an "unknown ..." error), so conversion gives up
   rather than inventing a target. *)
exception Unresolved_reference

module Sequence = struct
  type t = {
    index_mapping : (Uint32.t, string) Hashtbl.t;
    label_mapping : (string, string) Hashtbl.t;
    mutable last_index : int;
    mutable current_index : int;
    namespace : Namespace.t;
    default : string;
    forbid_numeric : bool;
        (* When set (module-level sequences of a module containing conditional
           annotations), numeric references are refused: a field's index depends
           on which branch is taken, so it cannot be resolved to one name. *)
  }

  let make ?(forbid_numeric = false) namespace default =
    {
      index_mapping = Hashtbl.create 16;
      label_mapping = Hashtbl.create 16;
      last_index = 0;
      current_index = 0;
      namespace;
      default;
      forbid_numeric;
    }

  let register' seq export_tbl (kind : Src.exportable option)
      (id : Src.name option) exports =
    let idx = Uint32.of_int seq.last_index in
    match id with
    | Some nm
      when seq.forbid_numeric && Hashtbl.mem seq.label_mapping nm.Ast.desc ->
        (* The same [$id] was already registered (it appears in another branch
           of a conditional). Reuse its Wax name so references stay coherent,
           but still consume an index slot so positional naming via
           [get_current] stays aligned with the conversion order. This only
           applies to module-level sequences of a conditional module
           ([forbid_numeric]); locals reuse a single sequence across functions,
           where a repeated [$id] is a distinct variable, not the same entity. *)
        let name = Hashtbl.find seq.label_mapping nm.Ast.desc in
        seq.last_index <- seq.last_index + 1;
        Hashtbl.add seq.index_mapping idx name;
        name
    | _ ->
        let name =
          let name =
            match (id, exports) with
            | (Some nm, _ | None, nm :: _)
              when Lexer.is_valid_identifier nm.Ast.desc ->
                nm.Ast.desc
            | _ -> (
                match kind with
                | None -> seq.default
                | Some kind -> (
                    match Hashtbl.find_opt export_tbl (kind, Src.Num idx) with
                    | Some (nm :: _) when Lexer.is_valid_identifier nm.Ast.desc
                      ->
                        nm.Ast.desc
                    | _ -> seq.default))
          in
          Namespace.add seq.namespace name
        in
        seq.last_index <- seq.last_index + 1;
        Hashtbl.add seq.index_mapping idx name;
        Option.iter
          (fun id -> Hashtbl.add seq.label_mapping id.Ast.desc name)
          id;
        name

  let register seq export_tbl kind id exports =
    ignore (register' seq export_tbl kind id exports)

  let get seq (idx : Src.idx) =
    {
      idx with
      desc =
        (match idx.desc with
        | Num n -> (
            if seq.forbid_numeric then
              raise (Numeric_ref_in_conditional idx.Ast.info);
            match Hashtbl.find_opt seq.index_mapping n with
            | Some name -> name
            | None -> raise Unresolved_reference)
        | Id id -> (
            match Hashtbl.find_opt seq.label_mapping id with
            | Some name -> name
            | None -> raise Unresolved_reference));
    }

  let get_current seq =
    let i = seq.current_index in
    seq.current_index <- i + 1;
    Ast.no_loc (Hashtbl.find seq.index_mapping (Uint32.of_int i))

  (* A fresh, unique name in this sequence's namespace, for an entity not in the
     source (e.g. an element segment synthesised from an inline table init). *)
  let fresh_name seq = Ast.no_loc (Namespace.add seq.namespace seq.default)
  let consume_currents seq = seq.current_index <- seq.last_index
end

module LabelStack = struct
  type t = {
    ns : Namespace.t;
    stack : (string option * (string * bool ref)) list;
  }

  let push st (label : Src.name option) =
    let ns = Namespace.dup st.ns in
    let used = ref false in
    let name =
      Namespace.add ns
        (match label with
        | Some label when Lexer.is_valid_identifier label.desc -> label.desc
        | _ -> "l")
    in
    ( (fun () ->
        if !used then
          Some
            (match label with
            | Some label -> { label with desc = name }
            | None -> Ast.no_loc name)
        else None),
      {
        ns;
        stack =
          (Option.map (fun l -> l.Ast.desc) label, (name, used)) :: st.stack;
      } )

  let get st (idx : Src.idx) =
    let name, used =
      match idx.desc with
      | Num n -> (
          match List.nth_opt st.stack (Uint32.to_int n) with
          | Some entry -> snd entry
          | None -> raise Unresolved_reference)
      | Id id -> (
          match List.assoc_opt (Some id) st.stack with
          | Some entry -> entry
          | None -> raise Unresolved_reference)
    in
    used := true;
    { idx with desc = name }

  let make () = { ns = Namespace.make ~kind:`Label (); stack = [] }
end

module CondTbl = struct
  (* A single Wax name may stand for several declarations across conditional
     branches with different definitions (e.g. a function imported with a
     different signature, hence a different arity, in each branch of an
     [(@if …)]). Each declaration is recorded with the assumption under which
     it holds, and a lookup resolves against the current branch's assumption,
     so a reference in a given branch sees the matching declaration. With a
     single declaration this degenerates to a plain name-keyed table. *)
  type 'a t = (string, (Cond.t * 'a) list) Hashtbl.t

  let make () : _ t = Hashtbl.create 16

  let add tbl asm name v =
    let prev = try Hashtbl.find tbl name with Not_found -> [] in
    Hashtbl.replace tbl name ((asm, v) :: prev)

  (* Raises [Not_found] when the name is unknown, like the plain table did. *)
  let find tbl asm name =
    match Hashtbl.find tbl name with
    | [ (_, v) ] -> v
    | entries -> (
        (* Resolve to the declaration whose branch is reachable under the
           current assumption, pruning declarations from mutually-exclusive
           branches. Falls back to the most recent if none is compatible
           (only for a reference that is itself unreachable). *)
        match
          List.find_opt
            (fun (c, _) -> Cond.is_satisfiable (Cond.and_ asm c))
            entries
        with
        | Some (_, v) -> v
        | None -> snd (List.hd entries))

  (* All declarations whose branch is reachable under [asm]. More than one
     means the reference does not select a single branch. *)
  let compatible tbl asm name =
    match Hashtbl.find_opt tbl name with
    | None -> []
    | Some entries ->
        List.filter_map
          (fun (c, v) ->
            if Cond.is_satisfiable (Cond.and_ asm c) then Some v else None)
          entries
end

type ctx = {
  types : Sequence.t;
  struct_fields : (string, Sequence.t * string list) Hashtbl.t;
  globals : Sequence.t;
  functions : Sequence.t;
  memories : Sequence.t;
  tables : Sequence.t;
  tags : Sequence.t;
  datas : Sequence.t;
  elems : Sequence.t;
  referenced_elems : (string, unit) Hashtbl.t;
      (* Wax names of element segments used by table.init / elem.drop /
         array.*_elem. A declarative segment is normally dropped (regenerated by
         [to_wasm] from ref.func usage), but one that is referenced this way
         needs an explicit declaration so the reference resolves. *)
  type_defs : Src.subtype CondTbl.t;
  implicit_types : (Uint32.t, Src.functype) Hashtbl.t;
      (* Function types that the WAT text format synthesises from inline
         [(param)]/[(result)] signatures (the type-use abbreviation), keyed by
         the type index they occupy. The source AST keeps such uses inline and
         does not materialise them as [Types] fields, so this table is what lets
         a numeric [(type N)] elsewhere resolve to the implicit type. These types
         are anonymous: they are rendered inline ([&fn(..)] / an inline [sign]),
         never as a named Wax type. Empty for modules with conditional
         annotations, where numeric references are forbidden anyway. *)
  function_types : Src.typeuse CondTbl.t;
  exports : (Src.exportable * string, (Cond.t * Src.name) list) Hashtbl.t;
      (* Standalone [(export …)] fields, keyed by the Wax name of their target,
         attached to that target as [#[export]] attributes. Each is paired with
         the conditional-branch assumption under which it appears, so a target
         that exists in several mutually exclusive branches receives only the
         exports of its own branch (and not the same export once per branch). *)
  mutable start : string option;
      (* Wax name of the start function, if any; rendered as a [#[start]]
         attribute on that function rather than a separate field. *)
  locals : Sequence.t;
  labels : LabelStack.t;
  tag_types : Src.typeuse CondTbl.t;
  label_arities : (string option * int) list;
  return_arity : int;
  strict_constants : bool;
      (* When set, every numeric constant is wrapped in a cast to its concrete
         type ([0 as i32], [0.0 as f64], ...). This keeps Wax type inference
         from re-typing an otherwise polymorphic literal, so a type mismatch in
         the source survives the round-trip. *)
  diagnostics : Utils.Diagnostic.context;
  cond_env : Cond.env;
  cond_diag : Utils.Diagnostic.context;
  mutable cond_asm : Cond.t;
      (* Assumption for the conditional branch currently being registered or
         converted; threaded through [Module_if_annotation]/[If_annotation] so
         the type tables above resolve to the right per-branch declaration. *)
}

let get_annot e = fst e.Ast.desc
let get_type e = snd e.Ast.desc

(* Build a located [annotated_array] element ([name : type] in a struct, or a
   subtype in a rec group), keeping the source location so a trailing comment
   attaches to the whole entry. *)
let annotated loc a t = { Ast.desc = (a, t); info = loc }

let idx ctx kind i =
  match kind with
  | `Type -> Sequence.get ctx.types i
  | `Global -> Sequence.get ctx.globals i
  | `Func -> Sequence.get ctx.functions i
  | `Mem -> Sequence.get ctx.memories i
  | `Table -> Sequence.get ctx.tables i
  | `Tag -> Sequence.get ctx.tags i
  | `Data -> Sequence.get ctx.datas i
  | `Elem -> Sequence.get ctx.elems i
  | `Local -> Sequence.get ctx.locals i

let label ctx i = LabelStack.get ctx.labels i

let heaptype st (t : Src.heaptype) : Ast.heaptype =
  match t with
  | Src.Func -> Ast.Func
  | NoFunc -> NoFunc
  | Exn -> Exn
  | NoExn -> NoExn
  | Cont -> Cont
  | NoCont -> NoCont
  | Extern -> Extern
  | NoExtern -> NoExtern
  | Any -> Any
  | Eq -> Eq
  | I31 -> I31
  | Struct -> Struct
  | Array -> Array
  | None_ -> None_
  | Type i -> Type (idx st `Type i)

let reftype st (t : Src.reftype) : Ast.reftype =
  { nullable = t.nullable; typ = heaptype st t.typ }

let valtype st (t : Src.valtype) : Ast.valtype =
  match t with
  | I32 -> I32
  | I64 -> I64
  | F32 -> F32
  | F64 -> F64
  | V128 -> V128
  | Ref t -> Ref (reftype st t)

let functype st (t : Src.functype) : Ast.functype =
  {
    params = Array.map (fun (id, t) -> (id, valtype st t)) t.params;
    results = Array.map (fun t -> valtype st t) t.results;
  }

let packedtype _ (t : Src.packedtype) : Ast.packedtype = t

let storagetype st (t : Src.storagetype) : Ast.storagetype =
  match t with
  | Value t -> Value (valtype st t)
  | Packed t -> Packed (packedtype st t)

let muttype typ st (t : _ Src.muttype) : _ Ast.muttype =
  { t with typ = typ st t.typ }

let fieldtype st = muttype storagetype st

let comptype st name (t : Src.comptype) : Ast.comptype =
  match t with
  | Func t -> Func (functype st t)
  | Struct l ->
      let seq = fst (Hashtbl.find st.struct_fields name) in
      Struct
        (Array.mapi
           (fun i t ->
             let id =
               Sequence.get seq
                 (match get_annot t with
                 | None -> Ast.no_loc (Src.Num (Uint32.of_int i))
                 | Some id -> { id with desc = Id id.Ast.desc })
             in
             annotated t.Ast.info id (fieldtype st (get_type t)))
           l)
  | Array t -> Array (fieldtype st t)
  | Cont i -> Cont (idx st `Type i)

let subtype st name (t : Src.subtype) : Ast.subtype =
  {
    typ = comptype st name t.typ;
    supertype = Option.map (fun i -> idx st `Type i) t.supertype;
    final = t.final;
  }

let rectype st (t : Src.rectype) : Ast.rectype =
  Array.map
    (fun t ->
      let name = Sequence.get_current st.types in
      annotated t.Ast.info name (subtype st name.desc (get_type t)))
    t

let globaltype st = muttype valtype st

type _ kind =
  | Type : Src.subtype kind
  | Func : Src.typeuse kind
  | Tag : Src.typeuse kind

(* Run [f] with [ctx.cond_asm] extended by the branch condition [cond] (taken
   positively for [@then], negatively for [@else]), restoring it afterwards.
   Used in both the name-registration passes and the conversion so that type
   declarations are recorded under, and references resolved against, the
   assumption of the branch they appear in. *)
let with_cond ctx ~location cond positive f =
  let saved = ctx.cond_asm in
  let c = Cond.of_cond ctx.cond_env ctx.cond_diag ~location cond in
  ctx.cond_asm <- Cond.and_ saved (if positive then c else Cond.not_ c);
  Fun.protect ~finally:(fun () -> ctx.cond_asm <- saved) f

let lookup_type (type typ) ctx (kind : typ kind) idx : typ =
  let get seq tbl idx =
    CondTbl.find tbl ctx.cond_asm (Sequence.get seq idx).desc
  in
  match kind with
  | Type -> get ctx.types ctx.type_defs idx
  | Func -> get ctx.functions ctx.function_types idx
  | Tag -> get ctx.tags ctx.tag_types idx

let register_type (type typ) ctx export_tbl (kind : typ kind) idx exports
    (typ : typ) =
  let register seq tbl kind idx =
    CondTbl.add tbl ctx.cond_asm
      (Sequence.register' seq export_tbl kind idx exports)
      typ
  in
  match kind with
  | Type -> assert false
  | Func -> register ctx.functions ctx.function_types (Some Func) idx
  | Tag -> register ctx.tags ctx.tag_types (Some Tag) idx

(* The source module is converted without being validated first (validation is
   off by default), so it may be type-invalid in ways the conversion cannot
   represent. Report such a case and abort the conversion rather than crashing
   on an [assert false]. *)
let conversion_error ctx ~location message =
  Utils.Diagnostic.report ctx.diagnostics ~location ~severity:Error ~message ();
  Utils.Diagnostic.abort ()

let functype_arity { Src.params; results } =
  (Array.length params, Array.length results)

(* The implicit (anonymous) function type a numeric [(type N)] denotes, if [N]
   was synthesised from an inline signature; [None] for a named/explicit type or
   a symbolic reference. Consulted before the named-type tables so such a
   reference resolves to its signature rather than raising. *)
let implicit_functype ctx (idx : Src.idx) =
  match idx.Ast.desc with
  | Src.Num n -> Hashtbl.find_opt ctx.implicit_types n
  | Id _ -> None

let type_arity ctx idx =
  match implicit_functype ctx idx with
  | Some ty -> functype_arity ty
  | None -> (
      match (lookup_type ctx Type idx).typ with
      | Func ty -> functype_arity ty
      | Struct _ | Array _ | Cont _ ->
          conversion_error ctx ~location:idx.Ast.info (fun f () ->
              Format.fprintf f "This type should be a function type."))

let typeuse_arity ctx (i, ty) =
  match (i, ty) with
  | _, Some t -> functype_arity t
  | Some i, None -> type_arity ctx i
  | None, None -> assert false

let blocktype_arity ctx (typ : Src.blocktype option) =
  match typ with
  | None -> (0, 0)
  | Some (Valtype _) -> (0, 1)
  | Some (Typeuse t) -> typeuse_arity ctx t

(* The arity used to convert a reference (how many operands a call consumes) is
   fixed in the produced Wax, so it must be the same in every branch reachable
   here. If a name is declared with different arities in mutually-exclusive
   branches and the reference does not select one (e.g. it sits in unconditional
   code, as [dv_make] does in io.wat), there is no single faithful conversion;
   report it rather than emit a wrong-arity call. *)
let checked_arity ctx kind tbl what name_idx compatible =
  let arity = typeuse_arity ctx (lookup_type ctx kind name_idx) in
  let name = (Sequence.get tbl name_idx).Ast.desc in
  (match compatible ctx.cond_asm name with
  | _ :: _ :: _ as l when List.exists (fun t -> typeuse_arity ctx t <> arity) l
    ->
      Utils.Diagnostic.report ctx.diagnostics ~location:name_idx.Ast.info
        ~severity:Error
        ~message:(fun f () ->
          Format.fprintf f
            "%s $%s is declared with different arities in mutually-exclusive \
             conditional branches but referenced where the branch is \
             undetermined; this cannot be converted to Wax."
            what name)
        ()
  | _ -> ());
  arity

let function_arity ctx f =
  checked_arity ctx Func ctx.functions "Function" f
    (CondTbl.compatible ctx.function_types)

let tag_arity ctx t =
  checked_arity ctx Tag ctx.tags "Tag" t (CondTbl.compatible ctx.tag_types)

let label_arity ctx (idx : Src.idx) =
  match idx.desc with
  | Id id -> (
      match
        List.find_opt
          (fun e -> match e with Some id', _ -> id = id' | _ -> false)
          ctx.label_arities
      with
      | Some e -> snd e
      | None -> raise Unresolved_reference)
  | Num i -> (
      match List.nth_opt ctx.label_arities (Uint32.to_int i) with
      | Some e -> snd e
      | None -> raise Unresolved_reference)

(* (parameter count, result count) of the function type a continuation type
   wraps. *)
let cont_arity ctx idx =
  match (lookup_type ctx Type idx).typ with
  | Cont ft -> type_arity ctx ft
  | Func _ | Struct _ | Array _ ->
      conversion_error ctx ~location:idx.Ast.info (fun f () ->
          Format.fprintf f "This type should be a continuation type.")

(* Number of values a [switch] to continuation [ct] produces: the parameters of
   the continuation referenced by the last parameter of [ct]'s function type. *)
let switch_output ctx ct =
  match (lookup_type ctx Type ct).typ with
  | Cont ft -> (
      match (lookup_type ctx Type ft).typ with
      | Func { params; _ } when Array.length params > 0 -> (
          match snd params.(Array.length params - 1) with
          | Ref { typ = Type ct2; _ } -> fst (cont_arity ctx ct2)
          | _ -> 0)
      | Func _ | Struct _ | Array _ | Cont _ -> 0)
  | Func _ | Struct _ | Array _ -> 0

let on_clause ctx (c : Src.on_clause) : Ast.on_clause =
  match c with
  | OnLabel (tag, lbl) -> OnLabel (idx ctx `Tag tag, label ctx lbl)
  | OnSwitch tag -> OnSwitch (idx ctx `Tag tag)

(*
Step 1: traverse types and find existing names
Step 2: use this info to generate using names without reusing existing names
*)

(*ZZZ
  - first pass to see missing labels
  - explode tuples
*)

module Stack = struct
  type stack = (bool * Ast.location Ast.instr) list
  type 'a t = stack -> stack * 'a

  let rec complete n cur =
    if n = 0 then cur else complete (n - 1) (Ast.no_loc Ast.Hole :: cur)

  let rec grab_rec n stack cur =
    if n = 0 then (stack, cur)
    else
      match stack with
      | (true, instr) :: rem -> grab_rec (n - 1) rem (instr :: cur)
      | _ -> (stack, complete n cur)

  let consume inputs stack =
    if inputs = 0 then (stack, ())
    else
      ( (match stack with
        | (true, instr) :: rem -> (false, instr) :: rem
        | _ -> stack),
        () )

  let grab n stack = grab_rec n stack []
  let push arity i stack = ((arity = 1, i) :: stack, ())
  let push_poly i stack = ((false, i) :: stack, ())

  let pop stack =
    match stack with
    | (true, i) :: rem -> (rem, i)
    | _ -> (stack, Ast.no_loc Ast.Hole)

  let try_pop stack =
    match stack with (true, i) :: rem -> (rem, Some i) | _ -> (stack, None)

  let run f =
    let st, () = f [] in
    List.rev_map snd st
end

let ( let* ) e f st =
  let st, v = e st in
  f v st

let return v st = (st, v)
let sequence l = match l with [ i ] -> i | _ -> Ast.no_loc (Ast.Sequence l)

let is_integer =
  let int_re =
    Re.(
      compile
        (whole_string
           (alt
              [
                rep1 (alt [ rg '0' '9'; char '_' ]);
                seq
                  [
                    str "0x";
                    rep1 (alt [ rg '0' '9'; rg 'a' 'f'; rg 'A' 'F'; char '_' ]);
                  ];
              ])))
  in
  fun s -> Re.execp int_re s

let is_negative n = n.[0] = '-'

let remove_sign n =
  if n.[0] = '-' || n.[0] = '+' then String.sub n 1 (String.length n - 1) else n

(* A Wax operator carries its own source location; reuse the (source or target)
   instruction's, which is the best approximation we have when reconstructing
   from Wasm. Polymorphic in the carried [desc] so it works for either AST. *)
let op_loc (i : (_, Ast.location) Ast.annotated) op :
    (_, Ast.location) Ast.annotated =
  { i with Ast.desc = op }

let integer i n : _ Ast.instr =
  let e : _ Ast.instr = { i with desc = Int (remove_sign n) } in
  if is_negative n then { i with desc = UnOp (op_loc i Ast.Neg, e) } else e

let float i n =
  if is_integer n then integer i n
  else
    let e : _ Ast.instr = { i with desc = Float (remove_sign n) } in
    if is_negative n then { i with desc = UnOp (op_loc i Ast.Neg, e) } else e

let sequence_opt l =
  match l with
  | [] -> None
  | [ i ] -> Some i
  | l -> Some (Ast.no_loc (Ast.Sequence l))

let reasonable_string =
  Re.(
    compile
      (whole_string
         (rep
            (alt
               [ diff any (rg '\000' '\031'); char '\n'; char '\r'; char '\t' ]))))

let string_args n args =
  if n = Uint32.zero then None
  else
    try
      if Uint32.of_int (List.length args) <> n then raise Exit;
      List.iter
        (fun arg ->
          match arg.Ast.desc with
          | Ast.Int c
            when let c = int_of_string c in
                 c >= 0 && c < 256 ->
              ()
          | _ -> raise Exit)
        args;
      let b = Bytes.create (Uint32.to_int n) in
      List.iteri
        (fun i arg ->
          match arg.Ast.desc with
          | Ast.Int c -> Bytes.set b i (Char.chr (int_of_string c))
          | _ -> assert false)
        args;
      let s = Bytes.to_string b in
      if String.is_valid_utf_8 s && Re.execp reasonable_string s then Some s
      else None
    with Exit -> None

let inttype ty : Ast.valtype =
  match ty with
  | `I32 -> I32
  | `I64 -> I64
  | `F32 -> I32
  | `F64 -> I64
  | _ -> assert false

let floattype ty : Ast.valtype =
  match ty with
  | `I32 -> F32
  | `I64 -> F64
  | `F32 -> F32
  | `F64 -> F64
  | _ -> assert false

let int_un_op i0 sz (op : Src.int_un_op) =
  let with_loc (i : _ Ast.instr_desc) = { i0 with Ast.desc = i } in
  (* A no-argument instruction method [recv.meth()]. *)
  let method_call recv meth =
    with_loc (Call (with_loc (StructGet (recv, Ast.no_loc meth)), []))
  in
  let* e' = Stack.try_pop in
  let e ty =
    match e' with
    | Some e -> e
    | None -> Ast.no_loc (Ast.Cast (Ast.no_loc Ast.Hole, Valtype ty))
  in
  Stack.push 1
    (match op with
    | Clz -> method_call (e (inttype sz)) "clz"
    | Ctz -> method_call (e (inttype sz)) "ctz"
    | Popcnt -> method_call (e (inttype sz)) "popcnt"
    | Eqz -> with_loc (UnOp (op_loc i0 Ast.Not, e (inttype sz)))
    | Trunc (_, signage) ->
        with_loc
          (Cast
             (e (floattype sz), Signedtype { typ = sz; signage; strict = true }))
    | TruncSat (_, signage) ->
        with_loc
          (Cast
             (e (floattype sz), Signedtype { typ = sz; signage; strict = false }))
    | Reinterpret ->
        method_call
          (let e = e (floattype sz) in
           if e' = None then e
           else { e with desc = Ast.Cast (e, Valtype (floattype sz)) })
          "to_bits"
    | ExtendS `_32 ->
        (* i64.extend32_s *)
        with_loc
          (Cast
             ( (let e = e (inttype `I32) in
                if e' = None then e
                else { e with desc = Ast.Cast (e, Valtype (inttype `I32)) }),
               Signedtype { typ = sz; signage = Signed; strict = false } ))
    | ExtendS `_8 -> method_call (e (inttype sz)) "extend8_s"
    | ExtendS `_16 -> method_call (e (inttype sz)) "extend16_s")

let int_bin_op i0 (op : Src.int_bin_op) =
  let with_loc (i : _ Ast.instr_desc) = { i0 with Ast.desc = i } in
  let symbol op =
    let* e2 = Stack.pop in
    let* e1 = Stack.pop in
    Stack.push 1 (with_loc (BinOp (op_loc i0 op, e1, e2)))
  in
  match op with
  | Add -> symbol Add
  | Sub -> symbol Sub
  | Mul -> symbol Mul
  | Div s -> symbol (Div (Some s))
  | Rem s -> symbol (Rem s)
  | And -> symbol And
  | Or -> symbol Or
  | Xor -> symbol Xor
  | Shl -> symbol Shl
  | Shr s -> symbol (Shr s)
  | Rotl ->
      let* e2 = Stack.pop in
      let* e1 = Stack.pop in
      Stack.push 1
        (with_loc (Call (with_loc (StructGet (e1, Ast.no_loc "rotl")), [ e2 ])))
  | Rotr ->
      let* e2 = Stack.pop in
      let* e1 = Stack.pop in
      Stack.push 1
        (with_loc (Call (with_loc (StructGet (e1, Ast.no_loc "rotr")), [ e2 ])))
  | Eq -> symbol Eq
  | Ne -> symbol Ne
  | Lt s -> symbol (Lt (Some s))
  | Gt s -> symbol (Gt (Some s))
  | Le s -> symbol (Le (Some s))
  | Ge s -> symbol (Ge (Some s))

let float_un_op i0 sz (op : Src.float_un_op) =
  let with_loc (i : _ Ast.instr_desc) = { i0 with Ast.desc = i } in
  (* A no-argument instruction method [recv.meth()]. *)
  let method_call recv meth =
    with_loc (Call (with_loc (StructGet (recv, Ast.no_loc meth)), []))
  in
  let* e' = Stack.try_pop in
  let e ty =
    match e' with
    | Some e -> e
    | None -> Ast.no_loc (Ast.Cast (Ast.no_loc Ast.Hole, Valtype ty))
  in
  Stack.push 1
    (match op with
    | Neg -> with_loc (UnOp (op_loc i0 Ast.Neg, e (floattype sz)))
    | Abs -> method_call (e (floattype sz)) "abs"
    | Ceil -> method_call (e (floattype sz)) "ceil"
    | Floor -> method_call (e (floattype sz)) "floor"
    | Trunc -> method_call (e (floattype sz)) "trunc"
    | Nearest -> method_call (e (floattype sz)) "nearest"
    | Sqrt -> method_call (e (floattype sz)) "sqrt"
    | Convert (sz', signage) ->
        with_loc
          (Cast
             ( e (inttype (sz' :> [ `I32 | `I64 | `F32 | `F64 ])),
               Signedtype { typ = sz; signage; strict = false } ))
    | Reinterpret ->
        method_call
          (let e = e (inttype sz) in
           if e' = None then e
           else { e with desc = Ast.Cast (e, Valtype (inttype sz)) })
          "from_bits")

let float_bin_op i0 (op : Src.float_bin_op) =
  let with_loc (i : _ Ast.instr_desc) = { i0 with Ast.desc = i } in
  let symbol op =
    let* e2 = Stack.pop in
    let* e1 = Stack.pop in
    Stack.push 1 (with_loc (BinOp (op_loc i0 op, e1, e2)))
  in
  match op with
  | Add -> symbol Add
  | Sub -> symbol Sub
  | Mul -> symbol Mul
  | Div -> symbol (Div None)
  | Min ->
      let* e2 = Stack.pop in
      let* e1 = Stack.pop in
      Stack.push 1
        (with_loc (Call (with_loc (StructGet (e1, Ast.no_loc "min")), [ e2 ])))
  | Max ->
      let* e2 = Stack.pop in
      let* e1 = Stack.pop in
      Stack.push 1
        (with_loc (Call (with_loc (StructGet (e1, Ast.no_loc "max")), [ e2 ])))
  | CopySign ->
      let* e2 = Stack.pop in
      let* e1 = Stack.pop in
      Stack.push 1
        (with_loc
           (Call (with_loc (StructGet (e1, Ast.no_loc "copysign")), [ e2 ])))
  | Eq -> symbol Eq
  | Ne -> symbol Ne
  | Lt -> symbol (Lt None)
  | Gt -> symbol (Gt None)
  | Le -> symbol (Le None)
  | Ge -> symbol (Ge None)

let blocktype ctx (typ : Src.blocktype option) =
  match typ with
  | None -> { Ast.params = [||]; results = [||] }
  | Some (Valtype ty) -> { Ast.params = [||]; results = [| valtype ctx ty |] }
  | Some (Typeuse (ty_idx, sign)) ->
      let { Src.params; results } =
        match (ty_idx, sign) with
        | _, Some sign -> sign
        | Some idx, _ -> (
            let ty = lookup_type ctx Type idx in
            match ty.typ with
            | Struct _ | Array _ | Cont _ -> assert false
            | Func sign -> sign)
        | None, None -> assert false
      in
      {
        Ast.params = Array.map (fun (_, t) -> (None, valtype ctx t)) params;
        results = Array.map (fun t -> valtype ctx t) results;
      }

let push_label ctx ~loop label typ =
  let arity = blocktype_arity ctx typ in
  let i = if loop then fst arity else snd arity in
  let label_arities =
    (Option.map (fun l -> l.Ast.desc) label, i) :: ctx.label_arities
  in
  let label, labels = LabelStack.push ctx.labels label in
  (label, { ctx with labels; label_arities })

(*
let bottom_heap_type ctx (t : Src.heaptype) : Ast.heaptype =
  match t with
  | Any | Eq | I31 | Struct | Array | None_ -> None_
  | Func | NoFunc -> NoFunc
  | Exn | NoExn -> NoExn
  | Extern | NoExtern -> NoExtern
  | Type ty -> (
      match (lookup_type ctx Type ty).typ with
      | Struct _ | Array _ -> None_
      | Func _ -> NoFunc)
*)
(* Trailing [align]/[offset] literal arguments of a memory access: [align] only
   when it differs from the natural alignment, [offset] only when non-zero (and
   then [align] too, since they are positional). *)
let mem_extra with_loc (memarg : Src.memarg) nat =
  let lit v = with_loc (Ast.Int (Utils.Uint64.to_string v)) in
  let nat = Utils.Uint64.of_int nat in
  if Utils.Uint64.compare memarg.offset Utils.Uint64.zero <> 0 then
    [ lit memarg.align; lit memarg.offset ]
  else if Utils.Uint64.compare memarg.align nat <> 0 then [ lit memarg.align ]
  else []

(* The callee of an indirect call: [tab[index]] narrowed to the call's function
   type, i.e. [tab[index] as &$ft] (named type) or [tab[index] as &fn(..)] (an
   inline type, with no named type to reference). The cast is always emitted;
   [to_wasm] re-fuses the whole pattern back to [call_indirect]. *)
let indirect_callee ctx with_loc tab ((tyidx, sign) : Src.typeuse) index =
  let tabget =
    with_loc (Ast.ArrayGet (with_loc (Ast.Get (idx ctx `Table tab)), index))
  in
  let inline_functype (s : Src.functype) : Ast.casttype =
    let sign : Ast.functype =
      {
        params = Array.map (fun (_, t) -> (None, valtype ctx t)) s.params;
        results = Array.map (fun t -> valtype ctx t) s.results;
      }
    in
    Ast.Functype { nullable = true; sign }
  in
  let cast_type : Ast.casttype option =
    match Option.bind tyidx (implicit_functype ctx) with
    | Some ft ->
        (* Anonymous implicit type: no named type to reference, render inline. *)
        Some (inline_functype ft)
    | None -> (
        match tyidx with
        | Some ti ->
            Some
              (Ast.Valtype
                 (Ast.Ref { nullable = true; typ = Ast.Type (idx ctx `Type ti) }))
        | None -> Option.map inline_functype sign)
  in
  match cast_type with
  | Some ct -> with_loc (Ast.Cast (tabget, ct))
  | None -> tabget

let rec instruction ctx (i : _ Src.instr) : unit Stack.t =
  let with_loc (i' : _ Ast.instr_desc) = { i with Ast.desc = i' } in
  let mem_call m meth args =
    with_loc
      (Ast.Call
         ( with_loc
             (Ast.StructGet
                (with_loc (Ast.Get (idx ctx `Mem m)), Ast.no_loc meth)),
           args ))
  in
  let table_call t meth args =
    with_loc
      (Ast.Call
         ( with_loc
             (Ast.StructGet
                (with_loc (Ast.Get (idx ctx `Table t)), Ast.no_loc meth)),
           args ))
  in
  (* [seg.drop()] on a data or element segment. *)
  let drop_call kind seg =
    with_loc
      (Ast.Call
         ( with_loc
             (Ast.StructGet
                (with_loc (Ast.Get (idx ctx kind seg)), Ast.no_loc "drop")),
           [] ))
  in
  (* [recv.meth(args)] method call and [f(args)] free-function call, used for
     SIMD intrinsics. *)
  let meth_call recv meth args =
    with_loc (Ast.Call (with_loc (Ast.StructGet (recv, Ast.no_loc meth)), args))
  in
  let free_call name args =
    with_loc (Ast.Call (with_loc (Ast.Get (Ast.no_loc name)), args))
  in
  match i.desc with
  | Block { label; typ; block } ->
      let label, ctx = push_label ctx ~loop:false label typ in
      let block = Stack.run (instructions ctx block) in
      let inputs, outputs = blocktype_arity ctx typ in
      let* () = Stack.consume inputs in
      Stack.push
        (if inputs > 0 then 0 else outputs)
        (with_loc (Block { label = label (); typ = blocktype ctx typ; block }))
  | Loop { label; typ; block } ->
      let label, ctx = push_label ctx ~loop:true label typ in
      let block = Stack.run (instructions ctx block) in
      let inputs, outputs = blocktype_arity ctx typ in
      let* () = Stack.consume inputs in
      Stack.push
        (if inputs > 0 then 0 else outputs)
        (with_loc (Loop { label = label (); typ = blocktype ctx typ; block }))
  | If { label; typ; if_block; else_block } ->
      let label, ctx = push_label ctx ~loop:false label typ in
      (* Keep the (then ...)/(else ...) clause locations on the Wax blocks so a
         comment opening a clause attaches to the block rather than the
         condition or the previous clause's last instruction. *)
      let if_block =
        { if_block with Ast.desc = Stack.run (instructions ctx if_block.desc) }
      in
      let else_block =
        if else_block.desc = [] then None
        else
          Some
            {
              else_block with
              Ast.desc = Stack.run (instructions ctx else_block.desc);
            }
      in
      let inputs, outputs = blocktype_arity ctx typ in
      let* cond = Stack.pop in
      let* () = Stack.consume inputs in
      Stack.push
        (if inputs > 0 then 0 else outputs)
        (with_loc
           (If
              {
                label = label ();
                typ = blocktype ctx typ;
                cond;
                if_block;
                else_block;
              }))
  | TryTable { label = labl; typ; block; catches } ->
      let labl, block_ctx = push_label ctx ~loop:false labl typ in
      let block = Stack.run (instructions block_ctx block) in
      let catches =
        List.map
          (fun (catch : Src.catch) : Ast.catch ->
            match catch with
            | Catch (t, l) -> Catch (idx ctx `Tag t, label ctx l)
            | CatchRef (t, l) -> CatchRef (idx ctx `Tag t, label ctx l)
            | CatchAll l -> CatchAll (label ctx l)
            | CatchAllRef l -> CatchAllRef (label ctx l))
          catches
      in
      let inputs, outputs = blocktype_arity ctx typ in
      let* () = Stack.consume inputs in
      Stack.push
        (if inputs > 0 then 0 else outputs)
        (with_loc
           (TryTable
              { label = labl (); typ = blocktype ctx typ; block; catches }))
  | Try { label; typ; block; catches; catch_all } ->
      let label, ctx = push_label ctx ~loop:false label typ in
      let block = Stack.run (instructions ctx block) in
      let catches =
        List.map
          (fun (t, block) ->
            (idx ctx `Tag t, Stack.run (instructions ctx block)))
          catches
      in
      let catch_all =
        Option.map (fun block -> Stack.run (instructions ctx block)) catch_all
      in
      let inputs, outputs = blocktype_arity ctx typ in
      let* () = Stack.consume inputs in
      Stack.push
        (if inputs > 0 then 0 else outputs)
        (with_loc
           (Try
              {
                label = label ();
                typ = blocktype ctx typ;
                block;
                catches;
                catch_all;
              }))
  | Unreachable -> Stack.push_poly (with_loc Unreachable)
  | Nop -> Stack.push 0 (with_loc Nop)
  | Drop ->
      let* e = Stack.pop in
      Stack.push 0 (with_loc (Set (None, e)))
  | Br i ->
      let input = label_arity ctx i in
      let* args = Stack.grab input in
      Stack.push_poly (with_loc (Br (label ctx i, sequence_opt args)))
  | Br_if i ->
      let input = label_arity ctx i in
      let* args = Stack.grab (input + 1) in
      Stack.push input (with_loc (Br_if (label ctx i, sequence args)))
  | Br_table (labels, lab) ->
      let input = label_arity ctx lab in
      let* args = Stack.grab (input + 1) in
      Stack.push_poly
        (with_loc
           (Br_table
              (List.map (fun i -> label ctx i) (labels @ [ lab ]), sequence args)))
  | Br_on_null i ->
      let input = label_arity ctx i in
      let* args = Stack.grab (input + 1) in
      Stack.push (input + 1)
        (with_loc (Br_on_null (label ctx i, sequence args)))
  | Br_on_non_null i ->
      let input = label_arity ctx i in
      let* args = Stack.grab input in
      Stack.push (input - 1)
        (with_loc (Br_on_non_null (label ctx i, sequence args)))
  | Br_on_cast (i, _, t) ->
      let input = label_arity ctx i in
      let* args = Stack.grab input in
      Stack.push input
        (with_loc (Br_on_cast (label ctx i, reftype ctx t, sequence args)))
  | Br_on_cast_fail (i, _, t) ->
      let input = label_arity ctx i in
      let* args = Stack.grab input in
      Stack.push input
        (with_loc (Br_on_cast_fail (label ctx i, reftype ctx t, sequence args)))
  | Folded (i, l) ->
      let* () = instructions ctx l in
      instruction ctx i
  | LocalGet x -> Stack.push 1 (with_loc (Get (idx ctx `Local x)))
  | GlobalGet x -> Stack.push 1 (with_loc (Get (idx ctx `Global x)))
  | LocalSet x ->
      let* e = Stack.pop in
      Stack.push 0 (with_loc (Set (Some (idx ctx `Local x), e)))
  | GlobalSet x ->
      let* e = Stack.pop in
      Stack.push 0 (with_loc (Set (Some (idx ctx `Global x), e)))
  | LocalTee x ->
      let* e = Stack.pop in
      Stack.push 1 (with_loc (Tee (idx ctx `Local x, e)))
  | BinOp (I32 op) | BinOp (I64 op) -> int_bin_op i op
  | BinOp (F32 op) | BinOp (F64 op) -> float_bin_op i op
  | UnOp (I64 op) -> int_un_op i `I64 op
  | UnOp (I32 op) -> int_un_op i `I32 op
  | UnOp (F64 op) -> float_un_op i `F64 op
  | UnOp (F32 op) -> float_un_op i `F32 op
  | StructNew i ->
      let type_name = idx ctx `Type i in
      let fields = snd (Hashtbl.find ctx.struct_fields type_name.desc) in
      let* args = Stack.grab (List.length fields) in
      Stack.push 1
        (with_loc
           (Struct
              ( Some (idx ctx `Type i),
                List.map2 (fun nm i -> (Ast.no_loc nm, i)) fields args )))
  | StructNewDefault i ->
      Stack.push 1 (with_loc (StructDefault (Some (idx ctx `Type i))))
  | StructGet (s, t, f) ->
      let type_name = idx ctx `Type t in
      let name =
        Sequence.get (fst (Hashtbl.find ctx.struct_fields type_name.desc)) f
      in
      let* arg = Stack.pop in
      let arg =
        {
          arg with
          desc =
            Ast.Cast
              (arg, Valtype (Ref { nullable = true; typ = Type type_name }));
        }
      in
      let e = with_loc (StructGet (arg, name)) in
      Stack.push 1
        (match s with
        | None -> e
        | Some signage ->
            with_loc
              (Cast (e, Signedtype { typ = `I32; signage; strict = false })))
  | StructSet (t, f) ->
      let type_name = idx ctx `Type t in
      let name =
        Sequence.get (fst (Hashtbl.find ctx.struct_fields type_name.desc)) f
      in
      let* e2 = Stack.pop in
      let* e1 = Stack.pop in
      let e1 =
        {
          e1 with
          desc =
            Ast.Cast
              (e1, Valtype (Ref { nullable = true; typ = Type type_name }));
        }
      in
      Stack.push 1 (with_loc (StructSet (e1, name, e2)))
  | ArrayNew t ->
      let* len = Stack.pop in
      let* v = Stack.pop in
      Stack.push 1 (with_loc (Array (Some (idx ctx `Type t), v, len)))
  | ArrayNewDefault t ->
      let* len = Stack.pop in
      Stack.push 1 (with_loc (ArrayDefault (Some (idx ctx `Type t), len)))
  | ArrayNewFixed (t, n) ->
      let* args = Stack.grab (Uint32.to_int n) in
      Stack.push 1
        (match string_args n args with
        | Some s -> with_loc (String (Some (idx ctx `Type t), s))
        | None -> with_loc (ArrayFixed (Some (idx ctx `Type t), args)))
  | ArrayGet (s, t) ->
      let* e2 = Stack.pop in
      let* e1 = Stack.pop in
      let e1 =
        {
          e1 with
          desc =
            Ast.Cast
              ( e1,
                Valtype (Ref { nullable = true; typ = Type (idx ctx `Type t) })
              );
        }
      in
      let e = with_loc (ArrayGet (e1, e2)) in
      Stack.push 1
        (match s with
        | None -> e
        | Some signage ->
            with_loc
              (Cast (e, Signedtype { typ = `I32; signage; strict = false })))
  | ArraySet t ->
      let* e3 = Stack.pop in
      let* e2 = Stack.pop in
      let* e1 = Stack.pop in
      let e1 =
        {
          e1 with
          desc =
            Ast.Cast
              ( e1,
                Valtype (Ref { nullable = true; typ = Type (idx ctx `Type t) })
              );
        }
      in
      Stack.push 1 (with_loc (ArraySet (e1, e2, e3)))
  | Call f ->
      let input, output = function_arity ctx f in
      let* args = Stack.grab input in
      Stack.push output
        (with_loc (Call (with_loc (Get (idx ctx `Func f)), args)))
  | CallRef t ->
      let input, output = type_arity ctx t in
      let* f = Stack.pop in
      let f =
        {
          f with
          desc =
            Ast.Cast
              ( f,
                Valtype (Ref { nullable = true; typ = Type (idx ctx `Type t) })
              );
        }
      in
      let* args = Stack.grab input in
      Stack.push output (with_loc (Call (f, args)))
  | ReturnCall f ->
      let input, _ = function_arity ctx f in
      let* args = Stack.grab input in
      Stack.push_poly
        (with_loc (TailCall (with_loc (Get (idx ctx `Func f)), args)))
  | ReturnCallRef t ->
      let input, _ = type_arity ctx t in
      let* f = Stack.pop in
      let f =
        {
          f with
          desc =
            Ast.Cast
              ( f,
                Valtype (Ref { nullable = true; typ = Type (idx ctx `Type t) })
              );
        }
      in
      let* args = Stack.grab input in
      Stack.push_poly (with_loc (TailCall (f, args)))
  | Return ->
      let* args = Stack.grab ctx.return_arity in
      Stack.push_poly (with_loc (Return (sequence_opt args)))
  | Const c ->
      let lit, ty =
        match c with
        | I32 n -> (integer i n, Ast.I32)
        | I64 n -> (integer i n, Ast.I64)
        | F32 f -> (float i f, Ast.F32)
        | F64 f -> (float i f, Ast.F64)
      in
      Stack.push 1
        (if ctx.strict_constants then with_loc (Cast (lit, Valtype ty)) else lit)
  | RefI31 ->
      let* e = Stack.pop in
      Stack.push 1
        (with_loc (Cast (e, Valtype (Ref { nullable = false; typ = I31 }))))
  | I31Get signage ->
      let* e = Stack.pop in
      Stack.push 1
        (with_loc
           (Cast (e, Signedtype { typ = `I32; signage; strict = false })))
  | I64ExtendI32 signage ->
      let* e = Stack.pop in
      Stack.push 1
        (with_loc
           (Cast (e, Signedtype { typ = `I64; signage; strict = false })))
  | I32WrapI64 ->
      let* e = Stack.pop in
      Stack.push 1 (with_loc (Cast (e, Valtype I32)))
  | F64PromoteF32 ->
      let* e = Stack.pop in
      Stack.push 1 (with_loc (Cast (e, Valtype F64)))
  | F32DemoteF64 ->
      let* e = Stack.pop in
      Stack.push 1 (with_loc (Cast (e, Valtype F32)))
  | ExternConvertAny ->
      let* e = Stack.pop in
      Stack.push 1
        (with_loc (Cast (e, Valtype (Ref { nullable = true; typ = Extern }))))
  | AnyConvertExtern ->
      let* e = Stack.pop in
      Stack.push 1
        (with_loc (Cast (e, Valtype (Ref { nullable = true; typ = Any }))))
  | ArrayNewData (t, d) ->
      let* len = Stack.pop in
      let* off = Stack.pop in
      Stack.push 1
        (with_loc
           (ArraySegment (Some (idx ctx `Type t), idx ctx `Data d, off, len)))
  | ArrayNewElem (t, e) ->
      let* len = Stack.pop in
      let* off = Stack.pop in
      Stack.push 1
        (with_loc
           (ArraySegment (Some (idx ctx `Type t), idx ctx `Elem e, off, len)))
  | TableGet t ->
      let* index = Stack.pop in
      Stack.push 1
        (with_loc (ArrayGet (with_loc (Get (idx ctx `Table t)), index)))
  | TableSet t ->
      let* value = Stack.pop in
      let* index = Stack.pop in
      Stack.push 1
        (with_loc (ArraySet (with_loc (Get (idx ctx `Table t)), index, value)))
  (* call_indirect desugars to [(tab[i] as &$functype)(args)] (a call_ref);
     [to_wasm] re-fuses this back to call_indirect. *)
  | CallIndirect (tab, tu) ->
      let input, output = typeuse_arity ctx tu in
      let* index = Stack.pop in
      let* args = Stack.grab input in
      let f = indirect_callee ctx with_loc tab tu index in
      Stack.push output (with_loc (Call (f, args)))
  | ReturnCallIndirect (tab, tu) ->
      let input, _ = typeuse_arity ctx tu in
      let* index = Stack.pop in
      let* args = Stack.grab input in
      let f = indirect_callee ctx with_loc tab tu index in
      Stack.push_poly (with_loc (TailCall (f, args)))
  | ArrayLen ->
      let* e = Stack.pop in
      Stack.push 1
        (with_loc (Call (with_loc (StructGet (e, Ast.no_loc "length")), [])))
  | RefCast t ->
      let* e = Stack.pop in
      Stack.push 1 (with_loc (Cast (e, Valtype (Ref (reftype ctx t)))))
  | RefTest t ->
      let* e = Stack.pop in
      Stack.push 1 (with_loc (Test (e, reftype ctx t)))
  | RefEq ->
      let* e2 = Stack.pop in
      let* e1 = Stack.pop in
      Stack.push 1 (with_loc (BinOp (op_loc i Ast.Eq, e1, e2)))
  | RefFunc f -> Stack.push 1 (with_loc (Get (idx ctx `Func f)))
  | RefNull typ ->
      Stack.push 1
        (with_loc
           (Cast
              ( with_loc Null,
                Valtype (Ref { nullable = true; typ = heaptype ctx typ }) )))
  | RefIsNull ->
      let* e = Stack.pop in
      Stack.push 1 (with_loc (UnOp (op_loc i Ast.Not, e)))
  | Select tys ->
      (* The Wax [?:] carries no result type, but resolve the annotation (if
         any) so an out-of-range type reference is still caught. *)
      Option.iter
        (List.iter (fun t -> ignore (valtype ctx t : Ast.valtype)))
        tys;
      let* cond = Stack.pop in
      let* e2 = Stack.pop in
      let* e1 = Stack.pop in
      Stack.push 1 (with_loc (Select (cond, e1, e2)))
  | Throw t ->
      let input, _ = tag_arity ctx t in
      let* args = Stack.grab input in
      Stack.push_poly (with_loc (Throw (idx ctx `Tag t, sequence_opt args)))
  | ThrowRef ->
      let* e = Stack.pop in
      Stack.push_poly (with_loc (ThrowRef e))
  | ContNew ct ->
      let* f = Stack.pop in
      Stack.push 1 (with_loc (ContNew (idx ctx `Type ct, f)))
  | ContBind (src, dst) ->
      let sp, _ = cont_arity ctx src in
      let dp, _ = cont_arity ctx dst in
      let* args = Stack.grab (sp - dp + 1) in
      Stack.push 1
        (with_loc (ContBind (idx ctx `Type src, idx ctx `Type dst, args)))
  | Suspend t ->
      let input, output = tag_arity ctx t in
      let* args = Stack.grab input in
      Stack.push output (with_loc (Suspend (idx ctx `Tag t, args)))
  | Resume (ct, handlers) ->
      let input, output = cont_arity ctx ct in
      let* args = Stack.grab (input + 1) in
      Stack.push output
        (with_loc
           (Resume (idx ctx `Type ct, List.map (on_clause ctx) handlers, args)))
  | ResumeThrow (ct, tag, handlers) ->
      let tinput, _ = tag_arity ctx tag in
      let _, output = cont_arity ctx ct in
      let* args = Stack.grab (tinput + 1) in
      Stack.push output
        (with_loc
           (ResumeThrow
              ( idx ctx `Type ct,
                idx ctx `Tag tag,
                List.map (on_clause ctx) handlers,
                args )))
  | ResumeThrowRef (ct, handlers) ->
      let _, output = cont_arity ctx ct in
      let* args = Stack.grab 2 in
      Stack.push output
        (with_loc
           (ResumeThrowRef
              (idx ctx `Type ct, List.map (on_clause ctx) handlers, args)))
  | Switch (ct, tag) ->
      let input, _ = cont_arity ctx ct in
      let output = switch_output ctx ct in
      let* args = Stack.grab input in
      Stack.push output
        (with_loc (Switch (idx ctx `Type ct, idx ctx `Tag tag, args)))
  | RefAsNonNull ->
      let* e = Stack.pop in
      Stack.push 1 (with_loc (NonNull e))
  | ArrayFill _ ->
      let* n = Stack.pop in
      let* v = Stack.pop in
      let* i = Stack.pop in
      let* a = Stack.pop in
      Stack.push 0
        (with_loc
           (Call (with_loc (StructGet (a, Ast.no_loc "fill")), [ i; v; n ])))
  | ArrayCopy _ ->
      let* n = Stack.pop in
      let* i2 = Stack.pop in
      let* a2 = Stack.pop in
      let* i1 = Stack.pop in
      let* a1 = Stack.pop in
      Stack.push 0
        (with_loc
           (Call
              (with_loc (StructGet (a1, Ast.no_loc "copy")), [ i1; a2; i2; n ])))
  | Load (m, memarg, nt) ->
      let* addr = Stack.pop in
      let meth, nat =
        match nt with
        | NumI32 -> ("load32", 4)
        | NumI64 -> ("load64", 8)
        | NumF32 -> ("loadf32", 4)
        | NumF64 -> ("loadf64", 8)
      in
      Stack.push 1 (mem_call m meth (addr :: mem_extra with_loc memarg nat))
  | LoadS (m, memarg, result_ty, size, signage) ->
      let* addr = Stack.pop in
      let meth, nat =
        match size with
        | `I8 -> ("load8", 1)
        | `I16 -> ("load16", 2)
        | `I32 -> ("load32", 4)
      in
      let call = mem_call m meth (addr :: mem_extra with_loc memarg nat) in
      let cast typ e =
        with_loc (Ast.Cast (e, Signedtype { typ; signage; strict = false }))
      in
      let result =
        match (size, result_ty) with
        | _, `I32 -> cast `I32 call
        | `I32, `I64 -> cast `I64 call
        | (`I8 | `I16), `I64 -> cast `I64 (cast `I32 call)
      in
      Stack.push 1 result
  | Store (m, memarg, nt) ->
      let* value = Stack.pop in
      let* addr = Stack.pop in
      let meth, nat =
        match nt with
        | NumI32 -> ("store32", 4)
        | NumI64 -> ("store64", 8)
        | NumF32 -> ("storef32", 4)
        | NumF64 -> ("storef64", 8)
      in
      Stack.push 0
        (mem_call m meth (addr :: value :: mem_extra with_loc memarg nat))
  | StoreS (m, memarg, _result_ty, size) ->
      let* value = Stack.pop in
      let* addr = Stack.pop in
      let meth, nat =
        match size with
        | `I8 -> ("store8", 1)
        | `I16 -> ("store16", 2)
        | `I32 -> ("store32", 4)
      in
      Stack.push 0
        (mem_call m meth (addr :: value :: mem_extra with_loc memarg nat))
  | Char c -> Stack.push 1 (with_loc (Char c))
  | String (t, s) ->
      let s = String.concat "" (List.map (fun s -> s.Ast.desc) s) in
      Stack.push 1 (with_loc (String (Option.map (idx ctx `Type) t, s)))
  | If_annotation { cond; then_body; else_body } ->
      let then_body =
        with_cond ctx ~location:i.info cond true (fun () ->
            Stack.run (instructions ctx then_body))
      in
      let else_body =
        Option.map
          (fun b ->
            with_cond ctx ~location:i.info cond false (fun () ->
                Stack.run (instructions ctx b)))
          else_body
      in
      Stack.push 0 (with_loc (If_annotation { cond; then_body; else_body }))
  | MemorySize m -> Stack.push 1 (mem_call m "size" [])
  | MemoryGrow m ->
      let* d = Stack.pop in
      Stack.push 1 (mem_call m "grow" [ d ])
  | MemoryFill m ->
      let* n = Stack.pop in
      let* v = Stack.pop in
      let* d = Stack.pop in
      Stack.push 0 (mem_call m "fill" [ d; v; n ])
  | MemoryCopy (m, m') ->
      let* n = Stack.pop in
      let* s = Stack.pop in
      let* d = Stack.pop in
      (* A copy between two different memories names the source explicitly. *)
      let args =
        if (idx ctx `Mem m).desc = (idx ctx `Mem m').desc then [ d; s; n ]
        else with_loc (Ast.Get (idx ctx `Mem m')) :: [ d; s; n ]
      in
      Stack.push 0 (mem_call m "copy" args)
  | MemoryInit (m, data) ->
      let* n = Stack.pop in
      let* s = Stack.pop in
      let* d = Stack.pop in
      let seg = with_loc (Ast.Get (idx ctx `Data data)) in
      Stack.push 0 (mem_call m "init" [ seg; d; s; n ])
  | DataDrop data -> Stack.push 0 (drop_call `Data data)
  | TableSize t -> Stack.push 1 (table_call t "size" [])
  | TableGrow t ->
      let* n = Stack.pop in
      let* v = Stack.pop in
      Stack.push 1 (table_call t "grow" [ v; n ])
  | TableFill t ->
      let* n = Stack.pop in
      let* v = Stack.pop in
      let* d = Stack.pop in
      Stack.push 0 (table_call t "fill" [ d; v; n ])
  | TableCopy (t, t') ->
      let* n = Stack.pop in
      let* s = Stack.pop in
      let* d = Stack.pop in
      let args =
        if (idx ctx `Table t).desc = (idx ctx `Table t').desc then [ d; s; n ]
        else with_loc (Ast.Get (idx ctx `Table t')) :: [ d; s; n ]
      in
      Stack.push 0 (table_call t "copy" args)
  | TableInit (t, elem) ->
      let* n = Stack.pop in
      let* s = Stack.pop in
      let* d = Stack.pop in
      let seg = with_loc (Ast.Get (idx ctx `Elem elem)) in
      Stack.push 0 (table_call t "init" [ seg; d; s; n ])
  | ElemDrop elem -> Stack.push 0 (drop_call `Elem elem)
  | ArrayInitData (_, data) ->
      let* n = Stack.pop in
      let* s = Stack.pop in
      let* d = Stack.pop in
      let* a = Stack.pop in
      let seg = with_loc (Ast.Get (idx ctx `Data data)) in
      Stack.push 0
        (with_loc
           (Call (with_loc (StructGet (a, Ast.no_loc "init")), [ seg; d; s; n ])))
  | ArrayInitElem (_, elem) ->
      let* n = Stack.pop in
      let* s = Stack.pop in
      let* d = Stack.pop in
      let* a = Stack.pop in
      let seg = with_loc (Ast.Get (idx ctx `Elem elem)) in
      Stack.push 0
        (with_loc
           (Call (with_loc (StructGet (a, Ast.no_loc "init")), [ seg; d; s; n ])))
  | VecUnOp op ->
      let* v = Stack.pop in
      Stack.push 1 (meth_call v (Simd.unop_name op) [])
  | VecBinOp op ->
      let* e2 = Stack.pop in
      let* e1 = Stack.pop in
      Stack.push 1 (meth_call e1 (Simd.binop_name op) [ e2 ])
  | VecTernOp op ->
      let* e3 = Stack.pop in
      let* e2 = Stack.pop in
      let* e1 = Stack.pop in
      Stack.push 1 (meth_call e1 (Simd.ternop_name op) [ e2; e3 ])
  | VecShift op ->
      let* count = Stack.pop in
      let* v = Stack.pop in
      Stack.push 1 (meth_call v (Simd.shift_name op) [ count ])
  | VecTest op ->
      let* v = Stack.pop in
      Stack.push 1 (meth_call v (Simd.test_name op) [])
  | VecBitmask op ->
      let* v = Stack.pop in
      Stack.push 1 (meth_call v (Simd.bitmask_name op) [])
  | VecSplat s ->
      let* x = Stack.pop in
      Stack.push 1 (meth_call x (Simd.splat_name s) [])
  | VecBitselect ->
      let* e3 = Stack.pop in
      let* e2 = Stack.pop in
      let* e1 = Stack.pop in
      Stack.push 1 (free_call Simd.bitselect_name [ e1; e2; e3 ])
  | VecExtract (s, sign, lane) ->
      let* v = Stack.pop in
      Stack.push 1
        (meth_call v (Simd.extract_name s sign)
           [ integer i (Int.to_string lane) ])
  | VecReplace (s, lane) ->
      let* value = Stack.pop in
      let* v = Stack.pop in
      Stack.push 1
        (meth_call v (Simd.replace_name s)
           [ integer i (Int.to_string lane); value ])
  | VecShuffle lanes ->
      let* e2 = Stack.pop in
      let* e1 = Stack.pop in
      let imms =
        List.init 16 (fun k -> integer i (Int.to_string (Char.code lanes.[k])))
      in
      Stack.push 1 (meth_call e1 Simd.shuffle_name (imms @ [ e2 ]))
  | VecConst v ->
      let lit =
        match v.Utils.V128.shape with
        | F32x4 | F64x2 -> float i
        | I8x16 | I16x8 | I32x4 | I64x2 -> integer i
      in
      Stack.push 1
        (free_call (Simd.const_name v.shape) (List.map lit v.components))
  | VecLoad (m, op, memarg) ->
      let* addr = Stack.pop in
      let nat = Simd.vec_load_nat_align op in
      Stack.push 1
        (mem_call m (Simd.vec_load_name op)
           (addr :: mem_extra with_loc memarg nat))
  | VecStore (m, memarg) ->
      let* value = Stack.pop in
      let* addr = Stack.pop in
      Stack.push 0
        (mem_call m Simd.store_name
           (addr :: value :: mem_extra with_loc memarg 16))
  | VecLoadSplat (m, w, memarg) ->
      let* addr = Stack.pop in
      let nat = Simd.lane_nat_align w in
      Stack.push 1
        (mem_call m (Simd.load_splat_name w)
           (addr :: mem_extra with_loc memarg nat))
  | VecLoadLane (m, w, memarg, lane) ->
      let* v = Stack.pop in
      let* addr = Stack.pop in
      let nat = Simd.lane_nat_align w in
      Stack.push 1
        (mem_call m (Simd.load_lane_name w)
           (addr :: v
           :: integer i (Int.to_string lane)
           :: mem_extra with_loc memarg nat))
  | VecStoreLane (m, w, memarg, lane) ->
      let* v = Stack.pop in
      let* addr = Stack.pop in
      let nat = Simd.lane_nat_align w in
      Stack.push 0
        (mem_call m (Simd.store_lane_name w)
           (addr :: v
           :: integer i (Int.to_string lane)
           :: mem_extra with_loc memarg nat))

and instructions ctx l =
  match l with
  | [] -> return ()
  | i :: rem ->
      let* () = instruction ctx i in
      instructions ctx rem

let bind_locals st l =
  List.map
    (fun e ->
      let _, t = e.Ast.desc in
      Ast.no_loc
        (Ast.Let
           ( [ (Some (Sequence.get_current st.locals), Some (valtype st t)) ],
             None )))
    l

let typeuse ctx ((typ, sign) : Src.typeuse) =
  let ns = Namespace.make () in
  let signature ({ params; results } : Src.functype) : Ast.functype =
    {
      params =
        Array.map
          (fun (id, t) ->
            ( Option.map
                (fun id -> { id with Ast.desc = Namespace.add ns id.Ast.desc })
                id,
              valtype ctx t ))
          params;
      results = Array.map (fun t -> valtype ctx t) results;
    }
  in
  match Option.bind typ (implicit_functype ctx) with
  | Some ft ->
      (* The reference points at an anonymous implicit type; there is no named
         type to refer to, so render it inline. *)
      (None, Some (signature (match sign with Some s -> s | None -> ft)))
  | None ->
      (Option.map (fun i -> idx ctx `Type i) typ, Option.map signature sign)

let string_of_name (nm : Src.name) =
  { nm with desc = Ast.String (None, nm.desc) }

(* Reserve, in a function's fresh local namespace, the Wax names of the
   module-level entities its body references by a bare identifier: globals (via
   [global.get]/[global.set]) and functions (via [call]/[return_call]/
   [ref.func], all of which lower to [Get name]). Without this an auto-named
   local could be assigned a colliding name and shadow the reference, since Wax
   resolves a bare name to a local before a global or function. *)
let rec reserve_module_names_in_instr ctx ns (i : _ Src.instr) =
  match i.desc with
  | Block { block; _ } | Loop { block; _ } | TryTable { block; _ } ->
      reserve_module_names_in_instrs ctx ns block
  | If { if_block; else_block; _ } ->
      reserve_module_names_in_instrs ctx ns if_block.desc;
      reserve_module_names_in_instrs ctx ns else_block.desc
  | Try { block; catches; catch_all; _ } ->
      reserve_module_names_in_instrs ctx ns block;
      List.iter
        (fun (_, block) -> reserve_module_names_in_instrs ctx ns block)
        catches;
      Option.iter
        (fun block -> reserve_module_names_in_instrs ctx ns block)
        catch_all
  | Folded (i, l) ->
      reserve_module_names_in_instrs ctx ns l;
      reserve_module_names_in_instr ctx ns i
  | GlobalGet x | GlobalSet x -> Namespace.reserve ns (idx ctx `Global x).desc
  | Call f | ReturnCall f | RefFunc f ->
      Namespace.reserve ns (idx ctx `Func f).desc
  | _ -> ()

and reserve_module_names_in_instrs ctx ns l =
  List.iter (reserve_module_names_in_instr ctx ns) l

(* Collect the Wax names of element segments referenced by table.init /
   elem.drop / array.new_elem / array.init_elem, so a declarative segment used
   this way is emitted explicitly rather than dropped. *)
let rec collect_elem_refs ctx acc (i : _ Src.instr) =
  match i.desc with
  | Block { block; _ } | Loop { block; _ } | TryTable { block; _ } ->
      collect_elem_refs_instrs ctx acc block
  | If { if_block; else_block; _ } ->
      collect_elem_refs_instrs ctx acc if_block.desc;
      collect_elem_refs_instrs ctx acc else_block.desc
  | Try { block; catches; catch_all; _ } ->
      collect_elem_refs_instrs ctx acc block;
      List.iter (fun (_, b) -> collect_elem_refs_instrs ctx acc b) catches;
      Option.iter (collect_elem_refs_instrs ctx acc) catch_all
  | Folded (i, l) ->
      collect_elem_refs_instrs ctx acc l;
      collect_elem_refs ctx acc i
  | TableInit (_, e) | ElemDrop e | ArrayNewElem (_, e) | ArrayInitElem (_, e)
    -> (
      try Hashtbl.replace acc (idx ctx `Elem e).desc () with _ -> ())
  | _ -> ()

and collect_elem_refs_instrs ctx acc l = List.iter (collect_elem_refs ctx acc) l

let exports ctx kind name e =
  (* [e] are the inline exports declared on this field (already in the right
     branch); the table holds the standalone exports, kept only when their
     branch is reachable under the current assumption. *)
  let standalone =
    match Hashtbl.find_opt ctx.exports (kind, name.Ast.desc) with
    | None -> []
    | Some entries ->
        List.filter_map
          (fun (c, nm) ->
            if Cond.is_satisfiable (Cond.and_ ctx.cond_asm c) then Some nm
            else None)
          entries
  in
  List.map (fun nm -> ("export", Some (string_of_name nm))) (e @ standalone)

let import module_ name =
  ( "import",
    Some
      (Ast.no_loc
         (Ast.Sequence [ string_of_name module_; string_of_name name ])) )

(* The [#[start]] attribute, if function [name] is the module's start. *)
let start_attribute ctx name =
  if ctx.start = Some name.Ast.desc then [ ("start", None) ] else []

let single_expression ctx ~location l =
  match l with
  | [ e ] -> e
  | _ ->
      conversion_error ctx ~location (fun f () ->
          Format.fprintf f "A constant expression must produce a single value.")

let rec modulefield ctx export_tbl (f : (_ Src.modulefield, _) Ast.annotated) =
  (* Sibling fields synthesised alongside [f] (e.g. an element segment for an
     inline table initializer), emitted right after it. *)
  let extra = ref [] in
  let desc : _ Ast.modulefield option =
    match f.desc with
    | Types t -> Some (Type (rectype ctx t))
    | Func { locals; instrs; typ; exports = e; _ } ->
        let label, labels = LabelStack.push (LabelStack.make ()) None in
        let ctx =
          let return_arity = snd (typeuse_arity ctx typ) in
          let local_namespace =
            let ns = Namespace.make () in
            reserve_module_names_in_instrs ctx ns instrs;
            ns
          in
          {
            ctx with
            locals = Sequence.make local_namespace "x";
            labels;
            label_arities = [ (None, return_arity) ];
            return_arity;
          }
        in
        let sign =
          match typ with
          | _, Some { params; results } ->
              let params =
                Array.map
                  (fun (id, t) ->
                    let name =
                      Sequence.register' ctx.locals export_tbl None id []
                    in
                    ( Some
                        (match id with
                        | None -> Ast.no_loc name
                        | Some id -> { id with Ast.desc = name }),
                      valtype ctx t ))
                  params
              in
              Sequence.consume_currents ctx.locals;
              {
                Ast.params;
                results = Array.map (fun t -> valtype ctx t) results;
              }
          | Some i, None -> (
              let functype =
                match implicit_functype ctx i with
                | Some ft -> Some ft
                | None -> (
                    match (lookup_type ctx Type i).typ with
                    | Func ft -> Some ft
                    | Struct _ | Array _ | Cont _ -> None)
              in
              match functype with
              | Some { params; results } ->
                  let params =
                    Array.map
                      (fun (id, t) ->
                        let name =
                          Sequence.register' ctx.locals export_tbl None id []
                        in
                        ( Some
                            (match id with
                            | None -> Ast.no_loc name
                            | Some id -> { id with Ast.desc = name }),
                          valtype ctx t ))
                      params
                  in
                  Sequence.consume_currents ctx.locals;
                  {
                    Ast.params;
                    results = Array.map (fun t -> valtype ctx t) results;
                  }
              | None -> assert false)
          | None, None -> assert false (* Should not happen *)
        in
        (* An anonymous implicit type has no name to reference; the inline [sign]
           above already carries its signature, so drop the named reference. *)
        let typ =
          match fst typ with
          | Some i when Option.is_some (implicit_functype ctx i) -> None
          | t -> Option.map (fun i -> idx ctx `Type i) t
        in
        List.iter
          (fun e ->
            Sequence.register ctx.locals export_tbl None (fst e.Ast.desc) [])
          locals;
        let locals = bind_locals ctx locals in
        let name = Sequence.get_current ctx.functions in
        Some
          (Func
             {
               name;
               typ;
               sign = Some sign;
               body = (label (), locals @ Stack.run (instructions ctx instrs));
               attributes = start_attribute ctx name @ exports ctx Func name e;
             })
    | Import { module_; name = nm; desc; exports = e; _ } -> (
        match desc with
        | Func typ ->
            let typ, sign = typeuse ctx typ in
            let name = Sequence.get_current ctx.functions in
            Some
              (Fundecl
                 {
                   name;
                   typ;
                   sign;
                   attributes = import module_ nm :: exports ctx Func name e;
                 })
        | Tag typ ->
            let typ, sign = typeuse ctx typ in
            let name = Sequence.get_current ctx.tags in
            Some
              (Tag
                 {
                   name;
                   typ;
                   sign;
                   attributes = import module_ nm :: exports ctx Tag name e;
                 })
        | Global typ ->
            let typ' = globaltype ctx typ in
            let name = Sequence.get_current ctx.globals in
            Some
              (GlobalDecl
                 {
                   name;
                   mut = typ'.mut;
                   typ = typ'.typ;
                   attributes = import module_ nm :: exports ctx Global name e;
                 })
        | Memory lim ->
            let l = lim.Ast.desc in
            let name = Sequence.get_current ctx.memories in
            Some
              (Memory
                 {
                   name;
                   address_type = l.address_type;
                   limits = Some (l.mi, l.ma);
                   data = [];
                   attributes = import module_ nm :: exports ctx Memory name e;
                 })
        | Table tt ->
            let name = Sequence.get_current ctx.tables in
            let l = tt.Src.limits.Ast.desc in
            Some
              (Table
                 {
                   name;
                   address_type = l.address_type;
                   reftype = reftype ctx tt.Src.reftype;
                   limits = Some (l.mi, l.ma);
                   init = None;
                   attributes = import module_ nm :: exports ctx Table name e;
                 }))
    | Global { typ; init; exports = e; _ } ->
        let typ' = globaltype ctx typ in
        let name = Sequence.get_current ctx.globals in
        Some
          (Global
             {
               name;
               mut = typ'.mut;
               typ = Some typ'.typ;
               def =
                 single_expression ctx ~location:f.info
                   (Stack.run (instructions ctx init));
               attributes = exports ctx Global name e;
             })
    | Tag { typ; exports = e; _ } ->
        let typ, sign = typeuse ctx typ in
        let name = Sequence.get_current ctx.tags in
        Some (Tag { name; typ; sign; attributes = exports ctx Tag name e })
    | Memory { limits = lim; init; exports = e; _ } ->
        let l = lim.Ast.desc in
        let name = Sequence.get_current ctx.memories in
        let data =
          match init with
          | None -> []
          | Some bytes ->
              let s = String.concat "" (List.map (fun b -> b.Ast.desc) bytes) in
              [
                {
                  Ast.data_name = None;
                  offset = Ast.no_loc (Ast.Int "0");
                  init = s;
                };
              ]
        in
        Some
          (Memory
             {
               name;
               address_type = l.address_type;
               limits = Some (l.mi, l.ma);
               data;
               attributes = exports ctx Memory name e;
             })
    | Data { init; mode; _ } ->
        let name = Sequence.get_current ctx.datas in
        let s = String.concat "" (List.map (fun b -> b.Ast.desc) init) in
        let mode' : _ Ast.datamode =
          match mode with
          | Passive -> Passive
          | Active (memidx, off) ->
              Active
                ( idx ctx `Mem memidx,
                  single_expression ctx ~location:f.info
                    (Stack.run (instructions ctx off)) )
        in
        Some
          (Data { name = Some name; mode = mode'; init = s; attributes = [] })
    | Table { typ = tt; init; exports = e; _ } ->
        let name = Sequence.get_current ctx.tables in
        let l = tt.Src.limits.Ast.desc in
        let init =
          match init with
          | Init_default -> None
          | Init_expr ex ->
              Some
                (single_expression ctx ~location:f.info
                   (Stack.run (instructions ctx ex)))
          | Init_segment segs ->
              (* A per-element initializer is not expressible on the table
                 itself; desugar it into a separate active element segment
                 filling the table from offset 0. *)
              let elem_init =
                List.map
                  (fun ex ->
                    single_expression ctx ~location:f.info
                      (Stack.run (instructions ctx ex)))
                  segs
              in
              let elem : _ Ast.modulefield =
                Elem
                  {
                    name = Sequence.fresh_name ctx.elems;
                    reftype = reftype ctx tt.Src.reftype;
                    mode = EActive (name, Ast.no_loc (Ast.Int "0"));
                    init = elem_init;
                    attributes = [];
                  }
              in
              extra := [ { f with desc = elem } ];
              None
        in
        Some
          (Table
             {
               name;
               address_type = l.address_type;
               reftype = reftype ctx tt.Src.reftype;
               limits = Some (l.mi, l.ma);
               init;
               attributes = exports ctx Table name e;
             })
    | Elem { typ; init; mode; _ } -> (
        (* Declare elems are regenerated by [to_wasm] from [call_ref] usage, so
           they are normally dropped. One referenced by table.init / elem.drop /
           array.*_elem still needs a binding: emit it as an empty passive
           segment, which is runtime-equivalent (a declarative segment is a
           dropped passive one — table.init traps, elem.drop is a no-op). *)
        match mode with
        | Declare ->
            let name = Sequence.get_current ctx.elems in
            if Hashtbl.mem ctx.referenced_elems name.Ast.desc then
              Some
                (Elem
                   {
                     name;
                     reftype = reftype ctx typ;
                     mode = EPassive;
                     init = [];
                     attributes = [];
                   })
            else None
        | Passive | Active _ ->
            let name = Sequence.get_current ctx.elems in
            let init =
              List.map
                (fun e ->
                  single_expression ctx ~location:f.info
                    (Stack.run (instructions ctx e)))
                init
            in
            let mode' : _ Ast.elemmode =
              match mode with
              | Passive -> EPassive
              | Active (tab, off) ->
                  EActive
                    ( idx ctx `Table tab,
                      single_expression ctx ~location:f.info
                        (Stack.run (instructions ctx off)) )
              | Declare -> assert false
            in
            Some
              (Elem
                 {
                   name;
                   reftype = reftype ctx typ;
                   mode = mode';
                   init;
                   attributes = [];
                 }))
    | Start _ | Export _ -> None
    | String_global { typ; init; _ } ->
        let name = Sequence.get_current ctx.globals in
        Some
          (Global
             {
               name;
               mut = false;
               typ = None;
               def =
                 {
                   f with
                   desc =
                     String
                       ( Option.map (idx ctx `Type) typ,
                         String.concat "" (List.map (fun s -> s.Ast.desc) init)
                       );
                 };
               attributes = [];
             })
    | Module_if_annotation { cond; then_fields; else_fields } ->
        (* Convert [then] before [else]: positional naming via [get_current]
           must consume names in the same order [register_names] registered
           them (then-branch first). A record literal would leave the field
           evaluation order unspecified (OCaml evaluates right-to-left), which
           would consume the names swapped and scramble them across branches.
           [with_cond] sets the branch assumption so per-branch declarations
           (e.g. an import with a branch-dependent signature) resolve correctly
           in the branch's bodies. *)
        let then_fields =
          with_cond ctx ~location:f.info cond true (fun () ->
              List.concat_map (modulefield ctx export_tbl) then_fields)
        in
        let else_fields =
          Option.map
            (fun e ->
              with_cond ctx ~location:f.info cond false (fun () ->
                  List.concat_map (modulefield ctx export_tbl) e))
            else_fields
        in
        Some (Conditional { cond; then_fields; else_fields })
  in
  Option.to_list (Option.map (fun desc -> { f with desc }) desc) @ !extra

(* Structural equality on function types, ignoring parameter names and source
   locations. Used to replicate the WAT type-use abbreviation, where an inline
   signature reuses an identical existing type rather than minting a new one. *)
let rec valtype_eq (a : Src.valtype) (b : Src.valtype) =
  match (a, b) with
  | I32, I32 | I64, I64 | F32, F32 | F64, F64 | V128, V128 -> true
  | Ref x, Ref y -> x.nullable = y.nullable && heaptype_eq x.typ y.typ
  | (I32 | I64 | F32 | F64 | V128 | Ref _), _ -> false

and heaptype_eq (a : Src.heaptype) (b : Src.heaptype) =
  match (a, b) with
  | Type i, Type j -> (
      match (i.Ast.desc, j.Ast.desc) with
      | Num m, Num n -> Uint32.compare m n = 0
      | Id s, Id t -> String.equal s t
      | (Num _ | Id _), _ -> false)
  | _ -> a = b

let functype_eq (a : Src.functype) (b : Src.functype) =
  let valtypes a = List.map snd (Array.to_list a) in
  Array.length a.params = Array.length b.params
  && Array.length a.results = Array.length b.results
  && List.for_all2 valtype_eq (valtypes a.params) (valtypes b.params)
  && List.for_all2 valtype_eq (Array.to_list a.results)
       (Array.to_list b.results)

let empty_functype : Src.functype = { params = [||]; results = [||] }

(* Populate [ctx.implicit_types] with the function types the WAT text format
   synthesises from inline [(param)]/[(result)] signatures. Explicit type
   definitions occupy the low indices in source order; each inline signature
   then reuses the lowest-indexed identical type, or appends a new one at the
   end of the index space. This mirrors the spec's elaboration so that a numeric
   [(type N)] referring to such a type resolves to the right signature.

   Only called for modules without conditional annotations (where numeric
   references are allowed); there the index space is unambiguous. *)
let elaborate_implicit_types ctx fields =
  let next = ref 0 in
  (* Known function types by index, explicit ones first, then minted implicit
     ones, used to decide whether an inline signature needs a fresh index. *)
  let known = ref [] in
  let record ft = known := (Uint32.of_int !next, ft) :: !known in
  (* Phase 1: explicit type definitions, in source order. *)
  List.iter
    (fun (field : (_ Src.modulefield, _) Ast.annotated) ->
      match field.desc with
      | Types rectype ->
          Array.iter
            (fun e ->
              (match (snd e.Ast.desc : Src.subtype).typ with
              | Func ft -> record ft
              | Struct _ | Array _ | Cont _ -> ());
              incr next)
            rectype
      | _ -> ())
    fields;
  (* Phase 2: every inline signature, in source order, appended after the
     explicit types. *)
  let consider ((typ, sign) : Src.typeuse) =
    match typ with
    | Some _ -> () (* references an existing type; mints nothing *)
    | None ->
        let ft = Option.value sign ~default:empty_functype in
        if not (List.exists (fun (_, ft') -> functype_eq ft ft') !known) then (
          Hashtbl.replace ctx.implicit_types (Uint32.of_int !next) ft;
          record ft;
          incr next)
  in
  let blocktype = function Some (Src.Typeuse tu) -> consider tu | _ -> () in
  let rec instr (i : _ Src.instr) =
    match i.Ast.desc with
    | CallIndirect (_, tu) | ReturnCallIndirect (_, tu) -> consider tu
    | Block { typ; block; _ } | Loop { typ; block; _ } ->
        blocktype typ;
        instrs block
    | If { typ; if_block; else_block; _ } ->
        blocktype typ;
        instrs if_block.Ast.desc;
        instrs else_block.Ast.desc
    | TryTable { typ; block; _ } ->
        blocktype typ;
        instrs block
    | Try { typ; block; catches; catch_all; _ } ->
        blocktype typ;
        instrs block;
        List.iter (fun (_, b) -> instrs b) catches;
        Option.iter instrs catch_all
    | Folded (i, l) ->
        instr i;
        instrs l
    | _ -> ()
  and instrs l = List.iter instr l in
  List.iter
    (fun (field : (_ Src.modulefield, _) Ast.annotated) ->
      match field.desc with
      | Func { typ; instrs = body; _ } ->
          consider typ;
          instrs body
      | Import { desc = Func tu; _ } | Import { desc = Tag tu; _ } ->
          consider tu
      | Tag { typ; _ } -> consider typ
      | Global { init; _ } -> instrs init
      | Elem { init; _ } -> List.iter instrs init
      | Table { init = Init_expr e; _ } -> instrs e
      | Table { init = Init_segment l; _ } -> List.iter instrs l
      | Types _ | Import _ | Memory _ | Table _ | Export _ | Start _ | Data _
      | String_global _ | Module_if_annotation _ ->
          ())
    fields

let register_names ctx export_tbl fields =
  (* Both passes recurse into the branches of a conditional, in the same order
     the converter visits them, so positional naming stays aligned. *)
  let rec pass1 fields =
    List.iter
      (fun (field : (_ Src.modulefield, _) Ast.annotated) ->
        match field.desc with
        | Import { id; desc; exports; _ } -> (
            (* ZZZ Check for non-import fields *)
            match desc with
            | Func _ -> ()
            | Memory _ ->
                Sequence.register ctx.memories export_tbl
                  (Some (Memory : Src.exportable))
                  id exports
            | Table _ ->
                Sequence.register ctx.tables export_tbl (Some Table) id exports
            | Global _ ->
                Sequence.register ctx.globals export_tbl (Some Global) id
                  exports
            | Tag ty -> register_type ctx export_tbl Tag id exports ty)
        | Types rectype ->
            Array.iter
              (fun e ->
                let id, ty = e.Ast.desc in
                let name = Sequence.register' ctx.types export_tbl None id [] in
                CondTbl.add ctx.type_defs ctx.cond_asm name ty;
                match (ty : Src.subtype).typ with
                | Func _ | Array _ | Cont _ -> ()
                | Struct l ->
                    let seq = Sequence.make (Namespace.make ()) "f" in
                    let fields =
                      Array.map
                        (fun t ->
                          Sequence.register' seq export_tbl None (get_annot t)
                            [])
                        l
                    in
                    Hashtbl.replace ctx.struct_fields name
                      (seq, Array.to_list fields))
              rectype
        | Global { id; exports; _ } ->
            Sequence.register ctx.globals export_tbl (Some Global) id exports
        | Func _ | Export _ | Start _ -> ()
        | Elem { id; _ } -> Sequence.register ctx.elems export_tbl None id []
        | Data { id; _ } -> Sequence.register ctx.datas export_tbl None id []
        | Memory { id; exports; _ } ->
            Sequence.register ctx.memories export_tbl (Some Memory) id exports
        | Table { id; exports; _ } ->
            Sequence.register ctx.tables export_tbl (Some Table) id exports
        | Tag { id; exports; typ; _ } ->
            register_type ctx export_tbl Tag id exports typ
        | String_global { id; _ } ->
            Sequence.register ctx.globals export_tbl (Some Global) (Some id) []
        | Module_if_annotation { then_fields; else_fields; cond } ->
            with_cond ctx ~location:field.info cond true (fun () ->
                pass1 then_fields);
            Option.iter
              (fun e ->
                with_cond ctx ~location:field.info cond false (fun () ->
                    pass1 e))
              else_fields)
      fields
  in
  let rec pass2 fields =
    List.iter
      (fun (field : (_ Src.modulefield, _) Ast.annotated) ->
        match field.desc with
        | Import { id; desc; exports; _ } -> (
            (* ZZZ Check for non-import fields *)
            match desc with
            | Func typ -> register_type ctx export_tbl Func id exports typ
            | Memory _ | Table _ | Global _ | Tag _ -> ())
        | Func { id; exports; typ; _ } ->
            register_type ctx export_tbl Func id exports typ
        | Module_if_annotation { then_fields; else_fields; cond } ->
            with_cond ctx ~location:field.info cond true (fun () ->
                pass2 then_fields);
            Option.iter
              (fun e ->
                with_cond ctx ~location:field.info cond false (fun () ->
                    pass2 e))
              else_fields
        | Types _ | Global _ | Export _ | Start _ | Elem _ | Data _ | Memory _
        | Table _ | Tag _ | String_global _ ->
            ())
      fields
  in
  pass1 fields;
  pass2 fields

let collect_exports cond_env diagnostics fields =
  let tbl = Hashtbl.create 16 in
  let lst = ref [] in
  (* [asm] is the branch assumption under which the fields being walked appear,
     so each standalone export is recorded with the condition that guards it. *)
  let rec go asm fields =
    List.iter
      (fun (field : (_ Src.modulefield, _) Ast.annotated) ->
        match field.desc with
        | Export { name; kind; index } ->
            (* Don't keep a meaningless location *)
            lst := (kind, index, Ast.no_loc name.desc, asm) :: !lst;
            let k = (kind, index.Ast.desc) in
            Hashtbl.replace tbl k
              (name :: (try Hashtbl.find tbl k with Not_found -> []))
        | Module_if_annotation { cond; then_fields; else_fields } ->
            let c =
              Cond.of_cond cond_env diagnostics ~location:field.info cond
            in
            go (Cond.and_ asm c) then_fields;
            Option.iter (go (Cond.and_ asm (Cond.not_ c))) else_fields
        | _ -> ())
      fields
  in
  go Cond.true_ fields;
  (tbl, !lst)

let rec module_has_conditional fields =
  List.exists
    (fun (f : (_ Src.modulefield, _) Ast.annotated) ->
      match f.desc with
      | Module_if_annotation { then_fields; else_fields; _ } ->
          module_has_conditional then_fields
          || Option.fold ~none:false ~some:module_has_conditional else_fields
          || true
      | _ -> false)
    fields

let rec count_memories fields =
  List.fold_left
    (fun n (f : (_ Src.modulefield, _) Ast.annotated) ->
      match f.desc with
      | Memory _ | Import { desc = Memory _; _ } -> n + 1
      | Module_if_annotation { then_fields; else_fields; _ } ->
          n + count_memories then_fields
          + Option.fold ~none:0 ~some:count_memories else_fields
      | _ -> n)
    0 fields

let module_ ?(strict_constants = false) diagnostics (_, fields) =
  Utils.Debug.timed "convert" @@ fun () ->
  try
    let forbid_numeric = module_has_conditional fields in
    (* Loads/stores reference the memory implicitly by index 0. When the module
     has a single memory that numeric reference is unambiguous (even if the
     memory itself sits in a conditional branch), so numeric memory references
     are allowed; with several memories, indices may shift across branches like
     any other field, so the general constraint stands. *)
    let forbid_numeric_memory = forbid_numeric && count_memories fields > 1 in
    let ctx =
      let common_namespace = Namespace.make () in
      {
        diagnostics;
        types =
          Sequence.make ~forbid_numeric (Namespace.make ~kind:`Type ()) "t";
        struct_fields = Hashtbl.create 16;
        globals = Sequence.make ~forbid_numeric common_namespace "g";
        functions = Sequence.make ~forbid_numeric common_namespace "f";
        memories =
          Sequence.make ~forbid_numeric:forbid_numeric_memory common_namespace
            "m";
        tables = Sequence.make ~forbid_numeric common_namespace "t";
        tags = Sequence.make ~forbid_numeric (Namespace.make ()) "t";
        datas = Sequence.make ~forbid_numeric (Namespace.make ()) "d";
        elems = Sequence.make ~forbid_numeric (Namespace.make ()) "e";
        referenced_elems = Hashtbl.create 16;
        type_defs = CondTbl.make ();
        implicit_types = Hashtbl.create 16;
        function_types = CondTbl.make ();
        tag_types = CondTbl.make ();
        exports = Hashtbl.create 16;
        start = None;
        locals = Sequence.make common_namespace "x";
        labels = LabelStack.make ();
        label_arities = [];
        return_arity = 0;
        strict_constants;
        cond_env = Cond.create ();
        cond_diag = Utils.Diagnostic.collector ();
        cond_asm = Cond.true_;
      }
    in
    let export_tbl, export_lst =
      collect_exports ctx.cond_env ctx.cond_diag fields
    in
    register_names ctx export_tbl fields;
    (* Resolve the start function (if any) to its Wax name; it is rendered as a
       [#[start]] attribute on that function. *)
    List.iter
      (fun f ->
        match f.Ast.desc with
        | Src.Start i -> ctx.start <- Some (idx ctx `Func i).Ast.desc
        | _ -> ())
      fields;
    if not forbid_numeric then elaborate_implicit_types ctx fields;
    List.iter
      (fun (kind, index, name, asm) ->
        let k =
          ( kind,
            (idx ctx
               (match (kind : Src.exportable) with
               | Func -> `Func
               | Memory -> `Mem
               | Table -> `Table
               | Tag -> `Tag
               | Global -> `Global)
               index)
              .desc )
        in
        let l =
          (asm, name)
          ::
          (match Hashtbl.find_opt ctx.exports k with
          | None -> []
          | Some l -> l)
        in
        Hashtbl.replace ctx.exports k l)
      export_lst;
    (* Record which element segments are referenced by table.init / elem.drop /
     array.*_elem (recursing into conditional branches), so a declarative
     segment used this way is declared rather than dropped. *)
    let rec collect_field (f : (_ Src.modulefield, _) Ast.annotated) =
      match f.Ast.desc with
      | Func { instrs; _ } ->
          collect_elem_refs_instrs ctx ctx.referenced_elems instrs
      | Module_if_annotation { then_fields; else_fields; _ } ->
          List.iter collect_field then_fields;
          Option.iter (List.iter collect_field) else_fields
      | _ -> ()
    in
    List.iter collect_field fields;
    Sink_let.module_
      (Recover_loops.module_
         (Recover_dispatch.module_
            (List.concat_map (fun f -> modulefield ctx export_tbl f) fields)))
  with Numeric_ref_in_conditional location ->
    Utils.Diagnostic.report diagnostics ~location ~severity:Error
      ~message:(fun f () ->
        Format.pp_print_string f
          "Numeric references to module fields are not supported in a module \
           with conditional annotations; use a symbolic $name.")
      ();
    Utils.Diagnostic.abort ()

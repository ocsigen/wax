open Ast
open Infer

(* A member-completion candidate for [recv.<here>] or [ns::<here>]: a struct
   field, a value method, or a namespace free function, its [member_kind]
   driving the editor's icon and [member_detail] a rendered type/signature —
   the field's declared type or the method/function's signature. *)
type member_kind = Field | Method | Function

type member_candidate = {
  member_name : string;
  member_kind : member_kind;
  member_detail : string;
}

(* What a member access [recv.<here>]'s completion candidates are derived from.
   The typer records this lightweight descriptor (a kind and the receiver's
   type), and {!member_candidates} turns it into the candidate list on demand —
   so the list, which for a v128 or memory receiver is large, is built only for
   the access under the cursor, not at every access in the file. *)
type member_receiver =
  | R_numeric of inferred_type
      (** a value receiver: its integer / float / v128 methods *)
  | R_struct of fieldtype Ast.annotated_array  (** the struct's fields *)
  | R_array of fieldtype  (** by element type: [length]/[fill]/[copy]/[init] *)
  | R_memory of [ `I32 | `I64 ]  (** by address type *)
  | R_table of [ `I32 | `I64 ] * reftype  (** by address and element type *)
  | R_cont of member_candidate list
      (** a continuation-typed receiver: the resume family and [switch],
          prebuilt (their signatures need the type context) *)

(* What a value method's result type is relative to its receiver: [Same] as the
   receiver, or the equal-width opposite numeric family ([i32]<->[f32],
   [i64]<->[f64]), as [from_bits] / [to_bits] reinterpret. *)
type method_result = Same | Reinterpret

type value_method = {
  vm_name : string;
  vm_binary : bool;  (** takes a second operand of the receiver's type *)
  vm_result : method_result;
}

let meth ?(binary = false) ?(result = Same) vm_name =
  { vm_name; vm_binary = binary; vm_result = result }

(* The value methods offered by member completion for an integer / float
   receiver. A curated registry: the method dispatch (see
   [type_unary_intrinsic_call] / [type_binary_intrinsic_call]) is match-based
   and cannot be enumerated, so the test in test/method-consistency type-checks
   each of these — arity and result type included — to keep the registry in step
   with what the typer actually accepts. Vector ([v128]) and memory / table
   methods (a different dispatch path) are not covered yet. *)
let integer_methods =
  [
    meth "clz";
    meth "ctz";
    meth "popcnt";
    meth "extend8_s";
    meth "extend16_s";
    meth ~result:Reinterpret "from_bits";
    meth ~binary:true "rotl";
    meth ~binary:true "rotr";
  ]

let float_methods =
  [
    meth "abs";
    meth "ceil";
    meth "floor";
    meth "trunc";
    meth "nearest";
    meth "sqrt";
    meth ~result:Reinterpret "to_bits";
    meth ~binary:true "min";
    meth ~binary:true "max";
    meth ~binary:true "copysign";
  ]

let numtype_name : Ast.valtype -> string = function
  | I32 -> "i32"
  | I64 -> "i64"
  | F32 -> "f32"
  | F64 -> "f64"
  | V128 -> "v128"
  | Ref _ -> "ref"

(* The member-completion candidates for [methods] on a numeric receiver
   rendered as [recv_name] (a concrete [i32] or a flexible-literal family like
   [int]), with a real signature ([fn() -> i32], [fn(f32) -> f32]).
   [reinterp_name] is the result type of a bit-reinterpreting method
   ([from_bits]/[to_bits]) — the opposite family, which for a flexible receiver
   is rendered by family name too. *)
let method_candidates ~recv_name ~reinterp_name methods =
  List.map
    (fun m ->
      let params = if m.vm_binary then recv_name else "" in
      let result =
        match m.vm_result with
        | Same -> recv_name
        | Reinterpret -> reinterp_name
      in
      {
        member_name = m.vm_name;
        member_kind = Method;
        member_detail = Printf.sprintf "fn(%s) -> %s" params result;
      })
    methods

(* A struct field's declared type, rendered for the member-completion detail
   (e.g. [i32], [mut i32], [&point]) as it reads in a type definition. [Output]
   here is [Infer.Output] (open Infer), whose printers take a formatter. *)
let render_fieldtype (f : Ast.fieldtype) =
  String.trim (Format.asprintf "%a" Output.fieldtype f)

(* A reference type rendered as it reads in source (e.g. [&func], [&?extern]),
   for a table's element type in the member-completion detail. *)
let render_reftype (rt : Ast.reftype) =
  String.trim (Format.asprintf "%a" Output.valtype (Ast.Ref rt))

(* The member candidates for a struct's [fields] (each name and declared type),
   for member completion. *)
let struct_candidates fields =
  Array.to_list fields
  |> List.map (fun f ->
      let nm, typ = f.Ast.desc in
      {
        member_name = nm.Ast.desc;
        member_kind = Field;
        member_detail = render_fieldtype typ;
      })

(* Expected operand/result type of a SIMD intrinsic, as a fresh type cell. *)
let simd_valtype : Simd.ty -> inferred_valtype = function
  | TV128 -> { typ = V128; internal = V128; anon_comptype = None }
  | TI32 -> i32_valtype
  | TI64 -> i64_valtype
  | TF32 -> f32_valtype
  | TF64 -> f64_valtype

let simd_ty_name t = numtype_name (simd_valtype t).typ

(* The member-completion candidate for a SIMD method [name] (e.g. [add_i32x4]),
   its signature read straight from the registry the typer dispatches through
   ([Simd.classify]): the leading constant lane immediates, then the
   non-receiver stack operands, then the result. *)
let simd_method_candidate name =
  let detail =
    match Simd.classify name with
    | Some { operands = _receiver :: rest; result; imm; _ } ->
        let imm_params =
          match imm with
          | Simd.No_imm -> []
          | Lane _ -> [ "lane index" ]
          | Shuffle -> [ "16 lane indices" ]
        in
        let params = imm_params @ List.map simd_ty_name rest in
        let result =
          match result with Some t -> simd_ty_name t | None -> "()"
        in
        Printf.sprintf "fn(%s) -> %s" (String.concat ", " params) result
    | _ -> ""
  in
  { member_name = name; member_kind = Method; member_detail = detail }

(* The value methods offered by member completion for a [v128] receiver — the
   vector ops [v.add_i32x4(w)], enumerated from the SIMD registry (so, unlike
   the scalar registries above, no drift is possible: the same table classifies
   the call). *)
let simd_v128_methods () =
  List.map simd_method_candidate (Simd.method_names Simd.TV128)

(* The value-method candidates member completion offers for a numeric receiver
   of inferred type [t], or [None] if it has none. Beyond the concrete numeric
   valtypes ([i32] … [f64], [v128]), a receiver can still be a flexible literal
   type: an [int] takes its integer methods only, a [number] or [large number]
   both families (either narrowing is still open), a [float] its float methods
   only. A packed [i8]/[i16] read must be cast before any method, so gets none.
   The [from_bits]/[to_bits] reinterpretation flips the family, rendered by
   family name for a flexible receiver since the width is uncommitted. *)
let numeric_receiver_candidates (t : inferred_type) :
    member_candidate list option =
  let ints ~recv_name ~reinterp =
    method_candidates ~recv_name ~reinterp_name:reinterp integer_methods
  in
  let floats ~recv_name ~reinterp =
    method_candidates ~recv_name ~reinterp_name:reinterp float_methods
  in
  match t with
  | Valtype { typ = I32; _ } -> Some (ints ~recv_name:"i32" ~reinterp:"f32")
  | Valtype { typ = I64; _ } -> Some (ints ~recv_name:"i64" ~reinterp:"f64")
  | Valtype { typ = F32; _ } -> Some (floats ~recv_name:"f32" ~reinterp:"i32")
  | Valtype { typ = F64; _ } -> Some (floats ~recv_name:"f64" ~reinterp:"i64")
  | Valtype { typ = V128; _ } -> Some (simd_v128_methods ())
  | Int -> Some (ints ~recv_name:"int" ~reinterp:"float")
  | Number ->
      Some
        (ints ~recv_name:"number" ~reinterp:"float"
        @ floats ~recv_name:"number" ~reinterp:"int")
  | LargeInt ->
      Some
        (ints ~recv_name:"large number" ~reinterp:"float"
        @ floats ~recv_name:"large number" ~reinterp:"int")
  | Float -> Some (floats ~recv_name:"float" ~reinterp:"int")
  | _ -> None

(* Whether a value receiver of type [t] has value methods, as an [R_numeric]
   descriptor — the cheap classification the recorder uses to decide whether to
   record, without building the (possibly large) candidate list. Its domain must
   match [numeric_receiver_candidates] returning [Some]. *)
let numeric_receiver_kind (t : inferred_type) : member_receiver option =
  match t with
  | Valtype { typ = I32 | I64 | F32 | F64 | V128; _ }
  | Int | Number | LargeInt | Float ->
      Some (R_numeric t)
  | _ -> None

let address_type_name : [ `I32 | `I64 ] -> string = function
  | `I32 -> "i32"
  | `I64 -> "i64"

(* [fn(<params>) -> <result>], with an empty result rendered [()] and several
   as a tuple. *)
let render_signature params result =
  let result =
    match result with
    | [] -> "()"
    | [ r ] -> r
    | rs -> "(" ^ String.concat ", " rs ^ ")"
  in
  Printf.sprintf "fn(%s) -> %s" (String.concat ", " params) result

(* The methods member completion offers on a continuation-typed receiver — the
   resume family and [switch] — with [params]/[results] the rendered parameter
   and result types of the continuation's function type and [switch_results]
   the rendered results of a [switch] (the last parameter's own continuation
   parameters, when it has one). Unlike the other receivers, the candidate
   list is built at record time (the signatures need the type context) and
   carried by {!R_cont}; the editor's signature help rebuilds it from the
   declarations. *)
let cont_method_candidates ~params ~results ~switch_results =
  let m member_name member_detail =
    { member_name; member_kind = Method; member_detail }
  in
  let leading = List.filteri (fun i _ -> i < List.length params - 1) params in
  [
    m "resume" (render_signature params results);
    m "resume_throw" (render_signature [ "tag(payload)" ] results);
    m "resume_throw_ref" (render_signature [ "&?exn" ] results);
    m "switch" (render_signature (leading @ [ "tag: tag" ]) switch_results);
  ]

(* The atomic memory accesses ([mem.atomic_load32(addr)],
   [mem.atomic_rmw_add8(addr, v)], …), enumerated from the
   {!Wax_wasm.Atomics.families} the typer dispatches on; the address takes
   [addr_name]. The name carries the access width only: a narrow load returns
   the raw-bits [i8]/[i16] (resolved by a surrounding [as iN_u] cast) and a
   narrow store/RMW value picks the i32/i64 family by its type (rendered
   [int]); the 64-bit accesses are necessarily [i64]. *)
let atomic_method_candidates ~addr_name =
  let value : Wax_wasm.Atomics.width -> string = function
    | `W8 | `W16 | `W32 -> "int"
    | `W64 -> "i64"
  in
  let load_result : Wax_wasm.Atomics.width -> string = function
    | `W8 -> "i8"
    | `W16 -> "i16"
    | `W32 -> "i32"
    | `W64 -> "i64"
  in
  List.map
    (fun f ->
      let operands, results =
        match (f : Wax_wasm.Atomics.family) with
        | Load w -> ([], [ load_result w ])
        | Store w -> ([ value w ], [])
        | Rmw (Wax_wasm.Ast.AtomicCmpxchg, w) ->
            ([ value w; value w ], [ value w ])
        | Rmw (_, w) -> ([ value w ], [ value w ])
        | Wait `I32 -> ([ "i32"; "i64" ], [ "i32" ])
        | Wait `I64 -> ([ "i64"; "i64" ], [ "i32" ])
        | Notify -> ([ "i32" ], [ "i32" ])
      in
      {
        member_name = Wax_wasm.Atomics.method_name f;
        member_kind = Method;
        member_detail =
          render_signature
            ((addr_name :: operands) @ [ "offset?: int" ])
            results;
      })
    Wax_wasm.Atomics.families

(* The SIMD memory accesses ([mem.loadv128(addr)],
   [mem.load8_lane(addr, v, lane)], …), enumerated from
   {!Wax_wasm.Simd.mem_method_names}; the first operand is the address. *)
let simd_mem_method_candidates ~addr_name =
  List.map
    (fun name ->
      let mi : Simd.mem_intrinsic = Option.get (Simd.mem_method name) in
      let rest =
        match mi.m_operands with
        | _addr :: r -> List.map simd_ty_name r
        | [] -> []
      in
      let params =
        (addr_name :: rest)
        @ (if mi.m_lane then [ "lane: int" ] else [])
        @ [ "offset?: int"; "align?: int" ]
      in
      {
        member_name = name;
        member_kind = Method;
        member_detail =
          render_signature params
            (match mi.m_result with Some t -> [ simd_ty_name t ] | None -> []);
      })
    Simd.mem_method_names

(* The value methods member completion offers on a memory receiver
   [mem.load8(addr)], with [addr_name] the memory's address type: the scalar
   loads/stores (with their optional labelled [offset]/[align] immediates),
   the size/grow/fill/copy/init management ops, and the atomic and SIMD memory
   accesses. *)
let memory_method_candidates ~addr_name =
  let m member_name member_detail =
    { member_name; member_kind = Method; member_detail }
  in
  let load name r =
    m name
      (Printf.sprintf "fn(%s, offset?: int, align?: int) -> %s" addr_name r)
  in
  let store name v =
    m name
      (Printf.sprintf "fn(%s, %s, offset?: int, align?: int) -> ()" addr_name v)
  in
  [
    load "load8" "i32";
    load "load16" "i32";
    load "load32" "i32";
    load "load64" "i64";
    load "loadf32" "f32";
    load "loadf64" "f64";
    store "store8" "i32";
    store "store16" "i32";
    store "store32" "i32";
    store "store64" "i64";
    store "storef32" "f32";
    store "storef64" "f64";
    m "size" (Printf.sprintf "fn() -> %s" addr_name);
    m "grow" (Printf.sprintf "fn(%s) -> %s" addr_name addr_name);
    m "fill" (Printf.sprintf "fn(%s, i32, %s) -> ()" addr_name addr_name);
    m "copy"
      (Printf.sprintf "fn(%s, %s, %s) -> ()" addr_name addr_name addr_name);
    m "init" (Printf.sprintf "fn(data, %s, i32, i32) -> ()" addr_name);
  ]
  @ atomic_method_candidates ~addr_name
  @ simd_mem_method_candidates ~addr_name

(* The value methods member completion offers on a table receiver [tab.size()],
   with [addr_name] the table's address type and [elem_name] its element type:
   the size/grow/fill/copy/init management ops. Element access is [tab[i]], not
   a method. *)
let table_method_candidates ~addr_name ~elem_name =
  let m member_name member_detail =
    { member_name; member_kind = Method; member_detail }
  in
  [
    m "size" (Printf.sprintf "fn() -> %s" addr_name);
    m "grow" (Printf.sprintf "fn(%s, %s) -> %s" elem_name addr_name addr_name);
    m "fill"
      (Printf.sprintf "fn(%s, %s, %s) -> ()" addr_name elem_name addr_name);
    m "copy"
      (Printf.sprintf "fn(%s, %s, %s) -> ()" addr_name addr_name addr_name);
    m "init" (Printf.sprintf "fn(elem, %s, i32, i32) -> ()" addr_name);
  ]

(* The methods member completion offers on an array receiver [a.length()] with
   element [elem]: [length], and the [fill]/[copy]/[init] bulk operations (the
   last from a data / element segment). Indices and counts are [i32]; [fill]'s
   value and [copy]'s source array are the element type. *)
let array_method_candidates elem =
  let m member_name member_detail =
    { member_name; member_kind = Method; member_detail }
  in
  let value = render_fieldtype { elem with Ast.mut = false } in
  let arr = "&[" ^ render_fieldtype elem ^ "]" in
  [
    m "length" "fn() -> i32";
    m "fill" (Printf.sprintf "fn(i32, %s, i32) -> ()" value);
    m "copy" (Printf.sprintf "fn(i32, %s, i32, i32) -> ()" arr);
    m "init" (Printf.sprintf "fn(seg, i32, i32, i32) -> ()");
  ]

(* The member-completion candidates a recorded {!member_receiver} stands for,
   derived on demand (the editor forces only the one under the cursor). *)
let member_candidates : member_receiver -> member_candidate list = function
  | R_numeric t -> Option.value ~default:[] (numeric_receiver_candidates t)
  | R_struct fields -> struct_candidates fields
  | R_array elem -> array_method_candidates elem
  | R_memory at -> memory_method_candidates ~addr_name:(address_type_name at)
  | R_table (at, rt) ->
      table_method_candidates ~addr_name:(address_type_name at)
        ~elem_name:(render_reftype rt)
  | R_cont l -> l

(* Free-function members offered after [v128::] — [bitselect] and the per-shape
   const constructors — with signatures from the SIMD registry. *)
let simd_free_members () =
  List.map
    (fun name ->
      let full = Simd.free_full name in
      let detail =
        match Simd.const_shape_of_name full with
        | Some shape ->
            Printf.sprintf "fn(%d lanes) -> v128" (Simd.const_arity shape)
        | None -> (
            match Simd.classify full with
            | Some { operands; result; _ } ->
                Printf.sprintf "fn(%s) -> %s"
                  (String.concat ", " (List.map simd_ty_name operands))
                  (match result with Some t -> simd_ty_name t | None -> "()")
            | None -> "")
      in
      { member_name = name; member_kind = Function; member_detail = detail })
    Simd.free_member_names

(* The free functions offered by completion after an intrinsic namespace path
   [ns::]: [v128::] holds the SIMD const constructors and [bitselect], [i64::]
   the wide-arithmetic ops, [atomic::] the memory fence. Mirrors the dispatch in
   [type_path_intrinsic_call] / [type_wide_arith_call] (test/method-consistency
   type-checks each offered call). Empty for an unknown namespace. *)
let namespace_members ns : member_candidate list =
  let fn member_name member_detail =
    { member_name; member_kind = Function; member_detail }
  in
  let wide = "fn(i64, i64, i64, i64) -> (i64, i64)" in
  let mul = "fn(i64, i64) -> (i64, i64)" in
  match ns with
  | "v128" -> simd_free_members ()
  | "i64" ->
      [
        fn "add128" wide;
        fn "sub128" wide;
        fn "mul_wide_s" mul;
        fn "mul_wide_u" mul;
      ]
  | "atomic" -> [ fn "fence" "fn() -> ()" ]
  | _ -> []

(* The intrinsic namespace names ([v128], [i64], [atomic]), for completion of
   the [ns] before [::]. Exactly the namespaces {!namespace_members} answers. *)
let intrinsic_namespaces = [ "v128"; "i64"; "atomic" ]

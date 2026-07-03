let validate_refs = ref true

module Uint32 = Wax_utils.Uint32
module Uint64 = Wax_utils.Uint64
open Ast.Binary.Types

(* The [@]-suffixed operators sequence [option] computations, short-circuiting
   on [None]: [let*@] binds, [let+@] maps, and [let>@] runs the body for its
   side effect and discards the result. (The unsuffixed [let*]/[let*!]/[let*?]
   defined further down instead thread the value stack.) *)
let ( let*@ ) = Option.bind
let ( let+@ ) o f = Option.map f o
let ( let>@ ) o f = Option.iter f o

(*** Source types and printers ***)

let print_string f s =
  let s = s.Ast.desc in
  let len, s = Output.escape_string s in
  Format.pp_print_as f len s

let print_ident f id =
  if Lexer.is_valid_identifier id then Format.fprintf f "$%s" id
  else Format.fprintf f "$\"%s\"" (snd (Misc.escape_string id))

let print_index f (idx : Ast.Text.idx) =
  match idx.desc with
  | Num n -> Format.fprintf f "%s" (Uint32.to_string n)
  | Id id -> print_ident f id

let print_wrapped f s =
  Format.fprintf f "%a"
    (Format.pp_print_list
       ~pp_sep:(fun f () -> Format.pp_print_space f ())
       Format.pp_print_string)
    (String.split_on_char ' ' s)

(* Render a type as the source wrote it, naming an indexed type by its source
   reference ($foo or a number) rather than an interned canonical index. *)
let print_text_heaptype f (ty : Ast.Text.heaptype) =
  match Ast.Text.heaptype_keyword ty with
  | Some kw -> Format.pp_print_string f kw
  | None -> (
      match ty with
      | Type idx -> print_index f idx
      | Exact idx -> Format.fprintf f "@[<1>(exact@ %a)@]" print_index idx
      | _ -> assert false)

let print_text_valtype f (ty : Ast.Text.valtype) =
  match ty with
  | I32 -> Format.fprintf f "i32"
  | I64 -> Format.fprintf f "i64"
  | F32 -> Format.fprintf f "f32"
  | F64 -> Format.fprintf f "f64"
  | V128 -> Format.fprintf f "v128"
  | Ref { nullable; typ } ->
      if nullable then
        Format.fprintf f "@[<1>(ref@ null@ %a)@]" print_text_heaptype typ
      else Format.fprintf f "@[<1>(ref@ %a)@]" print_text_heaptype typ

let print_text_storagetype f (ty : Ast.Text.storagetype) =
  match ty with
  | Value v -> print_text_valtype f v
  | Packed I8 -> Format.pp_print_string f "i8"
  | Packed I16 -> Format.pp_print_string f "i16"

let print_text_fieldtype f ({ mut; typ } : Ast.Text.fieldtype) =
  if mut then Format.fprintf f "@[<1>(mut@ %a)@]" print_text_storagetype typ
  else print_text_storagetype f typ

let print_text_functype f ({ params; results } : Ast.Text.functype) =
  Array.iter
    (fun p ->
      Format.fprintf f "@ @[<1>(param@ %a)@]" print_text_valtype
        (snd p.Ast.desc))
    params;
  Array.iter
    (fun t -> Format.fprintf f "@ @[<1>(result@ %a)@]" print_text_valtype t)
    results

(* Render a composite type as its source signature, for a reference to a type
   the user did not name (an implicit [ref.func] type, the internal string
   type). *)
let print_text_comptype f (ty : Ast.Text.comptype) =
  match ty with
  | Func ft -> Format.fprintf f "@[<1>(func%a)@]" print_text_functype ft
  | Array ft -> Format.fprintf f "@[<1>(array@ %a)@]" print_text_fieldtype ft
  | Struct fields ->
      Format.fprintf f "@[<1>(struct";
      Array.iter
        (fun e ->
          let _, ft = e.Ast.desc in
          Format.fprintf f "@ @[<1>(field@ %a)@]" print_text_fieldtype ft)
        fields;
      Format.fprintf f ")@]"
  | Cont idx -> Format.fprintf f "@[<1>(cont@ %a)@]" print_index idx

(* The source rendering of a stack value: either a value type the user wrote
   (or that names a type the user declared), or — for a reference whose type has
   no source name — that referenced type's signature, shown inline. *)
type source_type =
  | Plain of Ast.Text.valtype
  | Inline_ref of Ast.Text.comptype
  (* The bottom reference type [(ref bot)]. It has no user-written form; it is
     synthesized only to render a stack value of the bottom reference type in a
     diagnostic (e.g. when such a value reaches a numeric context). *)
  | Bottom_ref

let print_source_type f = function
  | Plain v -> print_text_valtype f v
  | Inline_ref comptype ->
      Format.fprintf f "@[<1>(ref@ %a)@]" print_text_comptype comptype
  | Bottom_ref -> Format.fprintf f "@[<1>(ref@ bot)@]"

(* Reconstruct a source type from an interned one. Used as the source type of a
   pushed value when no truer reference is available, so every concrete stack
   value carries a source type (as on the Wax side, where an inferred type
   bundles both forms). Only abstract heap types are reconstructed this way: a
   concrete [Type] reference always carries a truer source from its declaration. *)
let source_of_heaptype (h : heaptype) : Ast.Text.heaptype =
  match h with
  | Func -> Func
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
  | Type _ | Exact _ -> assert false

let source_of_valtype (ty : valtype) : source_type =
  Plain
    (match ty with
    | I32 -> I32
    | I64 -> I64
    | F32 -> F32
    | F64 -> F64
    | V128 -> V128
    | Ref { nullable; typ } -> Ref { nullable; typ = source_of_heaptype typ })

(*** Diagnostics ***)

module Error = struct
  open Wax_utils

  let did_you_mean lst =
    match List.rev lst with
    | [] -> None
    | last :: rest ->
        let rest = List.rev rest in
        let pp f = Format.fprintf f "%s" in
        Some
          (fun f () ->
            Format.fprintf f "Did@ you@ mean@ %a%s%a?"
              (Format.pp_print_list
                 ~pp_sep:(fun f () -> Format.fprintf f ",@ ")
                 pp)
              rest
              (if rest = [] then "" else " or ")
              pp last)

  let unbound_label context ~location id lst =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "Unknown label: %a is not bound." print_index id)
      ?hint:(did_you_mean lst) ()

  let unbound_index context ~location kind id lst =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "Unknown %s: index %a is not bound." kind print_index
          id)
      ?hint:(did_you_mean lst) ()

  let packed_array_access context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "This instruction cannot be used on packed arrays. Use array.get_s \
           or array.get_u to specify sign extension.")
      ()

  let unpacked_array_access context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "This instruction is only valid for packed arrays. Use array.get.")
      ()

  let packed_struct_access context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "This instruction cannot be used on packed fields. Use struct.get_s \
           or struct.get_u to specify sign extension.")
      ()

  let unpacked_struct_access context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "This instruction is only valid for packed fields. Use struct.get.")
      ()

  (* The caret points at the instruction that {e produced} the value still on
     the stack, not at the one consuming it (whose location is [consumer]): the
     wording makes that explicit, and a secondary caret marks the use site. *)
  let instruction_type_mismatch context ~location ~consumer ~provided_source
      ~expected_source =
    (* Mark the use site with a secondary caret, but only when it is a distinct
       location that does not enclose the producer: an implicit function or
       block result spans the whole construct, so a caret there would just be
       noise around the precise one. *)
    let encloses outer inner =
      outer.Ast.loc_start.Lexing.pos_cnum <= inner.Ast.loc_start.Lexing.pos_cnum
      && inner.Ast.loc_end.Lexing.pos_cnum <= outer.Ast.loc_end.Lexing.pos_cnum
    in
    let related =
      match consumer with
      | Some loc
        when loc.Ast.loc_start.Lexing.pos_cnum >= 0
             && not (encloses loc location) ->
          [
            {
              Wax_utils.Diagnostic.location = loc;
              message = (fun f () -> Format.pp_print_string f "expected here");
            };
          ]
      | _ -> []
    in
    Diagnostic.report context ~location ~severity:Error ~related
      ~message:(fun f () ->
        Format.fprintf f
          "Type mismatch: this produces a value of type@ @[<2>%a@],@ but type@ \
           @[<2>%a@]@ is expected."
          print_source_type provided_source print_source_type expected_source)
      ()

  let expected_ref_type context ~location ~src_loc ~source =
    match src_loc with
    | None ->
        Diagnostic.report context ~location ~severity:Error
          ~message:(fun f () ->
            Format.fprintf f
              "Type mismatch: expected reference type but got type@ @[<2>%a@]."
              print_source_type source)
          ()
    | Some location ->
        Diagnostic.report context ~location ~severity:Error
          ~message:(fun f () ->
            Format.fprintf f
              "Type mismatch: this instruction should return a reference type \
               but has type@ @[<2>%a@]."
              print_source_type source)
          ()

  let table_type_mismatch context ~location ~source idx =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "Type mismatch: the table %a@ %a@ @[%a@]." print_index
          idx print_wrapped
          "should contain functions but its elements have type"
          print_source_type source)
      ()

  let elem_segment_type_mismatch context ~location ~elem_source ~table_source =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "Type mismatch: the element segment has type@ @[<2>%a@],@ which is \
           not a subtype of the table element type@ @[<2>%a@]."
          print_source_type elem_source print_source_type table_source)
      ()

  let duplicate_local context ~location name =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "The local $%s is already defined." name)
      ()

  let type_mismatch context ~location ~provided_source ~expected_source =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "Type mismatch: expecting type@ @[<2>%a@]@ but got type@ @[<2>%a@]."
          print_source_type expected_source print_source_type provided_source)
      ()

  let br_cast_type_mismatch context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "Type mismatch: the first type must be a supertype of the second one.")
      ()

  let br_on_non_null_no_ref context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "Type mismatch: br_on_non_null requires the target label to end in a \
           reference type, but it has no result types.")
      ()

  let select_type_mismatch context ~location ~loc1 ~source1 ~loc2 ~source2 =
    (* Point a caret at each branch value (when its push site is known),
       labelled with its type. A placeholder location uses a negative column;
       skip those, as in [locations]. *)
    let branch_label loc source =
      match loc with
      | Some loc when loc.Ast.loc_start.Lexing.pos_cnum >= 0 ->
          Some
            {
              Wax_utils.Diagnostic.location = loc;
              message =
                (fun f () ->
                  Format.fprintf f "@[<2>%a@]" print_source_type source);
            }
      | _ -> None
    in
    let related =
      List.filter_map Fun.id
        [ branch_label loc1 source1; branch_label loc2 source2 ]
    in
    Diagnostic.report context ~location ~severity:Error ~related
      ~message:(fun f () ->
        (* When both carets are shown they carry the types; otherwise name the
           two types in the message so they are not lost. *)
        if List.length related = 2 then
          Format.fprintf f
            "Type mismatch: both branches of a select should have the same \
             type."
        else
          Format.fprintf f
            "Type mismatch: both branches of a select should have the same \
             type.@ Here, they have type@ @[<2>%a@]@ and@ @[<2>%a@]."
            print_source_type source1 print_source_type source2)
      ()

  let empty_stack context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "Type mismatch: the stack is empty (a value is missing).")
      ()

  let non_empty_stack context ~location output_stack =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "Type mismatch: unexpected values left on the stack:%a"
          output_stack ())
      ()

  (* Report the values still on the stack by pointing a caret at each of them.
     [location] carries the topmost value; [related] the others. *)
  let leftover_values context ~location ~related =
    Diagnostic.report context ~location ~severity:Error ~related
      ~message:(fun f () ->
        Format.pp_print_string f
          (if related = [] then
             "Type mismatch: this value is left on the stack."
           else "Type mismatch: these values are left on the stack."))
      ()

  (* Print a list of source types. *)
  let print_sources f source =
    Format.fprintf f "@[<1>[%a]@]"
      (Format.pp_print_list
         ~pp_sep:(fun f () -> Format.pp_print_space f ())
         print_source_type)
      (Array.to_list source)

  let argument_count_mismatch context ~location ~descr ~provided_source
      ~expected_source =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "Type mismatch: %s provides type@ @[<2>%a@]@ but type@ @[<2>%a@]@ \
           was expected."
          descr print_sources provided_source print_sources expected_source)
      ()

  let argument_type_mismatch context ~location ~descr ~provided_source
      ~expected_source =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "Type mismatch: %s provides type@ @[<2>%a@]@ but type@ @[<2>%a@]@ \
           was expected."
          descr print_source_type provided_source print_source_type
          expected_source)
      ()

  let branch_parameter_count_mismatch context ~location label len label' len' =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "Type mismatch: the default branch target@ %a@ expects@ %d@ \
           parameters, while branch target@ %a@ expects@ %d@ parameters."
          print_index label len print_index label' len')
      ()

  let memory_offset_too_large context ~location max_offset =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "The memory offset should be less than 0x%Lx."
          (Uint64.to_int64 max_offset))
      ()

  let memory_align_too_large context ~location natural =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "The memory alignment is larger than the natural alignment %d."
          natural)
      ()

  let bad_memory_align context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "The memory alignment should be a power of two.")
      ()

  let atomic_alignment context ~location natural =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "The alignment of an atomic access must be its natural alignment %d."
          natural)
      ()

  let invalid_lane_index context ~location max_lane =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "The lane index should be less than %d." max_lane)
      ()

  let inline_function_type_mismatch context ~location _ =
    (*ZZZ print expected type *)
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "The inline function type does not match the type definition.")
      ()

  let constant_expression_required context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "Only constant expressions are allowed here.")
      ()

  let immutable_global context ~location idx =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "The global %a should be mutable." print_index idx)
      ()

  let limit_too_large context ~location kind max =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "The %s size is too large. It should be less than 0x%Lx." kind
          (Uint64.to_int64 max))
      ()

  let invalid_page_size context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "The custom page size must be 1 or 65536.")
      ()

  let shared_memory_without_max context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "A shared memory must have a maximum size.")
      ()

  let limit_mismatch context ~location kind =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "The %s maximum size should be larger than the minimal size." kind)
      ()

  let duplicated_export context ~location name =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "There is already an export of name \"%a\"."
          print_string name)
      ()

  let import_after_definition context ~location kind =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "This import is after a %s definition." kind)
      ()

  let supertype_mismatch context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "The supertype is not of the same kind as this type.")
      ()

  let invalid_subtype context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "This type is not a valid subtype of its declared supertype.")
      ()

  let descriptor_outside_rec_group context ~location ~described =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "The %s type must be in the same recursion group."
          (if described then "described" else "descriptor"))
      ()

  let descriptor_not_reciprocal context ~location ~described =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        if described then
          Format.fprintf f
            "This descriptor does not describe the type it is attached to."
        else
          Format.fprintf f
            "The descriptor of this type does not describe it back.")
      ()

  let forward_use_of_described context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "A described type must be declared before its descriptor.")
      ()

  let descriptor_not_struct context ~location ~described =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "A %s type must be a struct type."
          (if described then "described" else "descriptor"))
      ()

  let not_function_type context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () -> Format.fprintf f "This should be a function type.")
      ()

  let exception_tag_with_results context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "The type of an exception tag must have no results.")
      ()

  let select_result_count context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "A typed select must be annotated with exactly one result type.")
      ()

  let non_nullable_table_type context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "Type mismatch: the type of the elements of this table must be \
           nullable.")
      ()

  let uninitialized_local context ~location idx =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "The local variable %a has not been initialized."
          print_index idx)
      ()

  (* A local that is declared but never read. Prefix its name with [_] to
     silence the warning. *)
  let unused_local context ~location name =
    Diagnostic.report context ~location ~severity:Warning
      ~warning:Warning.Unused_local ~universal:true
      ~message:(fun f () ->
        match name with
        | Some id ->
            Format.fprintf f "The local variable %a is never used." print_ident
              id
        | None -> Format.fprintf f "This local is never used.")
      ()

  let index_already_bound context ~location kind index =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "The %s index %a is already bound." kind print_ident
          index.Ast.desc)
      ()

  let expected_func_type context ~location idx =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "Type %a should be a function type." print_index idx)
      ()

  let expected_struct_type context ~location idx =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "Type %a should be a struct type." print_index idx)
      ()

  let expected_array_type context ~location idx =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "Type %a should be an array type." print_index idx)
      ()

  let expected_cont_type context ~location idx =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "Type %a should be a continuation type." print_index
          idx)
      ()

  let stack_switching_type_mismatch context ~location ~descr =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "Type mismatch in this stack switching instruction:@ %s." descr)
      ()

  let invalid_cast_type context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "Continuation types cannot be used in a cast instruction.")
      ()

  let type_without_descriptor context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "This descriptor instruction requires a type that has a descriptor.")
      ()

  let feature_disabled context ~location feature =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "This uses the %s feature, which is not enabled; pass @[--feature \
           %s@]."
          (Wax_utils.Feature.name feature)
          (Wax_utils.Feature.name feature))
      ()

  let descriptor_allocation_required context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "A type with a descriptor must be allocated with a descriptor \
           (struct.new_desc / struct.new_default_desc).")
      ()

  let expected_number_or_vec context ~location ~source =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "Type mismatch: expecting a numeric or vector type but got type@ \
           @[<2>%a@]."
          print_source_type source)
      ()

  let immutable context ~location what =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () -> Format.fprintf f "This %s is immutable." what)
      ()

  let not_defaultable context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "This type has no default value for all its fields.")
      ()

  let field_index_out_of_bounds context ~location ~index ~count =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "The field index %d is out of bounds: the structure has %d field(s)."
          index count)
      ()

  let unknown_field context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () -> Format.fprintf f "There is no such field.")
      ()

  let numeric_array_required context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "This operation requires an array of numeric elements.")
      ()

  let incompatible_array_element context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "The array element type is incompatible.")
      ()

  let ref_func_inaccessible context ~location idx =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "The function %a is not declared as referenceable (ref.func)."
          print_index idx)
      ()

  let non_constant_global context ~location idx =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "Only an immutable global may be used in a constant expression: %a."
          print_index idx)
      ()

  let start_function_signature context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "The start function must have no parameters and no results.")
      ()

  let multiple_start context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "A module can have at most one start function.")
      ()
end

let print_instr f i = Wax_utils.Printer.run f (fun p -> Output.instr p i)

(*** Symbol tables (sequences) ***)

module Sequence = struct
  type 'a t = {
    name : string;
    index_mapping : (int, 'a) Hashtbl.t;
    label_mapping : (string, int) Hashtbl.t;
    mutable last_index : int;
  }

  let make name =
    {
      name;
      index_mapping = Hashtbl.create 16;
      label_mapping = Hashtbl.create 16;
      last_index = 0;
    }

  let register seq id v =
    let idx = seq.last_index in
    seq.last_index <- seq.last_index + 1;
    Hashtbl.add seq.index_mapping idx v;
    Option.iter (fun id -> Hashtbl.add seq.label_mapping id.Ast.desc idx) id

  let get d seq (idx : Ast.Text.idx) =
    try
      match idx.desc with
      | Num n -> Some (Hashtbl.find seq.index_mapping (Uint32.to_int n))
      | Id id ->
          Some
            (Hashtbl.find seq.index_mapping (Hashtbl.find seq.label_mapping id))
    with Not_found ->
      let lst =
        match idx.desc with
        | Num _ -> []
        | Id id ->
            Wax_utils.Spell_check.f
              (fun f -> Hashtbl.iter (fun id' _ -> f id') seq.label_mapping)
              id
      in
      Error.unbound_index d ~location:idx.info seq.name idx lst;
      None

  let get_index seq (idx : Ast.Text.idx) =
    match idx.desc with
    | Num n -> Uint32.to_int n
    | Id id -> (
        try Hashtbl.find seq.label_mapping id
        with Not_found -> assert false (* Should not happen *))

  (* Resolve to an index without reporting or raising when a name is unbound —
     for callers that only want to note a resolvable reference and leave the
     error reporting to the pass that validates the reference. *)
  let get_index_opt seq (idx : Ast.Text.idx) =
    match idx.desc with
    | Num n -> Some (Uint32.to_int n)
    | Id id -> Hashtbl.find_opt seq.label_mapping id
end

(*** Types and the type context ***)

type type_context = {
  types : Types.t;
  mutable last_index : int;
  (* Keyed by a source type reference (numeric index / name): the resolved
     global index, a struct's field-name-to-position map, and the source
     composite type. The last lets an error name a component (a struct field,
     an array element, a function result) as the source wrote it; keying by the
     reference (rather than the deduplicated global index) keeps it injective,
     so [$a] is named with [$a] even when a structurally-equal [$b] shares its
     global index. *)
  index_mapping :
    (Uint32.t, int * (string * int) list * Ast.Text.comptype) Hashtbl.t;
  label_mapping :
    (string, int * (string * int) list * Ast.Text.comptype) Hashtbl.t;
  (* For each type definition, keyed by its text-level index: its source index
     node (its name when it has one, else its numeric index, carrying the
     definition's location), and — for a continuation type — the source
     reference to the wrapped type. Keying by text index (rather than the
     resolved, deduplicated global index) keeps the mapping injective, so a
     check on a type is reported at the exact definition and names types as they
     appear in the source. *)
  type_defs : (int, Ast.Text.idx * Ast.Text.idx option) Hashtbl.t;
  (* For a type carrying a [descriptor] clause, keyed by its resolved global
     index: the source reference to its descriptor type. The descriptor
     instructions derive the descriptor type from the described one, so this
     recovers the descriptor's source name for error rendering (there is no
     immediate to name it by). Deduplicated types share a descriptor, so keying
     by the global index is unambiguous. *)
  descriptor_source : (int, Ast.Text.idx) Hashtbl.t;
  (* The enabled optional features / proposals, and which are used. *)
  features : Wax_utils.Feature.set;
}

(* The source composite type a reference resolves to, named as the source wrote
   it (injective), or [None] for an unbound or sourceless reference. Does not
   report errors — callers that resolve the reference do. *)
let reference_comptype tc (idx : Ast.Text.idx) =
  let _, _, c =
    match idx.desc with
    | Num x -> Hashtbl.find tc.index_mapping x
    | Id id -> Hashtbl.find tc.label_mapping id
  in
  c

(* The source function type a reference resolves to, when it names one. *)
let reference_functype tc idx =
  match reference_comptype tc idx with Func ft -> ft | _ -> assert false

(* The source function type a [typeuse] denotes: the one named by its type
   reference, or its inline signature. Resolve the reference in preference to the
   inline signature, consistent with [typeuse] (which drives the corresponding
   [return_types]); for valid input the two agree, and preferring one uniformly
   keeps their arities in step when a malformed module gives both a [(type $i)]
   and a disagreeing inline signature. *)
let typeuse_functype tc (tu_idx, tu_sign) =
  match (tu_idx, tu_sign) with
  | Some idx, _ -> reference_functype tc idx
  | None, Some ft -> ft
  | _ -> assert false

(* Per-element source types for a source function type's params and results, to
   pass straight to [pop_args]/[push_results]'s [~source]. *)
let functype_sources ({ params; results } : Ast.Text.functype) =
  ( Array.map (fun p -> Plain (snd p.Ast.desc)) params,
    Array.map (fun v -> Plain v) results )

(* The source function type that the continuation type named by [idx] wraps. *)
let cont_source_functype tc idx =
  match reference_comptype tc idx with
  | Cont r -> reference_functype tc r
  | _ -> assert false

let get_type_info d ctx (idx : Ast.Text.idx) =
  try
    match idx.desc with
    | Num x -> Some (Hashtbl.find ctx.index_mapping x)
    | Id id -> Some (Hashtbl.find ctx.label_mapping id)
  with Not_found ->
    let lst =
      match idx.desc with
      | Num _ -> []
      | Id id ->
          Wax_utils.Spell_check.f
            (fun f -> Hashtbl.iter (fun id' _ -> f id') ctx.label_mapping)
            id
    in
    Error.unbound_index d ~location:idx.info "type" idx lst;
    None

let resolve_type_index d ctx idx =
  let+@ gidx, _, _ = get_type_info d ctx idx in
  gidx

(* Record that [feature] is used and, if it is not enabled, report it at
   [location]. Validation continues either way (the construct is still typed,
   for error recovery). *)
let require_feature d (ctx : type_context) ~location feature =
  Wax_utils.Feature.mark_used ctx.features feature;
  if not (Wax_utils.Feature.is_enabled ctx.features feature) then
    Error.feature_disabled d ~location feature

let heaptype d ctx (h : Ast.Text.heaptype) : heaptype option =
  match h with
  | Func -> Some Func
  | NoFunc -> Some NoFunc
  | Exn -> Some Exn
  | NoExn -> Some NoExn
  | Cont -> Some Cont
  | NoCont -> Some NoCont
  | Extern -> Some Extern
  | NoExtern -> Some NoExtern
  | Any -> Some Any
  | Eq -> Some Eq
  | I31 -> Some I31
  | Struct -> Some Struct
  | Array -> Some Array
  | None_ -> Some None_
  | Type idx ->
      let+@ ty = resolve_type_index d ctx idx in
      Type ty
  | Exact idx ->
      require_feature d ctx ~location:idx.info
        Wax_utils.Feature.Custom_descriptors;
      let+@ ty = resolve_type_index d ctx idx in
      Exact ty

let reftype d ctx { Ast.Text.nullable; typ } =
  let+@ typ = heaptype d ctx typ in
  { nullable; typ }

let valtype d ctx (ty : Ast.Text.valtype) =
  match ty with
  | I32 -> Some I32
  | I64 -> Some I64
  | F32 -> Some F32
  | F64 -> Some F64
  | V128 -> Some V128
  | Ref r ->
      let+@ ty = reftype d ctx r in
      Ref ty

let array_map_opt f arr =
  let exception Short_circuit in
  try
    let result =
      Array.init (Array.length arr) (fun i ->
          match f arr.(i) with Some v -> v | None -> raise Short_circuit)
    in
    Some result
  with Short_circuit -> None

let array_mapi_opt f arr =
  let exception Short_circuit in
  try
    let result =
      Array.init (Array.length arr) (fun i ->
          match f i arr.(i) with Some v -> v | None -> raise Short_circuit)
    in
    Some result
  with Short_circuit -> None

let functype d ctx { Ast.Text.params; results } =
  let*@ params =
    array_map_opt (fun p -> valtype d ctx (snd p.Ast.desc)) params
  in
  let+@ results = array_map_opt (fun ty -> valtype d ctx ty) results in
  { params; results }

let storagetype d ctx (ty : Ast.Text.storagetype) =
  match ty with
  | Value ty ->
      let+@ ty = valtype d ctx ty in
      Value ty
  | Packed ty -> Some (Packed ty)

let muttype f d ctx { mut; typ } =
  let+@ typ = f d ctx typ in
  { mut; typ }

let fieldtype d ctx ty = muttype storagetype d ctx ty

let tabletype d ctx ({ limits; reftype = typ } : Ast.Text.tabletype) =
  let+@ reftype = reftype d ctx typ in
  { Ast.Binary.limits = limits.desc; reftype }

let globaltype d ctx ty = muttype valtype d ctx ty

let comptype d ctx (ty : Ast.Text.comptype) =
  match ty with
  | Func ty ->
      let+@ ty = functype d ctx ty in
      Func ty
  | Struct fields ->
      let+@ fields =
        array_map_opt (fun e -> fieldtype d ctx (snd e.Ast.desc)) fields
      in
      Struct fields
  | Array field ->
      let+@ field = fieldtype d ctx field in
      Array field
  | Cont idx ->
      let+@ ty = resolve_type_index d ctx idx in
      Cont ty

let subtype d ctx current
    { Ast.Text.typ; supertype; final; descriptor; describes } =
  let*@ typ = comptype d ctx typ in
  let*@ supertype =
    match supertype with
    | None -> Some None
    | Some idx ->
        let+@ i = resolve_type_index d ctx idx in
        (if i <= lnot current then
           let lst =
             match idx.desc with
             | Num _ -> []
             | Id id ->
                 Wax_utils.Spell_check.f
                   (fun f ->
                     Hashtbl.iter
                       (fun id' (i, _, _) -> if i > lnot current then f id')
                       ctx.label_mapping)
                   id
           in
           Error.unbound_index d ~location:idx.info "type" idx lst);
        Some i
  in
  let resolve_opt = function
    | None -> Some None
    | Some (idx : Ast.Text.idx) ->
        require_feature d ctx ~location:idx.info
          Wax_utils.Feature.Custom_descriptors;
        let+@ i = resolve_type_index d ctx idx in
        Some i
  in
  let*@ descriptor = resolve_opt descriptor in
  let+@ describes = resolve_opt describes in
  { typ; supertype; final; descriptor; describes }

let rectype d ctx ty =
  array_mapi_opt (fun i e -> subtype d ctx i (snd e.Ast.desc)) ty

let typeuse d ctx (idx, sign) =
  match (idx, sign) with
  | Some idx, _ -> (
      (* A typeuse always denotes a function type, so reject a reference to a
         struct/array type with a clean error rather than letting the later
         [typeuse_functype]/[reference_functype] assert. *)
      let*@ ty = resolve_type_index d ctx idx in
      match reference_comptype ctx idx with
      | Func _ -> Some ty
      | _ ->
          Error.expected_func_type d ~location:idx.info idx;
          None)
  | _, Some sign ->
      let+@ ty = functype d ctx sign in
      Types.add_rectype ctx.types
        [|
          {
            typ = Func ty;
            supertype = None;
            final = true;
            descriptor = None;
            describes = None;
          };
        |]
  | None, None -> assert false (* Should not happen *)

(* Intern the internal representation type of Wax strings — a mutable array of
   [i8] — and return its global index. *)
let string_type ctx =
  Types.add_rectype ctx.types
    [|
      {
        typ = Array { mut = true; typ = Packed I8 };
        supertype = None;
        final = true;
        descriptor = None;
        describes = None;
      };
    |]

(*** The module context ***)

type module_context = {
  diagnostics : Wax_utils.Diagnostic.context;
  types : type_context;
  subtyping_info : Types.subtyping_info;
  (* Each function carries its type's global index, the source type index it was
     declared with (when it names one, for a [ref.func]'s rendering), and its
     source signature (from its declaration, or its referenced type) — so a call
     names argument and result types from the function's own declaration rather
     than a shared (deduplicated) type index that another structurally-equal type
     may own. *)
  (* Per function: interned type, source type index (if named), signature, and
     whether [ref.func] on it yields an *exact* reference (true for a defined
     function or an exact import, false for a plain import). *)
  functions : (int * Ast.Text.idx option * Ast.Text.functype * bool) Sequence.t;
  memories : limits Sequence.t;
  tables : (Ast.Binary.tabletype * source_type) Sequence.t;
  globals : (globaltype * source_type) Sequence.t;
  (* Each tag carries its type's global index and its source signature, to name
     a thrown payload's types. *)
  tags : (int * Ast.Text.functype) Sequence.t;
  data : unit Sequence.t;
  (* Each element segment carries its interned reference type and the source
     reference type from its declaration, to name a mismatched element type. *)
  elem : (reftype * source_type) Sequence.t;
  exports : (string, unit) Hashtbl.t;
  refs : (int, unit) Hashtbl.t;
}

module IntSet = Set.Make (Int)

type ctx = {
  (* Each local carries the interned type and the source type for error
     messages (reconstructed from the interned type if no source is known). *)
  locals : (valtype * source_type) Sequence.t;
  (* Each entry is a branch target: its optional label, the interned types a
     branch carries to it, and their source types for error messages. *)
  control_types : (string option * valtype array * source_type array) list;
  return_types : valtype array;
  return_source : source_type array;
  modul : module_context;
  mutable initialized_locals : IntSet.t;
  (* Indices of locals read by a [local.get]. A local that is never read is
     reported as unused once the function body has been validated. A [ref]
     (rather than a snapshot field like [initialized_locals]) so a read inside a
     block propagates up to the function level. *)
  used_locals : IntSet.t ref;
}

let lookup_func_type ctx idx =
  let ctx = ctx.modul in
  let*@ ty = resolve_type_index ctx.diagnostics ctx.types idx in
  let def = Types.get_subtype ctx.subtyping_info ty in
  match def.typ with
  | Func f -> Some (ty, f)
  | _ ->
      Error.expected_func_type ctx.diagnostics ~location:idx.info idx;
      None

let lookup_struct_type ctx idx =
  let ctx = ctx.modul in
  let*@ ty, field_map, _ = get_type_info ctx.diagnostics ctx.types idx in
  let def = Types.get_subtype ctx.subtyping_info ty in
  match def.typ with
  | Struct fields -> Some (ty, field_map, fields)
  | _ ->
      Error.expected_struct_type ctx.diagnostics ~location:idx.info idx;
      None

let struct_field_index ctx idx' field_map fields =
  match idx'.Ast.desc with
  | Ast.Text.Id id -> (
      match List.assoc_opt id field_map with
      | Some n -> Some n
      | None ->
          Error.unknown_field ctx.modul.diagnostics ~location:idx'.Ast.info;
          None)
  | Ast.Text.Num n ->
      let n = Uint32.to_int n in
      if n < Array.length fields then Some n
      else (
        Error.field_index_out_of_bounds ctx.modul.diagnostics
          ~location:idx'.Ast.info ~index:n ~count:(Array.length fields);
        None)

let lookup_array_type ctx idx =
  let ctx = ctx.modul in
  let*@ ty = resolve_type_index ctx.diagnostics ctx.types idx in
  let def = Types.get_subtype ctx.subtyping_info ty in
  match def.typ with
  | Array field -> Some (ty, field)
  | _ ->
      Error.expected_array_type ctx.diagnostics ~location:idx.info idx;
      None

(* The descriptor type of the type at global index [ty], for the descriptor
   instructions ([struct.new_desc], [ref.get_desc], …). Reports an error and
   returns [None] when the type carries no [descriptor] clause. *)
let type_descriptor ctx ~location ty =
  match (Types.get_subtype ctx.modul.subtyping_info ty).descriptor with
  | Some desc -> Some desc
  | None ->
      Error.type_without_descriptor ctx.modul.diagnostics ~location;
      None

(* The heap type of the descriptor operand expected by a [_desc_eq] cast/branch
   whose target heap type is [target] (either [Exact x] or [Type x]). The
   operand's exactness matches the target's ([exact_1] in the spec); [y] is [x]'s
   descriptor. *)
let descriptor_operand_type ctx ~location (target : heaptype) =
  match target with
  | Exact x ->
      let+@ d = type_descriptor ctx ~location x in
      Exact d
  | Type x ->
      let+@ d = type_descriptor ctx ~location x in
      Type d
  | _ ->
      Error.invalid_cast_type ctx.modul.diagnostics ~location;
      None

(* The parameter types of an exception [tag] and, when known, their source
   types for naming a thrown payload. *)
let lookup_tag_type ctx tag =
  let ctx = ctx.modul in
  let*@ ty, sign = Sequence.get ctx.diagnostics ctx.tags tag in
  match (Types.get_subtype ctx.subtyping_info ty).typ with
  | Struct _ | Array _ | Cont _ ->
      Error.not_function_type ctx.diagnostics ~location:tag.info;
      None
  | Func { params; results } ->
      if results <> [||] then
        Error.exception_tag_with_results ctx.diagnostics ~location:tag.info;
      Some (params, Array.map (fun p -> Plain (snd p.Ast.desc)) sign.params)

(* Full function type of a tag, used for stack-switching suspension tags whose
   results may be non-empty (unlike exception tags). *)
let lookup_tag_signature ctx tag =
  let ctx = ctx.modul in
  let*@ ty, sign = Sequence.get ctx.diagnostics ctx.tags tag in
  match (Types.get_subtype ctx.subtyping_info ty).typ with
  | Func ft -> Some (ft, sign)
  | Struct _ | Array _ | Cont _ ->
      Error.not_function_type ctx.diagnostics ~location:tag.info;
      None

(* Resolve a continuation type index to its own index and the function type it
   wraps. Emits an error if the type is not a continuation type. *)
let lookup_cont_type ctx idx =
  let mctx = ctx.modul in
  let*@ ty = resolve_type_index mctx.diagnostics mctx.types idx in
  match (Types.get_subtype mctx.subtyping_info ty).typ with
  | Cont ft -> (
      match (Types.get_subtype mctx.subtyping_info ft).typ with
      | Func f -> Some (ty, ft, f)
      | Struct _ | Array _ | Cont _ ->
          Error.expected_cont_type mctx.diagnostics ~location:idx.info idx;
          None)
  | Struct _ | Array _ | Func _ ->
      Error.expected_cont_type mctx.diagnostics ~location:idx.info idx;
      None

(* The continuation type referenced by a heap type, if any. *)
let cont_functype_of_heaptype ctx (h : heaptype) =
  match h with
  | Type ty -> (
      match (Types.get_subtype ctx.modul.subtyping_info ty).typ with
      | Cont ft -> (
          match (Types.get_subtype ctx.modul.subtyping_info ft).typ with
          | Func f -> Some f
          | Struct _ | Array _ | Cont _ -> None)
      | Func _ | Struct _ | Array _ -> None)
  | _ -> None

(* [functype_matches info ft ft'] holds when [ft] is a subtype of [ft']:
   parameters are contravariant and results covariant. *)
let functype_matches info (ft : functype) (ft' : functype) =
  Array.length ft.params = Array.length ft'.params
  && Array.length ft.results = Array.length ft'.results
  && Array.for_all Fun.id
       (Array.mapi
          (fun i p -> Types.val_subtype info ft'.params.(i) p)
          ft.params)
  && Array.for_all Fun.id
       (Array.mapi
          (fun i r -> Types.val_subtype info r ft'.results.(i))
          ft.results)

(* [result_subtype info ts ts'] holds when result type [ts] matches [ts']
   (same length, covariant element by element). *)
let result_subtype info (ts : valtype array) (ts' : valtype array) =
  Array.length ts = Array.length ts'
  && Array.for_all Fun.id
       (Array.mapi (fun i t -> Types.val_subtype info t ts'.(i)) ts)

(* Source type of struct field [n] of the type that reference [idx] names, when
   the field has a (non-packed) value type. Packed fields surface as i32, so
   they get no name. Resolving through the reference (not the deduplicated
   global index) names the field as written at this very type. *)
let source_field_valtype ctx idx n : source_type =
  match reference_comptype ctx.modul.types idx with
  | Struct fields -> (
      let _, (ft : Ast.Text.fieldtype) = fields.(n).Ast.desc in
      match ft.typ with Value v -> Plain v | Packed _ -> Plain I32)
  | _ -> assert false

(* Source type of the element of the array type that reference [idx] names. *)
let source_element_valtype ctx idx : source_type =
  match reference_comptype ctx.modul.types idx with
  | Array (ft : Ast.Text.fieldtype) -> (
      match ft.typ with Value v -> Plain v | Packed _ -> Plain I32)
  | _ -> assert false

(*** The validation stack ***)

(* A stack entry is one of the two bottoms of the validation type lattice or a
   concrete value. [Bot] is the unknown value of a polymorphic (unreachable)
   stack: a subtype of every type. [Bot_ref] is the bottom reference type
   [(ref bot)], produced when a reference-eliminating instruction consumes a
   [Bot]: it is a subtype of every reference type but of no numeric or vector
   type, which is what lets [ref.as_non_null] / [br_on_null] reject a numeric
   use of their result on an otherwise polymorphic stack. [Val] pairs the
   interned type used for subtype checking with the source type the value was
   written as, mirroring the Wax side's [inferred_valtype]; the source type is
   always present, a push that does not supply one reconstructing it from the
   interned type (naming an indexed type by its canonical index). *)
type stack_entry = Bot | Bot_ref | Val of valtype * source_type

type stack =
  | Unreachable
  | Empty
  | Cons of Ast.location option * stack_entry * stack

(* Returns the popped entry, along with its push location. A pop from an
   unreachable or empty stack yields the unknown value [Bot]. *)
let pop_any ctx loc st =
  match st with
  | Unreachable -> (Unreachable, (Bot, None))
  | Cons (loc, ty, r) -> (r, (ty, loc))
  | Empty ->
      Error.empty_stack ctx.modul.diagnostics ~location:loc;
      (st, (Bot, None))

(* The non-null version of a popped reference's source type, for an instruction
   that re-pushes the value with the null case removed. *)
let non_null_source (source : source_type) : source_type =
  match source with
  | Plain (Ref r) -> Plain (Ref { r with nullable = false })
  | Inline_ref _ as source -> source
  | _ -> assert false

let pop ctx loc ~expected_source ty st =
  let mismatch location source =
    match location with
    | Some location ->
        Error.instruction_type_mismatch ctx.modul.diagnostics ~location
          ~consumer:(Some loc) ~provided_source:source ~expected_source
    | None ->
        Error.type_mismatch ctx.modul.diagnostics ~location:loc
          ~provided_source:source ~expected_source
  in
  match st with
  | Unreachable -> (Unreachable, ())
  | Cons (_, Bot, r) -> (r, ())
  | Cons (location, Bot_ref, r) ->
      (* [(ref bot)] is a subtype of every reference type but of no numeric or
         vector type. *)
      (match ty with Ref _ -> () | _ -> mismatch location Bottom_ref);
      (r, ())
  | Cons (location, Val (ty', source), r) ->
      let ok = Types.val_subtype ctx.modul.subtyping_info ty' ty in
      if not ok then mismatch location source;
      (r, ())
  | Empty ->
      Error.empty_stack ctx.modul.diagnostics ~location:loc;
      (Unreachable, ())

(* Pop a value whose expected type has no user-written source form — a builtin,
   address, or abstract reference type — so its rendering is reconstructed. *)
let pop_known ctx loc ty =
  pop ctx loc ~expected_source:(source_of_valtype ty) ty

let push_poly loc st = (Cons (Some loc, Bot, st), ())
let push_bot_ref loc st = (Cons (loc, Bot_ref, st), ())
let push ~source loc ty st = (Cons (loc, Val (ty, source), st), ())

(* Push a value whose type has no user-written source form, reconstructing its
   rendering from the type. *)
let push_known loc ty = push ~source:(source_of_valtype ty) loc ty

(* The source rendering of a reference to the named type [idx], used as the
   [source] form of a value an instruction pushes ([named_ref_source], non-null) or
   expects ([named_ref_null_source], the nullable form pop accepts). *)
let named_ref_source idx : source_type =
  Plain (Ref { nullable = false; typ = Type idx })

let named_ref_null_source idx : source_type =
  Plain (Ref { nullable = true; typ = Type idx })

(* The source rendering of the descriptor of the type at global index
   [described] — the [_desc_eq] cast/branch operand (nullable), or the
   [ref.get_desc] result (non-null, via [~nullable:false]). The descriptor type
   has no immediate to name it by, so its source name is recovered from
   [descriptor_source] (recorded at its definition); [exact] matches [described]'s
   own exactness. *)
let descriptor_operand_source ?(nullable = true) tc (described : heaptype) :
    source_type =
  let build exact x =
    match Hashtbl.find_opt tc.descriptor_source x with
    | Some node ->
        Plain
          (Ref { nullable; typ = (if exact then Exact node else Type node) })
    | None ->
        (* No recorded source (a well-formed descriptor type always has one);
           fall back to the abstract struct supertype rather than a misleading
           index. *)
        Plain (Ref { nullable; typ = source_of_heaptype Struct })
  in
  match described with
  | Exact x -> build true x
  | Type x -> build false x
  | _ -> Plain (Ref { nullable; typ = source_of_heaptype Struct })

(* Source-type array for popping the prefix arguments [param_source] followed by a
   continuation operand of the type named by [x]. *)
let cont_operand_source param_source x =
  Array.append param_source [| named_ref_null_source x |]

(* Source params of the function type the continuation type [x] wraps; they are
   exactly that function type's parameters. *)
let cont_param_source ctx x =
  Array.map
    (fun p -> Plain (snd p.Ast.desc))
    (cont_source_functype ctx.modul.types x).params

let unreachable _ = (Unreachable, ())
let return v st = (st, v)

(* These operators thread the value stack through validation. [let*] sequences
   two stack transformers, passing the stack from one to the next. [let*!] and
   [let*?] guard a transformer on an [option] (typically a failed lookup that
   has already reported an error): on [None] they abandon this instruction's
   effect, [let*!] yielding the [unreachable] transformer and [let*?] yielding
   no stack effect at all (for checks run outside a transformer). *)
let ( let* ) e f st =
  let st, v = e st in
  f v st

let ( let*! ) e f = match e with Some v -> f v | None -> unreachable
let ( let*? ) e f = match e with Some v -> f v | None -> ()

let get_local ctx ?(initialize = false) i =
  let+@ l = Sequence.get ctx.modul.diagnostics ctx.locals i in
  let idx = Sequence.get_index ctx.locals i in
  if initialize then
    ctx.initialized_locals <- IntSet.add idx ctx.initialized_locals
  else begin
    ctx.used_locals := IntSet.add idx !(ctx.used_locals);
    if not (IntSet.mem idx ctx.initialized_locals) then
      Error.uninitialized_local ctx.modul.diagnostics ~location:i.info i
  end;
  l

(* The result nullability of [extern.convert_any] / [any.convert_extern], which
   propagate the operand's nullability. The operand must be a reference in the
   [typ] hierarchy: a bottom reference satisfies it as known non-null, a
   fully-unknown [Bot] is treated as nullable, and a non-reference operand (a
   reported error) is treated as nullable rather than crashing. *)
let convert_operand_nullable ctx loc entry ~typ =
  match entry with
  | Bot -> true
  | Bot_ref -> false
  | Val (ty, source) -> (
      let expected = Ref { nullable = true; typ } in
      if not (Types.val_subtype ctx.modul.subtyping_info ty expected) then
        Error.type_mismatch ctx.modul.diagnostics ~location:loc
          ~provided_source:source
          ~expected_source:(source_of_valtype expected);
      match ty with Ref { nullable; _ } -> nullable | _ -> true)

let is_defaultable ty =
  match ty with
  | I32 | I64 | F32 | F64 | V128 -> true
  | Ref { nullable; _ } -> nullable

let number_or_vec ty =
  match ty with I32 | I64 | F32 | F64 | V128 -> true | Ref _ -> false

let int_un_op_type ty (op : Ast.Text.int_un_op) =
  match op with
  | Clz | Ctz | Popcnt | ExtendS _ -> (ty, ty)
  | Trunc (sz, _) | TruncSat (sz, _) ->
      ((match sz with `F32 -> F32 | `F64 -> F64), ty)
  | Reinterpret ->
      ( (match ty with
        | I32 -> F32
        | I64 -> F64
        | _ -> assert false (* Should not happen *)),
        ty )
  | Eqz -> (ty, I32)

let int_bin_op_type ty (op : Ast.Text.int_bin_op) =
  match op with
  | Add | Sub | Mul | Div _ | Rem _ | And | Or | Xor | Shl | Shr _ | Rotl | Rotr
    ->
      ty
  | Eq | Ne | Lt _ | Gt _ | Le _ | Ge _ -> I32

let float_un_op_type ty (op : Ast.Text.float_un_op) =
  match op with
  | Neg | Abs | Ceil | Floor | Trunc | Nearest | Sqrt -> ty
  | Convert (sz, _) -> ( match sz with `I32 -> I32 | `I64 -> I64)
  | Reinterpret -> (
      match ty with
      | F32 -> I32
      | F64 -> I64
      | _ -> assert false (* Should not happen *))

let float_bin_op_type ty (op : Ast.Text.float_bin_op) =
  match op with
  | Add | Sub | Mul | Div | Min | Max | CopySign -> ty
  | Eq | Ne | Lt | Gt | Le | Ge -> I32

(* Returns the interned block parameter and result types, plus their per-element
   source types (for [pop_args]/[push_results]'s [~source]). *)
let blocktype ctx (ty : Ast.Text.blocktype option) =
  match ty with
  | None -> Some ([||], [||], [||], [||])
  | Some (Typeuse (_, Some ({ params; results } as ft))) ->
      let*@ iparams =
        array_map_opt
          (fun p ->
            valtype ctx.modul.diagnostics ctx.modul.types (snd p.Ast.desc))
          params
      in
      let+@ iresults =
        array_map_opt (valtype ctx.modul.diagnostics ctx.modul.types) results
      in
      let param_source, result_source = functype_sources ft in
      (iparams, iresults, param_source, result_source)
  | Some (Typeuse (Some idx, None)) ->
      let+@ _, { params; results } = lookup_func_type ctx idx in
      let param_source, result_source =
        functype_sources (reference_functype ctx.modul.types idx)
      in
      (params, results, param_source, result_source)
  | Some (Typeuse (None, None)) -> assert false (* Should not happen *)
  | Some (Valtype ty) ->
      let+@ t = valtype ctx.modul.diagnostics ctx.modul.types ty in
      ([||], [| t |], [||], [| Plain ty |])

let pop_args ctx loc ~source args =
  let rec loop i =
    if i < 0 then return ()
    else
      let* () = pop ctx loc ~expected_source:source.(i) args.(i) in
      loop (i - 1)
  in
  loop (Array.length args - 1)

let push_results ~source results =
  let rec loop i =
    if i >= Array.length results then return ()
    else
      let* () = push ~source:source.(i) None results.(i) in
      loop (i + 1)
  in
  loop 0

let rec output_stack ~full f st =
  match st with
  | Empty -> ()
  | Unreachable -> if full then Format.fprintf f "@ unreachable"
  | Cons (_, ty, st) ->
      (match ty with
      | Val (_, source) -> Format.fprintf f "@ %a" print_source_type source
      | Bot -> Format.fprintf f "@ bot"
      | Bot_ref -> Format.fprintf f "@ (ref bot)");
      output_stack ~full f st

let print_stack st =
  Format.eprintf "@[<2>Stack:%a@]@." (output_stack ~full:true) st;
  (st, ())

let _ = print_stack

let with_empty_stack ctx location f =
  let st, () = f Empty in
  (* The source locations of the values still on the stack, topmost first.
     Values without a usable location (a block parameter/result, or an
     error-recovery placeholder) are dropped. *)
  let rec locations = function
    | Cons (Some loc, _, st) when loc.Ast.loc_start.Lexing.pos_cnum >= 0 ->
        loc :: locations st
    | Cons (_, _, st) -> locations st
    | Empty | Unreachable -> []
  in
  match st with
  | Empty | Unreachable -> ()
  | Cons _ -> (
      match locations st with
      | location :: rest ->
          (* Point a caret right at each leftover value rather than at the
             (potentially large) enclosing construct. *)
          let related =
            List.map
              (fun location ->
                { Wax_utils.Diagnostic.location; message = (fun _ () -> ()) })
              rest
          in
          Error.leftover_values ctx.diagnostics ~location ~related
      | [] ->
          (* No value carries a usable location: point at the construct and
             list the values that remain, since the location alone does not
             show them. *)
          Error.non_empty_stack ctx.diagnostics ~location (fun f () ->
              Format.fprintf f "@[%a@]" (output_stack ~full:false) st))

(*** Instruction-checking helpers ***)

(* Check that a list of [provided] argument types matches a list of [expected]
   parameter types: same length, and each argument a subtype of the
   corresponding parameter. [descr] names the construct supplying the
   arguments. Reporting the two lists directly gives a far clearer message than
   simulating the comparison on the value stack. *)
let compare_types ctx ~location ~descr ~provided_source ~expected_source
    ~provided ~expected () =
  if Array.length provided <> Array.length expected then
    Error.argument_count_mismatch ctx.diagnostics ~location ~descr
      ~provided_source ~expected_source
  else
    Array.iteri
      (fun i p ->
        let e = expected.(i) in
        if not (Types.val_subtype ctx.subtyping_info p e) then
          Error.argument_type_mismatch ctx.diagnostics ~location ~descr
            ~provided_source:provided_source.(i)
            ~expected_source:expected_source.(i))
      provided

let branch_target ctx (idx : Ast.Text.idx) =
  match idx.desc with
  | Num i -> (
      try
        let _, params, source = List.nth ctx.control_types (Uint32.to_int i) in
        Some (params, source)
      with Failure _ ->
        Error.unbound_label ctx.modul.diagnostics ~location:idx.Ast.info idx [];
        None)
  | Id id ->
      let rec find l id =
        match l with
        | [] ->
            let lst =
              Wax_utils.Spell_check.f
                (fun f ->
                  List.iter
                    (fun (id_opt, _, _) ->
                      match id_opt with Some id -> f id | None -> ())
                    ctx.control_types)
                id
            in
            Error.unbound_label ctx.modul.diagnostics ~location:idx.Ast.info idx
              lst;
            None
        | (Some id', params, source) :: _ when id = id' -> Some (params, source)
        | _ :: rem -> find rem id
      in
      find ctx.control_types id

(* The top of the heap-type hierarchy that [t] belongs to (one of [any], [func],
   [exn], [cont], [extern]). A cast or test pops a reference to this top type —
   the most general operand the instruction accepts — before checking against
   the precise target. *)
let top_heap_type ctx (t : heaptype) : heaptype =
  match t with
  | Any | Eq | I31 | Struct | Array | None_ -> Any
  | Func | NoFunc -> Func
  | Exn | NoExn -> Exn
  | Cont | NoCont -> Cont
  | Extern | NoExtern -> Extern
  | Type ty | Exact ty -> (
      match (Types.get_subtype ctx.modul.subtyping_info ty).typ with
      | Struct _ | Array _ -> Any
      | Func _ -> Func
      | Cont _ -> Cont)

let storage_subtype info ty ty' =
  match (ty, ty') with
  | Packed I8, Packed I8 | Packed I16, Packed I16 -> true
  | Value ty, Value ty' -> Types.val_subtype info ty ty'
  | Packed I8, Packed I16
  | Packed I16, Packed I8
  | Packed _, Value _
  | Value _, Packed _ ->
      false

let field_subtype info (ty : fieldtype) (ty' : fieldtype) =
  ty.mut = ty'.mut
  && storage_subtype info ty.typ ty'.typ
  && ((not ty.mut) || storage_subtype info ty'.typ ty.typ)

(* The reference type difference [t1 \ t2] from the spec: [t1]'s heap type, made
   non-nullable once a nullable [t2] has consumed the null case. This is the type
   that falls through a [br_on_cast] (or is sent on by [br_on_cast_fail]); the
   inline [src_diff] in those arms is the same operation on source types. *)
let diff_ref_type t1 t2 =
  { nullable = t1.nullable && not t2.nullable; typ = t1.typ }

(* Whether a branching cast from [ty1] to [ty2] is well-typed. The
   custom-descriptors proposal relaxes the pre-existing [rt2 <: rt1] to only
   requiring that [rt1] and [rt2] share a supertype — i.e. lie in the same heap
   type hierarchy — so under that feature we compare the hierarchy tops. *)
let br_cast_compatible ctx (ty1 : reftype) (ty2 : reftype) =
  if
    Wax_utils.Feature.is_enabled ctx.modul.types.features
      Wax_utils.Feature.Custom_descriptors
  then top_heap_type ctx ty1.typ = top_heap_type ctx ty2.typ
  else Types.val_subtype ctx.modul.subtyping_info (Ref ty2) (Ref ty1)

(* The target of a branching cast ([br_on_cast] and its variants) always carries
   at least the matched reference to the label, so a zero-result label cannot
   receive it. [branch_target] alone accepts it — with a polymorphic operand the
   per-value [pop_args] check below is vacuous — so reject an empty label here. *)
let branch_cast_target ctx (idx : Ast.Text.idx) ~location =
  match branch_target ctx idx with
  | None -> None
  | Some (params, source) ->
      if Array.length params = 0 then (
        Error.br_cast_type_mismatch ctx.modul.diagnostics ~location;
        None)
      else Some (params, source)

(* Run [f] on the current stack and return its result as the monad value while
   leaving the stack untouched — a peek. [Br_table] uses it to validate every
   branch target against the same incoming stack. *)
let with_current_stack f st = (st, f st)

let unpack_type (f : fieldtype) =
  match f.typ with Value v -> v | Packed _ -> I32

(* Pop [n] values of type [ty] (as [array.new_fixed] does), in time proportional
   to the operands actually present, not to [n]. Once the stack is [Unreachable]
   -- the polymorphic base, or a reachable underflow after the first empty pop
   turns it into one -- every remaining pop trivially succeeds, so stop. This
   keeps a huge immediate count (e.g. [array.new_fixed 2^31]) from making
   validation O(n). *)
let rec pop_repeat ctx loc ~expected_source ty n st =
  if n <= 0 then (st, ())
  else
    match st with
    | Unreachable -> (Unreachable, ())
    | _ ->
        let st, () = pop ctx loc ~expected_source ty st in
        pop_repeat ctx loc ~expected_source ty (n - 1) st

let address_type_to_valtype = function `I32 -> I32 | `I64 -> I64

(* Constants for max offsets *)

let max_offset_i32_exclusive = Uint64.of_string "0x1_0000_0000" (* 2^32 *)
let max_align = Uint64.of_int 16

let check_memarg ctx location limits sz { Ast.Text.offset; align } =
  if limits.address_type = `I32 then
    if Uint64.compare offset max_offset_i32_exclusive >= 0 then
      Error.memory_offset_too_large ctx.modul.diagnostics ~location
        max_offset_i32_exclusive;
  let natural_alignment =
    match sz with
    | `I8 -> 1
    | `I16 -> 2
    | `I32 | `F32 -> 4
    | `I64 | `F64 -> 8
    | `V128 -> 16
  in
  if
    Uint64.compare align max_align > 0
    || Uint64.to_int align > natural_alignment
  then
    Error.memory_align_too_large ctx.modul.diagnostics ~location
      natural_alignment
  else
    match Uint64.to_int align with
    | 1 | 2 | 4 | 8 | 16 -> ()
    | _ -> Error.bad_memory_align ctx.modul.diagnostics ~location

(* An atomic access requires exactly its natural alignment, not merely at most. *)
let check_atomic_memarg ctx location limits op { Ast.Text.offset; align } =
  if
    limits.address_type = `I32
    && Uint64.compare offset max_offset_i32_exclusive >= 0
  then
    Error.memory_offset_too_large ctx.modul.diagnostics ~location
      max_offset_i32_exclusive;
  let natural = 1 lsl Atomics.natural_align_log2 op in
  if Uint64.compare align (Uint64.of_int natural) <> 0 then
    Error.atomic_alignment ctx.modul.diagnostics ~location natural

let memory_instruction_type_and_size ty =
  match (ty : Ast.Text.num_type) with
  | NumI32 -> (I32, `I32)
  | NumF32 -> (F32, `I32)
  | NumI64 -> (I64, `I64)
  | NumF64 -> (F64, `I64)

let field_has_default (ty : fieldtype) =
  match ty.typ with
  | Packed _ -> true
  | Value ty -> (
      match ty with
      | I32 | I64 | F32 | F64 | V128 -> true
      | Ref { nullable; _ } -> nullable)

let shape_type (shape : Ast.vec_shape) =
  match shape with
  | I8x16 | I16x8 | I32x4 -> I32
  | I64x2 -> I64
  | F32x4 -> F32
  | F64x2 -> F64

let check_shape_lanes ctx location (shape : Ast.vec_shape) lane =
  let max_lane =
    match shape with
    | I8x16 -> 16
    | I16x8 -> 8
    | I32x4 | F32x4 -> 4
    | I64x2 | F64x2 -> 2
  in
  if lane >= max_lane then
    Error.invalid_lane_index ctx.modul.diagnostics ~location max_lane

(* Validate the handler clauses of a [resume]/[resume_throw] instruction. [ts2]
   is the result type of the resumed continuation. *)
let check_resume_table ctx loc ts2 clauses =
  let info = ctx.modul.subtyping_info in
  List.iter
    (fun (clause : Ast.Text.on_clause) ->
      match clause with
      | OnLabel (tag, label) -> (
          match lookup_tag_signature ctx tag with
          | None -> ()
          | Some ({ params = ts3; results = ts4 }, _) -> (
              match branch_target ctx label with
              | None -> ()
              | Some (ts', _) ->
                  let n = Array.length ts' in
                  let mismatch () =
                    Error.stack_switching_type_mismatch ctx.modul.diagnostics
                      ~location:label.info
                      ~descr:
                        "this handler must take the tag's parameters followed \
                         by a continuation of the remaining result type"
                  in
                  (* The handler label receives the tag's parameters followed by
                     a continuation of type [cont (ts4 -> ts2)]. *)
                  if n <> Array.length ts3 + 1 then mismatch ()
                  else begin
                    Array.iteri
                      (fun i t ->
                        if not (Types.val_subtype info t ts'.(i)) then
                          mismatch ())
                      ts3;
                    match ts'.(n - 1) with
                    | Ref { typ = ht; _ } -> (
                        match cont_functype_of_heaptype ctx ht with
                        | Some ft' ->
                            if
                              not
                                (functype_matches info
                                   { params = ts4; results = ts2 }
                                   ft')
                            then mismatch ()
                        | None -> mismatch ())
                    | _ -> mismatch ()
                  end))
      | OnSwitch tag -> (
          match lookup_tag_signature ctx tag with
          | None -> ()
          | Some ({ params = ts3; _ }, _) ->
              if Array.length ts3 <> 0 then
                Error.stack_switching_type_mismatch ctx.modul.diagnostics
                  ~location:loc
                  ~descr:"the tag of a 'switch' handler must take no parameters"
          ))
    clauses

(* Look up an entry in a module-level index space, reporting an unbound-index
   error (via {!Sequence.get}) when the reference does not resolve. *)
let get_memory ctx = Sequence.get ctx.modul.diagnostics ctx.modul.memories
let get_table ctx = Sequence.get ctx.modul.diagnostics ctx.modul.tables
let get_global ctx = Sequence.get ctx.modul.diagnostics ctx.modul.globals
let get_function ctx = Sequence.get ctx.modul.diagnostics ctx.modul.functions
let get_data ctx = Sequence.get ctx.modul.diagnostics ctx.modul.data
let get_elem ctx = Sequence.get ctx.modul.diagnostics ctx.modul.elem

(* Pop a memory/table address operand, whose width follows the address type. *)
let pop_address ctx loc limits =
  pop_known ctx loc (address_type_to_valtype limits.address_type)

(*** The instruction validator ***)

let rec instruction ctx (i : _ Ast.Text.instr) =
  if false then Format.eprintf "%a@." print_instr i;
  let loc = i.info in
  match i.desc with
  | Block { label; typ; block = b } ->
      let*! params, results, param_source, result_source = blocktype ctx typ in
      let* () = pop_args ctx loc ~source:param_source params in
      block ctx loc label ~param_source ~result_source ~br_source:result_source
        ~params ~results ~br_params:results b;
      push_results ~source:result_source results
  | Loop { label; typ; block = b } ->
      let*! params, results, param_source, result_source = blocktype ctx typ in
      let* () = pop_args ctx loc ~source:param_source params in
      block ctx loc label ~param_source ~result_source ~br_source:param_source
        ~params ~results ~br_params:params b;
      push_results ~source:result_source results
  | If { label; typ; if_block; else_block } ->
      let*! params, results, param_source, result_source = blocktype ctx typ in
      let* () = pop_known ctx loc I32 in
      let* () = pop_args ctx loc ~source:param_source params in
      block ctx loc label ~param_source ~result_source ~br_source:result_source
        ~params ~results ~br_params:results if_block.desc;
      block ctx loc label ~param_source ~result_source ~br_source:result_source
        ~params ~results ~br_params:results else_block.desc;
      push_results ~source:result_source results
  | TryTable { label; typ; block = b; catches } ->
      let*! params, results, param_source, result_source = blocktype ctx typ in
      let* () = pop_args ctx loc ~source:param_source params in
      block ctx loc label ~param_source ~result_source ~br_source:result_source
        ~params ~results ~br_params:results b;
      List.iter
        (fun (catch : Ast.Text.catch) ->
          match catch with
          | Catch (tag, label) ->
              let*? args, arg_source = lookup_tag_type ctx tag in
              let*? params, param_source = branch_target ctx label in
              compare_types ctx.modul ~location:loc
                ~descr:"this exception handler" ~provided_source:arg_source
                ~expected_source:param_source ~provided:args ~expected:params ()
          | CatchRef (tag, label) ->
              let*? args, arg_source = lookup_tag_type ctx tag in
              let*? params, param_source = branch_target ctx label in
              let provided =
                Array.append args [| Ref { nullable = false; typ = Exn } |]
              in
              let provided_source =
                Array.append arg_source
                  [| Plain (Ref { nullable = false; typ = Exn }) |]
              in
              compare_types ctx.modul ~location:loc
                ~descr:"this exception handler" ~provided_source
                ~expected_source:param_source ~provided ~expected:params ()
          | CatchAll label ->
              Option.iter
                (fun (params, param_source) ->
                  compare_types ctx.modul ~location:loc
                    ~descr:"this exception handler" ~provided_source:[||]
                    ~expected_source:param_source ~provided:[||]
                    ~expected:params ())
                (branch_target ctx label)
          | CatchAllRef label ->
              Option.iter
                (fun (params, param_source) ->
                  compare_types ctx.modul ~location:loc
                    ~descr:"this exception handler"
                    ~provided_source:
                      [| Plain (Ref { nullable = false; typ = Exn }) |]
                    ~expected_source:param_source
                    ~provided:[| Ref { nullable = false; typ = Exn } |]
                    ~expected:params ())
                (branch_target ctx label))
        catches;
      push_results ~source:result_source results
  | Try { label; typ; block = b; catches; catch_all } ->
      let*! params, results, param_source, result_source = blocktype ctx typ in
      let* () = pop_args ctx loc ~source:param_source params in
      block ctx loc label ~param_source ~result_source ~br_source:result_source
        ~params ~results ~br_params:results b;
      List.iter
        (fun (tag, b) ->
          let*? params', param_source = lookup_tag_type ctx tag in
          block ctx loc label ~param_source ~result_source
            ~br_source:result_source ~params:params' ~results ~br_params:results
            b)
        catches;
      Option.iter
        (fun b ->
          block ctx loc label ~param_source ~result_source
            ~br_source:result_source ~params ~results ~br_params:results b)
        catch_all;
      push_results ~source:result_source results
  | Unreachable -> unreachable
  | Nop -> return ()
  | Throw idx ->
      let*! params, param_source = lookup_tag_type ctx idx in
      let* () = pop_args ctx loc ~source:param_source params in
      unreachable
  | ThrowRef ->
      let* () = pop_known ctx loc (Ref { nullable = true; typ = Exn }) in
      unreachable
  | ContNew x ->
      let*! ty, ft, _ = lookup_cont_type ctx x in
      let func_source =
        match reference_comptype ctx.modul.types x with
        | Cont r -> named_ref_null_source r
        | _ -> assert false
      in
      let* () =
        pop ctx loc ~expected_source:func_source
          (Ref { nullable = true; typ = Type ft })
      in
      push ~source:(named_ref_source x) (Some loc)
        (Ref { nullable = false; typ = Type ty })
  | ContBind (x, y) ->
      let*! xty, _, ftx = lookup_cont_type ctx x in
      let*! yty, _, fty = lookup_cont_type ctx y in
      let n1 = Array.length ftx.params in
      let n1' = Array.length fty.params in
      if n1 < n1' then (
        Error.stack_switching_type_mismatch ctx.modul.diagnostics ~location:loc
          ~descr:
            "the resulting continuation takes more parameters than the \
             original one";
        unreachable)
      else begin
        let ts11 = Array.sub ftx.params 0 (n1 - n1') in
        let ts12 = Array.sub ftx.params (n1 - n1') n1' in
        if
          not
            (functype_matches ctx.modul.subtyping_info
               { params = ts12; results = ftx.results }
               fty)
        then (
          Error.stack_switching_type_mismatch ctx.modul.diagnostics
            ~location:loc
            ~descr:
              "the bound parameters and results do not match between the two \
               continuation types";
          unreachable)
        else begin
          let* () =
            pop_args ctx loc
              ~source:
                (cont_operand_source
                   (Array.sub (cont_param_source ctx x) 0 (n1 - n1'))
                   x)
              (Array.append ts11 [| Ref { nullable = true; typ = Type xty } |])
          in
          push ~source:(named_ref_source y) (Some loc)
            (Ref { nullable = false; typ = Type yty })
        end
      end
  | Suspend x ->
      let*! { params = ts1; results = ts2 }, sign =
        lookup_tag_signature ctx x
      in
      let param_source, result_source = functype_sources sign in
      let* () = pop_args ctx loc ~source:param_source ts1 in
      push_results ~source:result_source ts2
  | Resume (x, clauses) ->
      let*! xty, _, ftx = lookup_cont_type ctx x in
      check_resume_table ctx loc ftx.results clauses;
      let _, result_source =
        functype_sources (cont_source_functype ctx.modul.types x)
      in
      let* () =
        pop_args ctx loc
          ~source:(cont_operand_source (cont_param_source ctx x) x)
          (Array.append ftx.params
             [| Ref { nullable = true; typ = Type xty } |])
      in
      push_results ~source:result_source ftx.results
  | ResumeThrow (x, y, clauses) ->
      let*! xty, _, ftx = lookup_cont_type ctx x in
      let*! { params = ts0; _ }, sign = lookup_tag_signature ctx y in
      check_resume_table ctx loc ftx.results clauses;
      let _, result_source =
        functype_sources (cont_source_functype ctx.modul.types x)
      in
      let* () =
        pop_args ctx loc
          ~source:(cont_operand_source (fst (functype_sources sign)) x)
          (Array.append ts0 [| Ref { nullable = true; typ = Type xty } |])
      in
      push_results ~source:result_source ftx.results
  | ResumeThrowRef (x, clauses) ->
      let*! xty, _, ftx = lookup_cont_type ctx x in
      check_resume_table ctx loc ftx.results clauses;
      let _, result_source =
        functype_sources (cont_source_functype ctx.modul.types x)
      in
      let* () =
        pop_args ctx loc
          ~source:
            [|
              Plain (Ref { nullable = true; typ = Exn });
              named_ref_null_source x;
            |]
          [|
            Ref { nullable = true; typ = Exn };
            Ref { nullable = true; typ = Type xty };
          |]
      in
      push_results ~source:result_source ftx.results
  | Switch (x, y) ->
      let*! xty, _, ftx = lookup_cont_type ctx x in
      let ts11 = ftx.params in
      let n = Array.length ts11 in
      let inner =
        match if n = 0 then None else Some ts11.(n - 1) with
        | Some (Ref { typ = ht; _ }) -> cont_functype_of_heaptype ctx ht
        | _ -> None
      in
      let*! inner_ft =
        match inner with
        | Some _ -> inner
        | None ->
            Error.stack_switching_type_mismatch ctx.modul.diagnostics
              ~location:loc
              ~descr:
                "the continuation's last parameter must itself be a \
                 continuation type";
            None
      in
      let*! { params = ts31; results = t }, _ = lookup_tag_signature ctx y in
      let info = ctx.modul.subtyping_info in
      if
        Array.length ts31 <> 0
        || (not (result_subtype info ftx.results t))
        || not (result_subtype info t inner_ft.results)
      then (
        Error.stack_switching_type_mismatch ctx.modul.diagnostics ~location:loc
          ~descr:
            "the 'switch' tag must take no parameters and its results must \
             match the two continuation types";
        unreachable)
      else begin
        (* The inner continuation is named by [x]'s last parameter, so its
           parameters' source types are that continuation's source params. *)
        let ts21 = inner_ft.params in
        let ts21_text =
          (* [inner] is [Some] only when [x]'s last parameter is a concrete
             continuation reference, so its source form is [(ref $idx)]. *)
          match (cont_param_source ctx x).(n - 1) with
          | Plain (Ref { typ = Type idx; _ }) -> cont_param_source ctx idx
          | _ -> assert false
        in
        let ts11' = Array.sub ts11 0 (n - 1) in
        let ts11'_text = Array.sub (cont_param_source ctx x) 0 (n - 1) in
        let* () =
          pop_args ctx loc
            ~source:(cont_operand_source ts11'_text x)
            (Array.append ts11' [| Ref { nullable = true; typ = Type xty } |])
        in
        push_results ~source:ts21_text ts21
      end
  | Br idx ->
      let*! params, param_source = branch_target ctx idx in
      let* () = pop_args ctx loc ~source:param_source params in
      unreachable
  | Br_if idx ->
      let* () = pop_known ctx loc I32 in
      let*! params, param_source = branch_target ctx idx in
      let* () = pop_args ctx loc ~source:param_source params in
      push_results ~source:param_source params
  (* Branch-hinting proposal: the wrapper is advisory and has the exact stack
     effect of the branch it wraps. *)
  | Hinted (_, inner) -> instruction ctx inner
  | Br_table (lst, idx) ->
      let* () = pop_known ctx loc I32 in
      let*! params, _ = branch_target ctx idx in
      let len = Array.length params in
      let* () =
        with_current_stack (fun st ->
            List.iter
              (fun idx' ->
                let*? params, param_source = branch_target ctx idx' in
                let len' = Array.length params in
                if len <> len' then
                  Error.branch_parameter_count_mismatch ctx.modul.diagnostics
                    ~location:loc idx len idx' len'
                else ignore (pop_args ctx loc ~source:param_source params st))
              (idx :: lst))
      in
      unreachable
  | Br_on_null idx -> (
      let* ty, loc' = pop_any ctx loc in
      (* The branch carries the label's parameters; the value falls through with
         its null case removed ([(ref bot)] when the operand was a bottom). *)
      let fallthrough push_top =
        let*! params, param_source = branch_target ctx idx in
        let* () = pop_args ctx loc ~source:param_source params in
        let* () = push_results ~source:param_source params in
        push_top
      in
      match ty with
      | Bot | Bot_ref -> fallthrough (push_bot_ref (Some loc))
      | Val (Ref { nullable = _; typ }, source) ->
          fallthrough
            (push ~source:(non_null_source source) (Some loc)
               (Ref { nullable = false; typ }))
      | Val (_, source) ->
          Error.expected_ref_type ctx.modul.diagnostics ~location:loc
            ~src_loc:loc' ~source;
          unreachable)
  | Br_on_non_null idx -> (
      let* ty, loc' = pop_any ctx loc in
      (* The branch carries the label's parameters ending in the non-null
         reference ([(ref bot)] for a bottom operand); the value is consumed on
         fall-through. *)
      let to_branch push_ref =
        let* () = push_ref in
        let*! params, param_source = branch_target ctx idx in
        (* [br_on_non_null] requires the target label to be [t* (ref ht)]: the
           pushed non-null reference is consumed by that trailing type. An empty
           label has no such type, so [pop_args] would silently accept it. *)
        if Array.length params = 0 then (
          Error.br_on_non_null_no_ref ctx.modul.diagnostics ~location:loc;
          unreachable)
        else
          let* () = pop_args ctx loc ~source:param_source params in
          let* () = push_results ~source:param_source params in
          let* _ = pop_any ctx loc in
          return ()
      in
      match ty with
      | Bot | Bot_ref -> to_branch (push_bot_ref None)
      | Val (Ref { nullable = _; typ }, source) ->
          to_branch
            (push ~source:(non_null_source source) None
               (Ref { nullable = false; typ }))
      | Val (_, source) ->
          Error.expected_ref_type ctx.modul.diagnostics ~location:loc
            ~src_loc:loc' ~source;
          unreachable)
  | Br_on_cast (idx, ty1, ty2) ->
      let src_ty1 = Plain (Ast.Text.Ref ty1)
      and src_ty2 = Plain (Ast.Text.Ref ty2) in
      (* The value that falls through has [ty1]'s heap type, non-null once a
         nullable [ty2] has consumed the null case. *)
      let src_diff =
        Plain
          (Ast.Text.Ref
             { nullable = ty1.nullable && not ty2.nullable; typ = ty1.typ })
      in
      let*! ty1 = reftype ctx.modul.diagnostics ctx.modul.types ty1 in
      let*! ty2 = reftype ctx.modul.diagnostics ctx.modul.types ty2 in
      (match (top_heap_type ctx ty1.typ, top_heap_type ctx ty2.typ) with
      | Cont, _ | _, Cont ->
          Error.invalid_cast_type ctx.modul.diagnostics ~location:loc
      | _ -> ());
      if not (br_cast_compatible ctx ty1 ty2) then
        Error.br_cast_type_mismatch ctx.modul.diagnostics ~location:loc;
      let* () = pop ctx loc ~expected_source:src_ty1 (Ref ty1) in
      let* () = push ~source:src_ty2 None (Ref ty2) in
      let*! params, param_source = branch_cast_target ctx idx ~location:loc in
      let* () = pop_args ctx loc ~source:param_source params in
      let* () = push_results ~source:param_source params in
      let* _ = pop_any ctx loc in
      push ~source:src_diff (Some loc) (Ref (diff_ref_type ty1 ty2))
  | Br_on_cast_fail (idx, ty1, ty2) ->
      let src_ty1 = Plain (Ast.Text.Ref ty1)
      and src_ty2 = Plain (Ast.Text.Ref ty2) in
      (* The value sent to the branch has [ty1]'s heap type, non-null once a
         nullable [ty2] has consumed the null case. *)
      let src_diff =
        Plain
          (Ast.Text.Ref
             { nullable = ty1.nullable && not ty2.nullable; typ = ty1.typ })
      in
      let*! ty1 = reftype ctx.modul.diagnostics ctx.modul.types ty1 in
      let*! ty2 = reftype ctx.modul.diagnostics ctx.modul.types ty2 in
      (match (top_heap_type ctx ty1.typ, top_heap_type ctx ty2.typ) with
      | Cont, _ | _, Cont ->
          Error.invalid_cast_type ctx.modul.diagnostics ~location:loc
      | _ -> ());
      if not (br_cast_compatible ctx ty1 ty2) then
        Error.br_cast_type_mismatch ctx.modul.diagnostics ~location:loc;
      let* () = pop ctx loc ~expected_source:src_ty1 (Ref ty1) in
      let* () = push ~source:src_diff None (Ref (diff_ref_type ty1 ty2)) in
      let*! params, param_source = branch_cast_target ctx idx ~location:loc in
      let* () = pop_args ctx loc ~source:param_source params in
      let* () = push_results ~source:param_source params in
      let* _ = pop_any ctx loc in
      push ~source:src_ty2 (Some loc) (Ref ty2)
  | Br_on_cast_desc_eq (idx, ty1, ty2) ->
      (* As [br_on_cast], preceded by consuming a descriptor operand whose
         exactness matches the target [ty2]. *)
      let src_ty1 = Plain (Ast.Text.Ref ty1)
      and src_ty2 = Plain (Ast.Text.Ref ty2) in
      let src_diff =
        Plain
          (Ast.Text.Ref
             { nullable = ty1.nullable && not ty2.nullable; typ = ty1.typ })
      in
      let*! ty1 = reftype ctx.modul.diagnostics ctx.modul.types ty1 in
      let*! ty2 = reftype ctx.modul.diagnostics ctx.modul.types ty2 in
      (match (top_heap_type ctx ty1.typ, top_heap_type ctx ty2.typ) with
      | Cont, _ | _, Cont ->
          Error.invalid_cast_type ctx.modul.diagnostics ~location:loc
      | _ -> ());
      if not (br_cast_compatible ctx ty1 ty2) then
        Error.br_cast_type_mismatch ctx.modul.diagnostics ~location:loc;
      let*! desc_ht = descriptor_operand_type ctx ~location:loc ty2.typ in
      let* () =
        pop ctx loc
          ~expected_source:(descriptor_operand_source ctx.modul.types ty2.typ)
          (Ref { nullable = true; typ = desc_ht })
      in
      let* () = pop ctx loc ~expected_source:src_ty1 (Ref ty1) in
      let* () = push ~source:src_ty2 None (Ref ty2) in
      let*! params, param_source = branch_cast_target ctx idx ~location:loc in
      let* () = pop_args ctx loc ~source:param_source params in
      let* () = push_results ~source:param_source params in
      let* _ = pop_any ctx loc in
      push ~source:src_diff (Some loc) (Ref (diff_ref_type ty1 ty2))
  | Br_on_cast_desc_eq_fail (idx, ty1, ty2) ->
      let src_ty1 = Plain (Ast.Text.Ref ty1)
      and src_ty2 = Plain (Ast.Text.Ref ty2) in
      let src_diff =
        Plain
          (Ast.Text.Ref
             { nullable = ty1.nullable && not ty2.nullable; typ = ty1.typ })
      in
      let*! ty1 = reftype ctx.modul.diagnostics ctx.modul.types ty1 in
      let*! ty2 = reftype ctx.modul.diagnostics ctx.modul.types ty2 in
      (match (top_heap_type ctx ty1.typ, top_heap_type ctx ty2.typ) with
      | Cont, _ | _, Cont ->
          Error.invalid_cast_type ctx.modul.diagnostics ~location:loc
      | _ -> ());
      if not (br_cast_compatible ctx ty1 ty2) then
        Error.br_cast_type_mismatch ctx.modul.diagnostics ~location:loc;
      let*! desc_ht = descriptor_operand_type ctx ~location:loc ty2.typ in
      let* () =
        pop ctx loc
          ~expected_source:(descriptor_operand_source ctx.modul.types ty2.typ)
          (Ref { nullable = true; typ = desc_ht })
      in
      let* () = pop ctx loc ~expected_source:src_ty1 (Ref ty1) in
      let* () = push ~source:src_diff None (Ref (diff_ref_type ty1 ty2)) in
      let*! params, param_source = branch_cast_target ctx idx ~location:loc in
      let* () = pop_args ctx loc ~source:param_source params in
      let* () = push_results ~source:param_source params in
      let* _ = pop_any ctx loc in
      push ~source:src_ty2 (Some loc) (Ref ty2)
  | Return ->
      let* () = pop_args ctx loc ~source:ctx.return_source ctx.return_types in
      unreachable
  | Call idx -> (
      let*! ty, _, sign, _ = get_function ctx idx in
      match (Types.get_subtype ctx.modul.subtyping_info ty).typ with
      | Struct _ | Array _ | Cont _ ->
          Error.expected_func_type ctx.modul.diagnostics ~location:loc idx;
          unreachable
      | Func { params; results } ->
          let param_source, result_source = functype_sources sign in
          let* () = pop_args ctx loc ~source:param_source params in
          push_results ~source:result_source results)
  | CallRef idx ->
      let*! type_idx, { params; results } = lookup_func_type ctx idx in
      let param_source, result_source =
        functype_sources (reference_functype ctx.modul.types idx)
      in
      let* () =
        pop ctx loc
          ~expected_source:(named_ref_null_source idx)
          (Ref { nullable = true; typ = Type type_idx })
      in
      let* () = pop_args ctx loc ~source:param_source params in
      push_results ~source:result_source results
  | CallIndirect (idx, tu) -> (
      let*! typ, table_source = get_table ctx idx in
      let*! ty = typeuse ctx.modul.diagnostics ctx.modul.types tu in
      if
        not
          (Types.val_subtype ctx.modul.subtyping_info (Ref typ.reftype)
             (Ref { nullable = true; typ = Func }))
      then (
        Error.table_type_mismatch ctx.modul.diagnostics ~location:loc
          ~source:table_source idx;
        unreachable)
      else
        match (Types.get_subtype ctx.modul.subtyping_info ty).typ with
        | Struct _ | Array _ | Cont _ ->
            Error.expected_func_type ctx.modul.diagnostics ~location:loc idx;
            unreachable
        | Func { params; results } ->
            let param_source, result_source =
              functype_sources (typeuse_functype ctx.modul.types tu)
            in
            let* () = pop_address ctx loc typ.limits in
            let* () = pop_args ctx loc ~source:param_source params in
            push_results ~source:result_source results)
  | ReturnCall idx -> (
      let*! ty, _, sign, _ = get_function ctx idx in
      match (Types.get_subtype ctx.modul.subtyping_info ty).typ with
      | Struct _ | Array _ | Cont _ ->
          Error.expected_func_type ctx.modul.diagnostics ~location:loc idx;
          unreachable
      | Func { params; results } ->
          let param_source, result_source = functype_sources sign in
          let* () = pop_args ctx loc ~source:param_source params in
          compare_types ctx.modul ~location:loc ~descr:"this tail call"
            ~provided_source:result_source ~expected_source:ctx.return_source
            ~provided:results ~expected:ctx.return_types ();
          unreachable)
  | ReturnCallRef idx ->
      let*! type_idx, { params; results } = lookup_func_type ctx idx in
      let param_source, result_source =
        functype_sources (reference_functype ctx.modul.types idx)
      in
      let* () =
        pop ctx loc
          ~expected_source:(named_ref_null_source idx)
          (Ref { nullable = true; typ = Type type_idx })
      in
      let* () = pop_args ctx loc ~source:param_source params in
      compare_types ctx.modul ~location:loc ~descr:"this tail call"
        ~provided_source:result_source ~expected_source:ctx.return_source
        ~provided:results ~expected:ctx.return_types ();
      unreachable
  | ReturnCallIndirect (idx, tu) -> (
      let*! typ, table_source = get_table ctx idx in
      let*! ty = typeuse ctx.modul.diagnostics ctx.modul.types tu in
      if
        not
          (Types.val_subtype ctx.modul.subtyping_info (Ref typ.reftype)
             (Ref { nullable = true; typ = Func }))
      then (
        Error.table_type_mismatch ctx.modul.diagnostics ~location:loc
          ~source:table_source idx;
        unreachable)
      else
        match (Types.get_subtype ctx.modul.subtyping_info ty).typ with
        | Struct _ | Array _ | Cont _ ->
            Error.expected_func_type ctx.modul.diagnostics ~location:loc idx;
            unreachable
        | Func { params; results } ->
            let param_source, result_source =
              functype_sources (typeuse_functype ctx.modul.types tu)
            in
            let* () = pop_address ctx loc typ.limits in
            let* () = pop_args ctx loc ~source:param_source params in
            compare_types ctx.modul ~location:loc ~descr:"this tail call"
              ~provided_source:result_source ~expected_source:ctx.return_source
              ~provided:results ~expected:ctx.return_types ();
            unreachable)
  | Drop ->
      let* _ = pop_any ctx loc in
      return ()
  | Select None -> (
      let* () = pop_known ctx loc I32 in
      let* ty1, loc1 = pop_any ctx loc in
      let* ty2, loc2 = pop_any ctx loc in
      (* A bare [select] forbids reference operands; the bottom reference, like
         any reference, is rejected here. Each operand reduces to its value
         ([None] when unknown), so the cases below mirror the operand stack. *)
      let as_operand = function
        | Bot -> None
        | Bot_ref ->
            Error.expected_number_or_vec ctx.modul.diagnostics ~location:loc
              ~source:Bottom_ref;
            None
        | Val (ty, source) -> Some (ty, source)
      in
      match (as_operand ty1, as_operand ty2) with
      | None, None -> push_poly loc
      | Some (ty1, source1), Some (ty2, source2) ->
          if not (number_or_vec ty1) then
            Error.expected_number_or_vec ctx.modul.diagnostics ~location:loc
              ~source:source1;
          if not (number_or_vec ty2) then
            Error.expected_number_or_vec ctx.modul.diagnostics ~location:loc
              ~source:source2;
          if ty1 <> ty2 then
            Error.select_type_mismatch ctx.modul.diagnostics ~location:loc ~loc1
              ~source1 ~loc2 ~source2;
          push ~source:source1 (Some loc) ty1
      | Some (ty, source), None | None, Some (ty, source) ->
          if not (number_or_vec ty) then
            Error.expected_number_or_vec ctx.modul.diagnostics ~location:loc
              ~source;
          push ~source (Some loc) ty)
  | Select (Some lst) -> (
      match lst with
      | [ typ ] ->
          let src_typ = Plain typ in
          let*! typ = valtype ctx.modul.diagnostics ctx.modul.types typ in
          let* () = pop_known ctx loc I32 in
          let* () = pop ctx loc ~expected_source:src_typ typ in
          let* () = pop ctx loc ~expected_source:src_typ typ in
          push ~source:src_typ (Some loc) typ
      | _ ->
          Error.select_result_count ctx.modul.diagnostics ~location:loc;
          pop_known ctx loc I32)
  | LocalGet i ->
      let*! ty, source = get_local ctx i in
      push ~source (Some loc) ty
  | LocalSet i ->
      let*! ty, source = get_local ~initialize:true ctx i in
      pop ctx loc ~expected_source:source ty
  | LocalTee i ->
      let*! ty, source = get_local ~initialize:true ctx i in
      let* () = pop ctx loc ~expected_source:source ty in
      push ~source (Some loc) ty
  | GlobalGet idx ->
      let*! ty, source = get_global ctx idx in
      push ~source (Some loc) ty.typ
  | GlobalSet idx ->
      let*! ty, source = get_global ctx idx in
      if not ty.mut then
        Error.immutable_global ctx.modul.diagnostics ~location:loc idx;
      pop ctx loc ~expected_source:source ty.typ
  | Load (idx, memarg, ty) ->
      let*! limits = get_memory ctx idx in
      let ty, sz = memory_instruction_type_and_size ty in
      check_memarg ctx loc limits sz memarg;
      let* () = pop_address ctx loc limits in
      push ~source:(source_of_valtype ty) (Some loc) ty
  | LoadS (idx, memarg, ty, sz, _) ->
      let*! limits = get_memory ctx idx in
      let ty = match ty with `I32 -> I32 | `I64 -> I64 in
      check_memarg ctx loc limits
        (sz :> [ `I8 | `I16 | `I32 | `I64 | `V128 ])
        memarg;
      let* () = pop_address ctx loc limits in
      push ~source:(source_of_valtype ty) (Some loc) ty
  | Store (idx, memarg, ty) ->
      let*! limits = get_memory ctx idx in
      let ty, sz = memory_instruction_type_and_size ty in
      check_memarg ctx loc limits sz memarg;
      let* () = pop_known ctx loc ty in
      let* () = pop_address ctx loc limits in
      return ()
  | StoreS (idx, memarg, ty, sz) ->
      let*! limits = get_memory ctx idx in
      let ty = match ty with `I32 -> I32 | `I64 -> I64 in
      check_memarg ctx loc limits
        (sz :> [ `I8 | `I16 | `I32 | `I64 | `V128 ])
        memarg;
      let* () = pop_known ctx loc ty in
      pop_address ctx loc limits
  | Atomic (idx, op, memarg) ->
      let*! limits = get_memory ctx idx in
      check_atomic_memarg ctx loc limits op memarg;
      let vt = function `I32 -> I32 | `I64 -> I64 in
      let operands, results = Atomics.signature op in
      (* Operands sit above the address, topmost last, so pop in reverse. *)
      let* () =
        List.fold_left
          (fun acc t ->
            let* () = acc in
            pop_known ctx loc (vt t))
          (return ()) (List.rev operands)
      in
      let* () = pop_address ctx loc limits in
      List.fold_left
        (fun acc t ->
          let* () = acc in
          push_known (Some loc) (vt t))
        (return ()) results
  | AtomicFence -> return ()
  | MemorySize idx ->
      let*! limits = get_memory ctx idx in
      let ty = address_type_to_valtype limits.address_type in
      push ~source:(source_of_valtype ty) (Some loc) ty
  | MemoryGrow idx ->
      let*! limits = get_memory ctx idx in
      let addr_ty = address_type_to_valtype limits.address_type in
      let* () = pop_known ctx loc addr_ty in
      push ~source:(source_of_valtype addr_ty) (Some loc) addr_ty
  | MemoryFill idx ->
      let*! limits = get_memory ctx idx in
      let addr_ty = address_type_to_valtype limits.address_type in
      let* () = pop_known ctx loc addr_ty in
      let* () = pop_known ctx loc I32 in
      pop_known ctx loc addr_ty
  | MemoryCopy (idx, idx') ->
      let*! limits = get_memory ctx idx in
      let*! limits' = get_memory ctx idx' in
      (* The length operand uses the smaller of the two address types: i32 if
         either memory is 32-bit, i64 only if both are 64-bit. *)
      let address_type =
        match (limits.address_type, limits'.address_type) with
        | `I32, _ | _, `I32 -> `I32
        | `I64, `I64 -> `I64
      in
      let addr_ty = address_type_to_valtype limits.address_type in
      let addr_ty' = address_type_to_valtype limits'.address_type in
      let addr_ty'' = address_type_to_valtype address_type in
      let* () = pop_known ctx loc addr_ty'' in
      let* () = pop_known ctx loc addr_ty' in
      pop_known ctx loc addr_ty
  | MemoryInit (idx, idx') ->
      let*! limits = get_memory ctx idx in
      ignore (get_data ctx idx');
      let addr_ty = address_type_to_valtype limits.address_type in
      let* () = pop_known ctx loc I32 in
      let* () = pop_known ctx loc I32 in
      pop_known ctx loc addr_ty
  | DataDrop idx ->
      ignore (get_data ctx idx);
      return ()
  | VecBinOp _ ->
      let* () = pop_known ctx loc V128 in
      let* () = pop_known ctx loc V128 in
      push_known (Some loc) V128
  | VecConst _ -> push_known (Some loc) V128
  | VecUnOp _ ->
      let* () = pop_known ctx loc V128 in
      push_known (Some loc) V128
  | VecTest _ ->
      let* () = pop_known ctx loc V128 in
      push_known (Some loc) I32
  | VecShift _ ->
      let* () = pop_known ctx loc I32 in
      let* () = pop_known ctx loc V128 in
      push_known (Some loc) V128
  | VecBitmask _ ->
      let* () = pop_known ctx loc V128 in
      push_known (Some loc) I32
  | VecTernOp _ ->
      let* () = pop_known ctx loc V128 in
      let* () = pop_known ctx loc V128 in
      let* () = pop_known ctx loc V128 in
      push_known (Some loc) V128
  | VecBitselect ->
      let* () = pop_known ctx loc V128 in
      let* () = pop_known ctx loc V128 in
      let* () = pop_known ctx loc V128 in
      push_known (Some loc) V128
  | VecSplat shape ->
      let ty = shape_type shape in
      let* () = pop_known ctx loc ty in
      push_known (Some loc) V128
  | VecLoad (idx, sz, memarg) ->
      let*! limits = get_memory ctx idx in
      check_memarg ctx loc limits
        (match sz with
        | Load128 -> `V128
        | Load8x8S | Load8x8U | Load16x4S | Load16x4U | Load32x2S | Load32x2U
        | Load64Zero ->
            `I64
        | Load32Zero -> `I32)
        memarg;
      let* () = pop_address ctx loc limits in
      push_known (Some loc) V128
  | VecStore (idx, memarg) ->
      let*! limits = get_memory ctx idx in
      check_memarg ctx loc limits `V128 memarg;
      let* () = pop_known ctx loc V128 in
      let* () = pop_address ctx loc limits in
      return ()
  | VecLoadLane (idx, op, mem, lane) ->
      let*! limits = get_memory ctx idx in
      check_memarg ctx loc limits
        (op :> [ `I8 | `I16 | `I32 | `I64 | `F32 | `F64 | `V128 ])
        mem;
      let sz = match op with `I8 -> 1 | `I16 -> 2 | `I32 -> 4 | `I64 -> 8 in
      if lane >= 16 / sz then
        Error.invalid_lane_index ctx.modul.diagnostics ~location:loc (16 / sz);
      let* () = pop_known ctx loc V128 in
      let* () = pop_address ctx loc limits in
      push_known (Some loc) V128
  | VecStoreLane (idx, op, mem, lane) ->
      let*! limits = get_memory ctx idx in
      check_memarg ctx loc limits
        (op :> [ `I8 | `I16 | `I32 | `I64 | `F32 | `F64 | `V128 ])
        mem;
      let sz = match op with `I8 -> 1 | `I16 -> 2 | `I32 -> 4 | `I64 -> 8 in
      if lane >= 16 / sz then
        Error.invalid_lane_index ctx.modul.diagnostics ~location:loc (16 / sz);
      let* () = pop_known ctx loc V128 in
      let* () = pop_address ctx loc limits in
      return ()
  | VecLoadSplat (idx, op, mem) ->
      let*! limits = get_memory ctx idx in
      check_memarg ctx loc limits
        (op :> [ `I8 | `I16 | `I32 | `I64 | `F32 | `F64 | `V128 ])
        mem;
      let* () = pop_address ctx loc limits in
      push_known (Some loc) V128
  | VecExtract (shape, _, lane) ->
      check_shape_lanes ctx loc shape lane;
      let* () = pop_known ctx loc V128 in
      push_known (Some loc) (shape_type shape)
  | VecReplace (shape, lane) ->
      check_shape_lanes ctx loc shape lane;
      let* () = pop_known ctx loc (shape_type shape) in
      let* () = pop_known ctx loc V128 in
      push_known (Some loc) V128
  | VecShuffle lanes ->
      if not (String.for_all (fun l -> Char.code l < 32) lanes) then
        Error.invalid_lane_index ctx.modul.diagnostics ~location:loc 32;
      let* () = pop_known ctx loc V128 in
      let* () = pop_known ctx loc V128 in
      push_known (Some loc) V128
  | TableGet idx ->
      let*! typ, source = get_table ctx idx in
      let addr_ty = address_type_to_valtype typ.limits.address_type in
      let* () = pop_known ctx loc addr_ty in
      push ~source (Some loc) (Ref typ.reftype)
  | TableSet idx ->
      let*! typ, source = get_table ctx idx in
      let addr_ty = address_type_to_valtype typ.limits.address_type in
      let* () = pop ctx loc ~expected_source:source (Ref typ.reftype) in
      pop_known ctx loc addr_ty
  | TableSize idx ->
      let*! typ, _ = get_table ctx idx in
      push_known (Some loc) (address_type_to_valtype typ.limits.address_type)
  | TableGrow idx ->
      let*! typ, source = get_table ctx idx in
      let addr_ty = address_type_to_valtype typ.limits.address_type in
      let* () = pop_known ctx loc addr_ty in
      let* () = pop ctx loc ~expected_source:source (Ref typ.reftype) in
      push_known (Some loc) addr_ty
  | TableFill idx ->
      let*! typ, source = get_table ctx idx in
      let addr_ty = address_type_to_valtype typ.limits.address_type in
      let* () = pop_known ctx loc addr_ty in
      let* () = pop ctx loc ~expected_source:source (Ref typ.reftype) in
      pop_known ctx loc addr_ty
  | TableCopy (idx, idx') ->
      let*! ty, dst_source = get_table ctx idx in
      let*! ty', src_source = get_table ctx idx' in
      if
        not
          (Types.val_subtype ctx.modul.subtyping_info (Ref ty'.reftype)
             (Ref ty.reftype))
      then
        Error.type_mismatch ctx.modul.diagnostics ~location:loc
          ~provided_source:src_source ~expected_source:dst_source;
      (* The length operand uses the smaller of the two address types: i32 if
         either table is 32-bit, i64 only if both are 64-bit. *)
      let address_type =
        match (ty.limits.address_type, ty'.limits.address_type) with
        | `I32, _ | _, `I32 -> `I32
        | `I64, `I64 -> `I64
      in
      let addr_ty = address_type_to_valtype ty.limits.address_type in
      let addr_ty' = address_type_to_valtype ty'.limits.address_type in
      let addr_ty'' = address_type_to_valtype address_type in
      let* () = pop_known ctx loc addr_ty'' in
      let* () = pop_known ctx loc addr_ty' in
      pop_known ctx loc addr_ty
  | TableInit (idx, idx') ->
      let*! tabletype, table_source = get_table ctx idx in
      let*! typ, elem_source = get_elem ctx idx' in
      if
        not
          (Types.val_subtype ctx.modul.subtyping_info (Ref typ)
             (Ref tabletype.reftype))
      then
        Error.type_mismatch ctx.modul.diagnostics ~location:loc
          ~provided_source:elem_source ~expected_source:table_source;
      let addr_ty = address_type_to_valtype tabletype.limits.address_type in
      let* () = pop_known ctx loc I32 in
      let* () = pop_known ctx loc I32 in
      pop_known ctx loc addr_ty
  | ElemDrop idx ->
      let*! _ = get_elem ctx idx in
      return ()
  | RefNull typ ->
      let source = Plain Ast.Text.(Ref { nullable = true; typ }) in
      let*! typ = heaptype ctx.modul.diagnostics ctx.modul.types typ in
      push ~source (Some loc) (Ref { nullable = true; typ })
  | RefFunc idx ->
      let*! i, type_idx, sign, exact = get_function ctx idx in
      if
        not
          ((not !validate_refs)
          || Hashtbl.mem ctx.modul.refs
               (Sequence.get_index ctx.modul.functions idx))
      then Error.ref_func_inaccessible ctx.modul.diagnostics ~location:loc idx;
      (* Name the function's type when it was declared with a named type,
         otherwise show the signature inline (a numeric index would be
         meaningless, as the interned index space is deduplicated). *)
      let source =
        match type_idx with
        | Some ({ desc = Id _; _ } as idx) -> named_ref_source idx
        | _ -> Inline_ref (Func sign)
      in
      push ~source (Some loc)
        (Ref { nullable = false; typ = (if exact then Exact i else Type i) })
  | RefIsNull -> (
      let* ty, loc' = pop_any ctx loc in
      match ty with
      | Bot | Bot_ref | Val (Ref _, _) -> push_known (Some loc) I32
      | Val (_, source) ->
          Error.expected_ref_type ctx.modul.diagnostics ~location:loc
            ~src_loc:loc' ~source;
          unreachable)
  | RefAsNonNull -> (
      let* ty, loc' = pop_any ctx loc in
      match ty with
      | Bot | Bot_ref -> push_bot_ref (Some loc)
      | Val (Ref ty, source) ->
          push ~source:(non_null_source source) (Some loc)
            (Ref { ty with nullable = false })
      | Val (_, source) ->
          Error.expected_ref_type ctx.modul.diagnostics ~location:loc
            ~src_loc:loc' ~source;
          unreachable)
  | RefEq ->
      let* () = pop_known ctx loc (Ref { nullable = true; typ = Eq }) in
      let* () = pop_known ctx loc (Ref { nullable = true; typ = Eq }) in
      push_known (Some loc) I32
  | RefTest ty ->
      let*! ty = reftype ctx.modul.diagnostics ctx.modul.types ty in
      (match top_heap_type ctx ty.typ with
      | Cont -> Error.invalid_cast_type ctx.modul.diagnostics ~location:loc
      | _ -> ());
      let* () =
        pop_known ctx loc
          (Ref { nullable = true; typ = top_heap_type ctx ty.typ })
      in
      push_known (Some loc) I32
  | RefCast ty ->
      let source = Plain Ast.Text.(Ref ty) in
      let*! ty = reftype ctx.modul.diagnostics ctx.modul.types ty in
      (match top_heap_type ctx ty.typ with
      | Cont -> Error.invalid_cast_type ctx.modul.diagnostics ~location:loc
      | _ -> ());
      let* () =
        pop_known ctx loc
          (Ref { nullable = true; typ = top_heap_type ctx ty.typ })
      in
      push ~source (Some loc) (Ref ty)
  | RefCastDescEq ty ->
      let source = Plain Ast.Text.(Ref ty) in
      let*! ty = reftype ctx.modul.diagnostics ctx.modul.types ty in
      (* The descriptor operand (top of stack); its exactness matches the target
         [ty]. *)
      let*! desc_ht = descriptor_operand_type ctx ~location:loc ty.typ in
      let* () =
        pop ctx loc
          ~expected_source:(descriptor_operand_source ctx.modul.types ty.typ)
          (Ref { nullable = true; typ = desc_ht })
      in
      let* () =
        pop_known ctx loc
          (Ref { nullable = true; typ = top_heap_type ctx ty.typ })
      in
      push ~source (Some loc) (Ref ty)
  | RefGetDesc idx ->
      let*! ty, _, _ = lookup_struct_type ctx idx in
      let*! desc = type_descriptor ctx ~location:i.info ty in
      let* entry, _ = pop_any ctx loc in
      (* [exact_1] is shared between the operand type [(ref null (exact_1 idx))]
         and the result [(ref (exact_1 desc))]: the descriptor is exact exactly
         when the operand is a subtype of the *exact* operand type. A subtype
         [(ref (exact $c))] with [$c <: idx] is NOT — its descriptor is [$c]'s,
         not [idx]'s — so the result is inexact there. A polymorphic operand
         (unreachable) fits either; take the most precise, exact. Validate the
         operand is a reference to [idx] (a subtype or null) either way. *)
      let exact =
        match entry with
        | Bot | Bot_ref -> true
        | Val (ty', source) ->
            if
              not
                (Types.val_subtype ctx.modul.subtyping_info ty'
                   (Ref { nullable = true; typ = Type ty }))
            then
              Error.type_mismatch ctx.modul.diagnostics ~location:loc
                ~provided_source:source
                ~expected_source:(named_ref_null_source idx);
            Types.val_subtype ctx.modul.subtyping_info ty'
              (Ref { nullable = true; typ = Exact ty })
      in
      push
        ~source:
          (descriptor_operand_source ~nullable:false ctx.modul.types
             (if exact then Exact ty else Type ty))
        (Some loc)
        (Ref
           { nullable = false; typ = (if exact then Exact desc else Type desc) })
  | StructNew idx ->
      let*! ty, _, fields = lookup_struct_type ctx idx in
      if
        Option.is_some
          (Types.get_subtype ctx.modul.subtyping_info ty).descriptor
      then
        Error.descriptor_allocation_required ctx.modul.diagnostics
          ~location:i.info;
      let* () =
        pop_args ctx loc
          ~source:
            (Array.init (Array.length fields) (source_field_valtype ctx idx))
          (Array.map
             (fun (f : fieldtype) ->
               match f.typ with Value v -> v | Packed _ -> I32)
             fields)
      in
      push ~source:(named_ref_source idx) (Some loc)
        (Ref { nullable = false; typ = Exact ty })
  | StructNewDefault idx ->
      let*! ty, _, fields = lookup_struct_type ctx idx in
      if not (Array.for_all field_has_default fields) then
        Error.not_defaultable ctx.modul.diagnostics ~location:i.info;
      if
        Option.is_some
          (Types.get_subtype ctx.modul.subtyping_info ty).descriptor
      then
        Error.descriptor_allocation_required ctx.modul.diagnostics
          ~location:i.info;
      push ~source:(named_ref_source idx) (Some loc)
        (Ref { nullable = false; typ = Exact ty })
  | StructNewDesc idx ->
      let*! ty, _, fields = lookup_struct_type ctx idx in
      let*! desc = type_descriptor ctx ~location:i.info ty in
      (* The descriptor operand is on top of the field values. *)
      let* () =
        pop ctx loc
          ~expected_source:
            (descriptor_operand_source ctx.modul.types (Exact ty))
          (Ref { nullable = true; typ = Exact desc })
      in
      let* () =
        pop_args ctx loc
          ~source:
            (Array.init (Array.length fields) (source_field_valtype ctx idx))
          (Array.map
             (fun (f : fieldtype) ->
               match f.typ with Value v -> v | Packed _ -> I32)
             fields)
      in
      push ~source:(named_ref_source idx) (Some loc)
        (Ref { nullable = false; typ = Exact ty })
  | StructNewDefaultDesc idx ->
      let*! ty, _, fields = lookup_struct_type ctx idx in
      if not (Array.for_all field_has_default fields) then
        Error.not_defaultable ctx.modul.diagnostics ~location:i.info;
      let*! desc = type_descriptor ctx ~location:i.info ty in
      let* () =
        pop ctx loc
          ~expected_source:
            (descriptor_operand_source ctx.modul.types (Exact ty))
          (Ref { nullable = true; typ = Exact desc })
      in
      push ~source:(named_ref_source idx) (Some loc)
        (Ref { nullable = false; typ = Exact ty })
  | StructGet (signage, idx, idx') ->
      let*! ty, field_map, fields = lookup_struct_type ctx idx in
      let* () =
        pop ctx loc
          ~expected_source:(named_ref_null_source idx)
          (Ref { nullable = true; typ = Type ty })
      in
      let*! n = struct_field_index ctx idx' field_map fields in
      (match fields.(n).typ with
      | Packed _ ->
          if signage = None then
            Error.packed_struct_access ctx.modul.diagnostics ~location:i.info
      | Value _ ->
          if signage <> None then
            Error.unpacked_struct_access ctx.modul.diagnostics ~location:i.info);
      push
        ~source:(source_field_valtype ctx idx n)
        (Some loc)
        (unpack_type fields.(n))
  | StructSet (idx, idx') ->
      let*! ty, field_map, fields = lookup_struct_type ctx idx in
      let*! n = struct_field_index ctx idx' field_map fields in
      if not fields.(n).mut then
        Error.immutable ctx.modul.diagnostics ~location:i.info "field";
      let* () =
        pop ctx loc
          ~expected_source:(source_field_valtype ctx idx n)
          (unpack_type fields.(n))
      in
      pop ctx loc
        ~expected_source:(named_ref_null_source idx)
        (Ref { nullable = true; typ = Type ty })
  | ArrayNew idx ->
      let*! ty, field = lookup_array_type ctx idx in
      let* () = pop_known ctx loc I32 in
      let* () =
        pop ctx loc
          ~expected_source:(source_element_valtype ctx idx)
          (unpack_type field)
      in
      push ~source:(named_ref_source idx) (Some loc)
        (Ref { nullable = false; typ = Exact ty })
  | ArrayNewDefault idx ->
      let*! ty, field = lookup_array_type ctx idx in
      if not (field_has_default field) then
        Error.not_defaultable ctx.modul.diagnostics ~location:i.info;
      let* () = pop_known ctx loc I32 in
      push ~source:(named_ref_source idx) (Some loc)
        (Ref { nullable = false; typ = Exact ty })
  | ArrayNewFixed (idx, n) ->
      let*! ty, field = lookup_array_type ctx idx in
      let* () =
        pop_repeat ctx loc
          ~expected_source:(source_element_valtype ctx idx)
          (unpack_type field) (Uint32.to_int n)
      in
      push ~source:(named_ref_source idx) (Some loc)
        (Ref { nullable = false; typ = Exact ty })
  | ArrayNewData (idx, idx') ->
      let*! ty, field = lookup_array_type ctx idx in
      ignore (get_data ctx idx');
      (match field.typ with
      | Packed _ | Value (I32 | I64 | F32 | F64 | V128) -> ()
      | Value (Ref _) ->
          Error.numeric_array_required ctx.modul.diagnostics ~location:i.info);
      let* () = pop_known ctx loc I32 in
      let* () = pop_known ctx loc I32 in
      push ~source:(named_ref_source idx) (Some loc)
        (Ref { nullable = false; typ = Exact ty })
  | ArrayNewElem (idx, idx') ->
      let*! ty, field = lookup_array_type ctx idx in
      let*! ty', _ = get_elem ctx idx' in
      (match field.typ with
      | Value ty when Types.val_subtype ctx.modul.subtyping_info (Ref ty') ty ->
          ()
      | _ ->
          Error.incompatible_array_element ctx.modul.diagnostics
            ~location:i.info);
      let* () = pop_known ctx loc I32 in
      let* () = pop_known ctx loc I32 in
      push ~source:(named_ref_source idx) (Some loc)
        (Ref { nullable = false; typ = Exact ty })
  | ArrayGet (signage, idx) ->
      let*! ty, field = lookup_array_type ctx idx in
      (match field.typ with
      | Packed _ ->
          if signage = None then
            Error.packed_array_access ctx.modul.diagnostics ~location:i.info
      | Value _ ->
          if signage <> None then
            Error.unpacked_array_access ctx.modul.diagnostics ~location:i.info);
      let* () = pop_known ctx loc I32 in
      let* () =
        pop ctx loc
          ~expected_source:(named_ref_null_source idx)
          (Ref { nullable = true; typ = Type ty })
      in
      push
        ~source:(source_element_valtype ctx idx)
        (Some loc) (unpack_type field)
  | ArraySet idx ->
      let*! ty, field = lookup_array_type ctx idx in
      if not field.mut then
        Error.immutable ctx.modul.diagnostics ~location:i.info "array";
      let* () =
        pop ctx loc
          ~expected_source:(source_element_valtype ctx idx)
          (unpack_type field)
      in
      let* () = pop_known ctx loc I32 in
      pop ctx loc
        ~expected_source:(named_ref_null_source idx)
        (Ref { nullable = true; typ = Type ty })
  | ArrayLen ->
      let* () = pop_known ctx loc (Ref { nullable = true; typ = Array }) in
      push_known (Some loc) I32
  | ArrayFill idx ->
      let*! ty, field = lookup_array_type ctx idx in
      if not field.mut then
        Error.immutable ctx.modul.diagnostics ~location:i.info "array";
      let* () = pop_known ctx loc I32 in
      let* () =
        pop ctx loc
          ~expected_source:(source_element_valtype ctx idx)
          (unpack_type field)
      in
      let* () = pop_known ctx loc I32 in
      pop ctx loc
        ~expected_source:(named_ref_null_source idx)
        (Ref { nullable = true; typ = Type ty })
  | ArrayCopy (idx1, idx2) ->
      let*! ty1, field1 = lookup_array_type ctx idx1 in
      let*! ty2, field2 = lookup_array_type ctx idx2 in
      if not field1.mut then
        Error.immutable ctx.modul.diagnostics ~location:i.info "array";
      if not (storage_subtype ctx.modul.subtyping_info field1.typ field2.typ)
      then
        Error.incompatible_array_element ctx.modul.diagnostics ~location:i.info;
      let* () = pop_known ctx loc I32 in
      let* () = pop_known ctx loc I32 in
      let* () =
        pop ctx loc
          ~expected_source:(named_ref_null_source idx2)
          (Ref { nullable = true; typ = Type ty2 })
      in
      let* () = pop_known ctx loc I32 in
      pop ctx loc
        ~expected_source:(named_ref_null_source idx1)
        (Ref { nullable = true; typ = Type ty1 })
  | ArrayInitData (idx, idx') ->
      let*! ty, field = lookup_array_type ctx idx in
      ignore (get_data ctx idx');
      if not field.mut then
        Error.immutable ctx.modul.diagnostics ~location:i.info "array";
      (match field.typ with
      | Packed _ | Value (I32 | I64 | F32 | F64 | V128) -> ()
      | Value (Ref _) ->
          Error.numeric_array_required ctx.modul.diagnostics ~location:i.info);
      let* () = pop_known ctx loc I32 in
      let* () = pop_known ctx loc I32 in
      let* () = pop_known ctx loc I32 in
      pop ctx loc
        ~expected_source:(named_ref_null_source idx)
        (Ref { nullable = true; typ = Type ty })
  | ArrayInitElem (idx, idx') ->
      let*! ty, field = lookup_array_type ctx idx in
      let*! ty', _ = get_elem ctx idx' in
      if not field.mut then
        Error.immutable ctx.modul.diagnostics ~location:i.info "array";
      (match field.typ with
      | Value ty when Types.val_subtype ctx.modul.subtyping_info (Ref ty') ty ->
          ()
      | _ ->
          Error.incompatible_array_element ctx.modul.diagnostics
            ~location:i.info);
      let* () = pop_known ctx loc I32 in
      let* () = pop_known ctx loc I32 in
      let* () = pop_known ctx loc I32 in
      pop ctx loc
        ~expected_source:(named_ref_null_source idx)
        (Ref { nullable = true; typ = Type ty })
  | RefI31 ->
      let* () = pop_known ctx loc I32 in
      push_known (Some loc) (Ref { nullable = false; typ = I31 })
  | I31Get _ ->
      let* () = pop_known ctx loc (Ref { nullable = true; typ = I31 }) in
      push_known (Some loc) I32
  | Const (I32 _) -> push_known (Some loc) I32
  | Const (I64 _) -> push_known (Some loc) I64
  | Const (F32 _) -> push_known (Some loc) F32
  | Const (F64 _) -> push_known (Some loc) F64
  | UnOp (I32 op) ->
      let expected, returned = int_un_op_type I32 op in
      let* () = pop_known ctx loc expected in
      push_known (Some loc) returned
  | UnOp (I64 op) ->
      let expected, returned = int_un_op_type I64 op in
      let* () = pop_known ctx loc expected in
      push_known (Some loc) returned
  | UnOp (F32 op) ->
      let expected = float_un_op_type F32 op in
      let* () = pop_known ctx loc expected in
      push_known (Some loc) F32
  | UnOp (F64 op) ->
      let expected = float_un_op_type F64 op in
      let* () = pop_known ctx loc expected in
      push_known (Some loc) F64
  | BinOp (I32 op) ->
      let* () = pop_known ctx loc I32 in
      let* () = pop_known ctx loc I32 in
      push_known (Some loc) (int_bin_op_type I32 op)
  | BinOp (I64 op) ->
      let* () = pop_known ctx loc I64 in
      let* () = pop_known ctx loc I64 in
      push_known (Some loc) (int_bin_op_type I64 op)
  | BinOp (F32 op) ->
      let* () = pop_known ctx loc F32 in
      let* () = pop_known ctx loc F32 in
      push_known (Some loc) (float_bin_op_type F32 op)
  | BinOp (F64 op) ->
      let* () = pop_known ctx loc F64 in
      let* () = pop_known ctx loc F64 in
      push_known (Some loc) (float_bin_op_type F64 op)
  | Add128 | Sub128 ->
      let* () = pop_known ctx loc I64 in
      let* () = pop_known ctx loc I64 in
      let* () = pop_known ctx loc I64 in
      let* () = pop_known ctx loc I64 in
      let* () = push_known (Some loc) I64 in
      push_known (Some loc) I64
  | MulWide _ ->
      let* () = pop_known ctx loc I64 in
      let* () = pop_known ctx loc I64 in
      let* () = push_known (Some loc) I64 in
      push_known (Some loc) I64
  | I32WrapI64 ->
      let* () = pop_known ctx loc I64 in
      push_known (Some loc) I32
  | I64ExtendI32 _ ->
      let* () = pop_known ctx loc I32 in
      push_known (Some loc) I64
  | F32DemoteF64 ->
      let* () = pop_known ctx loc F64 in
      push_known (Some loc) F32
  | F64PromoteF32 ->
      let* () = pop_known ctx loc F32 in
      push_known (Some loc) F64
  | ExternConvertAny ->
      let* tt, _ = pop_any ctx loc in
      let nullable = convert_operand_nullable ctx loc tt ~typ:Any in
      push_known (Some loc) (Ref { nullable; typ = Extern })
  | AnyConvertExtern ->
      let* tt, _ = pop_any ctx loc in
      let nullable = convert_operand_nullable ctx loc tt ~typ:Extern in
      push_known (Some loc) (Ref { nullable; typ = Any })
  | Folded (i, l) ->
      let* () = instructions ctx l in
      instruction ctx i
  | String (Some idx, _) ->
      let*! ty, field = lookup_array_type ctx idx in
      (match field.typ with
      | Value (I32 | I64 | F32 | F64) | Packed _ -> ()
      | Value (Ref _ | V128) ->
          Error.numeric_array_required ctx.modul.diagnostics ~location:i.info);
      push ~source:(named_ref_source idx) (Some loc)
        (Ref { nullable = false; typ = Exact ty })
  | String (None, _) ->
      let i = string_type ctx.modul.types in
      let comptype = Ast.Text.Array { mut = true; typ = Packed I8 } in
      push ~source:(Inline_ref comptype) (Some loc)
        (Ref { nullable = false; typ = Exact i })
  | Char _ -> push_known (Some loc) I32
  (* Conditional annotations are spliced out by [specialize] before a
     configuration is validated, so none can remain at this point. *)
  | If_annotation _ -> assert false

and instructions ctx l =
  match l with
  | [] -> return ()
  | i :: r ->
      let* () = instruction ctx i in
      instructions ctx r

and block ctx loc label ~param_source ~result_source ~br_source ~params ~results
    ~br_params block =
  with_empty_stack ctx.modul loc
    (let* () = push_results ~source:param_source params in
     let* () =
       instructions
         {
           ctx with
           control_types =
             (Option.map (fun l -> l.Ast.desc) label, br_params, br_source)
             :: ctx.control_types;
         }
         block
     in
     pop_args ctx loc ~source:result_source (*ZZZ More precise loc*) results)

(*** Constant expressions ***)

let rec check_constant_instruction ctx (i : _ Ast.Text.instr) =
  match i.desc with
  | GlobalGet idx ->
      let*? ty, _ = Sequence.get ctx.diagnostics ctx.globals idx in
      if ty.mut then
        Error.non_constant_global ctx.diagnostics ~location:idx.info idx
  | RefFunc i ->
      (* Record the referenced function by INDEX, not by its type: a ref.func in
         a body is valid only if that SAME function occurs outside any body, so
         keying by type would wrongly accept any other same-typed function. *)
      let*? _ = Sequence.get ctx.diagnostics ctx.functions i in
      Hashtbl.replace ctx.refs (Sequence.get_index ctx.functions i) ()
  | RefNull _ | StructNew _ | StructNewDefault _ | StructNewDesc _
  | StructNewDefaultDesc _ | ArrayNew _ | ArrayNewDefault _ | ArrayNewFixed _
  | RefI31 | Const _
  | BinOp (I32 (Add | Sub | Mul) | I64 (Add | Sub | Mul))
  | ExternConvertAny | AnyConvertExtern | VecConst _ | String _ | Char _ ->
      ()
  | Folded (i, l) ->
      check_constant_instruction ctx i;
      check_constant_instructions ctx l
  | Block _ | Loop _ | If _ | TryTable _ | Try _ | Unreachable | Nop | Throw _
  | ThrowRef | ContNew _ | ContBind _ | Suspend _ | Resume _ | ResumeThrow _
  | ResumeThrowRef _ | Switch _ | Br _ | Br_if _ | Br_table _ | Br_on_null _
  | Br_on_non_null _ | Br_on_cast _ | Br_on_cast_fail _ | Br_on_cast_desc_eq _
  | Br_on_cast_desc_eq_fail _ | Hinted _ | Return | Call _ | CallRef _
  | CallIndirect _ | ReturnCall _ | ReturnCallRef _ | ReturnCallIndirect _
  | Drop | Select _ | LocalGet _ | LocalSet _ | LocalTee _ | GlobalSet _
  | Load _ | LoadS _ | Store _ | StoreS _ | Atomic _ | AtomicFence
  | MemorySize _ | MemoryGrow _ | MemoryFill _ | MemoryCopy _ | MemoryInit _
  | DataDrop _ | TableGet _ | TableSet _ | TableSize _ | TableGrow _
  | TableFill _ | TableCopy _ | TableInit _ | ElemDrop _ | RefIsNull
  | RefAsNonNull | RefEq | RefTest _ | RefCast _ | RefCastDescEq _
  | RefGetDesc _ | StructGet _ | StructSet _ | ArrayNewData _ | ArrayNewElem _
  | ArrayGet _ | ArraySet _ | ArrayLen | ArrayFill _ | ArrayCopy _
  | ArrayInitData _ | ArrayInitElem _ | I31Get _ | UnOp _ | Add128 | Sub128
  | MulWide _
  | BinOp
      ( F32 _ | F64 _
      | I32
          ( Div _ | Rem _ | And | Or | Xor | Shl | Shr _ | Rotl | Rotr | Eq | Ne
          | Lt _ | Gt _ | Le _ | Ge _ )
      | I64
          ( Div _ | Rem _ | And | Or | Xor | Shl | Shr _ | Rotl | Rotr | Eq | Ne
          | Lt _ | Gt _ | Le _ | Ge _ ) )
  | I32WrapI64 | I64ExtendI32 _ | F32DemoteF64 | F64PromoteF32 | VecBitselect
  | VecUnOp _ | VecBinOp _ | VecTest _ | VecShift _ | VecBitmask _ | VecLoad _
  | VecStore _ | VecLoadLane _ | VecStoreLane _ | VecLoadSplat _ | VecExtract _
  | VecReplace _ | VecSplat _ | VecShuffle _ | VecTernOp _ ->
      Error.constant_expression_required ctx.diagnostics ~location:i.info
  (* Spliced out by [specialize] before validation; cannot occur here. *)
  | If_annotation _ -> assert false

and check_constant_instructions ctx l =
  List.iter (fun i -> check_constant_instruction ctx i) l

let constant_expression ctx ~location ~expected_source ty expr =
  check_constant_instructions ctx expr;
  with_empty_stack ctx location
    (let ctx =
       {
         locals = Sequence.make "local";
         control_types = [];
         return_types = [||];
         return_source = [||];
         modul = ctx;
         initialized_locals = IntSet.empty;
         used_locals = ref IntSet.empty;
       }
     in
     let* () = instructions ctx expr in
     pop ctx location ~expected_source ty)

(*** Type registration and the module environment ***)

let add_type d ctx ty =
  Array.iteri
    (fun i e ->
      let label, (sub : Ast.Text.subtype) = e.Ast.desc in
      (* These forward references are placeholders during the rec group's own
         resolution and are replaced (or dropped) below; the composite type is
         not consulted meanwhile, but carrying it keeps the field total. *)
      Hashtbl.replace ctx.index_mapping
        (Uint32.of_int (ctx.last_index + i))
        (lnot i, [], sub.typ);
      Option.iter
        (fun label ->
          Hashtbl.replace ctx.label_mapping label.Ast.desc (lnot i, [], sub.typ))
        label)
    ty;
  match rectype d ctx ty with
  | None ->
      Array.iteri
        (fun i e ->
          let label = fst e.Ast.desc in
          Hashtbl.remove ctx.index_mapping (Uint32.of_int (ctx.last_index + i));
          Option.iter
            (fun label -> Hashtbl.remove ctx.label_mapping label.Ast.desc)
            label)
        ty
  | Some ty' ->
      (* Well-formedness of [descriptor] / [describes] clauses, which must link
         two struct types within the same recursion group. In [ty'] an in-group
         type reference is a negative placeholder [lnot pos]; a non-negative
         index denotes an already-defined type, i.e. one outside this group. *)
      let in_group idx = if idx < 0 then Some (lnot idx) else None in
      Array.iteri
        (fun i (sub : Ast.Binary.subtype) ->
          let location = ty.(i).Ast.info in
          (match sub.descriptor with
          | None -> ()
          | Some di -> (
              match in_group di with
              | None ->
                  Error.descriptor_outside_rec_group d ~location
                    ~described:false
              | Some pos -> (
                  (* This type is described by [ty'.(pos)]; that descriptor must
                     describe this type back. *)
                  match ty'.(pos).describes with
                  | Some o when in_group o = Some i -> ()
                  | _ ->
                      Error.descriptor_not_reciprocal d ~location
                        ~described:false)));
          (match sub.describes with
          | None -> ()
          | Some oi -> (
              match in_group oi with
              | None ->
                  Error.descriptor_outside_rec_group d ~location ~described:true
              | Some pos -> (
                  if pos >= i then Error.forward_use_of_described d ~location;
                  (* This type is the descriptor of [ty'.(pos)], which must name
                     this type as its descriptor. *)
                  match ty'.(pos).descriptor with
                  | Some dd when in_group dd = Some i -> ()
                  | _ ->
                      Error.descriptor_not_reciprocal d ~location
                        ~described:true)));
          if
            (sub.descriptor <> None || sub.describes <> None)
            && match sub.typ with Struct _ -> false | _ -> true
          then
            Error.descriptor_not_struct d ~location
              ~described:(sub.describes <> None))
        ty';
      let i' = Types.add_rectype ctx.types ty' in
      Array.iteri
        (fun i e ->
          let label, typ = e.Ast.desc in
          let fields =
            match (typ : Ast.Text.subtype).typ with
            | Struct fields ->
                Array.mapi
                  (fun i e ->
                    match fst e.Ast.desc with
                    | Some id -> Some (id.Ast.desc, i)
                    | None -> None)
                  fields
                |> Array.to_list |> List.filter_map Fun.id
            | _ -> []
          in
          Hashtbl.replace ctx.index_mapping
            (Uint32.of_int (ctx.last_index + i))
            (i' + i, fields, typ.typ);
          let def_idx =
            let desc =
              match label with
              | Some l -> Ast.Text.Id l.Ast.desc
              | None -> Ast.Text.Num (Uint32.of_int (ctx.last_index + i))
            in
            { Ast.desc; info = e.Ast.info }
          in
          let cont_ref =
            match (typ : Ast.Text.subtype).typ with
            | Cont r -> Some r
            | Func _ | Struct _ | Array _ -> None
          in
          Hashtbl.replace ctx.type_defs (ctx.last_index + i) (def_idx, cont_ref);
          Option.iter
            (fun node -> Hashtbl.replace ctx.descriptor_source (i' + i) node)
            (typ : Ast.Text.subtype).descriptor;
          Option.iter
            (fun label ->
              Hashtbl.replace ctx.label_mapping label.Ast.desc
                (i' + i, fields, typ.typ))
            label)
        ty;
      ctx.last_index <- ctx.last_index + Array.length ty

let register_exports ctx lst =
  List.iter
    (fun (name : Ast.Text.name) ->
      if Hashtbl.mem ctx.exports name.desc then
        Error.duplicated_export ctx.diagnostics ~location:name.info name
      else Hashtbl.add ctx.exports name.desc ())
    lst

let limits ctx kind
    {
      Ast.desc = { mi; ma; address_type; page_size_log2; shared };
      info = location;
    } max_fn =
  (match page_size_log2 with
  | None | Some (0 | 16) -> ()
  | Some _ -> Error.invalid_page_size ctx.diagnostics ~location);
  (* A shared memory must declare a maximum size. *)
  if shared && ma = None then
    Error.shared_memory_without_max ctx.diagnostics ~location;
  let max = max_fn address_type page_size_log2 in
  match ma with
  | None ->
      if Uint64.compare mi max > 0 then
        Error.limit_too_large ctx.diagnostics ~location kind max
  | Some ma ->
      if Uint64.compare mi ma > 0 then
        Error.limit_mismatch ctx.diagnostics ~location kind;
      if Uint64.compare ma max > 0 then
        Error.limit_too_large ctx.diagnostics ~location kind max

(* The maximum number of pages: [min(2^bits - 1, 2^(bits - p))] where [bits] is
   32 (i32) or 64 (i64) and [2^p] is the page size (default 2^16). The byte span
   gives the [2^(bits - p)] term; the [2^bits - 1] cap bounds the page index
   itself (so e.g. a page size of 1 allows 2^32 - 1 pages, not 2^32). With the
   default page size this is the familiar 65536 / 2^48 pages. *)
let max_memory_size address_type page_size_log2 =
  let p = match page_size_log2 with None -> 16 | Some p -> p in
  let bits, index_max =
    match address_type with
    | `I32 -> (32, Uint64.of_string "0xffff_ffff")
    | `I64 -> (64, Uint64.of_string "0xffff_ffff_ffff_ffff")
  in
  let e = bits - p in
  let by_page =
    if e >= 64 then index_max
    else if e <= 0 then Uint64.zero
    else Uint64.of_int64 (Int64.shift_left 1L e)
  in
  if Uint64.compare index_max by_page <= 0 then index_max else by_page

let max_table_size address_type _page_size_log2 =
  match address_type with
  | `I32 -> Uint64.of_string "0xffff_ffff"
  | `I64 -> Uint64.of_string "0xffff_ffff_ffff_ffff"

let rec register_typeuses d ctx l =
  List.iter (fun i -> register_typeuses_instr d ctx i) l

and register_typeuses_instr d ctx (i : _ Ast.Text.instr) =
  match i.desc with
  | Block { typ; _ }
  | Loop { typ; _ }
  | If { typ; _ }
  | TryTable { typ; _ }
  | Try { typ; _ } -> (
      match typ with
      | Some (Typeuse use) -> ignore (typeuse d ctx use)
      | Some (Valtype _) | None -> ())
  | CallIndirect (_, use) | ReturnCallIndirect (_, use) ->
      ignore (typeuse d ctx use)
  | String _ -> ignore (string_type ctx)
  | If_annotation _ ->
      (* Spliced out by [specialize] before validation; cannot occur here. *)
      assert false
  | Folded (i, l) ->
      register_typeuses_instr d ctx i;
      register_typeuses d ctx l
  | Hinted (_, i) -> register_typeuses_instr d ctx i
  | Unreachable | Nop | Throw _ | ThrowRef | ContNew _ | ContBind _ | Suspend _
  | Resume _ | ResumeThrow _ | ResumeThrowRef _ | Switch _ | Br _ | Br_if _
  | Br_table _ | Br_on_null _ | Br_on_non_null _ | Br_on_cast _
  | Br_on_cast_fail _ | Br_on_cast_desc_eq _ | Br_on_cast_desc_eq_fail _
  | Return | Call _ | CallRef _ | ReturnCall _ | ReturnCallRef _ | Drop
  | Select _ | LocalGet _ | LocalSet _ | LocalTee _ | GlobalGet _ | GlobalSet _
  | Load _ | LoadS _ | Store _ | StoreS _ | Atomic _ | AtomicFence
  | MemorySize _ | MemoryGrow _ | MemoryFill _ | MemoryCopy _ | MemoryInit _
  | DataDrop _ | TableGet _ | TableSet _ | TableSize _ | TableGrow _
  | TableFill _ | TableCopy _ | TableInit _ | ElemDrop _ | RefNull _ | RefFunc _
  | RefIsNull | RefAsNonNull | RefEq | RefTest _ | RefCast _ | RefCastDescEq _
  | RefGetDesc _ | StructNew _ | StructNewDefault _ | StructNewDesc _
  | StructNewDefaultDesc _ | StructGet _ | StructSet _ | ArrayNew _
  | ArrayNewDefault _ | ArrayNewFixed _ | ArrayNewData _ | ArrayNewElem _
  | ArrayGet _ | ArraySet _ | ArrayLen | ArrayFill _ | ArrayCopy _
  | ArrayInitData _ | ArrayInitElem _ | RefI31 | I31Get _ | Const _ | UnOp _
  | BinOp _ | Add128 | Sub128 | MulWide _ | I32WrapI64 | I64ExtendI32 _
  | F32DemoteF64 | F64PromoteF32 | ExternConvertAny | AnyConvertExtern
  | VecBitselect | VecConst _ | VecUnOp _ | VecBinOp _ | VecTest _ | VecShift _
  | VecBitmask _ | VecLoad _ | VecStore _ | VecLoadLane _ | VecStoreLane _
  | VecLoadSplat _ | VecExtract _ | VecReplace _ | VecSplat _ | VecShuffle _
  | VecTernOp _ | Char _ ->
      ()

(* Collect the implicit function types denoted by inline signatures (function
   and tag definitions, imports, block types and [call_indirect]). Following
   the text format, such a type reuses a structurally-equal type if one already
   exists, and is otherwise appended to the end of the type index space, where
   it can be referred to by index. We must do this before resolving any type
   reference so that those indices are bound, and before computing the
   subtyping information so that it covers every type. Relies on
   {!Types.add_rectype} deduplicating: a [typeuse] encountered later during
   validation then resolves to the type collected here instead of growing the
   type table. *)
let collect_implicit_types d ctx fields =
  let collect sign =
    let>@ ft = functype d ctx sign in
    let before = Types.last_index ctx.types in
    let idx =
      Types.add_rectype ctx.types
        [|
          {
            typ = Func ft;
            supertype = None;
            final = true;
            descriptor = None;
            describes = None;
          };
        |]
    in
    if Types.last_index ctx.types > before then (
      Hashtbl.replace ctx.index_mapping
        (Uint32.of_int ctx.last_index)
        (idx, [], Func sign);
      ctx.last_index <- ctx.last_index + 1)
  in
  let rec collect_instrs l = List.iter collect_instr l
  and collect_instr (i : _ Ast.Text.instr) =
    (match i.desc with
    | Block { typ = Some (Typeuse (None, Some ft)); _ }
    | Loop { typ = Some (Typeuse (None, Some ft)); _ }
    | If { typ = Some (Typeuse (None, Some ft)); _ }
    | Try { typ = Some (Typeuse (None, Some ft)); _ }
    | TryTable { typ = Some (Typeuse (None, Some ft)); _ } ->
        collect ft
    | CallIndirect (_, (None, Some ft)) | ReturnCallIndirect (_, (None, Some ft))
      ->
        collect ft
    | _ -> ());
    match i.desc with
    | Block { block; _ } | Loop { block; _ } | TryTable { block; _ } ->
        collect_instrs block
    | If { if_block; else_block; _ } ->
        collect_instrs if_block.desc;
        collect_instrs else_block.desc
    | Try { block; catches; catch_all; _ } ->
        collect_instrs block;
        List.iter (fun (_, c) -> collect_instrs c) catches;
        Option.iter collect_instrs catch_all
    | If_annotation _ -> assert false
    | Folded (i, l) ->
        collect_instr i;
        collect_instrs l
    | _ -> ()
  in
  List.iter
    (fun (field : (_ Ast.Text.modulefield, _) Ast.annotated) ->
      (match field.desc with
      | Import { desc = Func { typ = None, Some sign; _ }; _ }
      | Import { desc = Tag (None, Some sign); _ }
      | Func { typ = None, Some sign; _ }
      | Tag { typ = None, Some sign; _ } ->
          collect sign
      | _ -> ());
      match field.desc with
      | Func { instrs; _ } -> collect_instrs instrs
      | _ -> ())
    fields

let build_initial_env ctx fields =
  List.iter
    (fun (field : (_ Ast.Text.modulefield, _) Ast.annotated) ->
      match field.desc with
      | Import { id; desc; exports; module_ = _; name = _ } -> (
          register_exports ctx exports;
          match desc with
          | Func { exact; typ = tu } ->
              ignore
                (let+@ ty = typeuse ctx.diagnostics ctx.types tu in
                 Sequence.register ctx.functions id
                   (ty, fst tu, typeuse_functype ctx.types tu, exact))
          | Memory lim ->
              limits ctx "memory" lim max_memory_size;
              Sequence.register ctx.memories id lim.desc
          | Table typ ->
              limits ctx "table" typ.limits max_table_size;
              let src = Plain (Ast.Text.Ref typ.reftype) in
              let>@ typ = tabletype ctx.diagnostics ctx.types typ in
              Sequence.register ctx.tables id (typ, src)
          | Global ty ->
              let src = Plain ty.typ in
              let>@ ty = globaltype ctx.diagnostics ctx.types ty in
              Sequence.register ctx.globals id (ty, src)
          | Tag tu ->
              let>@ ty = typeuse ctx.diagnostics ctx.types tu in
              let sign = typeuse_functype ctx.types tu in
              (* A tag's function type is deliberately not required to have empty
                 results: the stack-switching proposal uses tags with result
                 types (for [suspend] / [resume]), so the exception-handling
                 restriction to no results is not enforced. *)
              Sequence.register ctx.tags id (ty, sign))
      | Func { id; typ; instrs; _ } ->
          let>@ ty = typeuse ctx.diagnostics ctx.types typ in
          let sign = typeuse_functype ctx.types typ in
          (* A module-defined function has exactly its declared type. *)
          Sequence.register ctx.functions id (ty, fst typ, sign, true);
          register_typeuses ctx.diagnostics ctx.types instrs
      | Tag { id; typ; exports } ->
          let>@ ty = typeuse ctx.diagnostics ctx.types typ in
          let sign = typeuse_functype ctx.types typ in
          (* A tag's function type is deliberately not required to have empty
             results: the stack-switching proposal uses tags with result types
             (for [suspend] / [resume]), so the exception-handling restriction to
             no results is not enforced. *)
          register_exports ctx exports;
          Sequence.register ctx.tags id (ty, sign)
      | _ -> ())
    fields

let check_type_definitions ctx =
  for i = 0 to ctx.types.last_index - 1 do
    let def_idx, cont_ref =
      Option.value
        ~default:(Ast.no_loc (Ast.Text.Num (Uint32.of_int i)), None)
        (Hashtbl.find_opt ctx.types.type_defs i)
    in
    let location = def_idx.Ast.info in
    let>@ gidx, _, _ =
      get_type_info ctx.diagnostics ctx.types
        (Ast.no_loc (Ast.Text.Num (Uint32.of_int i)))
    in
    let ty = Types.get_subtype ctx.subtyping_info gidx in
    (* A continuation type must wrap a function type. *)
    (match ty.typ with
    | Cont ft -> (
        match (Types.get_subtype ctx.subtyping_info ft).typ with
        | Func _ -> ()
        | Struct _ | Array _ | Cont _ ->
            (* Name the wrapped type as the source wrote it: the resolved index
               [ft] is canonical, so identical types would otherwise be
               indistinguishable. *)
            let wrapped =
              Option.value
                ~default:(Ast.no_loc (Ast.Text.Num (Uint32.of_int ft)))
                cont_ref
            in
            Error.expected_func_type ctx.diagnostics ~location wrapped)
    | Func _ | Struct _ | Array _ -> ());
    let*? j = ty.supertype in
    let ty' = Types.get_subtype ctx.subtyping_info j in
    let invalid () = Error.invalid_subtype ctx.diagnostics ~location in
    if ty'.final then invalid ()
    else begin
      (match (ty.typ, ty'.typ) with
      | Func { params; results }, Func { params = params'; results = results' }
        ->
          if
            Array.length params <> Array.length params'
            || Array.length results <> Array.length results'
            || not
                 (Array.for_all2
                    (fun p p' -> Types.val_subtype ctx.subtyping_info p' p)
                    params params'
                 && Array.for_all2
                      (fun r r' -> Types.val_subtype ctx.subtyping_info r r')
                      results results')
          then invalid ()
      | Struct fields, Struct fields' ->
          if
            Array.length fields' > Array.length fields
            || not
                 (Array.for_all2
                    (field_subtype ctx.subtyping_info)
                    (Array.sub fields 0 (Array.length fields'))
                    fields')
          then invalid ()
      | Array field, Array field' ->
          if not (field_subtype ctx.subtyping_info field field') then invalid ()
      | Cont ft, Cont ft' ->
          if not (Types.heap_subtype ctx.subtyping_info (Type ft) (Type ft'))
          then invalid ()
      | Func _, (Struct _ | Array _ | Cont _)
      | Struct _, (Func _ | Array _ | Cont _)
      | Array _, (Func _ | Struct _ | Cont _)
      | Cont _, (Func _ | Struct _ | Array _) ->
          Error.supertype_mismatch ctx.diagnostics ~location);
      (* If the supertype has a descriptor, the subtype must too, and its
         descriptor must be a subtype of the supertype's. (A subtype may add a
         descriptor that its supertype lacks.) *)
      (match ty'.descriptor with
      | None -> ()
      | Some dp -> (
          match ty.descriptor with
          | Some ds
            when Types.heap_subtype ctx.subtyping_info (Type ds) (Type dp) ->
              ()
          | _ -> invalid ()));
      (* A subtype has a described type iff its supertype does, and the
         subtype's described type must be a subtype of the supertype's. *)
      match (ty.describes, ty'.describes) with
      | None, None -> ()
      | Some os, Some op ->
          if not (Types.heap_subtype ctx.subtyping_info (Type os) (Type op))
          then invalid ()
      | Some _, None | None, Some _ -> invalid ()
    end
  done

(*** Module-field validation passes ***)

let tables_and_memories ctx fields =
  List.iter
    (fun (field : (_ Ast.Text.modulefield, _) Ast.annotated) ->
      match field.desc with
      | Memory { id; limits = lim; init = _; exports } ->
          limits ctx "memory" lim max_memory_size;
          Sequence.register ctx.memories id lim.desc;
          register_exports ctx exports
      | Table { id; typ; init; exports } ->
          limits ctx "table" typ.limits max_table_size;
          let src = Plain (Ast.Text.Ref typ.reftype) in
          let>@ typ = tabletype ctx.diagnostics ctx.types typ in
          (match init with
          | Init_default ->
              if not typ.reftype.nullable then
                Error.non_nullable_table_type ctx.diagnostics
                  ~location:field.info (*ZZZ*)
          | Init_expr e ->
              constant_expression ctx ~location:field.info ~expected_source:src
                (Ref typ.reftype) e
          | Init_segment _ -> ());
          Sequence.register ctx.tables id (typ, src);
          register_exports ctx exports
      | _ -> ())
    fields

let globals ctx fields =
  List.iter
    (fun (field : (_ Ast.Text.modulefield, _) Ast.annotated) ->
      match field.desc with
      | Global { id; typ; init; exports } ->
          let src = Plain typ.typ in
          let>@ typ = globaltype ctx.diagnostics ctx.types typ in
          constant_expression ctx ~location:field.info ~expected_source:src
            typ.typ init;
          Sequence.register ctx.globals id (typ, src);
          register_exports ctx exports
      | String_global { id; _ } ->
          let i = string_type ctx.types in
          let typ =
            { mut = false; typ = Ref { nullable = false; typ = Type i } }
          in
          let comptype = Ast.Text.Array { mut = true; typ = Packed I8 } in
          Sequence.register ctx.globals (Some id) (typ, Inline_ref comptype)
      | _ -> ())
    fields

let segments ctx fields =
  List.iter
    (fun (field : (_ Ast.Text.modulefield, _) Ast.annotated) ->
      match field.desc with
      | Memory { init; _ } ->
          let*? _ = init in
          Sequence.register ctx.data None ()
      | Data { id; init = _; mode } ->
          (match mode with
          | Passive -> ()
          | Active (i, e) ->
              let*? limits = Sequence.get ctx.diagnostics ctx.memories i in
              let aty = address_type_to_valtype limits.address_type in
              constant_expression ctx ~location:field.info
                ~expected_source:(source_of_valtype aty) aty e);
          Sequence.register ctx.data id ()
      | Table { typ; init; _ } -> (
          match init with
          | Init_default | Init_expr _ -> ()
          | Init_segment lst ->
              let src = Plain (Ast.Text.Ref typ.reftype) in
              let>@ typ = reftype ctx.diagnostics ctx.types typ.reftype in
              List.iter
                (fun e ->
                  constant_expression ctx ~location:field.info
                    ~expected_source:src (Ref typ) e)
                lst;
              Sequence.register ctx.elem None (typ, src))
      | Elem { id; typ; init; mode } ->
          let elem_source = Plain (Ast.Text.Ref typ) in
          let>@ typ = reftype ctx.diagnostics ctx.types typ in
          (match mode with
          | Passive | Declare -> ()
          | Active (i, e) ->
              let*? tabletype, table_source =
                Sequence.get ctx.diagnostics ctx.tables i
              in
              if
                not
                  (Types.val_subtype ctx.subtyping_info (Ref typ)
                     (Ref tabletype.reftype))
              then
                Error.elem_segment_type_mismatch ctx.diagnostics
                  ~location:field.info ~elem_source ~table_source;
              let aty = address_type_to_valtype tabletype.limits.address_type in
              constant_expression ctx ~location:field.info
                ~expected_source:(source_of_valtype aty) aty e);
          List.iter
            (fun e ->
              constant_expression ctx ~location:field.info
                ~expected_source:elem_source (Ref typ) e)
            init;
          Sequence.register ctx.elem id (typ, elem_source)
      | _ -> ())
    fields

(* An exported function is referenceable by [ref.func] (it is in the module's
   [refs] set), like a function named in a global or element segment. Record
   exported functions by index BEFORE bodies are validated — the dedicated
   [exports] pass runs after [functions], too late for the [ref.func] check.
   Both a standalone export field and an inline export on a function count; in a
   binary all exports are standalone (the export section), inline being WAT
   sugar. Function indices are counted positionally, imports first (their order
   is enforced by [check_import_order]), matching how [build_initial_env]
   registers them. *)
let declared_func_exports ctx fields =
  let fi = ref 0 in
  List.iter
    (fun (field : (_ Ast.Text.modulefield, _) Ast.annotated) ->
      match field.desc with
      | Import { desc = Func _; exports; _ } ->
          if exports <> [] then Hashtbl.replace ctx.refs !fi ();
          incr fi
      | Import _ -> ()
      | Func { exports; _ } ->
          if exports <> [] then Hashtbl.replace ctx.refs !fi ();
          incr fi
      | Export { kind = Func; index; _ } ->
          Option.iter
            (fun i -> Hashtbl.replace ctx.refs i ())
            (Sequence.get_index_opt ctx.functions index)
      | _ -> ())
    fields

let functions ?(warn_unused = true) ctx fields =
  List.iter
    (fun (field : (_ Ast.Text.modulefield, _) Ast.annotated) ->
      match field.desc with
      | Func { id = _; typ; locals = locs; instrs; exports } ->
          let>@ func_typ =
            let*@ typ = typeuse ctx.diagnostics ctx.types typ in
            match (Types.get_subtype ctx.subtyping_info typ).typ with
            | Func typ -> Some typ
            | _ ->
                Error.not_function_type ctx.diagnostics ~location:field.info;
                None
          in
          let return_types = func_typ.results in
          let return_source =
            snd (functype_sources (typeuse_functype ctx.types typ))
          in
          let locals = Sequence.make "local" in
          let initialized_locals = ref IntSet.empty in
          let i = ref 0 in
          (match typ with
          | _, Some { params; _ } ->
              Array.iter
                (fun p ->
                  let id, typ = p.Ast.desc in
                  initialized_locals := IntSet.add !i !initialized_locals;
                  incr i;
                  let interned =
                    match valtype ctx.diagnostics ctx.types typ with
                    | None ->
                        (* Dummy value *) Ref { nullable = false; typ = None_ }
                    | Some typ' -> typ'
                  in
                  Sequence.register locals id (interned, Plain typ))
                params
          | _ ->
              (* No inline parameter list: take the parameters' source types
                 from the referenced function type's definition. *)
              let param_source =
                fst (functype_sources (typeuse_functype ctx.types typ))
              in
              Array.iteri
                (fun j typ ->
                  initialized_locals := IntSet.add !i !initialized_locals;
                  incr i;
                  let source = param_source.(j) in
                  Sequence.register locals None (typ, source))
                func_typ.params);
          (* The locals declared by the function (not its parameters), recorded
             as (index, optional name, declaration location) so an unread one
             can be reported as unused after the body is validated. *)
          let declared_locals = ref [] in
          List.iter
            (fun e ->
              let id, typ = e.Ast.desc in
              let typ' =
                match valtype ctx.diagnostics ctx.types typ with
                | None -> (* Dummy value *) Ref { nullable = true; typ = Any }
                | Some typ -> typ
              in
              if is_defaultable typ' then
                initialized_locals := IntSet.add !i !initialized_locals;
              (* Point a named local's warning at its name; an unnamed one at
                 the whole declaration. *)
              let location =
                match id with Some id -> id.Ast.info | None -> e.Ast.info
              in
              declared_locals :=
                (!i, Option.map (fun id -> id.Ast.desc) id, location)
                :: !declared_locals;
              incr i;
              Sequence.register locals id (typ', Plain typ))
            locs;
          let ctx =
            {
              locals;
              control_types = [ (None, return_types, return_source) ];
              return_types;
              return_source;
              modul = ctx;
              initialized_locals = !initialized_locals;
              used_locals = ref IntSet.empty;
            }
          in
          with_empty_stack ctx.modul field.info
            (let* () = instructions ctx instrs in
             pop_args ctx field.info (*ZZZ*) ~source:return_source return_types);
          (* A named local whose name starts with [_] is intentionally unused;
             unnamed locals are always reported. *)
          if warn_unused then
            List.iter
              (fun (idx, name, location) ->
                if
                  (not (IntSet.mem idx !(ctx.used_locals)))
                  && not
                       (match name with
                       | Some n -> String.length n > 0 && n.[0] = '_'
                       | None -> false)
                then Error.unused_local ctx.modul.diagnostics ~location name)
              (List.rev !declared_locals);
          register_exports ctx.modul exports
      | _ -> ())
    fields

let exports ctx fields =
  List.iter
    (fun (field : (_ Ast.Text.modulefield, _) Ast.annotated) ->
      match field.desc with
      | Export { name; kind; index } -> (
          register_exports ctx [ name ];
          match kind with
          | Func -> ignore (Sequence.get ctx.diagnostics ctx.functions index)
          | Memory -> ignore (Sequence.get ctx.diagnostics ctx.memories index)
          | Table -> ignore (Sequence.get ctx.diagnostics ctx.tables index)
          | Tag -> ignore (Sequence.get ctx.diagnostics ctx.tags index)
          | Global -> ignore (Sequence.get ctx.diagnostics ctx.globals index))
      | _ -> ())
    fields

let start ctx fields =
  List.iter
    (fun (field : (_ Ast.Text.modulefield, _) Ast.annotated) ->
      match field.desc with
      | Start idx -> (
          let*? ty, _, _, _ = Sequence.get ctx.diagnostics ctx.functions idx in
          match (Types.get_subtype ctx.subtyping_info ty).typ with
          | Struct _ | Array _ | Cont _ ->
              Error.not_function_type ctx.diagnostics ~location:idx.info
          | Func { params; results } ->
              if not (params = [||] && results = [||]) then
                Error.start_function_signature ctx.diagnostics
                  ~location:idx.info)
      | _ -> ())
    fields

(*** Whole-module validation ***)

(* Syntactic well-formedness checks that the stack-based validation does not
   cover: duplicate identifiers in each namespace, an inline type annotation
   that disagrees with the type it names, duplicate parameter/local names, and a
   second start function. Type references are resolved through [ctx], the type
   context the rest of validation has already built, which handles recursive and
   forward references correctly. *)
let check_syntax ctx lst =
  let types = Hashtbl.create 16 in
  let functions = Hashtbl.create 16 in
  let memories = Hashtbl.create 16 in
  let tables = Hashtbl.create 16 in
  let globals = Hashtbl.create 16 in
  let tags = Hashtbl.create 16 in
  let elems = Hashtbl.create 16 in
  let datas = Hashtbl.create 16 in
  let check_unbound tbl kind id =
    let>@ id : Ast.Text.name = id in
    if Hashtbl.mem tbl id.desc then
      Error.index_already_bound ctx.diagnostics ~location:id.info kind id
    else Hashtbl.add tbl id.desc ()
  in
  let rec iter_instrs f instrs =
    List.iter
      (fun i ->
        f i.Ast.desc;
        match i.Ast.desc with
        | Ast.Text.Block { block; _ }
        | Ast.Text.Loop { block; _ }
        | Ast.Text.TryTable { block; _ } ->
            iter_instrs f block
        | Ast.Text.If { if_block; else_block; _ } ->
            iter_instrs f if_block.desc;
            iter_instrs f else_block.desc
        | Ast.Text.Try { block; catches; catch_all; _ } ->
            iter_instrs f block;
            List.iter (fun (_, c) -> iter_instrs f c) catches;
            Option.iter (iter_instrs f) catch_all
        | Ast.Text.Folded (instr, instrs') -> iter_instrs f (instr :: instrs')
        | _ -> ())
      instrs
  in
  (* An inline type annotation [(type idx) (param ...) (result ...)] must name a
     function type whose signature equals the inline one. *)
  let check_inline_type idx target =
    let>@ gidx = resolve_type_index ctx.diagnostics ctx.types idx in
    match (Types.get_subtype ctx.subtyping_info gidx).typ with
    | Func f -> (
        match functype ctx.diagnostics ctx.types target with
        | Some f' ->
            if f <> f' then
              Error.inline_function_type_mismatch ctx.diagnostics
                ~location:idx.Ast.info f
        | None -> ())
    | Struct _ | Array _ | Cont _ ->
        Error.expected_func_type ctx.diagnostics ~location:idx.Ast.info idx
  in
  let check_instr_inline desc =
    let check_typeuse = function
      | Ast.Text.Typeuse (Some idx, Some ft) -> check_inline_type idx ft
      | _ -> ()
    in
    match desc with
    | Ast.Text.Block { typ = Some t; _ }
    | Ast.Text.Loop { typ = Some t; _ }
    | Ast.Text.If { typ = Some t; _ }
    | Ast.Text.Try { typ = Some t; _ }
    | Ast.Text.TryTable { typ = Some t; _ } ->
        check_typeuse t
    | CallIndirect (_, (Some idx, Some ft)) -> check_inline_type idx ft
    | ReturnCallIndirect (_, (Some idx, Some ft)) -> check_inline_type idx ft
    | _ -> ()
  in
  let check_duplicate_locals typ locals =
    let param_ids =
      match snd typ with
      | Some { Ast.Text.params; _ } ->
          Array.to_list (Array.map (fun p -> fst p.Ast.desc) params)
      | None -> []
    in
    let local_ids = List.map (fun e -> fst e.Ast.desc) locals in
    let seen = Hashtbl.create 16 in
    List.iter
      (fun id ->
        let*? id : Ast.Text.name = id in
        if Hashtbl.mem seen id.desc then
          Error.duplicate_local ctx.diagnostics ~location:id.Ast.info id.desc
        else Hashtbl.add seen id.desc ())
      (param_ids @ local_ids)
  in
  List.iter
    (fun (field : (_ Ast.Text.modulefield, _) Ast.annotated) ->
      match field.desc with
      | Types lst ->
          Array.iter
            (fun e ->
              check_unbound types "type" (fst e.Ast.desc);
              match (snd e.Ast.desc).Ast.Text.typ with
              | Ast.Text.Types.Func _ | Array _ | Cont _ -> ()
              | Struct lst ->
                  let fields = Hashtbl.create 16 in
                  Array.iter
                    (fun e -> check_unbound fields "field" (fst e.Ast.desc))
                    lst)
            lst
      | Import { id; desc; _ } -> (
          let tbl, kind =
            match desc with
            | Func _ -> (functions, "function")
            | Memory _ -> (memories, "memory")
            | Table _ -> (tables, "table")
            | Global _ -> (globals, "global")
            | Tag _ -> (tags, "tag")
          in
          check_unbound tbl kind id;
          match desc with
          | Func { typ = Some idx, Some sign; _ } -> check_inline_type idx sign
          | Tag (Some idx, Some sign) -> check_inline_type idx sign
          | _ -> ())
      | Func { id; typ; locals; instrs; _ } ->
          check_unbound functions "function" id;
          (match typ with
          | Some idx, Some sign -> check_inline_type idx sign
          | _ -> ());
          check_duplicate_locals typ locals;
          iter_instrs check_instr_inline instrs
      | Memory { id; _ } -> check_unbound memories "memory" id
      | Table { id; _ } -> check_unbound tables "table" id
      | Tag { id; typ = Some idx, Some sign; _ } ->
          check_unbound tags "tag" id;
          check_inline_type idx sign
      | Tag { id; _ } -> check_unbound tags "tag" id
      | Global { id; _ } -> check_unbound globals "global" id
      | Export _ | Start _ -> ()
      | Elem { id; _ } -> check_unbound elems "elem" id
      | Data { id; _ } -> check_unbound datas "data" id
      | String_global { id; _ } -> check_unbound globals "global" (Some id)
      | Module_if_annotation _ -> ())
    lst;
  match
    List.filter
      (fun field ->
        match field.Ast.desc with Ast.Text.Start _ -> true | _ -> false)
      lst
  with
  | _ :: second :: _ ->
      Error.multiple_start ctx.diagnostics ~location:second.Ast.info
  | _ -> ()

let validate_configuration ?(warn_unused = true)
    ?(features = Wax_utils.Feature.default ()) diagnostics (_, fields) =
  let type_context =
    {
      types = Types.create ();
      last_index = 0;
      index_mapping = Hashtbl.create 16;
      label_mapping = Hashtbl.create 16;
      type_defs = Hashtbl.create 16;
      descriptor_source = Hashtbl.create 16;
      features;
    }
  in
  List.iter
    (fun (field : (_ Ast.Text.modulefield, _) Ast.annotated) ->
      match field.desc with
      | Types rectype -> add_type diagnostics type_context rectype
      | _ -> ())
    fields;
  collect_implicit_types diagnostics type_context fields;
  (* Register the implicit [<string>] array type ([mut i8]) up front, so that
     validating an unnamed [@string] — which looks the type up via [string_type]
     ([add_rectype], idempotent) — gets an index within [subtyping_info] instead
     of one appended past the snapshot taken here. *)
  ignore (string_type type_context : int);
  let ctx =
    {
      diagnostics;
      types = type_context;
      subtyping_info = Types.subtyping_info type_context.types;
      functions = Sequence.make "function";
      memories = Sequence.make "memory";
      tables = Sequence.make "table";
      globals = Sequence.make "global";
      tags = Sequence.make "tag";
      data = Sequence.make "data segment";
      elem = Sequence.make "elem segment";
      exports = Hashtbl.create 16;
      refs = Hashtbl.create 16;
    }
  in
  check_type_definitions ctx;
  build_initial_env ctx fields;
  let ctx =
    { ctx with subtyping_info = Types.subtyping_info type_context.types }
  in
  check_syntax ctx fields;
  tables_and_memories ctx fields;
  globals ctx fields;
  segments ctx fields;
  declared_func_exports ctx fields;
  functions ~warn_unused ctx fields;
  exports ctx fields;
  start ctx fields

(* Path-sensitive validation of conditional annotations.

   A module containing [(@if ...)] conditionals denotes one concrete module per
   "configuration" (a choice of branch at every reachable conditional). We
   explore every reachable configuration (via {!Cond_explore.check_all}),
   specializing the module for each — splicing in the selected branches to obtain
   a conditional-free module — validating it with {!validate_configuration}, and
   reporting each distinct error once, annotated with the minimal assumption
   under which it occurs. *)

(*** Conditional compilation and entry point ***)

let rec instr_has_conditional (i : _ Ast.Text.instr) =
  match i.desc with
  | If_annotation _ -> true
  | Block { block; _ } | Loop { block; _ } | TryTable { block; _ } ->
      List.exists instr_has_conditional block
  | If { if_block; else_block; _ } ->
      List.exists instr_has_conditional if_block.desc
      || List.exists instr_has_conditional else_block.desc
  | Try { block; catches; catch_all; _ } ->
      List.exists instr_has_conditional block
      || List.exists (fun (_, l) -> List.exists instr_has_conditional l) catches
      || Option.fold ~none:false
           ~some:(List.exists instr_has_conditional)
           catch_all
  | Folded (h, l) ->
      instr_has_conditional h || List.exists instr_has_conditional l
  | _ -> false

let field_has_conditional (f : (_ Ast.Text.modulefield, _) Ast.annotated) =
  match f.desc with
  | Module_if_annotation _ -> true
  | Func { instrs; _ } -> List.exists instr_has_conditional instrs
  | Global { init; _ } -> List.exists instr_has_conditional init
  | Elem { init; _ } -> List.exists (List.exists instr_has_conditional) init
  | Table { init; _ } -> (
      match init with
      | Init_default -> false
      | Init_expr e -> List.exists instr_has_conditional e
      | Init_segment segs ->
          List.exists (List.exists instr_has_conditional) segs)
  | _ -> false

(* Specialize a module for one configuration: resolve every conditional using
   the assumption [asm], splicing in the selected branch. Undetermined
   conditionals select [@then] and [enqueue] the [@else] configuration; each
   selected branch literal is passed to [record] to build the configuration's
   full assumption. *)
let specialize env diagnostics ~enqueue ~record asm0 fields =
  (* Resolve one conditional and return both the specialized branch and the
     assumption that holds afterwards. Each branch is taken only if it is
     reachable under [asm] (its conjunction with the branch condition is
     satisfiable); an unreachable branch is pruned, so we never explore an
     infeasible configuration. The surviving assumption is threaded into the
     following siblings, so e.g. once [cond1] forces [$wasi], a sibling
     [(@if (not $wasi) …)] has its [@then] pruned. *)
  let choose asm cond ~location ~then_branch ~else_branch =
    let c = Cond_solver.of_cond env diagnostics ~location cond in
    let then_asm = Cond_solver.and_ asm c
    and else_asm = Cond_solver.and_ asm (Cond_solver.not_ c) in
    if not (Cond_solver.is_satisfiable then_asm) then (
      record (Cond_solver.not_ c);
      (else_branch else_asm, else_asm))
    else if not (Cond_solver.is_satisfiable else_asm) then (
      record c;
      (then_branch then_asm, then_asm))
    else (
      enqueue else_asm;
      record c;
      (then_branch then_asm, then_asm))
  in
  let rec sfields asm fl =
    match fl with
    | [] -> []
    | f :: rest ->
        let fields, asm = sfield asm f in
        fields @ sfields asm rest
  and sfield asm (f : (_ Ast.Text.modulefield, _) Ast.annotated) =
    match f.desc with
    | Module_if_annotation { cond; then_fields; else_fields } ->
        choose asm cond ~location:f.info
          ~then_branch:(fun asm' -> sfields asm' then_fields)
          ~else_branch:(fun asm' ->
            match else_fields with Some e -> sfields asm' e | None -> [])
    | Func { id; typ; locals; instrs; exports } ->
        let desc : _ Ast.Text.modulefield =
          Func { id; typ; locals; instrs = sinstrs asm instrs; exports }
        in
        ([ { f with desc } ], asm)
    | Global { id; typ; init; exports } ->
        let desc : _ Ast.Text.modulefield =
          Global { id; typ; init = sinstrs asm init; exports }
        in
        ([ { f with desc } ], asm)
    | Table { id; typ; init; exports } ->
        let init : _ Ast.Text.tableinit =
          match init with
          | Init_default -> Init_default
          | Init_expr e -> Init_expr (sinstrs asm e)
          | Init_segment segs -> Init_segment (List.map (sinstrs asm) segs)
        in
        let desc : _ Ast.Text.modulefield = Table { id; typ; init; exports } in
        ([ { f with desc } ], asm)
    | Elem { id; typ; init; mode } ->
        let desc : _ Ast.Text.modulefield =
          Elem { id; typ; init = List.map (sinstrs asm) init; mode }
        in
        ([ { f with desc } ], asm)
    | _ -> ([ f ], asm)
  and sinstrs asm l =
    match l with
    | [] -> []
    | i :: rest ->
        let instrs, asm = sinstr asm i in
        instrs @ sinstrs asm rest
  and sinstr asm (i : _ Ast.Text.instr) =
    match i.desc with
    | If_annotation { cond; then_body; else_body } ->
        choose asm cond ~location:i.info
          ~then_branch:(fun asm' -> sinstrs asm' then_body)
          ~else_branch:(fun asm' ->
            match else_body with Some e -> sinstrs asm' e | None -> [])
    | desc -> ([ { i with desc = sstructured asm desc } ], asm)
  and sstructured asm (desc : _ Ast.Text.instr_desc) =
    match desc with
    | Block b -> Block { b with block = sinstrs asm b.block }
    | Loop b -> Loop { b with block = sinstrs asm b.block }
    | If b ->
        If
          {
            b with
            if_block = { b.if_block with desc = sinstrs asm b.if_block.desc };
            else_block =
              { b.else_block with desc = sinstrs asm b.else_block.desc };
          }
    | TryTable b -> TryTable { b with block = sinstrs asm b.block }
    | Try b ->
        Try
          {
            b with
            block = sinstrs asm b.block;
            catches = List.map (fun (idx, l) -> (idx, sinstrs asm l)) b.catches;
            catch_all = Option.map (sinstrs asm) b.catch_all;
          }
    | Folded (h, l) ->
        Folded ({ h with desc = sstructured asm h.desc }, sinstrs asm l)
    | desc -> desc
  in
  sfields asm0 fields

(* WebAssembly requires every import to precede all non-import definitions
   (functions, tables, memories, globals, tags). Report any import that follows
   such a definition. *)
let check_import_order diagnostics fields =
  ignore
    (List.fold_left
       (fun can_import (field : (_ Ast.Text.modulefield, _) Ast.annotated) ->
         match (can_import, field.desc) with
         | Some previous, Import _ ->
             Error.import_after_definition diagnostics ~location:field.info
               previous;
             can_import
         | None, Func _ -> Some "function"
         | None, Memory _ -> Some "memory"
         | None, Table _ -> Some "table"
         | None, Tag _ -> Some "tag"
         | None, Global _ -> Some "global"
         | None, String_global _ -> Some "string"
         | ( Some _,
             (Func _ | Memory _ | Table _ | Tag _ | Global _ | String_global _)
           )
         | None, Import _
         | ( _,
             ( Types _ | Export _ | Start _ | Elem _ | Data _
             | Module_if_annotation _ ) ) ->
             can_import)
       None fields)

let f ?(warn_unused = true) ?(features = Wax_utils.Feature.default ())
    diagnostics ((name, fields) as modul) =
  Wax_utils.Debug.timed "validate" @@ fun () ->
  check_import_order diagnostics fields;
  if not (List.exists field_has_conditional fields) then
    validate_configuration ~warn_unused ~features diagnostics modul
  else
    Cond_explore.check_all diagnostics
      ?truncation_location:
        (match fields with f :: _ -> Some f.Ast.info | [] -> None)
      ~specialize:(fun env asm ~enqueue ~record ->
        (name, specialize env diagnostics ~enqueue ~record asm fields))
      ~check:(validate_configuration ~warn_unused ~features)
      ()

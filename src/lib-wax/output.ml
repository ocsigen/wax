(*ZZZZ
Should use string_as for comments
*)

open Wax_utils.Colors
open Ast

let indent_level = 4

(* Target line width for Wax output, matching the Rust Style Guide's default
   ([max_width = 100]); WebAssembly text output keeps the printer's own default.
   Passed at every [Printer.run] that renders a Wax module to a real
   formatter. *)
let width = 100

(*** Printer primitives ***)

let get_theme use_color =
  if use_color then
    {
      keyword = Ansi.bold ^ Ansi.magenta;
      operator = Ansi.bold ^ Ansi.white;
      annotation = Ansi.blue;
      attribute = Ansi.magenta;
      type_ = Ansi.cyan;
      identifier = Ansi.yellow;
      constant = Ansi.bold ^ Ansi.blue;
      string = Ansi.green;
      comment = Ansi.grey;
      punctuation = Ansi.white;
      instruction = "";
      reset = Ansi.reset;
    }
  else no_color

type 'info ctx = {
  base : Wax_utils.Styled_printer.t;
  (* Extract a source location from a node's annotation, to look its trivia up.
     [fun _ -> None] when printing typed ASTs for diagnostics (no trivia). *)
  locate : 'info -> location option;
}

let print_styled pp style ?(len = None) text =
  Wax_utils.Styled_printer.print_styled pp.base style ~len text

let box pp ?indent f = Wax_utils.Printer.box pp.base.printer ?indent f
let hvbox pp ?indent f = Wax_utils.Printer.hvbox pp.base.printer ?indent f
let hbox pp f = Wax_utils.Printer.hbox pp.base.printer f
let indent pp i f = Wax_utils.Printer.indent pp.base.printer i f
let space pp () = Wax_utils.Printer.space pp.base.printer ()
let cut pp () = Wax_utils.Printer.cut pp.base.printer ()
let newline pp () = Wax_utils.Printer.newline pp.base.printer ()
let punctuation pp s = print_styled pp Punctuation s
let operator pp s = print_styled pp Operator s

(* A declaration terminator [;], held past a deferred trailing comment so it
   sits before the comment ([const x = v; // c]) rather than dangling on its own
   line after it — as the block-statement [;] and list [,] separators already
   do. *)
let semicolon pp =
  Wax_utils.Printer.with_held_eol pp.base.printer (fun () -> punctuation pp ";")

let identifier pp s =
  print_styled pp Identifier ~len:(Some (Wax_utils.Unicode.terminal_width s)) s

let constant pp s = print_styled pp Constant s
let keyword pp s = print_styled pp Keyword s
let type_ pp s = print_styled pp Type s
let string pp ?len s = print_styled pp String ?len s
let attribute pp s = print_styled pp Attribute s

(* Branch-hinting proposal: the [#[likely]]/[#[unlikely]] prefix on a hinted
   conditional branch. *)
let branch_hint_attr pp likely =
  attribute pp (if likely then "#[likely]" else "#[unlikely]");
  space pp ()

(* Comment preservation: emit the trivia (comments, blank lines) the lexer
   collected, looked up by AST-node location. The rendering logic is shared with
   the WebAssembly printer in [Wax_utils.Trivia]. *)

let print_trivia pp lst = Wax_utils.Styled_printer.print_trivia pp.base lst

let get_trivia pp (loc : location option) =
  Wax_utils.Styled_printer.get_trivia pp.base loc

let atomic_node pp (loc : location option) f =
  Wax_utils.Styled_printer.atomic_node pp.base loc f

let with_style ctx style f =
  Wax_utils.Styled_printer.with_style ctx.base style f

let list ?(sep = space) f pp l =
  match l with
  | [] -> ()
  | [ x ] -> f pp x
  | x :: xs ->
      f pp x;
      List.iter
        (fun x ->
          sep pp ();
          f pp x)
        xs

let list_commasep f pp l =
  list
    ~sep:(fun pp () ->
      (* Hold any deferred trailing comment so the comma prints on the comment's
         line, ahead of it. *)
      Wax_utils.Printer.with_held_eol pp.base.printer (fun () ->
          punctuation pp ",");
      space pp ())
    f pp l

(* A trailing comma after the last element of [l], emitted only when the
   enclosing box wraps across lines (rustfmt style). Skipped when the last
   element carries a trailing comment: a comma there would push the comment off
   the element and change where it re-attaches on a reparse (breaking
   idempotence), so the comment-less last element keeps its layout. *)
let trailing_comma pp l =
  if l <> [] && not (Wax_utils.Printer.has_pending_eol pp.base.printer) then
    Wax_utils.Printer.if_broken pp.base.printer (fun () -> punctuation pp ",")

let list_commasep_trailing f pp l =
  list_commasep f pp l;
  trailing_comma pp l

let print_paren_list f pp l =
  punctuation pp "(";
  box pp (fun () -> list_commasep f pp l);
  punctuation pp ")"

(* A Rust-style parenthesised list: it stays on one line if it fits, otherwise
   [(] keeps the preceding token company and the elements break one per line,
   indented one level, with the closing [)] back at the opening column — never
   the Lisp-like [(] on its own line. The caller's enclosing [hvbox] makes the
   choice all-or-nothing. *)
let print_arg_list f pp l =
  punctuation pp "(";
  (match l with
  | [] -> ()
  | _ ->
      indent pp indent_level (fun () ->
          cut pp ();
          list_commasep_trailing f pp l);
      cut pp ());
  punctuation pp ")"

(*** Type printing ***)

let heaptype pp (t : heaptype) =
  match heaptype_keyword t with
  | Some kw -> type_ pp kw
  | None -> (
      match t with Type s | Exact s -> type_ pp s.desc | _ -> assert false)

let reftype pp { nullable; typ } =
  (* The [!] exact marker sits between the [&]/[&?] sigil and the type name. *)
  punctuation pp
    (match (nullable, typ) with
    | true, Exact _ -> "&?!"
    | false, Exact _ -> "&!"
    | true, _ -> "&?"
    | false, _ -> "&");
  heaptype pp typ

let rec valtype pp t =
  match t with
  | I32 -> type_ pp "i32"
  | I64 -> type_ pp "i64"
  | F32 -> type_ pp "f32"
  | F64 -> type_ pp "f64"
  | V128 -> type_ pp "v128"
  | Ref t -> reftype pp t

and tuple always_paren pp l =
  match l with
  | [ t ] when not always_paren -> valtype pp t
  | _ -> print_paren_list valtype pp l

let simple_pat pp p =
  match p with
  | Some x ->
      (* Anchor at the identifier's own location, so a comment trailing the name
         (e.g. before a parameter's [: type]) attaches to it. *)
      atomic_node pp (Some x.info) (fun () -> identifier pp x.desc)
  | None -> operator pp "_"

let print_key_value pp key val_printer value =
  box pp ~indent:indent_level (fun () ->
      identifier pp key;
      punctuation pp ":";
      space pp ();
      val_printer pp value)

let print_typed_pat pp (pat, opt_typ) =
  box pp ~indent:indent_level (fun () ->
      simple_pat pp pat;
      Option.iter
        (fun t ->
          punctuation pp ":";
          space pp ();
          valtype pp t)
        opt_typ)

let raw_functype pp { params; results } =
  print_arg_list
    (fun pp p ->
      let id, t = p.desc in
      (* Anchor trivia at the whole parameter, so a trailing comment attaches to
         it — named or not. *)
      atomic_node pp (Some p.info) (fun () ->
          match id with
          | None -> valtype pp t
          | Some _ -> print_typed_pat pp (id, Some t)))
    pp (Array.to_list params);
  if results <> [||] then
    (* Keep [-> Ret] glued to the closing [)] so the parameter list, not the
       arrow, is what breaks when the signature overflows. *)
    hbox pp (fun () ->
        space pp ();
        operator pp "->";
        space pp ();
        tuple false pp (Array.to_list results))

let functype pp ty =
  box pp ~indent:indent_level (fun () ->
      keyword pp "fn";
      raw_functype pp ty)

let blocktype pp typ =
  match typ with
  | { params = [||]; results = [| ty |] } -> valtype pp ty
  | _ -> box pp ~indent:indent_level (fun () -> raw_functype pp typ)

let packedtype pp t = type_ pp (match t with I8 -> "i8" | I16 -> "i16")

let storagetype pp t =
  match t with Value t -> valtype pp t | Packed t -> packedtype pp t

let muttype t pp { mut; typ } =
  if mut then
    box pp ~indent:indent_level (fun () ->
        keyword pp "mut";
        space pp ();
        t pp typ)
  else t pp typ

let fieldtype = muttype storagetype

let comptype pp (t : comptype) =
  match t with
  | Func t -> functype pp t
  | Struct l ->
      (* The opening brace is printed in [subtype] *)
      indent pp indent_level (fun () ->
          space pp ();
          list_commasep
            (fun pp field ->
              (* A leading [..] inherits the supertype's fields; the parser puts
                 it first, so it prints as the first comma-separated item. *)
              if Ast.is_splice_field field then punctuation pp ".."
              else
                let nm, t = field.desc in
                (* Look the field's trivia up by its own location, so a trailing
                   comment attaches to the whole field. *)
                atomic_node pp (Some field.info) (fun () ->
                    print_key_value pp nm.desc fieldtype t))
            pp (Array.to_list l));
      space pp ();
      punctuation pp "}"
  | Array t ->
      punctuation pp "[";
      box pp (fun () -> fieldtype pp t);
      punctuation pp "]"
  | Cont s ->
      type_ pp "cont";
      space pp ();
      type_ pp s.desc

let subtype pp field =
  let nm, { typ; supertype; final; descriptor; describes } = field.desc in
  atomic_node pp (Some field.info) @@ fun () ->
  hvbox pp (fun () ->
      let is_struct = match typ with Struct _ -> true | _ -> false in
      box pp (fun () ->
          keyword pp "type";
          space pp ();
          identifier pp nm.desc;
          (match supertype with
          | Some supertype ->
              punctuation pp ":";
              space pp ();
              identifier pp supertype.desc
          | None -> ());
          space pp ();
          punctuation pp "=";
          if not final then (
            space pp ();
            keyword pp "open");
          (* custom-descriptors clauses, between [open] and the body. *)
          let clause kw = function
            | Some (id : ident) ->
                space pp ();
                keyword pp kw;
                space pp ();
                identifier pp id.desc
            | None -> ()
          in
          clause "describes" describes;
          clause "descriptor" descriptor;
          if is_struct then (
            space pp ();
            punctuation pp "{"));
      space pp ();
      comptype pp typ;
      punctuation pp ";")

let rectype pp t =
  match Array.to_list t with
  | [ t ] -> subtype pp t
  | l ->
      hvbox pp (fun () ->
          box pp (fun () ->
              keyword pp "rec";
              space pp ();
              punctuation pp "{");
          indent pp indent_level (fun () ->
              space pp ();
              list ~sep:space subtype pp l);
          space pp ();
          punctuation pp "}")

(*** Operators and precedence ***)

let binop op =
  match op with
  | Add -> "+"
  | Sub -> "-"
  | Mul -> "*"
  | Div None -> "/"
  | Div (Some Signed) -> "/s"
  | Div (Some Unsigned) -> "/u"
  | Rem Signed -> "%s"
  | Rem Unsigned -> "%u"
  | And -> "&"
  | Or -> "|"
  | Xor -> "^"
  | Shl -> "<<"
  | Shr Signed -> ">>s"
  | Shr Unsigned -> ">>u"
  | Eq -> "=="
  | Ne -> "!="
  | Lt None -> "<"
  | Lt (Some Signed) -> "<s"
  | Lt (Some Unsigned) -> "<u"
  | Gt None -> ">"
  | Gt (Some Signed) -> ">s"
  | Gt (Some Unsigned) -> ">u"
  | Le None -> "<="
  | Le (Some Signed) -> "<=s"
  | Le (Some Unsigned) -> "<=u"
  | Ge None -> ">="
  | Ge (Some Signed) -> ">=s"
  | Ge (Some Unsigned) -> ">=u"

let unop op = match op with Neg -> "-" | Pos -> "+" | Not -> "!"

type prec =
  | Instruction
  | Branch
  | Assignement
  | Select
  | Comparison
  | LogicalOr
  | LogicalXor
  | LogicalAnd
  | Shift
  | Addition
  | Multiplication
  | Cast
  | UnaryPrefix
  | UnaryPostfix
  | CallAndFieldAccess
  | Atom

let parentheses expected actual pp g =
  if expected > actual then (
    punctuation pp "(";
    box pp (fun () ->
        g ();
        (* Hold the closing [)] past a trailing comment on the last inner token,
           so it hugs the expression ([(c == 108) // 'l']) instead of being
           pushed onto its own line after the comment — as [;] and [,] do. *)
        Wax_utils.Printer.with_held_eol pp.base.printer (fun () ->
            punctuation pp ")")))
  else g ()

let prec_op op =
  (* out, left, right *)
  match op with
  | Add | Sub -> (Addition, Addition, Multiplication)
  | Mul | Div _ | Rem _ -> (Multiplication, Multiplication, Cast)
  | And -> (LogicalAnd, LogicalAnd, Shift)
  | Or -> (LogicalOr, LogicalOr, LogicalXor)
  | Xor -> (LogicalXor, LogicalXor, LogicalAnd)
  | Shl | Shr _ -> (Shift, Shift, Addition)
  | Gt _ | Lt _ | Ge _ | Le _ | Eq | Ne -> (Comparison, LogicalOr, LogicalOr)

(*** Instruction-printing helpers ***)

let block_label pp label =
  Option.iter
    (fun label ->
      identifier pp "'";
      identifier pp label.desc;
      punctuation pp ":";
      space pp ())
    label

let need_blocktype bt = bt.params <> [||] || bt.results <> [||]

let casttype pp ty =
  match ty with
  | Valtype ty -> valtype pp ty
  | Functype { nullable; sign } ->
      punctuation pp (if nullable then "&?" else "&");
      functype pp sign
  | Signedtype { typ; signage; strict } ->
      type_ pp (Ast.format_signed_type typ signage strict)

let branch_instr instr pp name label i =
  box pp ~indent:indent_level (fun () ->
      keyword pp name;
      space pp ();
      identifier pp "'";
      identifier pp label.desc;
      Option.iter
        (fun i ->
          space pp ();
          instr Branch pp i)
        i)

let branch_ref_instr instr pp name label ty i =
  box pp ~indent:indent_level (fun () ->
      keyword pp name;
      space pp ();
      identifier pp "'";
      identifier pp label.desc;
      space pp ();
      reftype pp ty;
      space pp ();
      instr Branch pp i)

(* [ [?]descriptor(d) ] — the target-spec of the custom-descriptors instructions
   ([ref.cast_desc_eq], [br_on_cast_desc_eq], [struct.new_desc]). The target type
   is recovered from [d]'s descriptor type, so only the operand is written; a
   leading [?] marks a nullable result. The [( )] delimit [d] so it may be any
   expression with no precedence clash. *)
let descriptor_operand instr pp ?(nullable = false) d =
  if nullable then punctuation pp "?";
  keyword pp "descriptor";
  punctuation pp "(";
  box pp (fun () -> instr Instruction pp d);
  punctuation pp ")"

(* As [branch_ref_instr], for the custom-descriptors [br_on_cast_desc_eq] /
   [_fail]: the [[?]descriptor(d)] target-spec precedes the value, so the value
   is the sole trailing operand and prints at [Branch] like the plain form. *)
let branch_ref_desc_instr instr pp name label nullable i d =
  box pp ~indent:indent_level (fun () ->
      keyword pp name;
      space pp ();
      identifier pp "'";
      identifier pp label.desc;
      space pp ();
      descriptor_operand instr pp ~nullable d;
      space pp ();
      instr Branch pp i)

let call_instr instr pp ?prefix i l =
  hvbox pp (fun () ->
      (* Keep an optional prefix ([become]/[return]) and the callee glued to the
         opening [(]: only the argument list may break. *)
      hbox pp (fun () ->
          Option.iter
            (fun s ->
              keyword pp s;
              space pp ())
            prefix;
          instr CallAndFieldAccess pp i);
      print_arg_list (instr Instruction) pp l)

let print_on_clauses pp handlers =
  punctuation pp "[";
  box pp (fun () ->
      list_commasep
        (fun pp clause ->
          match clause with
          | OnLabel (tag, label) ->
              identifier pp tag.desc;
              space pp ();
              punctuation pp "->";
              space pp ();
              identifier pp "'";
              identifier pp label.desc
          | OnSwitch tag ->
              identifier pp tag.desc;
              space pp ();
              punctuation pp "->";
              space pp ();
              keyword pp "switch")
        pp handlers);
  punctuation pp "]"

let print_container pp ~opening ~closing ?(indent = 0) opt_type f =
  hvbox pp ~indent (fun () ->
      box pp (fun () ->
          punctuation pp opening;
          Option.iter
            (fun t ->
              identifier pp t.desc;
              punctuation pp "|")
            opt_type);
      f ();
      punctuation pp closing)

let struct_instr pp nm f =
  print_container pp ~opening:"{" ~closing:"}" ~indent:0 nm (fun () ->
      indent pp indent_level (fun () ->
          space pp ();
          f ());
      space pp ())

(* As [struct_instr] but with a leading [descriptor(d)] target-spec instead of a
   type name (the custom-descriptors [struct.new_desc] / [struct.new_default_desc];
   the struct type is recovered from [d]). [print_desc] renders the operand. *)
let struct_desc_instr pp print_desc f =
  hvbox pp ~indent:0 (fun () ->
      box pp (fun () ->
          punctuation pp "{";
          space pp ();
          print_desc ();
          punctuation pp "|");
      indent pp indent_level (fun () ->
          space pp ();
          f ());
      space pp ();
      punctuation pp "}")

let array_instr pp nm f =
  (* Indent the elements one level and break before the closing [\]] at the
     array's own column (like [struct_instr]), so a wrapped array reads
     [\[t|]/elem,/.../elem,/]\]] with [\]] dedented — not hugging the last
     element as [elem,\]]. *)
  print_container pp ~opening:"[" ~closing:"]" ~indent:0 nm (fun () ->
      indent pp indent_level (fun () ->
          cut pp ();
          f ());
      cut pp ())

let rec get_prec (i : _ Ast.instr) =
  match i.desc with
  (* Branch-hinting proposal: the hint is a transparent prefix; the wrapped
     branch drives precedence, block-ness, and layout. *)
  | Hinted (_, i) -> get_prec i
  | Block _ | Loop _ | While _ | If _ | Try _ | TryTable _ | If_annotation _
  | Dispatch _ | Match _ ->
      Atom
  | Unreachable | Nop | Hole | Null | Get _ | Path _ | Char _ | String _ | Int _
  | Float _ | Struct _ | StructDefault _ | StructDesc _ | StructDefaultDesc _
  | Array _ | ArrayDefault _ | ArrayFixed _ | ArraySegment _ | ArrayGet _
  | ArraySet _ | Sequence _ ->
      Atom
  | Set _ | Tee _ -> Assignement
  | Call _ | TailCall _ -> CallAndFieldAccess
  | ContNew _ | ContBind _ | Suspend _ | Resume _ | ResumeThrow _
  | ResumeThrowRef _ | Switch _ ->
      CallAndFieldAccess
  | Cast _ | CastDesc _ | Test _ -> Cast
  | NonNull _ -> UnaryPostfix
  | UnOp _ -> UnaryPrefix
  | StructGet _ | StructSet _ | GetDescriptor _ -> CallAndFieldAccess
  | BinOp (op, _, _) ->
      let out, _, _ = prec_op op.desc in
      out
  | Let _ -> Instruction
  | Br _ | Br_if _ | Br_table _ | Br_on_null _ | Br_on_non_null _ | Br_on_cast _
  | Br_on_cast_fail _ | Br_on_cast_desc_eq _ | Br_on_cast_desc_eq_fail _
  | Throw _ | ThrowRef _ | Return _ ->
      Branch
  | Select _ -> Select

let rec is_block (i : _ Ast.instr) =
  match i.desc with
  | Hinted (_, i) -> is_block i
  | Block _ | Loop _ | While _ | If _ | Try _ | TryTable _ | If_annotation _
  | Dispatch _ | Match _ ->
      true
  | Call _ | Unreachable | Nop | Hole | Null | Get _ | Path _ | Set _ | Tee _
  | TailCall _ | Char _ | String _ | Int _ | Float _ | Cast _ | CastDesc _
  | Test _ | NonNull _ | Struct _ | StructDefault _ | StructDesc _
  | StructDefaultDesc _ | StructGet _ | GetDescriptor _ | StructSet _ | Array _
  | ArrayDefault _ | ArrayFixed _ | ArraySegment _ | ArrayGet _ | ArraySet _
  | BinOp _ | UnOp _ | Let _ | Br _ | Br_if _ | Br_table _ | Br_on_null _
  | Br_on_non_null _ | Br_on_cast _ | Br_on_cast_fail _ | Br_on_cast_desc_eq _
  | Br_on_cast_desc_eq_fail _ | Throw _ | ThrowRef _ | ContNew _ | ContBind _
  | Suspend _ | Resume _ | ResumeThrow _ | ResumeThrowRef _ | Switch _
  | Return _ | Sequence _ | Select _ ->
      false

let rec starts_with_block_prec prec (i : 'a Ast.instr) =
  let actual = get_prec i in
  if prec > actual then false
  else
    match i.desc with
    | Hinted (_, i) -> starts_with_block_prec prec i
    | Block _ | Loop _ | While _ | If _ | Try _ | TryTable _ | If_annotation _
    | Dispatch _ | Match _ ->
        true
    | Call (i, _) | ArrayGet (i, _) | ArraySet (i, _, _) ->
        starts_with_block_prec CallAndFieldAccess i
    | Cast (i, _) | CastDesc (i, _, _) | Test (i, _) ->
        starts_with_block_prec Cast i
    | NonNull i -> starts_with_block_prec UnaryPostfix i
    | UnOp (_, i) -> starts_with_block_prec UnaryPrefix i
    | StructGet (i, _) | StructSet (i, _, _) | GetDescriptor i ->
        starts_with_block_prec CallAndFieldAccess i
    | BinOp (op, i, _) ->
        let _, left, _ = prec_op op.desc in
        starts_with_block_prec left i
    | Select (i, _, _) -> starts_with_block_prec Select i
    | Unreachable | Nop | Hole | Null | Get _ | Path _ | Set _ | Tee _
    | TailCall _ | Char _ | String _ | Int _ | Float _ | Struct _
    | StructDefault _ | StructDesc _ | StructDefaultDesc _ | Array _
    | ArrayDefault _ | ArrayFixed _ | ArraySegment _ | Let _ | Br _ | Br_if _
    | Br_table _ | Br_on_null _ | Br_on_non_null _ | Br_on_cast _
    | Br_on_cast_fail _ | Br_on_cast_desc_eq _ | Br_on_cast_desc_eq_fail _
    | Throw _ | ThrowRef _ | ContNew _ | ContBind _ | Suspend _ | Resume _
    | ResumeThrow _ | ResumeThrowRef _ | Switch _ | Return _ | Sequence _ ->
        false

let starts_with_block i = starts_with_block_prec Instruction i

let array_element_precedence nm first i =
  if nm = None && first then
    match i.desc with
    | BinOp ({ desc = Or; _ }, { desc = Get _; _ }, _) -> Atom
    | _ -> Instruction
  else Instruction

let cond_op_string (op : Wax_wasm.Ast.cmp_op) =
  match op with
  | Eq -> "="
  | Ne -> "!="
  | Lt -> "<"
  | Gt -> ">"
  | Le -> "<="
  | Ge -> ">="

let rec cond_to_string (c : Wax_wasm.Ast.cond) =
  match c with
  | Cond_var v -> v.desc
  | Cond_string s -> Printf.sprintf "%S" s.desc
  | Cond_version (a, b, c) -> Printf.sprintf "(%d, %d, %d)" a b c
  | Cond_cmp (op, a, b) ->
      Printf.sprintf "%s %s %s" (cond_to_string a) (cond_op_string op)
        (cond_to_string b)
  | Cond_and l -> Printf.sprintf "all(%s)" (cond_list l)
  | Cond_or l -> Printf.sprintf "any(%s)" (cond_list l)
  | Cond_not c -> Printf.sprintf "not(%s)" (cond_to_string c)

and cond_list l = String.concat ", " (List.map cond_to_string l)

(* The space-separated case labels of a [br_table]/[dispatch] bracket, ending in
   [else <default>]; printed inside a fill box so they pack and wrap. *)
let label_seq pp cases default =
  (match cases with
  | [] -> ()
  | first :: rest ->
      identifier pp "'";
      identifier pp first.desc;
      List.iter
        (fun l ->
          space pp ();
          identifier pp "'";
          identifier pp l.desc)
        rest;
      space pp ());
  keyword pp "else";
  space pp ();
  identifier pp "'";
  identifier pp default.desc

(* Print [<before>[ <labels> else <default> ]<after>], shared by [br_table] and
   [dispatch]. On one line when it fits; otherwise [<before>[] stays on the line,
   the labels are filled and indented, and []<after>] is dedented to the box's
   column:
     <before>[
         <labels …>
         … else <default>
     ]<after>
   [after] (e.g. the [dispatch] body's [{]) is glued to the []]. *)
let bracketed_labels pp ~before ?(after = fun () -> ()) cases default =
  hvbox pp ~indent:0 (fun () ->
      hbox pp (fun () ->
          before ();
          punctuation pp "[");
      indent pp indent_level (fun () ->
          space pp ();
          box pp (fun () -> label_seq pp cases default));
      space pp ();
      hbox pp (fun () ->
          punctuation pp "]";
          after ()))

let match_pattern pp (pat : Ast.match_pattern) =
  match pat with
  | MatchCast (bind, rt) ->
      Option.iter
        (fun x ->
          identifier pp x.desc;
          punctuation pp ":";
          space pp ())
        bind;
      reftype pp rt
  | MatchNull -> keyword pp "null"

(*** The instruction printer ***)

let rec instr prec pp (i : _ instr) =
  atomic_node pp (pp.locate i.info) @@ fun () ->
  parentheses prec (get_prec i) pp @@ fun () ->
  match i.desc with
  | Block { label; typ; block = l } ->
      (* A plain block is always introduced by [do] (a bare or labelled [{ … }]
         also parses, but [do] is the canonical form we emit). *)
      block pp label (Some "do") typ l
  | If_annotation { cond; then_body; else_body } ->
      let branch body =
        space pp ();
        punctuation pp "{";
        block_contents pp body;
        punctuation pp "}"
      in
      hvbox pp (fun () ->
          attribute pp (Printf.sprintf "#[if(%s)]" (cond_to_string cond));
          branch then_body;
          Option.iter
            (fun b ->
              newline pp ();
              attribute pp "#[else]";
              branch b)
            else_body)
  | Loop { label; typ; block = l } -> block pp label (Some "loop") typ l
  | While { label; cond; step; block = l } ->
      hvbox pp (fun () ->
          box pp (fun () ->
              block_label pp label;
              keyword pp "while";
              indent pp indent_level (fun () ->
                  space pp ();
                  instr Instruction pp cond;
                  (* Zig-style continue-expression: [: (step)] after the cond. *)
                  match step with
                  | None -> ()
                  | Some s ->
                      space pp ();
                      punctuation pp ":";
                      space pp ();
                      punctuation pp "(";
                      instr Instruction pp s;
                      punctuation pp ")");
              space pp ();
              punctuation pp "{");
          located_block_contents pp l;
          punctuation pp "}")
  | If { label; typ; cond; if_block; else_block } ->
      hvbox pp (fun () ->
          box pp (fun () ->
              block_label pp label;
              keyword pp "if";
              indent pp indent_level (fun () ->
                  space pp ();
                  instr Instruction pp cond;
                  if need_blocktype typ then (
                    space pp ();
                    box pp ~indent:indent_level (fun () ->
                        punctuation pp "=>";
                        space pp ();
                        blocktype pp typ)));
              space pp ();
              punctuation pp "{");
          located_block_contents pp if_block;
          match else_block with
          | Some else_block ->
              hvbox pp (fun () ->
                  box pp (fun () ->
                      punctuation pp "}";
                      space pp ();
                      keyword pp "else";
                      space pp ();
                      punctuation pp "{");
                  located_block_contents pp else_block;
                  punctuation pp "}")
          | None -> punctuation pp "}")
  | Try { label; typ; block = l; catches; catch_all } ->
      hvbox pp (fun () ->
          box pp (fun () ->
              block_label pp label;
              keyword pp "try";
              space pp ();
              if need_blocktype typ then (
                blocktype pp typ;
                space pp ());
              punctuation pp "{");
          located_block_contents pp l;
          hvbox pp (fun () ->
              box pp (fun () ->
                  punctuation pp "}";
                  space pp ();
                  keyword pp "catch";
                  space pp ();
                  punctuation pp "{");
              indent pp indent_level (fun () ->
                  List.iter
                    (fun (tag, block) ->
                      space pp ();
                      hvbox pp (fun () ->
                          box pp (fun () ->
                              identifier pp tag.desc;
                              space pp ();
                              punctuation pp "=>";
                              space pp ();
                              punctuation pp "{");
                          block_contents pp block;
                          punctuation pp "}"))
                    catches;
                  Option.iter
                    (fun block ->
                      space pp ();
                      hvbox pp (fun () ->
                          box pp (fun () ->
                              operator pp "_";
                              space pp ();
                              punctuation pp "=>";
                              space pp ();
                              punctuation pp "{");
                          block_contents pp block;
                          punctuation pp "}"))
                    catch_all);
              (* The break before the closing [}] must sit outside the [indent]
                 above so it lands at the catch block's own column, not the
                 handlers' deeper indent. *)
              space pp ();
              punctuation pp "}"))
  | TryTable { label; typ = bt; block = l; catches } ->
      hvbox pp (fun () ->
          box pp (fun () ->
              block_label pp label;
              keyword pp "try";
              space pp ();
              if need_blocktype bt then (
                blocktype pp bt;
                space pp ());
              punctuation pp "{");
          located_block_contents pp l;
          hvbox pp (fun () ->
              box pp (fun () ->
                  punctuation pp "}";
                  space pp ();
                  keyword pp "catch";
                  space pp ();
                  punctuation pp "[");
              indent pp indent_level (fun () ->
                  let last = List.length catches - 1 in
                  List.iteri
                    (fun i catch ->
                      space pp ();
                      box pp (fun () ->
                          match catch with
                          | Catch (tag, label) ->
                              identifier pp tag.desc;
                              space pp ();
                              punctuation pp "->";
                              space pp ();
                              identifier pp "'";
                              identifier pp label.desc;
                              if i < last then punctuation pp ","
                          | CatchRef (tag, label) ->
                              identifier pp tag.desc;
                              space pp ();
                              operator pp "&";
                              space pp ();
                              punctuation pp "->";
                              space pp ();
                              identifier pp "'";
                              identifier pp label.desc;
                              if i < last then punctuation pp ","
                          | CatchAll label ->
                              operator pp "_";
                              space pp ();
                              punctuation pp "->";
                              space pp ();
                              identifier pp "'";
                              identifier pp label.desc;
                              if i < last then punctuation pp ","
                          | CatchAllRef label ->
                              operator pp "_";
                              space pp ();
                              operator pp "&";
                              space pp ();
                              punctuation pp "->";
                              space pp ();
                              identifier pp "'";
                              identifier pp label.desc;
                              if i < last then punctuation pp ","))
                    catches);
              (* Break before the closing [\]] so a wrapped handler list dedents
                 it to the [try]'s column rather than hugging the last handler. *)
              cut pp ();
              punctuation pp "]"))
  | Unreachable -> keyword pp "unreachable"
  | Nop -> operator pp "nop"
  | Hole -> operator pp "_"
  | Get x -> identifier pp x.desc
  | Path (x, y) ->
      identifier pp x.desc;
      operator pp "::";
      identifier pp y.desc
  | Set (x, op, i) ->
      box pp ~indent:indent_level (fun () ->
          identifier pp x.desc;
          space pp ();
          (* [x op= e] for a compound assignment; a plain [=] otherwise. *)
          operator pp
            (match op with None -> "=" | Some o -> binop o.desc ^ "=");
          space pp ();
          instr Instruction pp i)
  | Tee (x, i) ->
      box pp ~indent:indent_level (fun () ->
          identifier pp x.desc;
          space pp ();
          operator pp ":=";
          space pp ();
          instr Instruction pp i)
  | Call (i, l) -> call_instr instr pp i l
  | TailCall (i, l) -> call_instr instr pp ~prefix:"become" i l
  | Char c ->
      let n = Uchar.utf_8_byte_length c in
      let b = Bytes.create n in
      ignore (Bytes.set_utf_8_uchar b 0 c);
      let len, s =
        Wax_utils.Unicode.escape_string ~hex_prefix:"x" (Bytes.to_string b)
      in
      string pp "\'";
      string pp ~len:(Some len) s;
      string pp "\'"
  | String (t, s) ->
      Option.iter
        (fun t ->
          type_ pp t.desc;
          operator pp "#")
        t;
      let len, s = Wax_utils.Unicode.escape_string ~hex_prefix:"x" s in
      string pp "\"";
      string pp ~len:(Some len) s;
      string pp "\""
  | Int s | Float s -> constant pp s
  | Cast (i, t) ->
      box pp ~indent:indent_level (fun () ->
          instr Cast pp i;
          space pp ();
          box pp (fun () ->
              keyword pp "as";
              space pp ();
              casttype pp t))
  | CastDesc (i, nullable, d) ->
      box pp ~indent:indent_level (fun () ->
          instr Cast pp i;
          space pp ();
          box pp (fun () ->
              keyword pp "as";
              space pp ();
              descriptor_operand instr pp ~nullable d))
  | NonNull i ->
      instr UnaryPostfix pp i;
      operator pp "!"
  | Test (i, t) ->
      box pp ~indent:indent_level (fun () ->
          instr Cast pp i;
          space pp ();
          box pp (fun () ->
              keyword pp "is";
              space pp ();
              reftype pp t))
  | Struct (nm, l) ->
      struct_instr pp nm (fun () -> list_commasep_trailing struct_field_kv pp l)
  | StructDefault nm -> struct_instr pp nm (fun () -> punctuation pp "..")
  | StructDesc (d, l) ->
      struct_desc_instr pp
        (fun () -> descriptor_operand instr pp d)
        (fun () -> list_commasep_trailing struct_field_kv pp l)
  | StructDefaultDesc d ->
      struct_desc_instr pp
        (fun () -> descriptor_operand instr pp d)
        (fun () -> punctuation pp "..")
  | StructGet (i, s) ->
      field_receiver pp i;
      operator pp ".";
      identifier pp s.desc
  | GetDescriptor i ->
      field_receiver pp i;
      operator pp ".";
      keyword pp "descriptor"
  | StructSet (i, s, i') ->
      box pp ~indent:indent_level (fun () ->
          field_receiver pp i;
          operator pp ".";
          identifier pp s.desc;
          space pp ();
          operator pp "=";
          space pp ();
          instr Instruction pp i')
  | Array (nm, i, n) ->
      array_instr pp nm (fun () ->
          instr (array_element_precedence nm true i) pp i;
          punctuation pp ";";
          space pp ();
          instr Instruction pp n)
  | ArrayDefault (nm, n) ->
      array_instr pp nm (fun () ->
          punctuation pp "..;";
          space pp ();
          instr Instruction pp n)
  | ArrayFixed (nm, l) ->
      array_instr pp nm (fun () ->
          list_commasep_trailing
            (fun ctx (first, i) ->
              instr (array_element_precedence nm first i) ctx i)
            pp
            (List.mapi (fun n i -> (n = 0, i)) l))
  | ArraySegment (nm, d, off, len) ->
      hvbox pp ~indent:0 (fun () ->
          box pp (fun () ->
              punctuation pp "[";
              Option.iter
                (fun t ->
                  identifier pp t.desc;
                  punctuation pp "|")
                nm;
              space pp ();
              identifier pp d.desc;
              space pp ();
              operator pp "@");
          indent pp indent_level (fun () ->
              space pp ();
              instr Instruction pp off);
          punctuation pp ";";
          indent pp indent_level (fun () ->
              space pp ();
              instr Instruction pp len);
          cut pp ();
          punctuation pp "]")
  | ArrayGet (i1, i2) ->
      box pp ~indent:indent_level (fun () ->
          instr CallAndFieldAccess pp i1;
          cut pp ();
          box pp (fun () ->
              operator pp "[";
              instr Instruction pp i2;
              operator pp "]"))
  | ArraySet (i1, i2, i3) ->
      box pp ~indent:indent_level (fun () ->
          instr CallAndFieldAccess pp i1;
          cut pp ();
          box pp (fun () ->
              operator pp "[";
              instr Instruction pp i2;
              operator pp "]");
          space pp ();
          operator pp "=";
          space pp ();
          instr Instruction pp i3)
  | BinOp (op, i, i') ->
      let _, left, right = prec_op op.desc in
      (* The [precedence] lint (see [Typing.lint_precedence]) flags a shift mixed
         with arithmetic, or a comparison with a bitwise operator, written
         without parentheses — precedence alone would not require them. Emit them
         anyway around such an operand (by demanding an [Atom] there) so
         re-printed / decompiled Wax stays quiet under the lint. The confusion
         table is shared with the lint ({!Ast_utils.confusing_precedence}). *)
      let operand_prec default (child : _ instr) =
        match child.desc with
        | BinOp (child_op, _, _)
          when Ast_utils.confusing_precedence
                 (Ast_utils.binop_kind op.desc)
                 (Ast_utils.binop_kind child_op.desc) ->
            Atom
        | _ -> default
      in
      box pp ~indent:indent_level (fun () ->
          instr (operand_prec left i) pp i;
          (* Break *before* the operator (rustfmt style: a wrapped operator
             leads its continuation line), so only the space ahead of it may
             break; the space after it is a plain, non-breaking blank. The
             operator carries its own location, so a comment between the left
             operand and it attaches to the operand, ahead of the break. *)
          space pp ();
          atomic_node pp (Some op.info) (fun () -> operator pp (binop op.desc));
          Wax_utils.Printer.string pp.base.printer " ";
          instr (operand_prec right i') pp i')
  | UnOp (op, i) ->
      atomic_node pp (Some op.info) (fun () -> operator pp (unop op.desc));
      instr UnaryPrefix pp i
  | Let ([ (None, typ) ], Some i) ->
      (* An anonymous binding is a discarded value: printed [_ = e] (or, when a
         width annotation is load-bearing, [_: t = e]) — without [let], since
         nothing is bound. Mirrors the [Set] layout. *)
      box pp ~indent:indent_level (fun () ->
          hbox pp (fun () ->
              operator pp "_";
              Option.iter
                (fun t ->
                  punctuation pp ":";
                  space pp ();
                  valtype pp t)
                typ;
              space pp ();
              operator pp "=");
          space pp ();
          instr Instruction pp i)
  | Let (l, i) ->
      box pp ~indent:indent_level (fun () ->
          (* Keep [let pat =] together as one unit: when the value breaks the
             line after [=], without this box the outer box would also split
             [let]/[pat]/[=] across lines. *)
          hbox pp (fun () ->
              keyword pp "let";
              space pp ();
              (match l with
              | [ p ] -> print_typed_pat pp p
              | l -> print_paren_list print_typed_pat pp l);
              if Option.is_some i then (
                space pp ();
                keyword pp "="));
          Option.iter
            (fun i ->
              space pp ();
              instr Instruction pp i)
            i)
  | Br (label, i) -> branch_instr instr pp "br" label i
  | Br_if (label, i) -> branch_instr instr pp "br_if" label (Some i)
  | Br_on_null (label, i) -> branch_instr instr pp "br_on_null" label (Some i)
  | Br_on_non_null (label, i) ->
      branch_instr instr pp "br_on_non_null" label (Some i)
  | Br_on_cast (label, ty, i) ->
      branch_ref_instr instr pp "br_on_cast" label ty i
  | Br_on_cast_fail (label, ty, i) ->
      branch_ref_instr instr pp "br_on_cast_fail" label ty i
  | Br_on_cast_desc_eq (label, nullable, i, d) ->
      branch_ref_desc_instr instr pp "br_on_cast" label nullable i d
  | Br_on_cast_desc_eq_fail (label, nullable, i, d) ->
      branch_ref_desc_instr instr pp "br_on_cast_fail" label nullable i d
  (* Branch-hinting proposal: [#[likely]] / [#[unlikely]] prefixing the wrapped
     conditional branch. The attribute is a bare prefix so the branch keeps its own
     layout (and stays on the same line: [#[likely] if …]). *)
  | Hinted (h, inner) ->
      branch_hint_attr pp h;
      instr prec pp inner
  | Br_table (labels, i) ->
      let default, cases =
        match List.rev labels with
        | default :: rev_cases -> (default, List.rev rev_cases)
        | [] -> assert false
      in
      box pp ~indent:indent_level (fun () ->
          bracketed_labels pp
            ~before:(fun () ->
              keyword pp "br_table";
              space pp ())
            cases default;
          space pp ();
          instr Branch pp i)
  | Dispatch { index; cases; default; arms } ->
      hvbox pp (fun () ->
          (* Head: [dispatch <index> [ <labels> else <default> ] {], laid out on
             one line or, when too wide, as
                 dispatch <index> [
                     <labels, filled and indented>
                 ] {
             with the [']'] dedented to the [dispatch] column (see
             [bracketed_labels]). *)
          bracketed_labels pp
            ~before:(fun () ->
              keyword pp "dispatch";
              space pp ();
              (* Parenthesise a non-atomic index: the following '[' would
                 otherwise bind to the index's last atom as an array access. *)
              instr Atom pp index;
              space pp ())
            ~after:(fun () ->
              space pp ();
              punctuation pp "{")
            cases default;
          if arms <> [] then (
            indent pp indent_level (fun () ->
                List.iter
                  (fun (l, body) ->
                    newline pp ();
                    block pp (Some l) None
                      { params = [||]; results = [||] }
                      (no_loc body))
                  arms);
            newline pp ());
          punctuation pp "}")
  | Match { scrutinee; arms; default } ->
      let arm pat_printer body =
        newline pp ();
        hvbox pp (fun () ->
            box pp (fun () ->
                pat_printer ();
                space pp ();
                punctuation pp "=>";
                space pp ();
                punctuation pp "{");
            block_contents pp body;
            punctuation pp "}")
      in
      hvbox pp (fun () ->
          box pp (fun () ->
              keyword pp "match";
              space pp ();
              (* Parenthesise a non-atomic scrutinee: the following '{' would
                 otherwise read as a struct/block continuation. *)
              instr Atom pp scrutinee;
              space pp ();
              punctuation pp "{");
          indent pp indent_level (fun () ->
              List.iter
                (fun (pat, body) -> arm (fun () -> match_pattern pp pat) body)
                arms;
              (* The default arm is compulsory, so always print it. *)
              arm (fun () -> operator pp "_") default);
          newline pp ();
          punctuation pp "}")
  | Return i ->
      box pp ~indent:indent_level (fun () ->
          keyword pp "return";
          Option.iter
            (fun i ->
              space pp ();
              instr Branch pp i)
            i)
  | Throw (tag, i) ->
      box pp ~indent:indent_level (fun () ->
          keyword pp "throw";
          space pp ();
          identifier pp tag.desc;
          Option.iter
            (fun i ->
              space pp ();
              instr Branch pp i)
            i)
  | ThrowRef i ->
      box pp ~indent:indent_level (fun () ->
          keyword pp "throw_ref";
          space pp ();
          instr Branch pp i)
  | ContNew (ct, i) ->
      box pp ~indent:indent_level (fun () ->
          keyword pp "cont_new";
          space pp ();
          identifier pp ct.desc;
          cut pp ();
          print_paren_list (instr Instruction) pp [ i ])
  | ContBind (src, dst, l) ->
      box pp ~indent:indent_level (fun () ->
          keyword pp "cont_bind";
          space pp ();
          identifier pp src.desc;
          space pp ();
          identifier pp dst.desc;
          cut pp ();
          print_paren_list (instr Instruction) pp l)
  | Suspend (tag, l) ->
      box pp ~indent:indent_level (fun () ->
          keyword pp "suspend";
          space pp ();
          identifier pp tag.desc;
          cut pp ();
          print_paren_list (instr Instruction) pp l)
  | Resume (ct, handlers, l) ->
      box pp ~indent:indent_level (fun () ->
          keyword pp "resume";
          space pp ();
          identifier pp ct.desc;
          space pp ();
          print_on_clauses pp handlers;
          cut pp ();
          print_paren_list (instr Instruction) pp l)
  | ResumeThrow (ct, tag, handlers, l) ->
      box pp ~indent:indent_level (fun () ->
          keyword pp "resume_throw";
          space pp ();
          identifier pp ct.desc;
          space pp ();
          identifier pp tag.desc;
          space pp ();
          print_on_clauses pp handlers;
          cut pp ();
          print_paren_list (instr Instruction) pp l)
  | ResumeThrowRef (ct, handlers, l) ->
      box pp ~indent:indent_level (fun () ->
          keyword pp "resume_throw_ref";
          space pp ();
          identifier pp ct.desc;
          space pp ();
          print_on_clauses pp handlers;
          cut pp ();
          print_paren_list (instr Instruction) pp l)
  | Switch (ct, tag, l) ->
      box pp ~indent:indent_level (fun () ->
          keyword pp "switch";
          space pp ();
          identifier pp ct.desc;
          space pp ();
          identifier pp tag.desc;
          cut pp ();
          print_paren_list (instr Instruction) pp l)
  | Sequence l -> print_paren_list (instr Instruction) pp l
  | Select (i1, i2, i3) ->
      box pp ~indent:indent_level (fun () ->
          instr Comparison pp i1;
          cut pp ();
          operator pp "?";
          instr Assignement pp i2;
          cut pp ();
          operator pp ":";
          instr Assignement pp i3)
  | Null -> keyword pp "null"

(* A struct-literal field. A punned field ([None], written [{x}]) prints as the
   bare name; an explicit field prints as [name: value]. *)
and struct_field_kv pp (nm, i) =
  match i with
  | None -> identifier pp nm.desc
  | Some i -> print_key_value pp nm.desc (instr Instruction) i

and field_receiver pp i =
  (* A bare numeric literal receiver would be misparsed: [0.foo] lexes [0.]
     as a float, so parenthesize it. *)
  match i.desc with
  | Int _ | Float _ ->
      punctuation pp "(";
      box pp (fun () ->
          instr Instruction pp i;
          punctuation pp ")")
  | _ -> instr CallAndFieldAccess pp i

and block pp label kind bt (l : (_ instr list, location) annotated) =
  hvbox pp (fun () ->
      box pp (fun () ->
          block_label pp label;
          Option.iter
            (fun kind ->
              keyword pp kind;
              space pp ())
            kind;
          if need_blocktype bt then (
            blocktype pp bt;
            space pp ());
          punctuation pp "{");
      located_block_contents pp l;
      punctuation pp "}")

and deliminated_instr pp (i : _ instr) =
  if is_block i then instr Instruction pp i
  else (
    instr (if starts_with_block i then Atom else Instruction) pp i;
    (* Hold any deferred trailing comment so the [;] prints on the statement's
       line, ahead of the comment ([expr; // c] rather than [expr // c] then a
       lone [;] on the next line). *)
    Wax_utils.Printer.with_held_eol pp.base.printer (fun () ->
        punctuation pp ";"))

and block_contents pp (l : _ instr list) =
  (* A non-empty block always breaks across lines (rustfmt never keeps a block
     body on one line), so every separator here is a hard [newline]; the
     enclosing box then lays the body out vertically. An empty block stays
     [{}]. *)
  if l <> [] then (
    indent pp indent_level (fun () ->
        List.iter
          (fun i ->
            newline pp ();
            deliminated_instr pp i)
          l);
    newline pp ())

(* Print the contents of a brace-delimited block, looking the block's own
   location up so a comment opening the clause attaches here rather than to the
   condition, and so an own-line comment trailing the last statement (anchored
   before the [}], hence [within] the block's span) renders *inside* the block at
   the statement indentation rather than leaking onto the next sibling. [before]
   still precedes the body and [after] still follows it. *)
and located_block_contents pp (b : (_ instr list, location) annotated) =
  let assoc = get_trivia pp (Some b.info) in
  print_trivia pp assoc.before;
  if b.desc <> [] || assoc.within <> [] then (
    indent pp indent_level (fun () ->
        List.iter
          (fun i ->
            newline pp ();
            deliminated_instr pp i)
          b.desc;
        print_trivia pp assoc.within);
    newline pp ());
  print_trivia pp assoc.after

(*** Declarations, attributes, and module fields ***)

let fundecl ?(exact = false) ~tag pp (name, typ, sign) =
  (* The whole signature is one all-or-nothing group anchored at the [fn]
     column: [fn name] stays glued (its own [hbox]) and so does [-> Ret], so the
     only thing that can break — when [fn name(params) -> Ret] overflows — is
     the parameter list, which then lays out one parameter per line. *)
  hvbox pp (fun () ->
      hbox pp (fun () ->
          keyword pp (if tag then "tag" else "fn");
          space pp ();
          identifier pp name.desc;
          (* An exact declaration with an inline signature marks the name
             ([fn f!(…)]); with a named type the marker hugs the type
             ([fn f: !t]). *)
          if exact && Option.is_none typ then punctuation pp "!";
          Option.iter
            (fun typ ->
              punctuation pp ":";
              space pp ();
              if exact then punctuation pp "!";
              identifier pp typ.desc;
              space pp ())
            typ);
      Option.iter (fun ty -> raw_functype pp ty) sign)

let print_attribute_gen open_ pp (name, i) =
  box pp ~indent:indent_level (fun () ->
      attribute pp open_;
      attribute pp name;
      (match i with
      | None -> ()
      | Some i ->
          space pp ();
          attribute pp "=";
          space pp ();
          with_style pp Attribute (fun () -> instr Instruction pp i));
      attribute pp "]")

let print_attribute pp a = print_attribute_gen "#[" pp a

(* Module-level inner attribute: [#![module = "name"]]. *)
let print_inner_attribute pp a = print_attribute_gen "#![" pp a

(* Separate attributes at this (enclosing) level rather than with a trailing
   space inside each attribute's box: a break between them then lands at the
   enclosing box's indentation, so stacked attributes stay aligned instead of
   each indenting relative to the previous one's box. *)
let print_attributes pp attributes =
  List.iteri
    (fun i a ->
      if i > 0 then space pp ();
      print_attribute pp a)
    attributes

let print_attr_prefix pp attributes_list content_fn =
  hvbox pp (fun () ->
      if attributes_list <> [] then (
        print_attributes pp attributes_list;
        newline pp ());
      content_fn ())

let print_data_bytes pp s =
  let len, s = Wax_utils.Unicode.escape_string ~hex_prefix:"x" s in
  string pp "\"";
  string pp ~len:(Some len) s;
  string pp "\""

let print_data_name pp n =
  match n with
  | Some (n : ident) -> identifier pp n.desc
  | None -> punctuation pp "_"

let simple_inline_instr (i : _ Ast.instr) =
  match i.desc with
  | Get _ | Path _ | Char _ | String _ | Int _ | Float _ -> true
  | _ -> false

let print_square_instr ?(leading_space = false) pp i =
  if simple_inline_instr i then (
    if leading_space then space pp ();
    punctuation pp "[";
    instr Instruction pp i;
    punctuation pp "]")
  else (
    if leading_space then
      hbox pp (fun () ->
          space pp ();
          punctuation pp "[")
    else punctuation pp "[";
    indent pp indent_level (fun () ->
        newline pp ();
        instr Instruction pp i);
    newline pp ();
    punctuation pp "]")

let print_square_instr_list ?(multiline = false) pp l =
  if not multiline then (
    punctuation pp "[";
    box pp (fun () -> list_commasep (fun pp i -> instr Instruction pp i) pp l);
    punctuation pp "]")
  else (
    punctuation pp "[";
    indent pp indent_level (fun () ->
        newline pp ();
        list_commasep (fun pp i -> instr Instruction pp i) pp l);
    newline pp ();
    punctuation pp "]")

let print_offset_brackets pp off = print_square_instr ~leading_space:true pp off

let print_targeted_offset pp target off =
  hbox pp (fun () ->
      space pp ();
      operator pp "@";
      space pp ();
      identifier pp target.desc);
  print_offset_brackets pp off

let print_eq_square_instr_list pp l =
  hbox pp (fun () ->
      space pp ();
      punctuation pp "=";
      space pp ());
  print_square_instr_list ~multiline:(List.length l > 3) pp l

let print_memdata pp (d : _ Ast.memdata) =
  box pp ~indent:indent_level (fun () ->
      hbox pp (fun () ->
          keyword pp "data";
          space pp ();
          print_data_name pp d.data_name;
          space pp ();
          operator pp "@");
      print_offset_brackets pp d.offset;
      hbox pp (fun () ->
          space pp ();
          punctuation pp "=");
      space pp ();
      print_data_bytes pp d.init;
      punctuation pp ";")

let print_limits pp limits =
  Option.iter
    (fun (mi, ma) ->
      space pp ();
      punctuation pp "[";
      constant pp (Wax_utils.Uint64.to_string mi);
      Option.iter
        (fun m ->
          punctuation pp ",";
          space pp ();
          constant pp (Wax_utils.Uint64.to_string m))
        ma;
      punctuation pp "]")
    limits

(* Print one entry of an [import "module" { ... }] block: its attributes and an
   [#[import = "name"]] override (when it is imported under a name other than
   its own), then the declaration itself. *)
let print_import_decl pp (decl : Ast.import_decl) =
  print_attr_prefix pp decl.attributes (fun () ->
      box pp (fun () ->
          (match decl.kind with
          | Import_func { typ; sign; exact } ->
              fundecl ~exact ~tag:false pp (decl.id, typ, sign)
          | Import_tag { typ; sign } -> fundecl ~tag:true pp (decl.id, typ, sign)
          | Import_global { mut; typ } ->
              keyword pp (if mut then "let" else "const");
              space pp ();
              identifier pp decl.id.desc;
              punctuation pp ":";
              space pp ();
              valtype pp typ
          | Import_memory { address_type; limits; page_size_log2; shared } ->
              keyword pp "memory";
              space pp ();
              identifier pp decl.id.desc;
              punctuation pp ":";
              space pp ();
              keyword pp
                (match address_type with `I32 -> "i32" | `I64 -> "i64");
              print_limits pp limits;
              Option.iter
                (fun p ->
                  space pp ();
                  keyword pp "pagesize";
                  space pp ();
                  constant pp (Int64.to_string (Int64.shift_left 1L p)))
                page_size_log2;
              if shared then (
                space pp ();
                keyword pp "shared")
          | Import_table { address_type; reftype = rt; limits } ->
              keyword pp "table";
              space pp ();
              identifier pp decl.id.desc;
              punctuation pp ":";
              space pp ();
              (match address_type with
              | `I32 -> ()
              | `I64 ->
                  keyword pp "i64";
                  space pp ());
              reftype pp rt;
              print_limits pp limits);
          semicolon pp))

let rec modulefield pp field =
  atomic_node pp (Some field.info) @@ fun () ->
  match field.desc with
  | Type t -> rectype pp t
  | Module_annotation attrs ->
      hvbox pp (fun () ->
          List.iteri
            (fun i a ->
              if i > 0 then space pp ();
              print_inner_attribute pp a)
            attrs)
  | Func { name; typ; sign; body = label, body; attributes = a } ->
      print_attr_prefix pp a (fun () ->
          hvbox pp (fun () ->
              box pp (fun () ->
                  fundecl ~tag:false pp (name, typ, sign);
                  (* Glue the opening [{] to the signature so [fundecl] counts
                     it when deciding whether to break the parameter list;
                     otherwise a signature one or two columns too long leaves
                     [{] stranded on its own line instead. *)
                  hbox pp (fun () ->
                      space pp ();
                      block_label pp label;
                      punctuation pp "{"));
              block_contents pp body;
              punctuation pp "}"))
  | Global { name; mut; typ; def; attributes = a } ->
      print_attr_prefix pp a (fun () ->
          box pp ~indent:indent_level (fun () ->
              keyword pp (if mut then "let" else "const");
              space pp ();
              identifier pp name.desc;
              Option.iter
                (fun t ->
                  punctuation pp ":";
                  space pp ();
                  valtype pp t)
                typ;
              space pp ();
              punctuation pp "=";
              space pp ();
              instr Instruction pp def;
              semicolon pp))
  | Tag { name; typ; sign; attributes = a } ->
      print_attr_prefix pp a (fun () ->
          box pp (fun () ->
              fundecl ~tag:true pp (name, typ, sign);
              semicolon pp))
  | Memory
      {
        name;
        address_type;
        limits;
        page_size_log2;
        shared;
        data;
        attributes = a;
      } ->
      print_attr_prefix pp a (fun () ->
          hvbox pp (fun () ->
              box pp (fun () ->
                  keyword pp "memory";
                  space pp ();
                  identifier pp name.desc;
                  punctuation pp ":";
                  space pp ();
                  keyword pp
                    (match address_type with `I32 -> "i32" | `I64 -> "i64");
                  Option.iter
                    (fun (mi, ma) ->
                      space pp ();
                      punctuation pp "[";
                      constant pp (Wax_utils.Uint64.to_string mi);
                      Option.iter
                        (fun m ->
                          punctuation pp ",";
                          space pp ();
                          constant pp (Wax_utils.Uint64.to_string m))
                        ma;
                      punctuation pp "]")
                    limits;
                  Option.iter
                    (fun p ->
                      space pp ();
                      keyword pp "pagesize";
                      space pp ();
                      constant pp (Int64.to_string (Int64.shift_left 1L p)))
                    page_size_log2;
                  if shared then (
                    space pp ();
                    keyword pp "shared"));
              match data with
              | [] -> semicolon pp
              | _ ->
                  hbox pp (fun () ->
                      space pp ();
                      punctuation pp "{");
                  indent pp indent_level (fun () ->
                      List.iter
                        (fun d ->
                          space pp ();
                          print_memdata pp d)
                        data);
                  space pp ();
                  punctuation pp "}"))
  | Data { name; mode; init; attributes = a } ->
      print_attr_prefix pp a (fun () ->
          box pp ~indent:indent_level (fun () ->
              hbox pp (fun () ->
                  keyword pp "data";
                  space pp ();
                  print_data_name pp name);
              (match mode with
              | Passive -> ()
              | Active (mem, off) -> print_targeted_offset pp mem off);
              hbox pp (fun () ->
                  space pp ();
                  punctuation pp "=");
              space pp ();
              print_data_bytes pp init;
              semicolon pp))
  | Table { name; address_type; reftype = rt; limits; init; attributes = a } ->
      print_attr_prefix pp a (fun () ->
          box pp ~indent:indent_level (fun () ->
              hbox pp (fun () ->
                  keyword pp "table";
                  space pp ();
                  identifier pp name.desc;
                  punctuation pp ":";
                  space pp ();
                  (match address_type with
                  | `I32 -> ()
                  | `I64 ->
                      keyword pp "i64";
                      space pp ());
                  reftype pp rt;
                  Option.iter
                    (fun (mi, ma) ->
                      space pp ();
                      punctuation pp "[";
                      constant pp (Wax_utils.Uint64.to_string mi);
                      Option.iter
                        (fun m ->
                          punctuation pp ",";
                          space pp ();
                          constant pp (Wax_utils.Uint64.to_string m))
                        ma;
                      punctuation pp "]")
                    limits);
              Option.iter
                (fun e ->
                  hbox pp (fun () ->
                      space pp ();
                      punctuation pp "=");
                  space pp ();
                  instr Instruction pp e)
                init;
              semicolon pp))
  | Elem { name; reftype = rt; mode; init; attributes = a } ->
      print_attr_prefix pp a (fun () ->
          box pp ~indent:indent_level (fun () ->
              hbox pp (fun () ->
                  keyword pp "elem";
                  space pp ();
                  identifier pp name.desc;
                  punctuation pp ":";
                  space pp ();
                  reftype pp rt);
              (match mode with
              | EPassive -> ()
              | EActive (tab, off) -> print_targeted_offset pp tab off);
              print_eq_square_instr_list pp init;
              semicolon pp))
  | Group { attributes; fields } ->
      print_attr_prefix pp attributes (fun () ->
          hvbox pp (fun () ->
              punctuation pp "{";
              if fields <> [] then (
                indent pp indent_level (fun () ->
                    List.iter
                      (fun f ->
                        space pp ();
                        modulefield pp f)
                      fields);
                space pp ());
              punctuation pp "}"))
  | Import { module_; decl } ->
      box pp (fun () ->
          keyword pp "import";
          space pp ();
          print_data_bytes pp module_.desc;
          space pp ();
          print_import_decl pp decl.desc)
  | Import_group { module_; decls } ->
      hvbox pp (fun () ->
          box pp (fun () ->
              keyword pp "import";
              space pp ();
              print_data_bytes pp module_.desc;
              space pp ();
              punctuation pp "{");
          (* Like any brace-delimited block (see [block_contents]), a non-empty
             import group always lays its declarations out vertically, one per
             line; an empty group stays [{}]. *)
          if decls <> [] then (
            indent pp indent_level (fun () ->
                List.iter
                  (fun d ->
                    newline pp ();
                    print_import_decl pp d.desc)
                  decls);
            newline pp ());
          punctuation pp "}")
  | Conditional { cond; then_fields; else_fields } ->
      let branch fields =
        match fields with
        | [ f ] -> modulefield pp f
        | _ ->
            hvbox pp (fun () ->
                punctuation pp "{";
                if fields <> [] then (
                  indent pp indent_level (fun () ->
                      List.iter
                        (fun f ->
                          space pp ();
                          modulefield pp f)
                        fields);
                  space pp ());
                punctuation pp "}")
      in
      hvbox pp (fun () ->
          attribute pp (Printf.sprintf "#[if(%s)]" (cond_to_string cond));
          newline pp ();
          branch then_fields;
          Option.iter
            (fun e ->
              newline pp ();
              attribute pp "#[else]";
              newline pp ();
              branch e)
            else_fields)

(*** Entry points ***)

let module_ ?(color = Auto) ?out_channel ?(tail = []) ?collect printer ~trivia
    (l : location module_) =
  (* [collect] marks the dry trivia-collection traversal; time the real emit
     only, so a single "output" timing is reported. *)
  Wax_utils.Debug.timed_if (collect = None) "output" @@ fun () ->
  let use_color = should_use_color ~color ~out_channel in
  let theme = get_theme use_color in
  let pp =
    {
      base = Wax_utils.Styled_printer.create ~printer ~theme ?collect ~trivia ();
      locate = (fun l -> Some l);
    }
  in
  hvbox pp (fun () -> list ~sep:space modulefield pp l);
  (* Trailing comments owned by no node. Drop trailing blank lines so the file
     does not end with spurious blank lines. *)
  let tail = Wax_utils.Trivia.drop_trailing_blank_lines tail in
  print_trivia pp tail

(* Context for printing AST fragments in diagnostics: no trivia, no location
   lookup, colour decided from [stderr]. *)
let diagnostic_ctx printer =
  let use_color = should_use_color ~color:Auto ~out_channel:(Some stderr) in
  let theme = get_theme use_color in
  {
    base =
      Wax_utils.Styled_printer.create ~printer ~theme ~trivia:(Hashtbl.create 0)
        ();
    locate = (fun _ -> None);
  }

let instr printer i = instr Instruction (diagnostic_ctx printer) i
let valtype printer i = valtype (diagnostic_ctx printer) i
let comptype printer i = comptype (diagnostic_ctx printer) i
let storagetype printer i = storagetype (diagnostic_ctx printer) i

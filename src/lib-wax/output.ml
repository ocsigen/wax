(*ZZZZ
Should use string_as for comments
*)

open Utils.Colors
open Ast

let indent_level = 4

(* Target line width for Wax output, matching the Rust Style Guide's default
   ([max_width = 100]); WebAssembly text output keeps the printer's own default.
   Passed at every [Printer.run] that renders a Wax module to a real
   formatter. *)
let width = 100

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
  base : Utils.Styled_printer.t;
  (* Extract a source location from a node's annotation, to look its trivia up.
     [fun _ -> None] when printing typed ASTs for diagnostics (no trivia). *)
  locate : 'info -> location option;
}

let print_styled pp style ?(len = None) text =
  Utils.Styled_printer.print_styled pp.base style ~len text

let box pp ?indent f = Utils.Printer.box pp.base.printer ?indent f
let hvbox pp ?indent f = Utils.Printer.hvbox pp.base.printer ?indent f
let hbox pp f = Utils.Printer.hbox pp.base.printer f
let indent pp i f = Utils.Printer.indent pp.base.printer i f
let space pp () = Utils.Printer.space pp.base.printer ()
let cut pp () = Utils.Printer.cut pp.base.printer ()
let newline pp () = Utils.Printer.newline pp.base.printer ()
let punctuation pp s = print_styled pp Punctuation s
let operator pp s = print_styled pp Operator s

(* A declaration terminator [;], held past a deferred trailing comment so it
   sits before the comment ([const x = v; // c]) rather than dangling on its own
   line after it — as the block-statement [;] and list [,] separators already
   do. *)
let semicolon pp =
  Utils.Printer.with_held_eol pp.base.printer (fun () -> punctuation pp ";")

let identifier pp s =
  print_styled pp Identifier ~len:(Some (Utils.Unicode.terminal_width s)) s

let constant pp s = print_styled pp Constant s
let keyword pp s = print_styled pp Keyword s
let type_ pp s = print_styled pp Type s
let string pp ?len s = print_styled pp String ?len s
let attribute pp s = print_styled pp Attribute s

(* Comment preservation: emit the trivia (comments, blank lines) the lexer
   collected, looked up by AST-node location. The rendering logic is shared with
   the WebAssembly printer in [Utils.Trivia]. *)

let print_trivia pp lst = Utils.Styled_printer.print_trivia pp.base lst

let atomic_node pp (loc : location option) f =
  Utils.Styled_printer.atomic_node pp.base loc f

let with_style ctx style f = Utils.Styled_printer.with_style ctx.base style f

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
      Utils.Printer.with_held_eol pp.base.printer (fun () -> punctuation pp ",");
      space pp ())
    f pp l

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
          list_commasep f pp l);
      cut pp ());
  punctuation pp ")"

let heaptype pp (t : heaptype) =
  match heaptype_keyword t with
  | Some kw -> type_ pp kw
  | None -> ( match t with Type s -> type_ pp s.desc | _ -> assert false)

let reftype pp { nullable; typ } =
  punctuation pp (if nullable then "&?" else "&");
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
  match p with Some x -> identifier pp x.desc | None -> operator pp "_"

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
    (fun pp (id, t) ->
      match id with
      | None -> valtype pp t
      | Some name ->
          (* Look the parameter's trivia up by its name location, so a comment
             trailing it attaches here rather than bubbling to a sibling. *)
          atomic_node pp (Some name.info) (fun () ->
              print_typed_pat pp (id, Some t)))
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
  let nm, { typ; supertype; final } = field.desc in
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
        punctuation pp ")"))
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

let array_instr pp nm f =
  print_container pp ~opening:"[" ~closing:"]" ~indent:indent_level nm
    (fun () ->
      cut pp ();
      f ())

let get_prec (i : _ Ast.instr) =
  match i.desc with
  | Block _ | Loop _ | If _ | Try _ | TryTable _ | If_annotation _ -> Atom
  | Unreachable | Nop | Hole | Null | Get _ | Char _ | String _ | Int _
  | Float _ | Struct _ | StructDefault _ | Array _ | ArrayDefault _
  | ArrayFixed _ | ArraySegment _ | ArrayGet _ | ArraySet _ | Sequence _ ->
      Atom
  | Set _ | Tee _ -> Assignement
  | Call _ | TailCall _ -> CallAndFieldAccess
  | ContNew _ | ContBind _ | Suspend _ | Resume _ | ResumeThrow _
  | ResumeThrowRef _ | Switch _ ->
      CallAndFieldAccess
  | Cast _ | Test _ -> Cast
  | NonNull _ -> UnaryPostfix
  | UnOp _ -> UnaryPrefix
  | StructGet _ | StructSet _ -> CallAndFieldAccess
  | BinOp (op, _, _) ->
      let out, _, _ = prec_op op in
      out
  | Let _ -> Instruction
  | Br _ | Br_if _ | Br_table _ | Br_on_null _ | Br_on_non_null _ | Br_on_cast _
  | Br_on_cast_fail _ | Throw _ | ThrowRef _ | Return _ ->
      Branch
  | Select _ -> Select

let is_block (i : _ Ast.instr) =
  match i.desc with
  | Block _ | Loop _ | If _ | Try _ | TryTable _ | If_annotation _ -> true
  | Call _ | Unreachable | Nop | Hole | Null | Get _ | Set _ | Tee _
  | TailCall _ | Char _ | String _ | Int _ | Float _ | Cast _ | Test _
  | NonNull _ | Struct _ | StructDefault _ | StructGet _ | StructSet _ | Array _
  | ArrayDefault _ | ArrayFixed _ | ArraySegment _ | ArrayGet _ | ArraySet _
  | BinOp _ | UnOp _ | Let _ | Br _ | Br_if _ | Br_table _ | Br_on_null _
  | Br_on_non_null _ | Br_on_cast _ | Br_on_cast_fail _ | Throw _ | ThrowRef _
  | ContNew _ | ContBind _ | Suspend _ | Resume _ | ResumeThrow _
  | ResumeThrowRef _ | Switch _ | Return _ | Sequence _ | Select _ ->
      false

let rec starts_with_block_prec prec (i : 'a Ast.instr) =
  let actual = get_prec i in
  if prec > actual then false
  else
    match i.desc with
    | Block _ | Loop _ | If _ | Try _ | TryTable _ | If_annotation _ -> true
    | Call (i, _) | ArrayGet (i, _) | ArraySet (i, _, _) ->
        starts_with_block_prec CallAndFieldAccess i
    | Cast (i, _) | Test (i, _) -> starts_with_block_prec Cast i
    | NonNull i -> starts_with_block_prec UnaryPostfix i
    | UnOp (_, i) -> starts_with_block_prec UnaryPrefix i
    | StructGet (i, _) | StructSet (i, _, _) ->
        starts_with_block_prec CallAndFieldAccess i
    | BinOp (op, i, _) ->
        let _, left, _ = prec_op op in
        starts_with_block_prec left i
    | Select (i, _, _) -> starts_with_block_prec Select i
    | Unreachable | Nop | Hole | Null | Get _ | Set _ | Tee _ | TailCall _
    | Char _ | String _ | Int _ | Float _ | Struct _ | StructDefault _ | Array _
    | ArrayDefault _ | ArrayFixed _ | ArraySegment _ | Let _ | Br _ | Br_if _
    | Br_table _ | Br_on_null _ | Br_on_non_null _ | Br_on_cast _
    | Br_on_cast_fail _ | Throw _ | ThrowRef _ | ContNew _ | ContBind _
    | Suspend _ | Resume _ | ResumeThrow _ | ResumeThrowRef _ | Switch _
    | Return _ | Sequence _ ->
        false

let starts_with_block i = starts_with_block_prec Instruction i

let array_element_precedence nm first i =
  if nm = None && first then
    match i.desc with
    | BinOp (Or, { desc = Get _; _ }, _) -> Atom
    | _ -> Instruction
  else Instruction

let cond_op_string (op : Wasm.Ast.cmp_op) =
  match op with
  | Eq -> "="
  | Ne -> "!="
  | Lt -> "<"
  | Gt -> ">"
  | Le -> "<="
  | Ge -> ">="

let rec cond_to_string (c : Wasm.Ast.cond) =
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

let rec instr prec pp (i : _ instr) =
  atomic_node pp (pp.locate i.info) @@ fun () ->
  parentheses prec (get_prec i) pp @@ fun () ->
  match i.desc with
  | Block { label; typ; block = l } ->
      block pp label
        (if true || need_blocktype typ then Some "do" else None)
        typ l
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
          block_contents pp l;
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
          block_contents pp l;
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
              punctuation pp "]"))
  | Unreachable -> keyword pp "unreachable"
  | Nop -> operator pp "nop"
  | Hole -> operator pp "_"
  | Get x -> identifier pp x.desc
  | Set (x, i) ->
      box pp ~indent:indent_level (fun () ->
          simple_pat pp x;
          space pp ();
          operator pp "=";
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
      let len, s = Wasm.Output.escape_string (Bytes.to_string b) in
      string pp "\'";
      string pp ~len:(Some len) s;
      string pp "\'"
  | String (t, s) ->
      Option.iter
        (fun t ->
          type_ pp t.desc;
          operator pp "#")
        t;
      let len, s = Wasm.Output.escape_string s in
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
      struct_instr pp nm (fun () ->
          list_commasep
            (fun pp (nm, i) -> print_key_value pp nm.desc (instr Instruction) i)
            pp l)
  | StructDefault nm -> struct_instr pp nm (fun () -> punctuation pp "..")
  | StructGet (i, s) ->
      field_receiver pp i;
      operator pp ".";
      identifier pp s.desc
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
          list_commasep
            (fun ctx (first, i) ->
              instr (array_element_precedence nm first i) ctx i)
            pp
            (List.mapi (fun n i -> (n = 0, i)) l))
  | ArraySegment (nm, d, off, len) ->
      array_instr pp nm (fun () ->
          identifier pp d.desc;
          space pp ();
          operator pp "@";
          space pp ();
          instr Instruction pp off;
          punctuation pp ";";
          space pp ();
          instr Instruction pp len)
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
      let _, left, right = prec_op op in
      box pp ~indent:indent_level (fun () ->
          instr left pp i;
          space pp ();
          operator pp (binop op);
          space pp ();
          instr right pp i')
  | UnOp (op, i) ->
      operator pp (unop op);
      instr UnaryPrefix pp i
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
  | Br_table (labels, i) ->
      let labels = List.rev labels in
      box pp ~indent:indent_level (fun () ->
          keyword pp "br_table";
          space pp ();
          box pp ~indent:indent_level (fun () ->
              punctuation pp "[";
              list
                ~sep:(fun _ () -> ())
                (fun pp label ->
                  space pp ();
                  identifier pp "'";
                  identifier pp label.desc)
                pp
                (List.rev (List.tl labels));
              space pp ();
              box pp (fun () ->
                  keyword pp "else";
                  space pp ();
                  identifier pp "'";
                  identifier pp (List.hd labels).desc);
              space pp ();
              punctuation pp "]");
          space pp ();
          instr Branch pp i)
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

and block pp label kind bt (l : _ instr list) =
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
      block_contents pp l;
      punctuation pp "}")

and deliminated_instr pp (i : _ instr) =
  if is_block i then instr Instruction pp i
  else (
    instr (if starts_with_block i then Atom else Instruction) pp i;
    (* Hold any deferred trailing comment so the [;] prints on the statement's
       line, ahead of the comment ([expr; // c] rather than [expr // c] then a
       lone [;] on the next line). *)
    Utils.Printer.with_held_eol pp.base.printer (fun () -> punctuation pp ";"))

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
   location up so any comment opening the clause (e.g. a [(then ...)]/[(else
   ...)] clause comment carried over from Wasm) attaches here rather than to the
   condition or the previous clause. *)
and located_block_contents pp (b : (_ instr list, location) annotated) =
  atomic_node pp (Some b.info) (fun () -> block_contents pp b.desc)

let fundecl ~tag pp (name, typ, sign) =
  (* The whole signature is one all-or-nothing group anchored at the [fn]
     column: [fn name] stays glued (its own [hbox]) and so does [-> Ret], so the
     only thing that can break — when [fn name(params) -> Ret] overflows — is
     the parameter list, which then lays out one parameter per line. *)
  hvbox pp (fun () ->
      hbox pp (fun () ->
          keyword pp (if tag then "tag" else "fn");
          space pp ();
          identifier pp name.desc;
          Option.iter
            (fun typ ->
              punctuation pp ":";
              space pp ();
              identifier pp typ.desc;
              space pp ())
            typ);
      Option.iter (fun ty -> raw_functype pp ty) sign)

let print_attribute pp (name, i) =
  box pp ~indent:indent_level (fun () ->
      attribute pp "#[";
      attribute pp name;
      (match i with
      | None -> ()
      | Some i ->
          space pp ();
          attribute pp "=";
          space pp ();
          with_style pp Attribute (fun () -> instr Instruction pp i));
      attribute pp "]")

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
  let len, s = Wasm.Output.escape_string s in
  string pp "\"";
  string pp ~len:(Some len) s;
  string pp "\""

let print_data_name pp n =
  match n with
  | Some (n : ident) -> identifier pp n.desc
  | None -> punctuation pp "_"

let print_memdata pp (d : _ Ast.memdata) =
  keyword pp "data";
  space pp ();
  print_data_name pp d.data_name;
  space pp ();
  operator pp "@";
  space pp ();
  punctuation pp "[";
  instr Instruction pp d.offset;
  punctuation pp "]";
  space pp ();
  punctuation pp "=";
  space pp ();
  print_data_bytes pp d.init;
  punctuation pp ";"

let rec modulefield pp field =
  atomic_node pp (Some field.info) @@ fun () ->
  match field.desc with
  | Type t -> rectype pp t
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
  | Fundecl { name; typ; sign; attributes = a } ->
      print_attr_prefix pp a (fun () ->
          box pp (fun () ->
              fundecl ~tag:false pp (name, typ, sign);
              semicolon pp))
  | Tag { name; typ; sign; attributes = a } ->
      print_attr_prefix pp a (fun () ->
          box pp (fun () ->
              fundecl ~tag:true pp (name, typ, sign);
              semicolon pp))
  | GlobalDecl { name; mut; typ; attributes = a } ->
      print_attr_prefix pp a (fun () ->
          box pp ~indent:indent_level (fun () ->
              keyword pp (if mut then "let" else "const");
              space pp ();
              identifier pp name.desc;
              punctuation pp ":";
              space pp ();
              valtype pp typ;
              semicolon pp))
  | Memory { name; address_type; limits; data; attributes = a } ->
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
                      constant pp (Utils.Uint64.to_string mi);
                      Option.iter
                        (fun m ->
                          punctuation pp ",";
                          space pp ();
                          constant pp (Utils.Uint64.to_string m))
                        ma;
                      punctuation pp "]")
                    limits);
              match data with
              | [] -> semicolon pp
              | _ ->
                  space pp ();
                  punctuation pp "{";
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
          box pp (fun () ->
              keyword pp "data";
              space pp ();
              print_data_name pp name;
              (match mode with
              | Passive -> ()
              | Active (mem, off) ->
                  space pp ();
                  operator pp "@";
                  space pp ();
                  identifier pp mem.desc;
                  space pp ();
                  punctuation pp "[";
                  instr Instruction pp off;
                  punctuation pp "]");
              space pp ();
              punctuation pp "=";
              space pp ();
              print_data_bytes pp init;
              semicolon pp))
  | Table { name; address_type; reftype = rt; limits; init; attributes = a } ->
      print_attr_prefix pp a (fun () ->
          box pp (fun () ->
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
                  constant pp (Utils.Uint64.to_string mi);
                  Option.iter
                    (fun m ->
                      punctuation pp ",";
                      space pp ();
                      constant pp (Utils.Uint64.to_string m))
                    ma;
                  punctuation pp "]")
                limits;
              Option.iter
                (fun e ->
                  space pp ();
                  punctuation pp "=";
                  space pp ();
                  instr Instruction pp e)
                init;
              semicolon pp))
  | Elem { name; reftype = rt; mode; init; attributes = a } ->
      print_attr_prefix pp a (fun () ->
          box pp (fun () ->
              keyword pp "elem";
              space pp ();
              identifier pp name.desc;
              punctuation pp ":";
              space pp ();
              reftype pp rt;
              (match mode with
              | EPassive -> ()
              | EActive (tab, off) ->
                  space pp ();
                  operator pp "@";
                  space pp ();
                  identifier pp tab.desc;
                  space pp ();
                  punctuation pp "[";
                  instr Instruction pp off;
                  punctuation pp "]");
              space pp ();
              punctuation pp "=";
              space pp ();
              punctuation pp "[";
              box pp (fun () ->
                  list_commasep (fun pp i -> instr Instruction pp i) pp init);
              punctuation pp "]";
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

let module_ ?(color = Auto) ?out_channel ?(tail = []) ?collect printer ~trivia
    (l : location module_) =
  let use_color = should_use_color ~color ~out_channel in
  let theme = get_theme use_color in
  let pp =
    {
      base = Utils.Styled_printer.create ~printer ~theme ?collect ~trivia ();
      locate = (fun l -> Some l);
    }
  in
  hvbox pp (fun () -> list ~sep:space modulefield pp l);
  (* Trailing comments owned by no node. Drop trailing blank lines so the file
     does not end with spurious blank lines. *)
  let tail = Utils.Trivia.drop_trailing_blank_lines tail in
  print_trivia pp tail

(* Context for printing AST fragments in diagnostics: no trivia, no location
   lookup, colour decided from [stderr]. *)
let diagnostic_ctx printer =
  let use_color = should_use_color ~color:Auto ~out_channel:(Some stderr) in
  let theme = get_theme use_color in
  {
    base =
      Utils.Styled_printer.create ~printer ~theme ~trivia:(Hashtbl.create 0) ();
    locate = (fun _ -> None);
  }

let instr printer i = instr Instruction (diagnostic_ctx printer) i
let valtype printer i = valtype (diagnostic_ctx printer) i
let storagetype printer i = storagetype (diagnostic_ctx printer) i

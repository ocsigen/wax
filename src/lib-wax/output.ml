(*ZZZZ
Should use string_as for comments
*)

open Utils.Colors
open Ast

let indent_level = 4

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

type ctx = {
  printer : Utils.Printer.t;
  theme : theme;
  mutable style_override : style option;
}

let print_styled pp style ?(len = None) text =
  let style = Option.value ~default:style pp.style_override in
  let seq = escape_sequence pp.theme style in
  if seq <> "" then Utils.Printer.string_as pp.printer 0 seq;
  (match len with
  | None -> Utils.Printer.string pp.printer text
  | Some len -> Utils.Printer.string_as pp.printer len text);
  if seq <> "" then Utils.Printer.string_as pp.printer 0 pp.theme.reset

let box pp ?indent f = Utils.Printer.box pp.printer ?indent f
let hvbox pp ?indent f = Utils.Printer.hvbox pp.printer ?indent f
let indent pp i f = Utils.Printer.indent pp.printer i f
let space pp () = Utils.Printer.space pp.printer ()
let cut pp () = Utils.Printer.cut pp.printer ()
let newline pp () = Utils.Printer.newline pp.printer ()
let punctuation pp s = print_styled pp Punctuation s
let operator pp s = print_styled pp Operator s

let identifier pp s =
  print_styled pp Identifier ~len:(Some (Utils.Unicode.terminal_width s)) s

let constant pp s = print_styled pp Constant s
let keyword pp s = print_styled pp Keyword s
let type_ pp s = print_styled pp Type s
let comment pp s = print_styled pp Comment s
let string pp ?len s = print_styled pp String ?len s
let attribute pp s = print_styled pp Attribute s

let with_style ctx style f =
  match ctx.style_override with
  | Some _ -> f ()
  | None ->
      ctx.style_override <- Some style;
      f ();
      ctx.style_override <- None

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
      punctuation pp ",";
      space pp ())
    f pp l

let print_paren_list f pp l =
  punctuation pp "(";
  box pp (fun () -> list_commasep f pp l);
  punctuation pp ")"

let heaptype pp (t : heaptype) =
  type_ pp
    (match t with
    | Func -> "func"
    | NoFunc -> "nofunc"
    | Exn -> "exn"
    | NoExn -> "noexn"
    | Cont -> "cont"
    | NoCont -> "nocont"
    | Extern -> "extern"
    | NoExtern -> "noextern"
    | Any -> "any"
    | Eq -> "eq"
    | I31 -> "i31"
    | Struct -> "struct"
    | Array -> "array"
    | None_ -> "none"
    | Type s -> s.desc)

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
  | Tuple l -> tuple false pp l

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
  print_paren_list
    (fun pp (id, t) ->
      match id with
      | None -> valtype pp t
      | Some _ -> print_typed_pat pp (id, Some t))
    pp (Array.to_list params);
  if results <> [||] then (
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
            (fun pp (nm, t) -> print_key_value pp nm.desc fieldtype t)
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

let subtype pp (nm, { typ; supertype; final }) =
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

let long_block l =
  let rec loop (l : _ instr list) n =
    if n <= 0 then 0
    else
      match l with
      | [] -> n
      | { desc = Block { block = l; _ }; _ } :: rem -> loop rem (loop l (n - 2))
      | { desc = Loop { block = l; _ }; _ } :: rem -> loop rem (loop l (n - 2))
      | { desc = If { cond = l1; if_block = l2; else_block = l3; _ }; _ } :: rem
        ->
          let n = loop [ l1 ] (n - 2) in
          let n = loop l2 n in
          let n = match l3 with None -> n | Some l2 -> loop l2 (n - 1) in
          loop rem n
      | { desc = Try { block = l; catches; catch_all; _ }; _ } :: rem ->
          let n = loop l (n - 2) in
          let n = List.fold_left (fun n (_, l) -> loop l (n - 1)) n catches in
          let n = match catch_all with None -> n | Some l -> loop l (n - 1) in
          loop rem n
      | _ :: rem -> loop rem (n - 1)
  in
  loop l 5 <= 0

let block_label pp label =
  Option.iter
    (fun label ->
      identifier pp "'";
      identifier pp label.desc;
      punctuation pp ":";
      space pp ())
    label

let label_comment pp (l, label) =
  if long_block l then
    Option.iter
      (fun label ->
        space pp ();
        comment pp "/* '";
        comment pp label.desc;
        comment pp " */")
      label

let need_blocktype bt = bt.params <> [||] || bt.results <> [||]

let casttype pp ty =
  match ty with
  | Valtype ty -> valtype pp ty
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
  box pp ~indent:indent_level (fun () ->
      Option.iter
        (fun s ->
          keyword pp s;
          space pp ())
        prefix;
      instr CallAndFieldAccess pp i;
      cut pp ();
      print_paren_list (instr Instruction) pp l)

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
  | ArrayFixed _ | ArrayGet _ | ArraySet _ | Sequence _ ->
      Atom
  | Set _ | Tee _ -> Assignement
  | Call _ | TailCall _ -> CallAndFieldAccess
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
  | ArrayDefault _ | ArrayFixed _ | ArrayGet _ | ArraySet _ | BinOp _ | UnOp _
  | Let _ | Br _ | Br_if _ | Br_table _ | Br_on_null _ | Br_on_non_null _
  | Br_on_cast _ | Br_on_cast_fail _ | Throw _ | ThrowRef _ | Return _
  | Sequence _ | Select _ ->
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
    | ArrayDefault _ | ArrayFixed _ | Let _ | Br _ | Br_if _ | Br_table _
    | Br_on_null _ | Br_on_non_null _ | Br_on_cast _ | Br_on_cast_fail _
    | Throw _ | ThrowRef _ | Return _ | Sequence _ ->
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
          block_contents pp if_block;
          match else_block with
          | Some else_block ->
              hvbox pp (fun () ->
                  box pp (fun () ->
                      punctuation pp "}";
                      space pp ();
                      keyword pp "else";
                      space pp ();
                      punctuation pp "{");
                  block_contents pp else_block;
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
                    catch_all;
                  space pp ());
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
      instr CallAndFieldAccess pp i;
      operator pp ".";
      identifier pp s.desc
  | StructSet (i, s, i') ->
      box pp ~indent:indent_level (fun () ->
          instr CallAndFieldAccess pp i;
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
          keyword pp "let";
          space pp ();
          (match l with
          | [ p ] -> print_typed_pat pp p
          | l -> print_paren_list print_typed_pat pp l);
          Option.iter
            (fun i ->
              space pp ();
              keyword pp "=";
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
      box pp (fun () ->
          punctuation pp "}";
          label_comment pp (l, label)))

and deliminated_instr pp (i : _ instr) =
  if is_block i then instr Instruction pp i
  else (
    instr (if starts_with_block i then Atom else Instruction) pp i;
    punctuation pp ";")

and block_contents pp (l : _ instr list) =
  if l <> [] then (
    indent pp indent_level (fun () ->
        List.iter
          (fun i ->
            space pp ();
            deliminated_instr pp i)
          l);
    space pp ())

let fundecl ~tag pp (name, typ, sign) =
  keyword pp (if tag then "tag" else "fn");
  space pp ();
  identifier pp name.desc;
  Option.iter
    (fun typ ->
      punctuation pp ":";
      space pp ();
      identifier pp typ.desc;
      space pp ())
    typ;
  Option.iter
    (fun ty ->
      cut pp ();
      raw_functype pp ty)
    sign

let print_attribute pp (name, i) =
  box pp ~indent:indent_level (fun () ->
      attribute pp "#[";
      attribute pp name;
      space pp ();
      attribute pp "=";
      space pp ();
      with_style pp Attribute (fun () -> instr Instruction pp i);
      attribute pp "]";
      space pp ())

let print_attributes pp attributes = List.iter (print_attribute pp) attributes

let print_attr_prefix pp attributes_list content_fn =
  hvbox pp (fun () ->
      if attributes_list <> [] then (
        print_attributes pp attributes_list;
        newline pp ());
      content_fn ())

let rec modulefield pp field =
  match field.desc with
  | Type t -> rectype pp t
  | Func { name; typ; sign; body = label, body; attributes = a } ->
      print_attr_prefix pp a (fun () ->
          hvbox pp (fun () ->
              box pp (fun () ->
                  fundecl ~tag:false pp (name, typ, sign);
                  space pp ();
                  block_label pp label;
                  punctuation pp "{");
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
              punctuation pp ";"))
  | Fundecl { name; typ; sign; attributes = a } ->
      print_attr_prefix pp a (fun () ->
          box pp (fun () ->
              fundecl ~tag:false pp (name, typ, sign);
              punctuation pp ";"))
  | Tag { name; typ; sign; attributes = a } ->
      print_attr_prefix pp a (fun () ->
          box pp (fun () ->
              fundecl ~tag:true pp (name, typ, sign);
              punctuation pp ";"))
  | GlobalDecl { name; mut; typ; attributes = a } ->
      print_attr_prefix pp a (fun () ->
          box pp ~indent:indent_level (fun () ->
              keyword pp (if mut then "let" else "const");
              space pp ();
              identifier pp name.desc;
              punctuation pp ":";
              space pp ();
              valtype pp typ;
              punctuation pp ";"))
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

let module_ ?(color = Auto) ?out_channel printer l =
  let use_color = should_use_color ~color ~out_channel in
  let theme = get_theme use_color in
  let pp = { printer; theme; style_override = None } in
  hvbox pp (fun () -> list ~sep:space modulefield pp l)

let instr printer i =
  let use_color = should_use_color ~color:Auto ~out_channel:(Some stderr) in
  let theme = get_theme use_color in
  let pp = { printer; theme; style_override = None } in
  instr Instruction pp i

let valtype printer i =
  let use_color = should_use_color ~color:Auto ~out_channel:(Some stderr) in
  let theme = get_theme use_color in
  let pp = { printer; theme; style_override = None } in
  valtype pp i

let storagetype printer i =
  let use_color = should_use_color ~color:Auto ~out_channel:(Some stderr) in
  let theme = get_theme use_color in
  let pp = { printer; theme; style_override = None } in
  storagetype pp i

open Ast
open Ast.Binary

module Encoder = struct
  let byte b i = Buffer.add_char b (Char.chr i)
  let string b s = Buffer.add_string b s

  let rec uint b i =
    if i < 128 then byte b i
    else (
      byte b (128 + (i land 127));
      uint b (i lsr 7))

  let rec sint b i =
    if i >= -64 && i < 64 then byte b (i land 127)
    else (
      byte b (128 + (i land 127));
      sint b (i asr 7))

  let rec sint32 b i =
    if i >= -64l && i < 64l then byte b (Int32.to_int i land 0x7f)
    else (
      byte b (128 + (Int32.to_int i land 127));
      sint32 b (Int32.shift_right i 7))

  let uint64 b i =
    let rec uint64 b i =
      if i >= 0L && i < 128L then byte b (Int64.to_int i)
      else (
        byte b (128 + (Int64.to_int i land 127));
        uint64 b (Int64.shift_right_logical i 7))
    in
    uint64 b (Uint64.to_int64 i)

  let rec sint64 b i =
    if i >= -64L && i < 64L then byte b (Int64.to_int i land 0x7f)
    else (
      byte b (128 + (Int64.to_int i land 127));
      sint64 b (Int64.shift_right i 7))

  let f32 b f =
    let i = Int32.bits_of_float f in
    byte b (Int32.to_int i land 0xff);
    byte b (Int32.to_int (Int32.shift_right i 8) land 0xff);
    byte b (Int32.to_int (Int32.shift_right i 16) land 0xff);
    byte b (Int32.to_int (Int32.shift_right i 24) land 0xff)

  let f64 b f =
    let i = Int64.bits_of_float f in
    byte b (Int64.to_int i land 0xff);
    byte b (Int64.to_int (Int64.shift_right i 8) land 0xff);
    byte b (Int64.to_int (Int64.shift_right i 16) land 0xff);
    byte b (Int64.to_int (Int64.shift_right i 24) land 0xff);
    byte b (Int64.to_int (Int64.shift_right i 32) land 0xff);
    byte b (Int64.to_int (Int64.shift_right i 40) land 0xff);
    byte b (Int64.to_int (Int64.shift_right i 48) land 0xff);
    byte b (Int64.to_int (Int64.shift_right i 56) land 0xff)

  let v128 b s = string b s

  let name b n =
    uint b (String.length n);
    string b n

  let vec f b l =
    uint b (List.length l);
    List.iter (f b) l

  let vec' f b l =
    uint b (Array.length l);
    Array.iter (f b) l

  let heaptype b (t : heaptype) =
    match t with
    | NoExn -> byte b 0x74
    | NoFunc -> byte b 0x73
    | NoExtern -> byte b 0x72
    | None_ -> byte b 0x71
    | Func -> byte b 0x70
    | Extern -> byte b 0x6F
    | Any -> byte b 0x6E
    | Eq -> byte b 0x6D
    | I31 -> byte b 0x6C
    | Struct -> byte b 0x6B
    | Array -> byte b 0x6A
    | Exn -> byte b 0x69
    | Cont -> byte b 0x68
    | NoCont -> byte b 0x75
    | Type idx -> sint b idx

  let reftype b (t : reftype) =
    byte b (if t.nullable then 0x63 else 0x64);
    heaptype b t.typ

  let valtype b (t : valtype) =
    match t with
    | I32 -> byte b 0x7F
    | I64 -> byte b 0x7E
    | F32 -> byte b 0x7D
    | F64 -> byte b 0x7C
    | V128 -> byte b 0x7B
    | Ref r -> reftype b r

  let mut b m = byte b (if m then 0x01 else 0x00)

  let storagetype b s =
    match s with
    | Value v -> valtype b v
    | Packed I8 -> byte b 0x78
    | Packed I16 -> byte b 0x77

  let fieldtype b (f : fieldtype) =
    storagetype b f.typ;
    mut b f.mut

  let limits b (l : limits) =
    let flag =
      (if l.ma <> None then 0x01 else 0x00)
      lor if l.address_type = `I64 then 0x04 else 0x00
    in
    byte b flag;
    uint64 b l.mi;
    match l.ma with None -> () | Some m -> uint64 b m

  let globaltype b (t : globaltype) =
    valtype b t.typ;
    mut b t.mut

  let tabletype b (t : tabletype) =
    reftype b t.reftype;
    limits b t.limits

  let functype b (t : functype) =
    byte b 0x60;
    vec' valtype b t.params;
    vec' valtype b t.results

  let comptype b (t : comptype) =
    match t with
    | Func f -> functype b f
    | Struct fields ->
        byte b 0x5F;
        vec' fieldtype b fields
    | Array field ->
        byte b 0x5E;
        fieldtype b field
    | Cont idx ->
        byte b 0x5D;
        heaptype b (Type idx)

  let subtype b (t : subtype) =
    if t.final && t.supertype = None then comptype b t.typ
    else (
      byte b (if t.final then 0x4F else 0x50);
      vec uint b (match t.supertype with Some i -> [ i ] | None -> []);
      comptype b t.typ)

  let rectype b (t : rectype) =
    match t with
    | [| t |] -> subtype b t
    | _ ->
        byte b 0x4E;
        vec' subtype b t

  let memarg b (m : memarg) idx =
    let align =
      Int.of_float (Float.log2 (Float.of_int (Utils.Uint64.to_int m.align)))
    in
    if idx = 0 then (
      uint b align;
      uint64 b m.offset)
    else (
      uint b (align lor 64);
      uint64 b m.offset;
      uint b idx)

  let blocktype b (t : blocktype) =
    match t with Valtype v -> valtype b v | Typeuse i -> sint b i

  let resumetable b clauses =
    vec
      (fun b c ->
        match c with
        | OnLabel (tag, label) ->
            byte b 0x00;
            uint b tag;
            uint b label
        | OnSwitch tag ->
            byte b 0x01;
            uint b tag)
      b clauses

  let rec instr ~source_map_t b (i : Ast.location instr) =
    (*ZZZ push absence of mapping *)
    (if
       i.info.Utils.Ast.loc_start.Lexing.pos_fname <> ""
       && i.info.Utils.Ast.loc_start.Lexing.pos_lnum <> -1
       && i.info.Utils.Ast.loc_start.Lexing.pos_cnum <> -1
     then
       let generated_offset = Buffer.length b in
       Utils.Source_map.add_mapping source_map_t ~generated_offset
         ~original_location:i.info);

    match i.desc with
    | Unreachable -> byte b 0x00
    | Nop -> byte b 0x01
    | Throw i ->
        byte b 0x08;
        uint b i
    | ThrowRef -> byte b 0x0A
    | ContNew i ->
        byte b 0xE0;
        uint b i
    | ContBind (i, j) ->
        byte b 0xE1;
        uint b i;
        uint b j
    | Suspend i ->
        byte b 0xE2;
        uint b i
    | Resume (i, clauses) ->
        byte b 0xE3;
        uint b i;
        resumetable b clauses
    | ResumeThrow (i, j, clauses) ->
        byte b 0xE4;
        uint b i;
        uint b j;
        resumetable b clauses
    | ResumeThrowRef (i, clauses) ->
        byte b 0xE5;
        uint b i;
        resumetable b clauses
    | Switch (i, j) ->
        byte b 0xE6;
        uint b i;
        uint b j
    | Block { typ; block; _ } ->
        byte b 0x02;
        (match typ with Some t -> blocktype b t | None -> byte b 0x40);
        List.iter (instr ~source_map_t b) block;
        byte b 0x0B
    | Loop { typ; block; _ } ->
        byte b 0x03;
        (match typ with Some t -> blocktype b t | None -> byte b 0x40);
        List.iter (instr ~source_map_t b) block;
        byte b 0x0B
    | If { typ; if_block; else_block; _ } ->
        byte b 0x04;
        (match typ with Some t -> blocktype b t | None -> byte b 0x40);
        List.iter (instr ~source_map_t b) if_block.desc;
        if else_block.desc <> [] then (
          byte b 0x05;
          List.iter (instr ~source_map_t b) else_block.desc);
        byte b 0x0B
    | TryTable { typ; block; catches; _ } ->
        byte b 0x1F;
        (match typ with Some t -> blocktype b t | None -> byte b 0x40);
        vec
          (fun b c ->
            match c with
            | Catch (tag, label) ->
                byte b 0x00;
                uint b tag;
                uint b label
            | CatchRef (tag, label) ->
                byte b 0x01;
                uint b tag;
                uint b label
            | CatchAll label ->
                byte b 0x02;
                uint b label
            | CatchAllRef label ->
                byte b 0x03;
                uint b label)
          b catches;
        List.iter (instr ~source_map_t b) block;
        byte b 0x0B
    | Try { typ; block; catches; catch_all; _ } ->
        byte b 0x06;
        (match typ with Some t -> blocktype b t | None -> byte b 0x40);
        List.iter (instr ~source_map_t b) block;
        List.iter
          (fun (tag, block) ->
            byte b 0x07;
            uint b tag;
            List.iter (instr ~source_map_t b) block)
          catches;
        (match catch_all with
        | Some block ->
            byte b 0x19;
            List.iter (instr ~source_map_t b) block
        | None -> ());
        byte b 0x0B
    | Br i ->
        byte b 0x0C;
        uint b i
    | Br_if i ->
        byte b 0x0D;
        uint b i
    | Br_table (ls, d) ->
        byte b 0x0E;
        vec uint b ls;
        uint b d
    | Br_on_null i ->
        byte b 0xD5;
        uint b i
    | Br_on_non_null i ->
        byte b 0xD6;
        uint b i
    | Br_on_cast (i, r1, r2) ->
        byte b 0xFB;
        byte b 0x18;
        byte b ((if r1.nullable then 1 else 0) + if r2.nullable then 2 else 0);
        uint b i;
        heaptype b r1.typ;
        heaptype b r2.typ
    | Br_on_cast_fail (i, r1, r2) ->
        byte b 0xFB;
        byte b 0x19;
        byte b ((if r1.nullable then 1 else 0) + if r2.nullable then 2 else 0);
        uint b i;
        heaptype b r1.typ;
        heaptype b r2.typ
    | Return -> byte b 0x0F
    | Call i ->
        byte b 0x10;
        uint b i
    | CallIndirect (table, type_idx) ->
        byte b 0x11;
        uint b type_idx;
        uint b table
    | CallRef i ->
        byte b 0x14;
        uint b i
    | ReturnCall i ->
        byte b 0x12;
        uint b i
    | ReturnCallRef i ->
        byte b 0x15;
        uint b i
    | ReturnCallIndirect (table, type_idx) ->
        byte b 0x13;
        uint b type_idx;
        uint b table
    | Drop -> byte b 0x1A
    | Select None -> byte b 0x1B
    | Select (Some types) ->
        byte b 0x1C;
        vec valtype b types
    | LocalGet i ->
        byte b 0x20;
        uint b i
    | LocalSet i ->
        byte b 0x21;
        uint b i
    | LocalTee i ->
        byte b 0x22;
        uint b i
    | GlobalGet i ->
        byte b 0x23;
        uint b i
    | GlobalSet i ->
        byte b 0x24;
        uint b i
    | TableGet i ->
        byte b 0x25;
        uint b i
    | TableSet i ->
        byte b 0x26;
        uint b i
    | TableSize i ->
        byte b 0xFC;
        byte b 0x10;
        uint b i
    | TableGrow i ->
        byte b 0xFC;
        byte b 0x0F;
        uint b i
    | TableFill i ->
        byte b 0xFC;
        byte b 0x11;
        uint b i
    | TableCopy (i1, i2) ->
        byte b 0xFC;
        byte b 0x0E;
        uint b i1;
        uint b i2
    | TableInit (i1, i2) ->
        byte b 0xFC;
        byte b 0x0C;
        uint b i1;
        uint b i2
    | ElemDrop i ->
        byte b 0xFC;
        byte b 0x0D;
        uint b i
    | Load (mem_idx, m, typ) ->
        (match typ with
        | NumI32 -> byte b 0x28
        | NumI64 -> byte b 0x29
        | NumF32 -> byte b 0x2A
        | NumF64 -> byte b 0x2B);
        memarg b m mem_idx
    | LoadS (mem_idx, m, typ, sz, s) ->
        (match (typ, sz, s) with
        | `I32, `I8, Signed -> byte b 0x2C
        | `I32, `I8, Unsigned -> byte b 0x2D
        | `I32, `I16, Signed -> byte b 0x2E
        | `I32, `I16, Unsigned -> byte b 0x2F
        | `I64, `I8, Signed -> byte b 0x30
        | `I64, `I8, Unsigned -> byte b 0x31
        | `I64, `I16, Signed -> byte b 0x32
        | `I64, `I16, Unsigned -> byte b 0x33
        | `I64, `I32, Signed -> byte b 0x34
        | `I64, `I32, Unsigned -> byte b 0x35
        | _ -> failwith "Invalid LoadS combination");
        memarg b m mem_idx
    | Store (mem_idx, m, typ) ->
        (match typ with
        | NumI32 -> byte b 0x36
        | NumI64 -> byte b 0x37
        | NumF32 -> byte b 0x38
        | NumF64 -> byte b 0x39);
        memarg b m mem_idx
    | StoreS (mem_idx, m, typ, sz) ->
        (match (typ, sz) with
        | `I32, `I8 -> byte b 0x3A
        | `I32, `I16 -> byte b 0x3B
        | `I64, `I8 -> byte b 0x3C
        | `I64, `I16 -> byte b 0x3D
        | `I64, `I32 -> byte b 0x3E
        | _ -> failwith "Invalid StoreS combination");
        memarg b m mem_idx
    | MemorySize i ->
        byte b 0x3F;
        uint b i
    | MemoryGrow i ->
        byte b 0x40;
        uint b i
    | MemoryFill i ->
        byte b 0xFC;
        byte b 0x0B;
        uint b i
    | MemoryCopy (i1, i2) ->
        byte b 0xFC;
        byte b 0x0A;
        uint b i1;
        uint b i2
    | MemoryInit (i1, i2) ->
        byte b 0xFC;
        byte b 0x08;
        uint b i1;
        uint b i2
    | DataDrop i ->
        byte b 0xFC;
        byte b 0x09;
        uint b i
    | Const (I32 i) ->
        byte b 0x41;
        sint32 b i
    | Const (I64 i) ->
        byte b 0x42;
        sint64 b i
    | Const (F32 f) ->
        byte b 0x43;
        f32 b f
    | Const (F64 f) ->
        byte b 0x44;
        f64 b f
    | UnOp op -> (
        match op with
        | I32 Clz -> byte b 0x67
        | I32 Ctz -> byte b 0x68
        | I32 Popcnt -> byte b 0x69
        | I64 Clz -> byte b 0x79
        | I64 Ctz -> byte b 0x7A
        | I64 Popcnt -> byte b 0x7B
        | F32 Abs -> byte b 0x8B
        | F32 Neg -> byte b 0x8C
        | F32 Ceil -> byte b 0x8D
        | F32 Floor -> byte b 0x8E
        | F32 Trunc -> byte b 0x8F
        | F32 Nearest -> byte b 0x90
        | F32 Sqrt -> byte b 0x91
        | F64 Abs -> byte b 0x99
        | F64 Neg -> byte b 0x9A
        | F64 Ceil -> byte b 0x9B
        | F64 Floor -> byte b 0x9C
        | F64 Trunc -> byte b 0x9D
        | F64 Nearest -> byte b 0x9E
        | F64 Sqrt -> byte b 0x9F
        | I32 Eqz -> byte b 0x45
        | I64 Eqz -> byte b 0x50
        | I32 (ExtendS `_8) -> byte b 0xC0
        | I32 (ExtendS `_16) -> byte b 0xC1
        | I64 (ExtendS `_8) -> byte b 0xC2
        | I64 (ExtendS `_16) -> byte b 0xC3
        | I64 (ExtendS `_32) -> byte b 0xC4
        | I32 (ExtendS `_32) -> failwith "Invalid ExtendS combination"
        | I32 (Trunc (`F32, Signed)) -> byte b 0xA8
        | I32 (Trunc (`F32, Unsigned)) -> byte b 0xA9
        | I32 (Trunc (`F64, Signed)) -> byte b 0xAA
        | I32 (Trunc (`F64, Unsigned)) -> byte b 0xAB
        | I64 (Trunc (`F32, Signed)) -> byte b 0xAE
        | I64 (Trunc (`F32, Unsigned)) -> byte b 0xAF
        | I64 (Trunc (`F64, Signed)) -> byte b 0xB0
        | I64 (Trunc (`F64, Unsigned)) -> byte b 0xB1
        | I32 (TruncSat (`F32, Signed)) ->
            byte b 0xFC;
            byte b 0x00
        | I32 (TruncSat (`F32, Unsigned)) ->
            byte b 0xFC;
            byte b 0x01
        | I32 (TruncSat (`F64, Signed)) ->
            byte b 0xFC;
            byte b 0x02
        | I32 (TruncSat (`F64, Unsigned)) ->
            byte b 0xFC;
            byte b 0x03
        | I64 (TruncSat (`F32, Signed)) ->
            byte b 0xFC;
            byte b 0x04
        | I64 (TruncSat (`F32, Unsigned)) ->
            byte b 0xFC;
            byte b 0x05
        | I64 (TruncSat (`F64, Signed)) ->
            byte b 0xFC;
            byte b 0x06
        | I64 (TruncSat (`F64, Unsigned)) ->
            byte b 0xFC;
            byte b 0x07
        | F32 (Convert (`I32, Signed)) -> byte b 0xB2
        | F32 (Convert (`I32, Unsigned)) -> byte b 0xB3
        | F32 (Convert (`I64, Signed)) -> byte b 0xB4
        | F32 (Convert (`I64, Unsigned)) -> byte b 0xB5
        | F64 (Convert (`I32, Signed)) -> byte b 0xB7
        | F64 (Convert (`I32, Unsigned)) -> byte b 0xB8
        | F64 (Convert (`I64, Signed)) -> byte b 0xB9
        | F64 (Convert (`I64, Unsigned)) -> byte b 0xBA
        | I32 Reinterpret -> byte b 0xBC
        | I64 Reinterpret -> byte b 0xBD
        | F32 Reinterpret -> byte b 0xBE
        | F64 Reinterpret -> byte b 0xBF)
    | BinOp op -> (
        match op with
        | I32 Add -> byte b 0x6A
        | I32 Sub -> byte b 0x6B
        | I32 Mul -> byte b 0x6C
        | I32 (Div Signed) -> byte b 0x6D
        | I32 (Div Unsigned) -> byte b 0x6E
        | I32 (Rem Signed) -> byte b 0x6F
        | I32 (Rem Unsigned) -> byte b 0x70
        | I32 And -> byte b 0x71
        | I32 Or -> byte b 0x72
        | I32 Xor -> byte b 0x73
        | I32 Shl -> byte b 0x74
        | I32 (Shr Signed) -> byte b 0x75
        | I32 (Shr Unsigned) -> byte b 0x76
        | I32 Rotl -> byte b 0x77
        | I32 Rotr -> byte b 0x78
        | I64 Add -> byte b 0x7C
        | I64 Sub -> byte b 0x7D
        | I64 Mul -> byte b 0x7E
        | I64 (Div Signed) -> byte b 0x7F
        | I64 (Div Unsigned) -> byte b 0x80
        | I64 (Rem Signed) -> byte b 0x81
        | I64 (Rem Unsigned) -> byte b 0x82
        | I64 And -> byte b 0x83
        | I64 Or -> byte b 0x84
        | I64 Xor -> byte b 0x85
        | I64 Shl -> byte b 0x86
        | I64 (Shr Signed) -> byte b 0x87
        | I64 (Shr Unsigned) -> byte b 0x88
        | I64 Rotl -> byte b 0x89
        | I64 Rotr -> byte b 0x8A
        | F32 Add -> byte b 0x92
        | F32 Sub -> byte b 0x93
        | F32 Mul -> byte b 0x94
        | F32 Div -> byte b 0x95
        | F32 Min -> byte b 0x96
        | F32 Max -> byte b 0x97
        | F32 CopySign -> byte b 0x98
        | F64 Add -> byte b 0xA0
        | F64 Sub -> byte b 0xA1
        | F64 Mul -> byte b 0xA2
        | F64 Div -> byte b 0xA3
        | F64 Min -> byte b 0xA4
        | F64 Max -> byte b 0xA5
        | F64 CopySign -> byte b 0xA6
        | I32 Eq -> byte b 0x46
        | I32 Ne -> byte b 0x47
        | I32 (Lt Signed) -> byte b 0x48
        | I32 (Lt Unsigned) -> byte b 0x49
        | I32 (Gt Signed) -> byte b 0x4A
        | I32 (Gt Unsigned) -> byte b 0x4B
        | I32 (Le Signed) -> byte b 0x4C
        | I32 (Le Unsigned) -> byte b 0x4D
        | I32 (Ge Signed) -> byte b 0x4E
        | I32 (Ge Unsigned) -> byte b 0x4F
        | I64 Eq -> byte b 0x51
        | I64 Ne -> byte b 0x52
        | I64 (Lt Signed) -> byte b 0x53
        | I64 (Lt Unsigned) -> byte b 0x54
        | I64 (Gt Signed) -> byte b 0x55
        | I64 (Gt Unsigned) -> byte b 0x56
        | I64 (Le Signed) -> byte b 0x57
        | I64 (Le Unsigned) -> byte b 0x58
        | I64 (Ge Signed) -> byte b 0x59
        | I64 (Ge Unsigned) -> byte b 0x5A
        | F32 Eq -> byte b 0x5B
        | F32 Ne -> byte b 0x5C
        | F32 Lt -> byte b 0x5D
        | F32 Gt -> byte b 0x5E
        | F32 Le -> byte b 0x5F
        | F32 Ge -> byte b 0x60
        | F64 Eq -> byte b 0x61
        | F64 Ne -> byte b 0x62
        | F64 Lt -> byte b 0x63
        | F64 Gt -> byte b 0x64
        | F64 Le -> byte b 0x65
        | F64 Ge -> byte b 0x66)
    | I32WrapI64 -> byte b 0xA7
    | I64ExtendI32 Signed -> byte b 0xAC
    | I64ExtendI32 Unsigned -> byte b 0xAD
    | F32DemoteF64 -> byte b 0xB6
    | F64PromoteF32 -> byte b 0xBB
    | ExternConvertAny ->
        byte b 0xFB;
        byte b 0x1B
    | AnyConvertExtern ->
        byte b 0xFB;
        byte b 0x1A
    | RefNull t ->
        byte b 0xD0;
        heaptype b t
    | RefIsNull -> byte b 0xD1
    | RefFunc i ->
        byte b 0xD2;
        uint b i
    | RefEq -> byte b 0xD3
    | RefAsNonNull -> byte b 0xD4
    | RefTest t ->
        byte b 0xFB;
        byte b (if t.nullable then 0x15 else 0x14);
        heaptype b t.typ
    | RefCast t ->
        byte b 0xFB;
        byte b (if t.nullable then 0x17 else 0x16);
        heaptype b t.typ
    | StructNew i ->
        byte b 0xFB;
        byte b 0x00;
        uint b i
    | StructNewDefault i ->
        byte b 0xFB;
        byte b 0x01;
        uint b i
    | StructGet (s, type_idx, field_idx) ->
        byte b 0xFB;
        byte b
          (match s with
          | None -> 0x02
          | Some Signed -> 0x03
          | Some Unsigned -> 0x04);
        uint b type_idx;
        uint b field_idx
    | StructSet (type_idx, field_idx) ->
        byte b 0xFB;
        byte b 0x05;
        uint b type_idx;
        uint b field_idx
    | ArrayNew i ->
        byte b 0xFB;
        byte b 0x06;
        uint b i
    | ArrayNewDefault i ->
        byte b 0xFB;
        byte b 0x07;
        uint b i
    | ArrayNewFixed (i, len) ->
        byte b 0xFB;
        byte b 0x08;
        uint b i;
        uint b (Utils.Uint32.to_int len)
    | ArrayNewData (type_idx, data_idx) ->
        byte b 0xFB;
        byte b 0x09;
        uint b type_idx;
        uint b data_idx
    | ArrayNewElem (type_idx, elem_idx) ->
        byte b 0xFB;
        byte b 0x0A;
        uint b type_idx;
        uint b elem_idx
    | ArrayGet (s, type_idx) ->
        byte b 0xFB;
        byte b
          (match s with
          | None -> 0x0B
          | Some Signed -> 0x0C
          | Some Unsigned -> 0x0D);
        uint b type_idx
    | ArraySet type_idx ->
        byte b 0xFB;
        byte b 0x0E;
        uint b type_idx
    | ArrayLen ->
        byte b 0xFB;
        byte b 0x0F
    | ArrayFill type_idx ->
        byte b 0xFB;
        byte b 0x10;
        uint b type_idx
    | ArrayCopy (type_idx_dst, type_idx_src) ->
        byte b 0xFB;
        byte b 0x11;
        uint b type_idx_dst;
        uint b type_idx_src
    | ArrayInitData (type_idx, data_idx) ->
        byte b 0xFB;
        byte b 0x12;
        uint b type_idx;
        uint b data_idx
    | ArrayInitElem (type_idx, elem_idx) ->
        byte b 0xFB;
        byte b 0x13;
        uint b type_idx;
        uint b elem_idx
    | RefI31 ->
        byte b 0xFB;
        byte b 0x1C
    | I31Get Signed ->
        byte b 0xFB;
        byte b 0x1D
    | I31Get Unsigned ->
        byte b 0xFB;
        byte b 0x1E
    | Pop _ -> ()
    | VecLoad (idx, op, m) ->
        byte b 0xFD;
        uint b
          (match op with
          | Load128 -> 0
          | Load8x8S -> 1
          | Load8x8U -> 2
          | Load16x4S -> 3
          | Load16x4U -> 4
          | Load32x2S -> 5
          | Load32x2U -> 6
          | Load32Zero -> 92
          | Load64Zero -> 93);
        memarg b m idx
    | VecLoadSplat (idx, op, m) ->
        byte b 0xFD;
        uint b (match op with `I8 -> 7 | `I16 -> 8 | `I32 -> 9 | `I64 -> 10);
        memarg b m idx
    | VecStore (idx, m) ->
        byte b 0xFD;
        uint b 11;
        memarg b m idx
    | VecConst v ->
        byte b 0xFD;
        uint b 12;
        v128 b v
    | VecShuffle v ->
        byte b 0xFD;
        uint b 13;
        v128 b v
    | VecSplat shape ->
        byte b 0xFD;
        uint b
          (match shape with
          | I8x16 -> 15
          | I16x8 -> 16
          | I32x4 -> 17
          | I64x2 -> 18
          | F32x4 -> 19
          | F64x2 -> 20)
    | VecExtract (op, s, lane) ->
        byte b 0xFD;
        uint b
          (match (op, s) with
          | I8x16, Some Signed -> 21
          | I8x16, Some Unsigned -> 22
          | I16x8, Some Signed -> 24
          | I16x8, Some Unsigned -> 25
          | I32x4, None -> 27
          | I64x2, None -> 29
          | F32x4, None -> 31
          | F64x2, None -> 33
          | _ -> assert false);
        uint b lane
    | VecReplace (op, lane) ->
        byte b 0xFD;
        uint b
          (match op with
          | I8x16 -> 23
          | I16x8 -> 26
          | I32x4 -> 28
          | I64x2 -> 30
          | F32x4 -> 32
          | F64x2 -> 34);
        uint b lane
    | VecBitselect ->
        byte b 0xFD;
        uint b 82
    | VecTest op ->
        byte b 0xFD;
        uint b
          (match op with
          | AnyTrue -> 83
          | AllTrue I8x16 -> 99
          | AllTrue I16x8 -> 131
          | AllTrue I32x4 -> 163
          | AllTrue I64x2 -> 195
          | AllTrue (F32x4 | F64x2) -> failwith "AllTrue on float not supported")
    | VecLoadLane (idx, op, m, lane) ->
        byte b 0xFD;
        uint b
          (match op with `I8 -> 84 | `I16 -> 85 | `I32 -> 86 | `I64 -> 87);
        memarg b m idx;
        uint b lane
    | VecStoreLane (idx, op, m, lane) ->
        byte b 0xFD;
        uint b
          (match op with `I8 -> 88 | `I16 -> 89 | `I32 -> 90 | `I64 -> 91);
        memarg b m idx;
        uint b lane
    | VecBitmask (Bitmask shape) ->
        byte b 0xFD;
        uint b
          (match shape with
          | I8x16 -> 100
          | I16x8 -> 132
          | I32x4 -> 164
          | I64x2 -> 196
          | F32x4 | F64x2 -> assert false)
    | VecShift op ->
        byte b 0xFD;
        uint b
          (match op with
          | Shl I8x16 -> 107
          | Shr (Signed, I8x16) -> 108
          | Shr (Unsigned, I8x16) -> 109
          | Shl I16x8 -> 139
          | Shr (Signed, I16x8) -> 140
          | Shr (Unsigned, I16x8) -> 141
          | Shl I32x4 -> 171
          | Shr (Signed, I32x4) -> 172
          | Shr (Unsigned, I32x4) -> 173
          | Shl I64x2 -> 203
          | Shr (Signed, I64x2) -> 204
          | Shr (Unsigned, I64x2) -> 205
          | _ -> assert false)
    | VecUnOp op ->
        byte b 0xFD;
        uint b
          (match op with
          | VecNot -> 77
          | VecDemote -> 94
          | VecPromote -> 95
          | VecAbs I8x16 -> 96
          | VecNeg I8x16 -> 97
          | VecPopcnt -> 98
          | VecCeil `F32 -> 103
          | VecFloor `F32 -> 104
          | VecTrunc `F32 -> 105
          | VecNearest `F32 -> 106
          | VecCeil `F64 -> 116
          | VecFloor `F64 -> 117
          | VecTrunc `F64 -> 122
          | VecExtAddPairwise (Signed, `I8) -> 124
          | VecExtAddPairwise (Unsigned, `I8) -> 125
          | VecExtAddPairwise (Signed, `I16) -> 126
          | VecExtAddPairwise (Unsigned, `I16) -> 127
          | VecAbs I16x8 -> 128
          | VecNeg I16x8 -> 129
          | VecExtend (`Low, `_8, Signed) -> 135
          | VecExtend (`High, `_8, Signed) -> 136
          | VecExtend (`Low, `_8, Unsigned) -> 137
          | VecExtend (`High, `_8, Unsigned) -> 138
          | VecNearest `F64 -> 148
          | VecAbs I32x4 -> 160
          | VecNeg I32x4 -> 161
          | VecExtend (`Low, `_16, Signed) -> 167
          | VecExtend (`High, `_16, Signed) -> 168
          | VecExtend (`Low, `_16, Unsigned) -> 169
          | VecExtend (`High, `_16, Unsigned) -> 170
          | VecAbs I64x2 -> 192
          | VecNeg I64x2 -> 193
          | VecExtend (`Low, `_32, Signed) -> 199
          | VecExtend (`High, `_32, Signed) -> 200
          | VecExtend (`Low, `_32, Unsigned) -> 201
          | VecExtend (`High, `_32, Unsigned) -> 202
          | VecAbs F32x4 -> 224
          | VecNeg F32x4 -> 225
          | VecSqrt `F32 -> 227
          | VecAbs F64x2 -> 236
          | VecNeg F64x2 -> 237
          | VecSqrt `F64 -> 239
          | VecTruncSat (`F32, Signed) -> 248
          | VecTruncSat (`F32, Unsigned) -> 249
          | VecConvert (`F32, Signed) -> 250
          | VecConvert (`F32, Unsigned) -> 251
          | VecTruncSat (`F64, Signed) -> 252
          | VecTruncSat (`F64, Unsigned) -> 253
          | VecConvert (`F64, Signed) -> 254
          | VecConvert (`F64, Unsigned) -> 255
          | VecRelaxedTrunc Signed -> 0x101
          | VecRelaxedTrunc Unsigned -> 0x102
          | VecRelaxedTruncZero Signed -> 0x103
          | VecRelaxedTruncZero Unsigned -> 0x104)
    | VecBinOp op ->
        byte b 0xFD;
        uint b
          (match op with
          | VecSwizzle -> 14
          | VecEq I8x16 -> 35
          | VecNe I8x16 -> 36
          | VecLt (Some Signed, I8x16) -> 37
          | VecLt (Some Unsigned, I8x16) -> 38
          | VecGt (Some Signed, I8x16) -> 39
          | VecGt (Some Unsigned, I8x16) -> 40
          | VecLe (Some Signed, I8x16) -> 41
          | VecLe (Some Unsigned, I8x16) -> 42
          | VecGe (Some Signed, I8x16) -> 43
          | VecGe (Some Unsigned, I8x16) -> 44
          | VecEq I16x8 -> 45
          | VecNe I16x8 -> 46
          | VecLt (Some Signed, I16x8) -> 47
          | VecLt (Some Unsigned, I16x8) -> 48
          | VecGt (Some Signed, I16x8) -> 49
          | VecGt (Some Unsigned, I16x8) -> 50
          | VecLe (Some Signed, I16x8) -> 51
          | VecLe (Some Unsigned, I16x8) -> 52
          | VecGe (Some Signed, I16x8) -> 53
          | VecGe (Some Unsigned, I16x8) -> 54
          | VecEq I32x4 -> 55
          | VecNe I32x4 -> 56
          | VecLt (Some Signed, I32x4) -> 57
          | VecLt (Some Unsigned, I32x4) -> 58
          | VecGt (Some Signed, I32x4) -> 59
          | VecGt (Some Unsigned, I32x4) -> 60
          | VecLe (Some Signed, I32x4) -> 61
          | VecLe (Some Unsigned, I32x4) -> 62
          | VecGe (Some Signed, I32x4) -> 63
          | VecGe (Some Unsigned, I32x4) -> 64
          | VecEq F32x4 -> 65
          | VecNe F32x4 -> 66
          | VecLt (None, F32x4) -> 67
          | VecGt (None, F32x4) -> 68
          | VecLe (None, F32x4) -> 69
          | VecGe (None, F32x4) -> 70
          | VecEq F64x2 -> 71
          | VecNe F64x2 -> 72
          | VecLt (None, F64x2) -> 73
          | VecGt (None, F64x2) -> 74
          | VecLe (None, F64x2) -> 75
          | VecGe (None, F64x2) -> 76
          | VecAnd -> 78
          | VecAndNot -> 79
          | VecOr -> 80
          | VecXor -> 81
          | VecNarrow (Signed, `I8) -> 101
          | VecNarrow (Unsigned, `I8) -> 102
          | VecAdd I8x16 -> 110
          | VecAddSat (Signed, `I8) -> 111
          | VecAddSat (Unsigned, `I8) -> 112
          | VecSub I8x16 -> 113
          | VecSubSat (Signed, `I8) -> 114
          | VecSubSat (Unsigned, `I8) -> 115
          | VecMin (Some Signed, I8x16) -> 118
          | VecMin (Some Unsigned, I8x16) -> 119
          | VecMax (Some Signed, I8x16) -> 120
          | VecMax (Some Unsigned, I8x16) -> 121
          | VecAvgr `I8 -> 123
          | VecQ15MulrSat -> 130
          | VecNarrow (Signed, `I16) -> 133
          | VecNarrow (Unsigned, `I16) -> 134
          | VecAdd I16x8 -> 142
          | VecAddSat (Signed, `I16) -> 143
          | VecAddSat (Unsigned, `I16) -> 144
          | VecSub I16x8 -> 145
          | VecSubSat (Signed, `I16) -> 146
          | VecSubSat (Unsigned, `I16) -> 147
          | VecMul I16x8 -> 149
          | VecMin (Some Signed, I16x8) -> 150
          | VecMin (Some Unsigned, I16x8) -> 151
          | VecMax (Some Signed, I16x8) -> 152
          | VecMax (Some Unsigned, I16x8) -> 153
          | VecAvgr `I16 -> 155
          | VecExtMulLow (Signed, `_8) -> 156
          | VecExtMulHigh (Signed, `_8) -> 157
          | VecExtMulLow (Unsigned, `_8) -> 158
          | VecExtMulHigh (Unsigned, `_8) -> 159
          | VecAdd I32x4 -> 174
          | VecSub I32x4 -> 177
          | VecMul I32x4 -> 181
          | VecMin (Some Signed, I32x4) -> 182
          | VecMin (Some Unsigned, I32x4) -> 183
          | VecMax (Some Signed, I32x4) -> 184
          | VecMax (Some Unsigned, I32x4) -> 185
          | VecDot -> 186
          | VecExtMulLow (Signed, `_16) -> 188
          | VecExtMulHigh (Signed, `_16) -> 189
          | VecExtMulLow (Unsigned, `_16) -> 190
          | VecExtMulHigh (Unsigned, `_16) -> 191
          | VecAdd I64x2 -> 206
          | VecSub I64x2 -> 209
          | VecMul I64x2 -> 213
          | VecEq I64x2 -> 214
          | VecNe I64x2 -> 215
          | VecLt (Some Signed, I64x2) -> 216
          | VecGt (Some Signed, I64x2) -> 217
          | VecLe (Some Signed, I64x2) -> 218
          | VecGe (Some Signed, I64x2) -> 219
          | VecExtMulLow (Signed, `_32) -> 220
          | VecExtMulHigh (Signed, `_32) -> 221
          | VecExtMulLow (Unsigned, `_32) -> 222
          | VecExtMulHigh (Unsigned, `_32) -> 223
          | VecAdd F32x4 -> 228
          | VecSub F32x4 -> 229
          | VecMul F32x4 -> 230
          | VecDiv `F32 -> 231
          | VecMin (None, F32x4) -> 232
          | VecMax (None, F32x4) -> 233
          | VecPMin `F32 -> 234
          | VecPMax `F32 -> 235
          | VecAdd F64x2 -> 240
          | VecSub F64x2 -> 241
          | VecMul F64x2 -> 242
          | VecDiv `F64 -> 243
          | VecMin (None, F64x2) -> 244
          | VecMax (None, F64x2) -> 245
          | VecPMin `F64 -> 246
          | VecPMax `F64 -> 247
          (* Relaxed SIMD *)
          | VecRelaxedSwizzle -> 0x100
          | VecRelaxedMin F32x4 -> 0x10d
          | VecRelaxedMax F32x4 -> 0x10e
          | VecRelaxedMin F64x2 -> 0x10f
          | VecRelaxedMax F64x2 -> 0x110
          | VecRelaxedQ15Mulr -> 0x111
          | VecRelaxedDot -> 0x112
          | VecMul I8x16
          | VecLt (Some Unsigned, I64x2)
          | VecGt (Some Unsigned, I64x2)
          | VecLe (Some Unsigned, I64x2)
          | VecGe (Some Unsigned, I64x2)
          | VecMin (Some Unsigned, I64x2)
          | VecMax (Some Unsigned, I64x2)
          | VecLt _ | VecGt _ | VecLe _ | VecGe _ | VecMin _ | VecMax _
          | VecRelaxedMin _ | VecRelaxedMax _ ->
              assert false)
    | VecTernOp op ->
        byte b 0xFD;
        uint b
          (match op with
          | VecRelaxedMAdd `F32 -> 0x105
          | VecRelaxedNMAdd `F32 -> 0x106
          | VecRelaxedMAdd `F64 -> 0x107
          | VecRelaxedNMAdd `F64 -> 0x108
          | VecRelaxedLaneSelect I8x16 -> 0x109
          | VecRelaxedLaneSelect I16x8 -> 0x10a
          | VecRelaxedLaneSelect I32x4 -> 0x10b
          | VecRelaxedLaneSelect I64x2 -> 0x10c
          | VecRelaxedDotAdd -> 0x113
          | VecRelaxedLaneSelect (F32x4 | F64x2) -> assert false)
    | String _ | Char _ -> assert false (* Desugared *)
    | If_annotation _ -> assert false (* Reported by [Text_to_binary]. *)
    | Folded (i, is) ->
        List.iter (instr ~source_map_t b) is;
        instr ~source_map_t b i

  let expr ~source_map_t b e =
    List.iter (instr ~source_map_t b) e;
    byte b 0x0B
end

let output_section ch id encoder data =
  let b = Buffer.create 1024 in
  encoder b data;
  Out_channel.output_byte ch id;
  let len = Buffer.length b in
  let rec output_uint i =
    if i < 128 then Out_channel.output_byte ch i
    else (
      Out_channel.output_byte ch (128 + (i land 127));
      output_uint (i lsr 7))
  in
  output_uint len;
  Buffer.output_buffer ch b

let module_ ~out_channel ?opt_source_map_file (m : Ast.location module_) =
  Out_channel.output_string out_channel "\x00\x61\x73\x6D\x01\x00\x00\x00";

  let source_map_t = Utils.Source_map.create () in

  (* 1. Type Section *)
  if m.types <> [] then
    output_section out_channel 1 (Encoder.vec Encoder.rectype) m.types;

  (* 2. Import Section *)
  if m.imports <> [] then
    output_section out_channel 2
      (Encoder.vec (fun b (i : import) ->
           Encoder.name b i.module_;
           Encoder.name b i.name;
           match i.desc with
           | Func i ->
               Encoder.byte b 0x00;
               Encoder.sint b i
           | Table t ->
               Encoder.byte b 0x01;
               Encoder.tabletype b t
           | Memory l ->
               Encoder.byte b 0x02;
               Encoder.limits b l
           | Global g ->
               Encoder.byte b 0x03;
               Encoder.globaltype b g
           | Tag t ->
               Encoder.byte b 0x04;
               Encoder.byte b 0x00;
               Encoder.sint b t))
      m.imports;

  (* 3. Function Section *)
  if m.functions <> [] then
    output_section out_channel 3 (Encoder.vec Encoder.sint) m.functions;

  (* 4. Table Section *)
  if m.tables <> [] then
    output_section out_channel 4
      (Encoder.vec (fun b (t : Ast.location table) ->
           match t.expr with
           | Some e ->
               Encoder.byte b 0x40;
               Encoder.byte b 0x00;
               Encoder.tabletype b t.typ;
               Encoder.expr ~source_map_t b e
           | None -> Encoder.tabletype b t.typ))
      m.tables;

  (* 5. Memory Section *)
  if m.memories <> [] then
    output_section out_channel 5 (Encoder.vec Encoder.limits) m.memories;

  (* 6. Tag Section *)
  if m.tags <> [] then
    output_section out_channel 13
      (Encoder.vec (fun b i ->
           Encoder.byte b 0x00;
           Encoder.sint b i))
      m.tags;

  (* 7. Global Section *)
  if m.globals <> [] then
    output_section out_channel 6
      (Encoder.vec (fun b (g : Ast.location global) ->
           Encoder.globaltype b g.typ;
           Encoder.expr ~source_map_t b g.init))
      m.globals;

  (* 8. Export Section *)
  if m.exports <> [] then
    output_section out_channel 7
      (Encoder.vec (fun b (e : export) ->
           Encoder.name b e.name;
           (match e.kind with
           | Func -> Encoder.byte b 0x00
           | Table -> Encoder.byte b 0x01
           | Memory -> Encoder.byte b 0x02
           | Global -> Encoder.byte b 0x03
           | Tag -> Encoder.byte b 0x04);
           Encoder.sint b e.index))
      m.exports;

  (* 9. Start Section *)
  (match m.start with
  | Some i -> output_section out_channel 8 Encoder.sint i
  | None -> ());

  (* 10. Element Section *)
  if m.elem <> [] then
    output_section out_channel 9
      (Encoder.vec (fun b (e : Ast.location elem) ->
           let get_func_indices exprs =
             try
               Some
                 (List.map
                    (function
                      | [ { Ast.desc = Ast.Binary.RefFunc idx; _ } ] -> idx
                      | _ -> raise Exit)
                    exprs)
             with Exit -> None
           in
           let is_funcref = e.typ.nullable && e.typ.typ = Func in
           let indices_opt =
             if is_funcref then get_func_indices e.init else None
           in
           match (e.mode, indices_opt) with
           | Active (0, offset), Some idxs ->
               Encoder.byte b 0x00;
               Encoder.expr ~source_map_t b offset;
               Encoder.vec Encoder.uint b idxs
           | Active (0, offset), None when is_funcref ->
               Encoder.byte b 0x04;
               Encoder.expr ~source_map_t b offset;
               Encoder.vec
                 (fun b ex -> Encoder.expr ~source_map_t b ex)
                 b e.init
           | Active (table, offset), Some idxs ->
               Encoder.byte b 0x02;
               Encoder.uint b table;
               Encoder.expr ~source_map_t b offset;
               Encoder.byte b 0x00;
               Encoder.vec Encoder.uint b idxs
           | Passive, Some idxs ->
               Encoder.byte b 0x01;
               Encoder.byte b 0x00;
               Encoder.vec Encoder.uint b idxs
           | Declare, Some idxs ->
               Encoder.byte b 0x03;
               Encoder.byte b 0x00;
               Encoder.vec Encoder.uint b idxs
           | Active (table, offset), _ ->
               Encoder.byte b 0x06;
               Encoder.uint b table;
               Encoder.expr ~source_map_t b offset;
               Encoder.reftype b e.typ;
               Encoder.vec
                 (fun b ex -> Encoder.expr ~source_map_t b ex)
                 b e.init
           | Passive, _ ->
               Encoder.byte b 0x05;
               Encoder.reftype b e.typ;
               Encoder.vec
                 (fun b ex -> Encoder.expr ~source_map_t b ex)
                 b e.init
           | Declare, _ ->
               Encoder.byte b 0x07;
               Encoder.reftype b e.typ;
               Encoder.vec
                 (fun b ex -> Encoder.expr ~source_map_t b ex)
                 b e.init))
      m.elem;

  (* 12. Data Count Section *)
  if m.data <> [] then
    output_section out_channel 12 Encoder.uint (List.length m.data);

  (* 11. Code Section *)
  if m.code <> [] then
    output_section out_channel 10
      (Encoder.vec (fun b (c : Ast.location code) ->
           let b_code = Buffer.create 128 in
           let coalesce_locals l =
             let rec loop acc n t l =
               match l with
               | [] -> List.rev ((n, t) :: acc)
               | t' :: r ->
                   if t = t' then loop acc (n + 1) t r
                   else loop ((n, t) :: acc) 1 t' r
             in
             match l with [] -> [] | t :: rem -> loop [] 1 t rem
           in
           let locals = coalesce_locals c.locals in
           Encoder.vec
             (fun b (n, t) ->
               Encoder.uint b n;
               Encoder.valtype b t)
             b_code locals;
           (Encoder.expr ~source_map_t b_code) c.instrs;
           Encoder.uint b (Buffer.length b_code);
           Buffer.add_buffer b b_code))
      m.code;

  (* 12. Data Section *)
  if m.data <> [] then
    output_section out_channel 11
      (Encoder.vec (fun b (d : Ast.location data) ->
           match d.mode with
           | Passive ->
               Encoder.byte b 0x01;
               Encoder.name b d.init
           | Active (mem, offset) ->
               if mem = 0 then (
                 Encoder.byte b 0x00;
                 Encoder.expr ~source_map_t b offset;
                 Encoder.name b d.init)
               else (
                 Encoder.byte b 0x02;
                 Encoder.uint b mem;
                 (Encoder.expr ~source_map_t b) offset;
                 Encoder.name b d.init)))
      m.data;

  (* Custom Name Section *)
  let output_name_subsection id name_list b =
    if not (IntMap.is_empty name_list) then (
      Encoder.byte b id;
      let b_sub = Buffer.create 128 in
      Encoder.vec
        (fun b (idx, name) ->
          Encoder.uint b idx;
          Encoder.name b name)
        b_sub
        (IntMap.bindings name_list);
      Encoder.uint b (Buffer.length b_sub);
      Buffer.add_buffer b b_sub)
  in

  let output_indirect_name_subsection id name_list b =
    if not (IntMap.is_empty name_list) then (
      Encoder.byte b id;
      let b_sub = Buffer.create 128 in
      Encoder.vec
        (fun b (outer_idx, inner_map) ->
          Encoder.uint b outer_idx;
          Encoder.vec
            (fun b (inner_idx, name) ->
              Encoder.uint b inner_idx;
              Encoder.name b name)
            b
            (IntMap.bindings inner_map))
        b_sub
        (IntMap.bindings name_list);
      Encoder.uint b (Buffer.length b_sub);
      Buffer.add_buffer b b_sub)
  in

  let b_names = Buffer.create 1024 in
  (match m.names.module_ with
  | Some name ->
      Encoder.byte b_names 0x00;
      (* Module name subsection ID *)
      let b_sub = Buffer.create 64 in
      Encoder.name b_sub name;
      Encoder.uint b_names (Buffer.length b_sub);
      Buffer.add_buffer b_names b_sub
  | None -> ());

  output_name_subsection 0x01 m.names.functions b_names;
  (* Function names *)
  output_indirect_name_subsection 0x02 m.names.locals b_names;
  (* Local names *)
  output_indirect_name_subsection 0x03 m.names.labels b_names;
  (* Label names *)
  output_name_subsection 0x04 m.names.types b_names;
  (* Type names *)
  output_name_subsection 0x05 m.names.tables b_names;
  (* Table names *)
  output_name_subsection 0x06 m.names.memories b_names;
  (* Memory names *)
  output_name_subsection 0x07 m.names.globals b_names;
  (* Global names *)
  output_name_subsection 0x08 m.names.elem b_names;
  (* Elem names *)
  output_name_subsection 0x09 m.names.data b_names;
  (* Data names *)
  output_indirect_name_subsection 0x0A m.names.fields b_names;
  (* Field names *)
  output_name_subsection 0x0B m.names.tags b_names;

  (* Tag names *)
  if Buffer.length b_names > 0 then (
    let b_custom_section_content = Buffer.create (Buffer.length b_names + 10) in
    Encoder.name b_custom_section_content "name";
    Buffer.add_buffer b_custom_section_content b_names;

    Out_channel.output_byte out_channel 0;
    (* Custom section ID (0) *)
    let len = Buffer.length b_custom_section_content in
    let rec output_uint i =
      if i < 128 then Out_channel.output_byte out_channel i
      else (
        Out_channel.output_byte out_channel (128 + (i land 127));
        output_uint (i lsr 7))
    in
    output_uint len;
    Buffer.output_buffer out_channel b_custom_section_content);

  (* Generate source map file *)
  match opt_source_map_file with
  | Some map_file_name ->
      let json_content =
        Utils.Source_map.to_json source_map_t ~file_name:map_file_name
      in
      Out_channel.with_open_text map_file_name (fun oc ->
          Out_channel.output_string oc json_content)
  | None -> ()

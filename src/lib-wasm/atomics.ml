(* Single source of truth for the atomic memory instructions (the threads
   proposal): the mapping between an [Ast.atomicop], its WAT mnemonic, its
   [0xFE]-prefix sub-opcode, its natural alignment and its stack signature.
   [Atomic.fence] is handled separately (it has no memory operand). *)

open Ast

let type_str = function `I32 -> "i32" | `I64 -> "i64"
let width_str = function `I8 -> "8" | `I16 -> "16" | `I32 -> "32"

let rmw_str = function
  | AtomicAdd -> "add"
  | AtomicSub -> "sub"
  | AtomicAnd -> "and"
  | AtomicOr -> "or"
  | AtomicXor -> "xor"
  | AtomicXchg -> "xchg"
  | AtomicCmpxchg -> "cmpxchg"

(* The WAT mnemonic of an atomic op. *)
let name = function
  | AtomicNotify -> "memory.atomic.notify"
  | AtomicWait `I32 -> "memory.atomic.wait32"
  | AtomicWait `I64 -> "memory.atomic.wait64"
  | AtomicLoad (t, None) -> type_str t ^ ".atomic.load"
  | AtomicLoad (t, Some w) -> type_str t ^ ".atomic.load" ^ width_str w ^ "_u"
  | AtomicStore (t, None) -> type_str t ^ ".atomic.store"
  | AtomicStore (t, Some w) -> type_str t ^ ".atomic.store" ^ width_str w
  | AtomicRmw (op, t, None) -> type_str t ^ ".atomic.rmw." ^ rmw_str op
  | AtomicRmw (op, t, Some w) ->
      type_str t ^ ".atomic.rmw" ^ width_str w ^ "." ^ rmw_str op ^ "_u"

(* The (type, width) sequence shared by every load / store / rmw sub-opcode
   block, in binary order: i32-full, i64-full, then the narrow accesses. *)
let variants =
  [
    (`I32, None);
    (`I64, None);
    (`I32, Some `I8);
    (`I32, Some `I16);
    (`I64, Some `I8);
    (`I64, Some `I16);
    (`I64, Some `I32);
  ]

let rmw_ops =
  [
    AtomicAdd;
    AtomicSub;
    AtomicAnd;
    AtomicOr;
    AtomicXor;
    AtomicXchg;
    AtomicCmpxchg;
  ]

(* Every [(sub-opcode, op)] pair, generated from the regular block layout. *)
let table =
  [ (0x00, AtomicNotify); (0x01, AtomicWait `I32); (0x02, AtomicWait `I64) ]
  @ List.mapi (fun i (t, w) -> (0x10 + i, AtomicLoad (t, w))) variants
  @ List.mapi (fun i (t, w) -> (0x17 + i, AtomicStore (t, w))) variants
  @ List.concat
      (List.mapi
         (fun j op ->
           let base = 0x1E + (j * 7) in
           List.mapi (fun i (t, w) -> (base + i, AtomicRmw (op, t, w))) variants)
         rmw_ops)

let all = List.map snd table
let by_opcode = Hashtbl.create 128
let () = List.iter (fun (code, op) -> Hashtbl.replace by_opcode code op) table
let opcode op = fst (List.find (fun (_, o) -> o = op) table)
let of_opcode code = Hashtbl.find_opt by_opcode code

(* The Wax method spelling on a memory receiver: the WAT mnemonic with a leading
   [memory.] dropped (the receiver is the memory) and [.] rewritten as [_], e.g.
   [i64.atomic.rmw16.add_u -> i64_atomic_rmw16_add_u], [memory.atomic.notify ->
   atomic_notify]. *)
let method_name op =
  let n = name op in
  let prefix = "memory." in
  let n =
    if
      String.length n >= String.length prefix
      && String.sub n 0 (String.length prefix) = prefix
    then
      String.sub n (String.length prefix)
        (String.length n - String.length prefix)
    else n
  in
  String.map (fun c -> if c = '.' then '_' else c) n

let by_method = Hashtbl.create 128

let () =
  List.iter (fun (_, op) -> Hashtbl.replace by_method (method_name op) op) table

let of_method_name n = Hashtbl.find_opt by_method n

(* Number of bytes accessed, whose base-2 logarithm is the required (exact)
   alignment. *)
let access_bytes = function
  | AtomicNotify | AtomicWait `I32 -> 4
  | AtomicWait `I64 -> 8
  | AtomicLoad (t, w) | AtomicStore (t, w) | AtomicRmw (_, t, w) -> (
      match w with
      | Some `I8 -> 1
      | Some `I16 -> 2
      | Some `I32 -> 4
      | None -> ( match t with `I32 -> 4 | `I64 -> 8))

let natural_align_log2 op =
  match access_bytes op with 1 -> 0 | 2 -> 1 | 4 -> 2 | _ -> 3

(* Stack signature after the address operand (which has the memory's address
   type): the remaining operands and the results. *)
let signature op : [ `I32 | `I64 ] list * [ `I32 | `I64 ] list =
  match op with
  | AtomicNotify -> ([ `I32 ], [ `I32 ])
  | AtomicWait `I32 -> ([ `I32; `I64 ], [ `I32 ])
  | AtomicWait `I64 -> ([ `I64; `I64 ], [ `I32 ])
  | AtomicLoad (t, _) -> ([], [ t ])
  | AtomicStore (t, _) -> ([ t ], [])
  | AtomicRmw (AtomicCmpxchg, t, _) -> ([ t; t ], [ t ])
  | AtomicRmw (_, t, _) -> ([ t ], [ t ])

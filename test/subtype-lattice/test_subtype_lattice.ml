(* In-process property test for [Types.heap_subtype] (src/lib-wasm/types.ml), the
   subtyping decision at the soundness core. Rather than pin a table of expected
   answers, it checks the structural laws the WasmGC reference-type lattice must
   satisfy over a small crafted universe: the five disjoint hierarchies
   (aggregate/i31, func, extern, exn, cont), each with a top and a bottom, plus
   concrete struct/array/func/cont types (with a subtype chain) and their [exact]
   variants. A wildcard slip or a mis-resolved type index breaks one of these
   invariants. The exhaustive verdict-level differential against wasm-tools and
   the reference interpreter lives in fuzz/subtype-lattice.sh; this is its fast,
   dependency-free in-process complement. *)

open Wax_wasm.Ast.Binary
module T = Wax_wasm.Types

(* The five top hierarchies; membership is disjoint and (except through the
   shared-by-nobody exception here) subtyping never crosses a hierarchy. *)
type hier = Aggr | Fn | Ext | Exn_ | Con

let top_of = function
  | Aggr -> (Any : heaptype)
  | Fn -> Func
  | Ext -> Extern
  | Exn_ -> Exn
  | Con -> Cont

let bot_of = function
  | Aggr -> (None_ : heaptype)
  | Fn -> NoFunc
  | Ext -> NoExtern
  | Exn_ -> NoExn
  | Con -> NoCont

let failures = ref 0

let name (h : heaptype) =
  match h with
  | Type i -> Printf.sprintf "(type %d)" i
  | Exact i -> Printf.sprintf "(exact %d)" i
  | _ -> ( match heaptype_keyword h with Some s -> s | None -> "?")

let check msg cond =
  if not cond then (
    incr failures;
    print_endline ("FAIL: " ^ msg))

let () =
  let t = T.create () in
  let sub ?(super = None) ?(final = false) typ =
    { typ; supertype = super; final; descriptor = None; describes = None }
  in
  let field = { mut = false; typ = Value I32 } in
  let ft = { params = [||]; results = [||] } in
  (* Concrete universe: a struct with a proper subtype, an array, a func and a
     cont — each interned and referred to by its canonical index. *)
  let s0 = T.add_rectype t [| sub (Struct [||]) |] in
  let s1 = T.add_rectype t [| sub ~super:(Some s0) (Struct [||]) |] in
  let a0 = T.add_rectype t [| sub ~final:true (Array field) |] in
  let f0 = T.add_rectype t [| sub ~final:true (Func ft) |] in
  let c0 = T.add_rectype t [| sub ~final:true (Cont f0) |] in
  let info = T.subtyping_info t in
  let hs a b = T.heap_subtype info a b in
  let concrete = [ (s0, Aggr); (s1, Aggr); (a0, Aggr); (f0, Fn); (c0, Con) ] in
  (* The full heap-type universe, each tagged with its hierarchy. *)
  let universe : (heaptype * hier) list =
    [
      (Any, Aggr);
      (Eq, Aggr);
      (I31, Aggr);
      (Struct, Aggr);
      (Array, Aggr);
      (None_, Aggr);
      (Func, Fn);
      (NoFunc, Fn);
      (Extern, Ext);
      (NoExtern, Ext);
      (Exn, Exn_);
      (NoExn, Exn_);
      (Cont, Con);
      (NoCont, Con);
    ]
    @ List.map (fun (i, h) -> (Type i, h)) concrete
    @ List.map (fun (i, h) -> (Exact i, h)) concrete
  in
  let hts = List.map fst universe in

  (* Reflexivity: every heap type is a subtype of itself. *)
  List.iter
    (fun a -> check (Printf.sprintf "reflexivity %s" (name a)) (hs a a))
    hts;

  (* Transitivity over all triples. *)
  List.iter
    (fun a ->
      List.iter
        (fun b ->
          List.iter
            (fun c ->
              if hs a b && hs b c then
                check
                  (Printf.sprintf "transitivity %s <: %s <: %s" (name a)
                     (name b) (name c))
                  (hs a c))
            hts)
        hts)
    hts;

  (* Hierarchy isolation: subtyping never relates two different hierarchies. *)
  List.iter
    (fun (a, ha) ->
      List.iter
        (fun (b, hb) ->
          if ha <> hb then
            check
              (Printf.sprintf "isolation: %s not <: %s (distinct hierarchies)"
                 (name a) (name b))
              (not (hs a b)))
        universe)
    universe;

  (* Top law: every member is a subtype of its hierarchy's top. *)
  List.iter
    (fun (a, h) ->
      let top = top_of h in
      check (Printf.sprintf "top: %s <: %s" (name a) (name top)) (hs a top))
    universe;

  (* Bottom laws: the hierarchy's bottom is a subtype of every member, and only
     the bottom is a subtype of the bottom. *)
  List.iter
    (fun (a, h) ->
      let bot = bot_of h in
      check
        (Printf.sprintf "bottom-min: %s <: %s" (name bot) (name a))
        (hs bot a);
      if a <> bot then
        check
          (Printf.sprintf "bottom-strict: %s not <: %s" (name a) (name bot))
          (not (hs a bot)))
    universe;

  (* Exact laws: an exact reference is a subtype of its inexact form but not the
     converse; exact is invariant among concrete types. *)
  List.iter
    (fun (i, _) ->
      check
        (Printf.sprintf "exact-subsumes: %s <: %s" (name (Exact i))
           (name (Type i)))
        (hs (Exact i) (Type i));
      check
        (Printf.sprintf "inexact-not-exact: %s not <: %s" (name (Type i))
           (name (Exact i)))
        (not (hs (Type i) (Exact i))))
    concrete;

  (* The declared subtype chain: s1 <: s0 but not the reverse. *)
  check "chain: (type s1) <: (type s0)" (hs (Type s1) (Type s0));
  check "chain: (type s0) not <: (type s1)" (not (hs (Type s0) (Type s1)));

  if !failures > 0 then (
    Printf.printf "subtype-lattice: %d property failure(s)\n" !failures;
    exit 1)

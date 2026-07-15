(* fuzz_recover — stress the Wax panic-mode error recovery
   ([Wax_conversion.Driver.wax_parse_recover]) for its two hard invariants:
   it must always TERMINATE and never CRASH, on any input.

   Usage: fuzz_recover [seed] [iterations] [corpus_dir]
     seed        integer RNG seed (default 0); a run replays exactly from it.
     iterations  number of inputs to try (default 20000).
     corpus_dir  optional dir of .wax files; when given, roughly half the inputs
                 are mutations of a real file (realistic "broken code") and the
                 rest are synthetic. Without it, all inputs are synthetic.

   Why in-process rather than via the CLI harness (fuzz/*.sh, which drive
   main.exe): [parse_recover] is an in-process API with no CLI surface, and
   termination is best checked by a per-input watchdog that can name the exact
   input that hangs. The oracle is simple — [parse_recover] must return without
   raising, within [TIMEOUT] seconds. A raised exception or a hang is the bug
   this hunts. Deterministic given the seed; exits non-zero iff a bug is found.

   Paired driver: fuzz/recover-fuzz.sh. *)

exception Timeout

let timeout_s = try int_of_string (Sys.getenv "TIMEOUT") with _ -> 10

(* Token-ish fragments, deliberately weighted toward the recovery machinery's
   pressure points: the sync boundaries and openers that [find_sync]/[unwind]
   pivot on, the leading keywords, and lexer-error triggers (garbage). *)
let boundaries = [| ";"; "}"; ")"; "]" |]
let openers = [| "{"; "("; "[" |]

let keywords =
  [|
    "fn";
    "let";
    "const";
    "type";
    "rec";
    "import";
    "memory";
    "data";
    "table";
    "elem";
    "tag";
    "return";
    "br";
    "br_if";
    "throw";
    "throw_ref";
    "if";
    "else";
    "loop";
    "while";
    "match";
    "as";
  |]

let garbage = [| "@"; "#"; "$"; "~"; "^"; "&"; "!"; "?"; "\\"; "`"; "|" |]

let atoms =
  [|
    "x";
    "foo";
    "0";
    "42";
    "i32";
    "f64";
    "->";
    "=>";
    "=";
    ":";
    "::";
    ",";
    ".";
    "+";
    "*";
    "-";
    "\"s\"";
    "'c'";
  |]

let pick st a = a.(Random.State.int st (Array.length a))

(* One weighted fragment: boundaries/openers/keywords are the interesting ones. *)
let fragment st =
  match Random.State.int st 100 with
  | n when n < 30 -> pick st boundaries
  | n when n < 50 -> pick st openers
  | n when n < 72 -> pick st keywords
  | n when n < 85 -> pick st garbage
  | _ -> pick st atoms

let sep st = [| ""; " "; " "; "\n"; "  " |].(Random.State.int st 5)

(* A pile of random fragments with random spacing. *)
let soup st =
  let n = 1 + Random.State.int st 80 in
  let b = Buffer.create 256 in
  for _ = 1 to n do
    Buffer.add_string b (fragment st);
    Buffer.add_string b (sep st)
  done;
  Buffer.contents b

(* Heavy repetition of a single fragment (";;;;", "))))", "fn fn fn", …): the
   most direct test that recovery makes progress and terminates. *)
let degenerate st =
  let unit =
    pick st
      [| ";"; ")"; "("; "]"; "["; "}"; "{"; "fn "; "let "; "@"; ", "; ":: " |]
  in
  let n = 1 + Random.State.int st 500 in
  let b = Buffer.create (String.length unit * n) in
  for _ = 1 to n do
    Buffer.add_string b unit
  done;
  Buffer.contents b

(* Deep nesting with garbage buried at the bottom and no closers: forces
   recovery to unwind a very deep parser stack, catching any [Stack_overflow]
   in [unwind]/menhir/[build_syntax_error]. *)
let deep st =
  let n = 200 + Random.State.int st 5000 in
  let opener = (pick st openers).[0] in
  let b = Buffer.create (n + 32) in
  Buffer.add_string b "fn f() -> i32 { ";
  Buffer.add_string b (String.make n opener);
  Buffer.add_string b " @ ";
  Buffer.contents b

let synthetic st =
  match Random.State.int st 10 with
  | 0 | 1 -> degenerate st
  | 2 -> deep st
  (* Wrap some soup in a plausible function so it reaches deep parser states
     before failing, rather than erroring at the very first token. *)
  | 3 | 4 | 5 -> "fn f() -> i32 { " ^ soup st ^ " "
  | _ -> soup st

(* Text-level mutation of a real source: delete / insert / duplicate a slice, or
   rotate the whole string. Produces realistic broken code. *)
let mutate st s =
  let s = ref s in
  let k = 1 + Random.State.int st 4 in
  for _ = 1 to k do
    let cur = !s in
    let len = String.length cur in
    if len = 0 then s := fragment st
    else
      match Random.State.int st 4 with
      | 0 ->
          let i = Random.State.int st len in
          let j = i + 1 + Random.State.int st (len - i) in
          s := String.sub cur 0 i ^ String.sub cur j (len - j)
      | 1 ->
          let i = Random.State.int st (len + 1) in
          let ins =
            if Random.State.bool st then fragment st else pick st garbage
          in
          s := String.sub cur 0 i ^ ins ^ String.sub cur i (len - i)
      | 2 ->
          let i = Random.State.int st len in
          let j = i + 1 + Random.State.int st (len - i) in
          s :=
            String.sub cur 0 j
            ^ String.sub cur i (j - i)
            ^ String.sub cur j (len - j)
      | _ ->
          let i = Random.State.int st len in
          s := String.sub cur i (len - i) ^ String.sub cur 0 i
  done;
  !s

let read_file f = In_channel.with_open_bin f In_channel.input_all

let load_corpus dir =
  Sys.readdir dir |> Array.to_list
  |> List.filter (fun f -> Filename.check_suffix f ".wax")
  |> List.filter_map (fun f ->
      let p = Filename.concat dir f in
      try Some (read_file p) with _ -> None)
  |> Array.of_list

let () =
  Sys.set_signal Sys.sigalrm (Sys.Signal_handle (fun _ -> raise Timeout));
  let arg i = if Array.length Sys.argv > i then Some Sys.argv.(i) else None in
  let seed = match arg 1 with Some s -> int_of_string s | None -> 0 in
  let iters = match arg 2 with Some s -> int_of_string s | None -> 20000 in
  let corpus =
    match arg 3 with
    | Some dir when Sys.file_exists dir && Sys.is_directory dir ->
        load_corpus dir
    | _ -> [||]
  in
  let st = Random.State.make [| seed |] in
  let gen () =
    if Array.length corpus > 0 && Random.State.bool st then
      mutate st (pick st corpus)
    else synthetic st
  in
  let fail kind src =
    ignore (Unix.alarm 0);
    Printf.eprintf
      "fuzz_recover: BUG (%s) at seed=%d\n\
       --- input (%d bytes) ---\n\
       %s\n\
       --- end ---\n"
      kind seed (String.length src) src;
    exit 1
  in
  for _ = 1 to iters do
    let src = gen () in
    try
      ignore (Unix.alarm timeout_s);
      ignore (Wax_conversion.Driver.wax_parse_recover ~filename:"fuzz.wax" src);
      ignore (Unix.alarm 0)
    with
    | Timeout -> fail "hang/timeout" src
    | e -> fail (Printexc.to_string e) src
  done;
  Printf.printf
    "fuzz_recover: ok — %d iterations, seed %d%s, no hang or crash\n" iters seed
    (if Array.length corpus > 0 then
       Printf.sprintf " (+%d corpus files)" (Array.length corpus)
     else "")

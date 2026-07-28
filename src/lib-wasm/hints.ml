type 'a hint = { value : 'a; loc : Wax_utils.Ast.location }
type freq = int

type 'idx t = {
  branch : bool hint option;
  freq : freq hint option;
  targets : ('idx * int) list hint option;
}

let none = { branch = None; freq = None; targets = None }

(* Field by field rather than [t = none]: ['idx] is abstract here, so structural
   equality on a non-empty [targets] would reach into it. *)
let is_empty { branch; freq; targets } =
  branch = None && freq = None && targets = None

let branch loc value t = { t with branch = Some { value; loc } }

let map_targets f t =
  match t.targets with
  | None -> { t with targets = None }
  | Some h ->
      {
        t with
        targets =
          Some { h with value = List.map (fun (x, pct) -> (f x, pct)) h.value };
      }

let freq loc value t = { t with freq = Some { value; loc } }
let targets loc value t = { t with targets = Some { value; loc } }

(*** Instruction frequency ***)

(* The wire byte is an offset base-2 logarithm of the executions-per-call ratio:
   [f = max 1 (min 64 (floor (log2 r) + 32))], with [32] meaning once. The
   endpoints are saturating, so a ratio outside \[2^-31, 2^32\] pins to 1 or 64. *)
let never_opt = 0
let always_opt = 127

let freq_of_ratio r =
  if r <= 0. then 1
  else
    let l = int_of_float (Float.floor (Float.log2 r)) + 32 in
    max 1 (min 64 l)

(* The ratio a byte stands for, when it is one the formula can produce. [None] for
   the two special values and for anything a hand-written binary put outside the
   range, which have no ratio and must round-trip through the raw payload. *)
let ratio_of_freq b =
  if b >= 1 && b <= 64 then Some (Float.pow 2. (float_of_int (b - 32)))
  else None

(*** Wire payloads ***)

(* A [metadata.code.instr_freq] payload is a single byte. *)
let freq_of_payload s =
  if String.length s = 1 then Ok (Char.code s.[0])
  else Error "An instruction-frequency hint must be a single byte."

let freq_payload b = String.make 1 (Char.chr (b land 0xff))

(* [metadata.code.call_targets] holds a run of LEB128 pairs, each a function index
   and a percentage. The text form spells the indices as names where it can; this
   decodes the raw-byte spelling, whose indices are numeric. *)
let uleb_of_string s pos =
  let rec go pos shift acc =
    if pos >= String.length s then Error "A call-target hint ends mid-integer."
    else
      let b = Char.code s.[pos] in
      let acc = acc lor ((b land 0x7f) lsl shift) in
      if b land 0x80 = 0 then Ok (acc, pos + 1)
      else go (pos + 1) (shift + 7) acc
  in
  go pos 0 0

let call_targets_of_payload s =
  let rec go pos acc =
    if pos >= String.length s then Ok (List.rev acc)
    else
      match uleb_of_string s pos with
      | Error _ as e -> e
      | Ok (idx, pos) -> (
          match uleb_of_string s pos with
          | Error _ as e -> e
          | Ok (pct, pos) -> go pos ((idx, pct) :: acc))
  in
  go 0 []

let uleb_to_buffer b n =
  let rec go n =
    let byte = n land 0x7f and rest = n lsr 7 in
    if rest = 0 then Buffer.add_char b (Char.chr byte)
    else begin
      Buffer.add_char b (Char.chr (byte lor 0x80));
      go rest
    end
  in
  go n

let call_targets_payload l =
  let b = Buffer.create 16 in
  List.iter
    (fun (idx, pct) ->
      uleb_to_buffer b idx;
      uleb_to_buffer b pct)
    l;
  Buffer.contents b

(*** Compilation priority ***)

type priority = { compilation : int; optimization : int option }

(* The proposal's prose gives 127 for "run once"; its own worked example instead
   renders the value as ["\01\1F"], i.e. 31. We follow the prose. The byte is only
   ever a spelling of this one value, so a binary carrying 31 round-trips as the
   plain number it is. *)
let run_once = 127

(* A [metadata.code.compilation_priority] payload is a compilation priority,
   optionally followed by an optimization priority. The proposal's
   forward-compatibility rule says to read the leading values and ignore the rest,
   so trailing bytes are dropped rather than rejected. *)
let priority_of_payload s =
  match uleb_of_string s 0 with
  | Error _ -> Error "A compilation-priority hint ends mid-integer."
  | Ok (compilation, pos) -> (
      if pos >= String.length s then Ok { compilation; optimization = None }
      else
        match uleb_of_string s pos with
        | Error _ as e -> e
        | Ok (optimization, _) ->
            Ok { compilation; optimization = Some optimization })

let priority_payload { compilation; optimization } =
  let b = Buffer.create 4 in
  uleb_to_buffer b compilation;
  Option.iter (uleb_to_buffer b) optimization;
  Buffer.contents b

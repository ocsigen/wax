type category = Timing

let categories = [ "timing" ]

let parse = function
  | "timing" -> Ok Timing
  | s ->
      Error
        (Printf.sprintf "Unknown debug category: %s (expected one of: %s)" s
           (String.concat ", " categories))

(* The set of active categories, set once at startup. Mirrors the one-shot
   global config used elsewhere (e.g. [Validation.validate_refs]). *)
let enabled : category list ref = ref []
let enable categories = enabled := categories
let is_enabled category = List.mem category !enabled

let timed_if cond label f =
  if not (cond && is_enabled Timing) then f ()
  else begin
    let start = Unix.gettimeofday () in
    let finally () =
      let elapsed = (Unix.gettimeofday () -. start) *. 1000. in
      Printf.eprintf "%s: %.1f ms\n%!" label elapsed
    in
    Fun.protect ~finally f
  end

let timed label f = timed_if true label f

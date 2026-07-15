(* Byte <-> UTF-16 column conversions, the piece the VS Code extension relies on
   to line up Lexing's byte columns with the editor's UTF-16 character positions.
   "é" (U+00E9) is 2 UTF-8 bytes but 1 UTF-16 unit; "😀" (U+1F600) is 4 UTF-8
   bytes and 2 UTF-16 units (a surrogate pair) — the two cases where a byte
   column and a UTF-16 column diverge. *)

open Wax_utils

let e = "\xC3\xA9" (* é : U+00E9 *)
let emoji = "\xF0\x9F\x98\x80" (* 😀 : U+1F600 *)

let check name got expected =
  Printf.printf "%-24s got=%d expected=%d %s\n" name got expected
    (if got = expected then "ok" else "FAIL")

let () =
  (* utf16_length: UTF-16 code units in a string. *)
  check "len ascii" (Unicode.utf16_length "abc") 3;
  check "len bmp" (Unicode.utf16_length ("a" ^ e ^ "b")) 3;
  check "len astral" (Unicode.utf16_length ("a" ^ emoji ^ "b")) 4;
  check "len empty" (Unicode.utf16_length "") 0;
  check "len agrees with list"
    (Unicode.utf16_length ("x" ^ e ^ emoji))
    (List.length (Unicode.utf16_code_units ("x" ^ e ^ emoji)));

  (* utf16_offset_to_byte: byte offset after n UTF-16 units. *)
  check "byte ascii" (Unicode.utf16_offset_to_byte "abc" 2) 2;
  (* a(1u/1B) é(1u/2B) b : 2 units -> after 'é' -> byte 3 *)
  check "byte bmp" (Unicode.utf16_offset_to_byte ("a" ^ e ^ "b") 2) 3;
  (* a(1u/1B) 😀(2u/4B) b : 1 unit -> before emoji -> byte 1 *)
  check "byte astral before"
    (Unicode.utf16_offset_to_byte ("a" ^ emoji ^ "b") 1)
    1;
  (* 3 units -> after 'a' and the emoji -> byte 5 *)
  check "byte astral after"
    (Unicode.utf16_offset_to_byte ("a" ^ emoji ^ "b") 3)
    5;
  (* Landing inside a surrogate pair lands past the whole scalar. *)
  check "byte mid-surrogate" (Unicode.utf16_offset_to_byte (emoji ^ "b") 1) 4;
  (* Past the end clamps to the byte length. *)
  check "byte clamp" (Unicode.utf16_offset_to_byte "ab" 9) 2;
  check "byte zero" (Unicode.utf16_offset_to_byte ("a" ^ e) 0) 0

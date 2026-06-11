let printf = Printf.printf

let () =
  let files = Sys.readdir "wasm-source" in
  Array.sort String.compare files;
  Array.iter
    (fun file ->
      if Filename.check_suffix file ".wat" then (
        let base = Filename.chop_suffix file ".wat" in

        (* 1. Format: wat -> wat (formatted) *)
        printf "(subdir wasm-formatted\n";
        printf " (rule\n";
        printf "  (target %s.gen)\n" file;
        printf "  (deps ../wasm-source/%s)\n" file;
        printf "  (action\n";
        printf
          "   (run wax --validate --input-format wat --format wat -o \
           %%{target} ../wasm-source/%s)))\n"
          file;
        printf " (rule\n";
        printf "  (alias runtest)\n";
        (*        printf "  (mode (promote (until-clean)))\n";*)
        printf "  (action\n";
        printf "   (diff %s %s.gen))))\n" file file;
        printf "\n";

        (* 2. Convert: wat -> wax *)
        printf "(subdir wax\n";
        printf " (rule\n";
        printf "  (target %s.wax.gen)\n" base;
        printf "  (deps ../wasm-source/%s)\n" file;
        printf " (action\n";
        printf
          "  (run wax --validate --input-format wat --format wax -o %%{target} \
           ../wasm-source/%s)))\n"
          file;
        printf " (rule\n";
        printf "  (alias runtest)\n";
        (*        printf "  (mode (promote (until-clean)))\n";*)
        printf "  (action\n";
        printf "   (diff %s.wax %s.wax.gen))))\n" base base;
        printf "\n";

        (* 3. Round-trip: wax -> wat *)
        printf "(subdir wasm-round-trip\n";
        printf " (rule\n";
        printf "  (target %s.gen)\n" file;
        printf "  (deps ../wax/%s.wax.gen)\n" base;
        printf " (action\n";
        printf
          "  (run wax --validate --input-format wax --format wat -o %%{target} \
           ../wax/%s.wax.gen)))\n"
          base;
        printf " (rule\n";
        printf "  (alias runtest)\n";
        (*        printf "  (mode (promote (until-clean)))\n";*)
        printf "  (action\n";
        printf "   (diff %s %s.gen))))\n" file file;
        printf "\n";

        (* 4. Idempotence: reformatting the generated wat must reproduce it *)
        printf "(subdir wat-idempotent\n";
        printf " (rule\n";
        printf "  (target %s.gen)\n" file;
        printf "  (deps ../wasm-formatted/%s.gen)\n" file;
        printf " (action\n";
        printf
          "  (run wax --validate --input-format wat --format wat -o %%{target} \
           ../wasm-formatted/%s.gen)))\n"
          file;
        printf " (rule\n";
        printf "  (alias runtest)\n";
        printf "  (action\n";
        printf "   (diff ../wasm-formatted/%s.gen %s.gen))))\n" file file;
        printf "\n";

        (* 5. Idempotence: reformatting the generated wax must reproduce it *)
        printf "(subdir wax-idempotent\n";
        printf " (rule\n";
        printf "  (target %s.wax.gen)\n" base;
        printf "  (deps ../wax/%s.wax.gen)\n" base;
        printf " (action\n";
        printf
          "  (run wax --validate --input-format wax --format wax -o %%{target} \
           ../wax/%s.wax.gen)))\n"
          base;
        printf " (rule\n";
        printf "  (alias runtest)\n";
        printf "  (action\n";
        printf "   (diff ../wax/%s.wax.gen %s.wax.gen))))\n" base base;
        printf "\n"))
    files

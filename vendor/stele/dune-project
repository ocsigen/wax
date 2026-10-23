(lang dune 3.20)
(using menhir 3.0)
(name stele)
(generate_opam_files true)

(authors "Jérôme Vouillon")
(maintainers "Jérôme Vouillon <jerome.vouillon@gmail.com>")
(source (github vouillon/stele))
(license "MIT")

(package
  (name stele)
  (synopsis "User-friendly syntax-error messages for any Menhir grammar")
  (description "stele writes the syntax-error messages of a Menhir grammar at build time. From `menhir --list-errors` and the grammar's `.cmly`, it produces a message for every error state: what could come next, which opening delimiter is still open, and, where the grammar uses `%on_error_reduce`, which construct the parser assumed complete. Each message is checked against the parser's tables, and the messages can be pinned in golden files, so a grammar change shows up as a diff to review. An optional config file improves the wording, an overrides file holds hand-written messages, and `stele tune` suggests changes to the `%on_error_reduce` annotations. The `stele.runtime` library, which depends only on `menhirLib`, turns the location markers in a message into source spans when the parser fails.")
  (depends
    (ocaml (>= 4.14))
    ; 20260122 for --no-code-generation and for the Cmly_api [Surface] module
    ; stele reads (token aliases, the pre-inlining surface grammar, the
    ; %on_error_reduce list). Not :build: stele's own build compiles no
    ; grammar, but its tests and `stele tune` run menhir, and so does every
    ; build that uses stele.
    (menhir (>= 20260122))
    (menhirSdk (>= 20260122))
    (menhirLib (>= 20260122))
    ; 2.0 for the Cmd.group subcommand CLI the generator exposes.
    (cmdliner (>= 2.0.0))
  )
)

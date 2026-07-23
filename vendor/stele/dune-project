(lang dune 3.20)
(using menhir 3.0)
(name stele)
(version "0.1.1~dev")
(generate_opam_files true)

(authors "Jérôme Vouillon")
(maintainers "Jérôme Vouillon")
(source (github ocsigen/wax))
(documentation "https://ocsigen.org/wax/")
(license "Apache-2.0")

(package
  (name stele)
  (synopsis "User-friendly syntax-error messages for any Menhir grammar")
  (description "A build-time generator that turns a Menhir grammar's --list-errors output and its .cmly into readable syntax-error messages, with a golden/census/stats workflow, a soundness oracle, and a hand-override escape hatch; plus a small runtime helper (stele.runtime) that resolves the delimiter markers the generated messages carry. Configured per grammar by a text sidecar, so the tool itself is grammar-agnostic.")
  (depends
    (ocaml (>= 4.14))
    (menhir (and :build (>= 20220210)))
    (menhirSdk (>= 20220210))
    (menhirLib (>= 20220210))
    ; 2.0 for the Cmd.group subcommand CLI the generator exposes.
    (cmdliner (>= 2.0.0))
  )
)

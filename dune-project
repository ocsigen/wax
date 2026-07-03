(lang dune 3.20)
(using menhir 3.0)
(name wax)
(generate_opam_files true)

(authors "Jérôme Vouillon")
(maintainers "Jérôme Vouillon")
(source (github vouillon/wax))
(license "Apache-2.0")

(package
  (name wax-lib)
  (synopsis "Libraries for Wax, a Rust-like syntax for WebAssembly")
  (description "The parsing, type-checking and format-conversion libraries behind the Wax toolchain (bidirectional Wax <-> Wasm Text <-> Wasm Binary).")
  (depends
    (ocaml (>= 4.14))
    (sedlex (>= 2.0))
    (menhir (and :build (>= 20220210)))
    (menhirLib (>= 20220210))
    (re (>= 1.10.0))
    (uucp (and :with-dev-setup (>= 16.0.0)))
  )
)

(package
  (name wax)
  (synopsis "A compiler toolchain for Wax, a Rust-like syntax for WebAssembly")
  (description "A compiler toolchain for Wax, a Rust-like syntax for WebAssembly. Capabilities: Formatting, Type Checking, Syntax Conversion (Wax <-> Wasm Text <-> Wasm Binary).")
  (depends
    (ocaml (>= 4.14))
    (wax-lib (= :version))
    (cmdliner (>= 1.1.0))
  )
)

(lang dune 3.20)
(using menhir 3.0)
(name wax)
(generate_opam_files true)

(authors "Jérôme Vouillon")
(maintainers "Jérôme Vouillon")
(source (github vouillon/wasm-syntax))
(license "Apache-2.0")

(package
  (name wax)
  (synopsis "A compiler toolchain for Wax, a Rust-like syntax for WebAssembly")
  (description "A compiler toolchain for Wax, a Rust-like syntax for WebAssembly. Capabilities: Formatting, Type Checking, Syntax Conversion (Wax <-> Wasm Text <-> Wasm Binary).")
  (depends
    sedlex
    menhirLib
    (uucp :with-dev-setup)
    re
    cmdliner
  )
)

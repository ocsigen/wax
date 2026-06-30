Converting Wasm to Wax drops a redundant type annotation on a global. For an
immutable (const) global the annotation is dropped not only when it equals the
initializer's type but also when it is a mere supertype of it: dropping then
narrows the global to that subtype, which is sound because nothing reassigns it
and a narrower immutable global still satisfies every use (and import) of the
wider type. A mutable global keeps the wider annotation, and a null initializer
keeps its annotation regardless.

  $ wax -i wat -f wax globals.wat
  type s = open { f: i32 };
  fn f() -> i32 {
      0;
  }
  const gc = f;
  const gstruct = { f: 7 };
  let gm: &?func = f;
  const gnull: &?any = null;

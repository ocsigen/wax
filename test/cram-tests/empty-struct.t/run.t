An empty struct literal '{}' is valid surface syntax (an empty aggregate, as for
a fieldless struct type):

  $ wax check ok.wax

It round-trips as '{ }' when reprinted:

  $ wax ok.wax -f wax
  type empty = { };
  type ints = [mut i32];
  
  #[export = "mk"]
  fn mk() -> &empty {
      { };
  }
  
  #[export = "s"]
  const s: &empty = {empty| };
  
  #[export = "a"]
  const a: &ints = [ints|];

On the Wasm->Wax path a redundant type name is dropped even when the aggregate is
empty, now that the name-less forms '{}' and '[]' both parse. The struct and
array constructions below both have a redundant name (supplied by the const's
expected type), so it is omitted on output:

  $ wax ok.wax -f wasm -o ok.wasm
  $ wax ok.wasm -f wax
  type empty = { };
  type ints = [mut i32];
  type t = fn() -> &empty;
  #[export]
  fn mk() -> &empty {
      { };
  }
  #[export]
  const s = { };
  #[export]
  const a: &ints = [];

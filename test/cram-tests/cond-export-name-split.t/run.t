A function may bundle several exports in one conditional branch while another
branch splits those exports across separate functions. Converting to Wax keys
each entity's cross-branch identity on its head export only, so the bundled
function's name is not reused for every split sibling (which used to bind the
same Wax name twice and fail with "already bound").

  $ wax multi.wat -f wax
  import "x" fn getuid() -> i32;
  #[if(wasi)]
  #[export]
  #[export = "caml_unix_getuid"]
  #[export = "unix_geteuid"]
  #[export = "caml_unix_geteuid"]
  fn unix_getuid(&eq) -> &eq {
      1 as &i31;
  }
  #[else]
  {
      #[export]
      #[export = "caml_unix_getuid"]
      fn unix_getuid(&eq) -> &eq {
          getuid() as &i31;
      }
      #[export]
      #[export = "caml_unix_geteuid"]
      fn unix_geteuid(&eq) -> &eq {
          getuid() as &i31;
      }
  }

Both configurations type-check.

  $ wax check multi.wat

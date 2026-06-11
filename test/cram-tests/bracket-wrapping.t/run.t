Regression test for how the bracketed label/handler lists of 'dispatch',
'br_table' and 'try_table' wrap when they don't fit on one line: the opening
'[' stays on the head line, the entries are indented one level (filled for the
space-separated 'dispatch'/'br_table' cases, one-per-line for the comma-
separated 'try_table' handlers), and the closing ']' dedents to the construct's
own column rather than hugging the last entry.

  $ wax wide.wax -f wax
  tag exc_a();
  tag exc_b();
  tag exc_c();
  tag exc_d();
  
  fn dispatch_wide(x: i32) {
      dispatch x [
          'case_one 'case_two 'case_one 'case_two 'case_one 'case_two 'case_one 'case_two 'case_one
          else 'case_dflt
      ] {
          'case_one: {
              return;
          }
          'case_two: {
              return;
          }
          'case_dflt: {
              return;
          }
      }
  }
  
  fn br_table_wide(x: i32) {
      'label_aaaa: do {
          'label_bbbb: do {
              br_table [
                  'label_aaaa 'label_bbbb 'label_aaaa 'label_bbbb 'label_aaaa 'label_bbbb 'label_aaaa
                  else 'label_bbbb
              ] x;
          }
      }
  }
  
  fn try_table_wide() {
      'handler_aaaa: do {
          'handler_bbbb: do {
              'handler_cccc: do {
                  'handler_dddd: do {
                      try {
                          nop;
                      } catch [
                          exc_a -> 'handler_aaaa,
                          exc_b -> 'handler_bbbb,
                          exc_c -> 'handler_cccc,
                          _ -> 'handler_dddd
                      ]
                  }
              }
          }
      }
  }

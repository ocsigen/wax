A `switch` without its enabling tag is reported at the `switch` method itself,
not at the start of the call expression. So two chained tag-less switches
(`c.switch().switch()`) report two genuine errors at their own columns rather
than one diagnostic duplicated at the shared chain-start column.

  $ wax check --error-format short m.wax
  m.wax:5:16: error: A 'switch' names its enabling tag as a labelled immediate, e.g. 'c.switch(x, tag: t)'.
  m.wax:5:7: error: A 'switch' names its enabling tag as a labelled immediate, e.g. 'c.switch(x, tag: t)'.
  [128]

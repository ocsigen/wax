`null!` (ref.as_non_null on a bare, floating null) is the non-null bottom
reference `&none` — a subtype of every reference type, trapping at runtime like
the original. It previously failed with "a reference type is expected here".
Regression: found by smith (a null in unreachable code whose heap type was not
pinned).

  $ cat > t.wax <<'EOF'
  > fn f() -> &none {
  >     null!;
  > }
  > EOF
  $ wax -i wax -f wat t.wax --validate | grep -c ref.as_non_null
  1

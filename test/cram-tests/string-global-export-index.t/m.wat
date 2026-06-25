(module
  (type $null (struct))
  (@string $a "x")
  (@string $b "y")
  (@string $c "z")
  (global $null (export "null") (ref eq) (struct.new $null)))

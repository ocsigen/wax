(module
   (type $string (struct (field externref)))
   (@string_imports "str")
   (@if $js_strings
   (@then
      (@string_type $string)))
   (@string $greeting "hello")
   (func (export "message") (result (ref eq)) (@string "world")))

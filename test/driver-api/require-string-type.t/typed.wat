(module
   (type $bytes (array (mut i8)))
   (type $js (struct (field externref)))
   (@string_imports "str")
   (func (export "raw") (result (ref $bytes)) (@string $bytes "raw"))
   (func (export "js") (result (ref $js)) (@string $js "js"))
   (func (export "plain") (result (ref extern)) (@string extern "plain")))

(component
  (core module $support
    (memory (export "mem") 1)
    (data (i32.const 4) "\01")
    (func (export "realloc") (param i32 i32 i32 i32) (result i32) (i32.const 32))
    (func (export "length") (result i32) (i32.load (i32.const 4))))
  (core instance $support (instantiate $support))
  (core func $new (canon error-context.new (memory (core memory $support "mem"))))
  (core func $debug (canon error-context.debug-message
    (memory (core memory $support "mem")) (realloc (core func $support "realloc"))))
  (core func $drop (canon error-context.drop))
  (func (export "new") (param "ptr" u32) (param "units" u32) (result error-context)
    (canon lift (core func $new)))
  (func (export "debug") (param "context" error-context) (param "ptr" u32)
    (canon lift (core func $debug)))
  (func (export "drop") (param "context" error-context) (canon lift (core func $drop)))
  (func (export "length") (result u32) (canon lift (core func $support "length"))))

(module
  (memory 2 2)
  (func (export "roundtrip") (result i32)
    i32.const 65535
    i32.const 305419896
    i32.store align=1
    i32.const 0
    i32.const 85
    i32.store8
    i32.const 65535
    i32.load align=1))

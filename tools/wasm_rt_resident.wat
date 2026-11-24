(module
  (memory 1 1)
  (func (export "hard-slot") (result i32)
    i32.const 256
    i32.const 305419896
    i32.store
    i32.const 256
    i32.load
    i32.const 3
    i32.add))

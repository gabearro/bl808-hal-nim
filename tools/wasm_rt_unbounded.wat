(module
  (memory 1 1)
  (func (export "hard-slot") (result i32)
    i32.const 0
    i32.const 0
    i32.const 512
    memory.fill
    i32.const 42))

(module
  (memory 1 2)
  (func (export "grow") (result i32)
    i32.const 1
    memory.grow)
  (func (export "divide") (result i32)
    i32.const 1
    i32.const 0
    i32.div_u)
  (func (export "load") (result i32)
    i32.const 131072
    i32.load)
)

(module
  (memory 1 2)
  (func (export "grow") (param i32) (result i32)
    local.get 0 memory.grow)
  (func (export "cross_page") (result i32)
    i32.const 65535 i32.const 305419896 i32.store align=1
    i32.const 65535 i32.load align=1)
  (func (export "bulk") (result i32)
    i32.const 4088 i32.const 90 i32.const 24 memory.fill
    i32.const 4092 i32.const 4088 i32.const 20 memory.copy
    i32.const 4095 i32.load8_u))

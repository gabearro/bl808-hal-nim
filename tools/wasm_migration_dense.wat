(module
  (memory 1 1)
  (func (export "run") (param $bytes i32) (result i32)
    i32.const 0
    i32.const 165
    local.get $bytes
    memory.fill
    local.get $bytes
    i32.const 4
    i32.sub
    i32.load align=1))

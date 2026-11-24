(module
  (memory (export "cm32p2_memory") 1)
  (func (export "cm32p2||sum-pair") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add)
  (func (export "cm32p2||make-pair") (param i32 i32) (result i32)
    i32.const 65532)
)

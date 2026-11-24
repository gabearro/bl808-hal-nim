(module
  (global $last (mut i64) (i64.const 0))
  (func (export "cm32p2||value") (param i64) (result i64)
    local.get 0
    global.get $last
    i64.add)
  (func (export "cm32p2||value_post") (param i64)
    local.get 0
    global.set $last))

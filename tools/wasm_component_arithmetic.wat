(module
  (global $add-calls (mut i32) (i32.const 0))
  (global $add-posts (mut i32) (i32.const 0))
  (func (export "cm32p2||add") (param i32 i32) (result i32)
    global.get $add-calls
    global.get $add-posts
    i32.ne
    if unreachable end
    global.get $add-calls
    i32.const 1
    i32.add
    global.set $add-calls
    local.get 0
    local.get 1
    i32.add)
  (func (export "cm32p2||add_post") (param i32)
    global.get $add-posts
    i32.const 1
    i32.add
    global.set $add-posts)
  (func (export "cm32p2||wrap") (param i32) (result i32)
    local.get 0
    i32.const 1
    i32.add)
  (func (export "cm32p2||halve") (param f64) (result f64)
    local.get 0
    f64.const 0.5
    f64.mul)
)

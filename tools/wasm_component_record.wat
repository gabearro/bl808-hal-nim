(module
  (memory (export "cm32p2_memory") 1)
  (global $posts (mut i32) (i32.const 0))
  (global $calls (mut i32) (i32.const 0))
  (func (export "cm32p2||sum-pair") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add)
  (func (export "cm32p2||make-pair") (param i32 i32) (result i32)
    global.get $posts
    global.get $calls
    i32.ne
    if unreachable end
    global.get $calls
    i32.const 1
    i32.add
    global.set $calls
    i32.const 256
    local.get 0
    i32.store
    i32.const 260
    local.get 1
    i32.store
    i32.const 256)
  (func (export "cm32p2||make-pair_post") (param i32)
    global.get $posts
    i32.const 1
    i32.add
    global.set $posts)
)

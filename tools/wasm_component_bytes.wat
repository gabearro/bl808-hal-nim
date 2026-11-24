(module
  (memory (export "cm32p2_memory") 1)
  (global $next (mut i32) (i32.const 384))
  (global $posts (mut i32) (i32.const 0))
  (global $calls (mut i32) (i32.const 0))
  (func (export "cm32p2_realloc") (param i32 i32 i32 i32) (result i32)
    (local $p i32)
    global.get $next
    local.set $p
    global.get $next
    local.get 3
    i32.add
    global.set $next
    local.get $p)
  (func (export "cm32p2||echo-bytes") (param i32 i32) (result i32)
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
  (func (export "cm32p2||echo-bytes_post") (param i32)
    global.get $posts
    i32.const 1
    i32.add
    global.set $posts)
)

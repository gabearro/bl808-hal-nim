(module
  (memory (export "cm32p2_memory") 1)
  (global $next (mut i32) (i32.const 384))
  (func (export "cm32p2_realloc") (param i32 i32 i32 i32) (result i32)
    (local $p i32)
    local.get 2
    i32.const 8
    i32.ne
    if unreachable end
    global.get $next
    local.set $p
    global.get $next
    local.get 3
    i32.add
    global.set $next
    local.get $p)
  (func (export "cm32p2||echo-qwords") (param i32 i32) (result i32)
    i32.const 256
    local.get 0
    i32.store
    i32.const 260
    local.get 1
    i32.store
    i32.const 256)
)

(module
  (memory (export "cm32p2_memory") 1)
  (global $next (mut i32) (i32.const 1024))
  (func (export "cm32p2_realloc") (param i32 i32 i32 i32) (result i32)
    (local $p i32)
    global.get $next
    local.set $p
    global.get $next
    local.get 3
    i32.add
    global.set $next
    local.get $p)
  (func (export "cm32p2||first-byte") (param i32 i32) (result i32)
    local.get 0
    i32.load8_u)
)

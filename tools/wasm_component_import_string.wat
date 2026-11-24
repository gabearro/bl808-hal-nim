(module
  (import "cm32p2" "count" (func $count (param i32 i32) (result i32)))
  (memory (export "cm32p2_memory") 1)
  (data (i32.const 320) "\ff")
  (global $next (mut i32) (i32.const 384))
  (func (export "cm32p2_realloc") (param i32 i32 i32 i32) (result i32)
    (local $p i32)
    global.get $next
    local.set $p
    global.get $next
    local.get 3
    i32.add
    global.set $next
    local.get $p)
  (func (export "cm32p2||answer") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    call $count
    i32.const 1
    i32.add)
  (func (export "cm32p2||bad-pointer") (result i32)
    i32.const 65535
    i32.const 2
    call $count)
  (func (export "cm32p2||bad-text") (result i32)
    i32.const 320
    i32.const 1
    call $count))

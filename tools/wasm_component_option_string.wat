(module
  (memory (export "cm32p2_memory") 1)
  (data (i32.const 320) "Ox64")
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
  (func (export "cm32p2||len") (param i32 i32 i32) (result i32)
    local.get 0
    if (result i32)
      local.get 2
    else
      i32.const 0
    end)
  (func (export "cm32p2||get") (result i32)
    i32.const 256
    i32.const 1
    i32.store
    i32.const 260
    i32.const 320
    i32.store
    i32.const 264
    i32.const 4
    i32.store
    i32.const 256)
)

(module
  (memory (export "memory") 1 1)
  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
    i32.const 256)

  (func (export "sum-large") (param $items i32) (result i32)
    (local $index i32) (local $sum i32)
    (loop $next
      local.get $sum
      local.get $items
      local.get $index
      i32.add
      i32.load
      i32.add
      local.set $sum
      local.get $index
      i32.const 4
      i32.add
      local.tee $index
      i32.const 68
      i32.lt_u
      br_if $next)
    local.get $sum))

(module
  (memory 2 2)
  (func (export "run") (param $bytes i32) (result i32)
    i32.const 0
    i32.const 165
    local.get $bytes
    memory.fill
    local.get $bytes
    i32.const 4
    i32.sub
    i32.load align=1)
  (func (export "sparse") (param i32) (result i32) (local $size i32)
    ;; Double the [0xA5, 0] pattern until it spans both pages.
    i32.const 0
    i32.const 165
    i32.store16
    i32.const 2
    local.set $size
    (loop $expand
      local.get $size
      i32.const 0
      local.get $size
      memory.copy
      local.get $size
      i32.const 1
      i32.shl
      local.tee $size
      i32.const 131072
      i32.lt_u
      br_if $expand)
    i32.const 131068
    i32.load align=1))

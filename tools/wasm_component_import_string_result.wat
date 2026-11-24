(module
  (import "cm32p2" "reply" (func $reply (param i32 i32 i32)))
  (memory (export "cm32p2_memory") 1)
  (global $next (mut i32) (i32.const 384))
  (func (export "cm32p2_realloc") (param $old i32) (param i32)
    (param $alignment i32) (param $size i32) (result i32)
    (local $p i32)
    local.get $old
    i32.eqz
    if (result i32)
      global.get $next
      local.get $alignment
      i32.const 1
      i32.sub
      i32.add
      i32.const 0
      local.get $alignment
      i32.sub
      i32.and
    else
      local.get $old
    end
    local.set $p
    local.get $p
    local.get $size
    i32.add
    local.tee $size
    global.get $next
    i32.gt_u
    if
      local.get $size
      global.set $next
    end
    local.get $p)
  (func (export "cm32p2||message") (param i32 i32) (result i32)
    (local $return-area i32)
    i32.const 256
    local.set $return-area
    local.get 0
    local.get 1
    local.get $return-area
    call $reply
    local.get $return-area)
  (func (export "cm32p2||encoded-length") (param i32 i32) (result i32)
    local.get 1)
  (func (export "cm32p2||odd-empty") (result i32)
    i32.const 256
    i32.const 1
    i32.store
    i32.const 260
    i32.const 0
    i32.store
    i32.const 256)
  (func (export "cm32p2||bad-surrogate") (result i32)
    i32.const 320
    i32.const 0xd800
    i32.store16
    i32.const 256
    i32.const 320
    i32.store
    i32.const 260
    i32.const 1
    i32.store
    i32.const 256))

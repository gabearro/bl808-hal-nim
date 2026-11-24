(module
  (import "cm32p2" "scale" (func $scale (param i32) (result i32)))
  (global $pings (mut i32) (i32.const 0))
  (global $ping-posts (mut i32) (i32.const 0))
  (func (export "cm32p2||adjusted") (param i32) (result i32)
    local.get 0
    call $scale
    i32.const 2
    i32.add)
  (func (export "cm32p2||adjusted_post") (param i32)
    local.get 0
    call $scale
    drop)
  (func (export "cm32p2||ping")
    global.get $pings
    global.get $ping-posts
    i32.ne
    if unreachable end
    global.get $pings
    i32.const 1
    i32.add
    global.set $pings)
  (func (export "cm32p2||ping_post")
    global.get $ping-posts
    i32.const 1
    i32.add
    global.set $ping-posts)
)

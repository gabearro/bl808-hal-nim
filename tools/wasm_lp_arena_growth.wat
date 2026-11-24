(module
  (func $recurse (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32
           i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
    local.get 0
    i32.eqz
    if (result i32)
      i32.const 42
    else
      local.get 0
      i32.const 1
      i32.sub
      call $recurse
    end)
  (func (export "deep") (result i32)
    i32.const 8
    call $recurse)
  (func (export "wide") (result i32)
    i32.const 1 i32.const 1 i32.const 1 i32.const 1
    i32.const 1 i32.const 1 i32.const 1 i32.const 1
    i32.const 1 i32.const 1 i32.const 1 i32.const 1
    i32.const 1 i32.const 1 i32.const 1 i32.const 1
    i32.const 1 i32.const 1 i32.const 1 i32.const 1
    i32.const 1 i32.const 1 i32.const 1 i32.const 1
    i32.const 1 i32.const 1 i32.const 1 i32.const 1
    i32.const 1 i32.const 1 i32.const 1 i32.const 1
    i32.const 1 i32.const 1 i32.const 1 i32.const 1
    i32.const 1 i32.const 1 i32.const 1 i32.const 1
    i32.const 1
    i32.add i32.add i32.add i32.add i32.add i32.add i32.add i32.add
    i32.add i32.add i32.add i32.add i32.add i32.add i32.add i32.add
    i32.add i32.add i32.add i32.add i32.add i32.add i32.add i32.add
    i32.add i32.add i32.add i32.add i32.add i32.add i32.add i32.add
    i32.add i32.add i32.add i32.add i32.add i32.add i32.add i32.add)
  (func (export "trap") unreachable))

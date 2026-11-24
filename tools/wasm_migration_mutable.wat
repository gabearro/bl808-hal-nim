(module
  (type $signature (func (result i32)))
  (memory 1 3)
  (table 1 2 funcref)
  (global $value (mut i32) (i32.const 1))
  (data (i32.const 7) "\aa")
  (data $discarded "\bb")
  (elem $items func $extra)
  (func $extra (type $signature) i32.const 4)
  (func $init
    i32.const 90
    i32.const 2
    i32.store8)
  (start $init)
  (func (export "run") (result i32)
    i32.const 7
    i32.const 0
    i32.store8
    i32.const 1
    memory.grow
    drop
    i32.const 65535
    i32.const 16909060
    i32.store align=1
    i32.const 7
    global.set $value
    ref.func $extra
    i32.const 1
    table.grow 0
    drop
    data.drop $discarded
    elem.drop $items
    i32.const 65535
    i32.load align=1
    i32.const 7
    i32.load8_u
    i32.add
    i32.const 90
    i32.load8_u
    i32.add
    global.get $value
    i32.add
    i32.const 1
    call_indirect (type $signature)
    i32.add
    memory.size
    i32.add))

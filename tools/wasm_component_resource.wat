(module
  (import "cm32p2|_ex_counters" "counter_new" (func $new (param i32) (result i32)))
  (global $last-dropped (mut i32) (i32.const 0))
  (func (export "cm32p2|counters|[constructor]counter")
    (param i32) (result i32)
    local.get 0
    call $new)
  (func (export "cm32p2|counters|[method]counter.get")
    (param i32) (result i32)
    local.get 0)
  (func (export "cm32p2|counters|counter_dtor") (param i32)
    local.get 0
    global.set $last-dropped)
  (func (export "cm32p2|counters|last-dropped") (result i32)
    global.get $last-dropped)
)

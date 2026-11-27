(component
  (canon context.get i32 0 (core func $get))
  (canon context.set i32 0 (core func $set))
  (core module $m
    (import "" "get" (func $get (result i32)))
    (import "" "set" (func $set (param i32)))
    (memory (export "mem") 1 1)
    (func $init
      call $get
      if unreachable end
      i32.const 17
      call $set)
    (start $init)
    (func (export "realloc") (param i32 i32 i32 i32) (result i32)
      call $get
      i32.const 16
      i32.add
      i32.const 31
      call $set)
    (func (export "run") (param $pointer i32) (param $length i32) (result i32)
      call $get
      local.get $pointer
      i32.add
      i32.const 16
      i32.sub
      local.get $length
      i32.add))
  (core instance $i (instantiate $m (with "" (instance
    (export "get" (func $get))
    (export "set" (func $set))))))
  (func (export "run") (param "text" string) (result u32)
    (canon lift (core func $i "run") (memory (core memory $i "mem"))
      (realloc (core func $i "realloc")))))

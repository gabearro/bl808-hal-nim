;; Start, allocation, and export entry each begin with a fresh cell.
;; Post-return runs in the same context as its export entry.
(component
  (canon context.get i32 0 (core func $get))
  (canon context.set i32 0 (core func $set))
  (core module $m
    (import "" "get" (func $get (result i32)))
    (import "" "set" (func $set (param i32)))
    (memory (export "mem") 1 1)
    (func $require-zero
      call $get
      if unreachable end)
    (func $init
      call $require-zero
      i32.const 17
      call $set)
    (start $init)
    (func (export "realloc") (param i32 i32 i32 i32) (result i32)
      call $require-zero
      i32.const 31
      call $set
      i32.const 16)
    (func (export "run") (param i32 i32) (result i32)
      call $get
      i32.const 0xfedcba98
      call $set
      local.get 1
      i32.add)
    (func (export "post") (param i32)
      call $get
      i32.const 0xfedcba98
      i32.ne
      if unreachable end
      i32.const 93
      call $set))
  (core instance $i (instantiate $m (with "" (instance
    (export "get" (func $get))
    (export "set" (func $set))))))
  (func (export "run") (param "text" string) (result u32)
    (canon lift (core func $i "run") (memory (core memory $i "mem"))
      (realloc (core func $i "realloc")) (post-return (core func $i "post")))))
(assert_return (invoke "run" (str.const "Ox64")) (u32.const 4))
(assert_return (invoke "run" (str.const "again")) (u32.const 5))

;; The caller retains its cell while a synchronous callee runs on its
;; own implicit thread, even across repeated calls to the same callee.
(component
  (component $child
    (canon context.get i32 0 (core func $get))
    (canon context.set i32 0 (core func $set))
    (core module $m
      (import "" "get" (func $get (result i32)))
      (import "" "set" (func $set (param i32)))
      (func (export "call") (result i32)
        call $get
        if unreachable end
        i32.const 17
        call $set
        call $get))
    (core instance $i (instantiate $m (with "" (instance
      (export "get" (func $get))
      (export "set" (func $set))))))
    (func (export "call") (result u32) (canon lift (core func $i "call"))))
  (instance $child (instantiate $child))
  (core func $call (canon lower (func $child "call")))
  (canon context.get i32 0 (core func $get))
  (canon context.set i32 0 (core func $set))
  (core module $m
    (import "" "get" (func $get (result i32)))
    (import "" "set" (func $set (param i32)))
    (import "" "call" (func $call (result i32)))
    (func (export "run") (result i32)
      i32.const 8
      call $set
      call $call
      call $call
      i32.add
      call $get
      i32.add))
  (core instance $i (instantiate $m (with "" (instance
    (export "get" (func $get))
    (export "set" (func $set))
    (export "call" (func $call))))))
  (func (export "run") (result u32) (canon lift (core func $i "run"))))
(assert_return (invoke "run") (u32.const 42))

;; Lifting the built-ins directly works without a core module. Each lift
;; still opens its own context.
(component
  (canon context.get i32 0 (core func $get))
  (canon context.set i32 0 (core func $set))
  (func (export "put") (param "value" u32) (canon lift (core func $set)))
  (func (export "get") (result u32) (canon lift (core func $get))))
(assert_return (invoke "put" (u32.const 42)))
(assert_return (invoke "get") (u32.const 0))

;; Lowering a child's string into an active caller gives the caller's
;; allocator a fresh cell and restores the caller's live value afterward.
(component
  (component $child
    (core module $m
      (memory (export "mem") 1)
      (data (i32.const 0) "\08\00\00\00\01\00\00\00!")
      (func (export "value") (result i32) i32.const 0))
    (core instance $i (instantiate $m))
    (func (export "value") (result string)
      (canon lift (core func $i "value") (memory (core memory $i "mem")))))
  (instance $child (instantiate $child))
  (canon context.get i32 0 (core func $get))
  (canon context.set i32 0 (core func $set))
  (core module $allocator
    (import "" "get" (func $get (result i32)))
    (import "" "set" (func $set (param i32)))
    (memory (export "mem") 1)
    (func (export "realloc") (param i32 i32 i32 i32) (result i32)
      call $get
      if unreachable end
      i32.const 91
      call $set
      i32.const 64))
  (core instance $a (instantiate $allocator (with "" (instance
    (export "get" (func $get)) (export "set" (func $set))))))
  (core func $value (canon lower (func $child "value")
    (memory (core memory $a "mem")) (realloc (core func $a "realloc"))))
  (core module $m
    (import "" "get" (func $get (result i32)))
    (import "" "set" (func $set (param i32)))
    (import "" "value" (func $value (param i32)))
    (import "" "mem" (memory 1))
    (func (export "run") (result i32)
      i32.const 42
      call $set
      i32.const 32
      call $value
      i32.const 32
      i32.load
      i32.load8_u
      i32.const 33
      i32.ne
      if unreachable end
      call $get))
  (core instance $i (instantiate $m (with "" (instance
    (export "get" (func $get)) (export "set" (func $set))
    (export "value" (func $value)) (export "mem" (memory $a "mem"))))))
  (func (export "run") (result u32) (canon lift (core func $i "run"))))
(assert_return (invoke "run") (u32.const 42))

(assert_invalid
  (component (canon context.get f32 0 (core func)))
  "canonical context type must be i32")
(assert_invalid
  (component (canon context.set i32 2 (core func)))
  "canonical context slot out of range")
(assert_invalid
  (component
    (canon context.set i32 0 (core func $set))
    (core module $m (import "" "set" (func (param i64))))
    (core instance (instantiate $m (with "" (instance (export "set" (func $set)))))))
  "canonical context function type mismatch")

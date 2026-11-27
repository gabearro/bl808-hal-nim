(component
  (core type $entry (func (param i32)))
  (core module $provider
    (table (export "entries") 1 funcref)
    (memory (export "words") 1 1 shared))
  (core instance $p (instantiate $provider))
  (core func $new (canon thread.new-indirect $entry (core table $p "entries")))
  (core func $later (canon thread.resume-later))
  (core module $consumer
    (import "" "entries" (table 1 funcref))
    (import "" "words" (memory 1 1 shared))
    (import "" "new" (func $new (param i32 i32) (result i32)))
    (import "" "later" (func $later (param i32)))
    (func $worker (param i32)
      (i32.atomic.store (i32.const 4) (local.get 0))
      (if (i32.ne (memory.atomic.notify (i32.const 0) (i32.const 1)) (i32.const 1))
        (then unreachable)))
    (elem (i32.const 0) $worker)
    (func (export "run") (result i32)
      (call $later (call $new (i32.const 0) (i32.const 42)))
      (i32.add
        (memory.atomic.wait32 (i32.const 0) (i32.const 0) (i64.const -1))
        (i32.atomic.load (i32.const 4)))))
  (core instance $c (instantiate $consumer (with "" (instance
    (export "entries" (table $p "entries")) (export "words" (memory $p "words"))
    (export "new" (func $new)) (export "later" (func $later))))))
  (func (export "run") (result u32) (canon lift (core func $c "run"))))

(component
  (type $token (resource (rep i32)))
  (canon resource.new $token (core func $new))
  (component $borrower
    (import "t" (type $token (sub resource)))
    (export $visible "t" (type $token))
    (canon resource.drop $token (core func $drop))
    (core module $m
      (import "" "d" (func $drop (param i32)))
      (func (export "b") (param i32) (result i32)
        (call $drop (local.get 0))
        (local.get 0)))
    (core instance $i (instantiate $m (with "" (instance (export "d" (func $drop))))))
    (func (export "b") (param "x" (borrow $visible)) (result u32)
      (canon lift (core func $i "b"))))
  (instance $b (instantiate $borrower (with "t" (type $token))))
  (canon lower (func $b "b") (core func $lend))
  (core module $m
    (import "" "n" (func $new (param i32) (result i32)))
    (import "" "b" (func $lend (param i32) (result i32)))
    (func (export "run") (result i32) (local $owner i32)
      (local.set $owner (call $new (i32.const 41)))
      (i32.add (call $lend (local.get $owner))
               (call $lend (local.get $owner)))
      (i32.add (i32.const 40))))
  (core instance $i (instantiate $m (with "" (instance
    (export "n" (func $new)) (export "b" (func $lend))))))
  (func (export "run") (result u32) (canon lift (core func $i "run"))))

(module
  (import "cm32p2" "verify" (func $verify (param i32 f64 i32 i64) (result i32)))
  (export "cm32p2||signature" (func $verify))
  (func (export "cm32p2||run") (result i32)
    (call $verify
      (i32.const 0xffffff2a) (f64.const 2.5)
      (i32.const 0) (i64.const 0xfeedbeef3f800000))
    (call $verify
      (i32.const 42) (f64.const 2.5)
      (i32.const 1) (i64.const 0xfedcba9876543210))
    i32.add))

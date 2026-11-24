(component
  (core module $source
    (tag $tag (export "t") (param i32))
    (func (export "throw") (throw $tag (i32.const 42))))
  (core instance $a (instantiate $source))
  (core instance $b (instantiate $source))
  (core module $catcher
    (import "a" "t" (tag $tag (param i32)))
    (import "a" "throw" (func $same))
    (import "b" "throw" (func $other))
    (func (export "run") (param i32) (result i32)
      (block $all
        (block $matched (result i32)
          (try_table (catch $tag $matched) (catch_all $all)
            (if (local.get 0) (then (call $other)) (else (call $same))))
          (return (i32.const 99)))
        (return))
      (i32.const 77)))
  (core instance $catcher (instantiate $catcher
    (with "a" (instance $a)) (with "b" (instance $b))))
  (func (export "run") (param "other" bool) (result u32)
    (canon lift (core func $catcher "run"))))

(component
  (import "configured" (implements "ox64:demo/bias@0.2")
      (version-suffix ".6+board") (external-id "") (instance $bias
    (export "offset" (func (param "value" s32) (result s32)))))
  (core func $offset (canon lower (func $bias "offset")))
  (core module $m
    (import "" "offset" (func $offset (param i32) (result i32)))
    (func (export "answer") (result i32)
      (call $offset (i32.const 41))))
  (core instance $core (instantiate $m
    (with "" (instance (export "offset" (func $offset))))))
  (func $answer (result s32) (canon lift (core func $core "answer")))
  (export "answer" (external-id "雪") (func $answer))
  (export "ox64:demo/bias@0.2" (version-suffix ".5") (instance $bias)))

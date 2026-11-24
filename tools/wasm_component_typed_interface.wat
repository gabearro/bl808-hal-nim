(component
  (import "factory" (component $factory
    (import "ox64:demo/bias@0.2.0" (instance
      (export "unused" (func (result s32)))
      (export "offset" (func (param "input" s32) (result s32)))))
    (export "ox64:demo/arithmetic@0.2.0" (instance
      (export "add" (func (param "lhs" s32) (param "rhs" s32) (result s32)))))))
  (import "ox64:demo/bias@0.2.0" (instance $host-bias
    (export "offset" (func (param "input" s32) (result s32)))))
  (alias export $host-bias "offset" (func $offset))
  (core module $unused (func (export "unused") (result i32) (i32.const 0)))
  (core instance $unused-code (instantiate $unused))
  (func $unused (result s32) (canon lift (core func $unused-code "unused")))
  (instance $bias (export "offset" (func $offset)) (export "unused" (func $unused)))
  (instance $demo (instantiate $factory (with "ox64:demo/bias@0.2.0" (instance $bias))))
  (export "ox64:demo/arithmetic@0.2.0" (instance $demo "ox64:demo/arithmetic@0.2.0")))

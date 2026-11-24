(component
  (core type $provider-type (module
    (type $t (func (param i32)))
    (export "t" (tag (type $t)))))
  (core module $provider (tag (export "t") (param i32)))
  (export $typed-provider "provider" (core module $provider)
    (core module (type $provider-type)))
  (core instance $provider (instantiate $typed-provider))
  (core type $relay-type (module
    (type $t (func (param i32)))
    (import "env" "t" (tag (type $t)))
    (export "t" (tag (type $t)))))
  (core module $relay
    (import "env" "t" (tag $t (param i32)))
    (export "t" (tag $t)))
  (export $typed-relay "relay" (core module $relay) (core module (type $relay-type)))
  (core instance $relay (instantiate $typed-relay (with "env" (instance $provider))))
  (core module $exercise
    (import "env" "t" (tag $t (param i32)))
    (func (export "run") (result i32)
      (block $catch (result i32)
        (try_table (catch $t $catch) (throw $t (i32.const 42)))
        unreachable)))
  (core instance $exercise (instantiate $exercise (with "env" (instance $relay))))
  (func (export "run") (result u32) (canon lift (core func $exercise "run"))))

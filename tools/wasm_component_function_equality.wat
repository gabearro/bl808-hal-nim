(component
  (component $provider
    (type $Record (record (field "value" u32)))
    (export $public "record" (type $Record))
    (type $Read (func (param "arg" $public) (result u32)))
    (export $Signature "signature" (type $Read))
    (core module $impl
      (func (export "read") (param i32) (result i32) (i32.add (local.get 0) (i32.const 1))))
    (core instance $impl (instantiate $impl))
    (func (export "read") (type $Signature) (canon lift (core func $impl "read"))))
  (component $relay
    (import "factory" (component $factory
      (type $Record (record (field "value" u32)))
      (export "record" (type $public (eq $Record)))
      (type $Read (func (param "arg" $public) (result u32)))
      (export "signature" (type $Signature (eq $Read)))
      (export "read" (func (type $Signature)))))
    (instance $schema (instantiate $factory))
    (export "schema" (instance $schema)))
  (instance $relayed (instantiate $relay (with "factory" (component $provider))))
  (alias export $relayed "schema" (instance $schema))
  (export $public-schema "schema" (instance $schema))
  (alias export $public-schema "signature" (type $Read))
  (core module $direct
    (func (export "read") (param i32) (result i32) (i32.add (local.get 0) (i32.const 1))))
  (core instance $direct (instantiate $direct))
  (func (export "direct") (type $Read) (canon lift (core func $direct "read")))

  (component $consumer
    (import "schema" (instance $schema
      (type $Record (record (field "value" u32)))
      (export "record" (type $public (eq $Record)))
      (type $Read (func (param "arg" $public) (result u32)))
      (export "signature" (type $Signature (eq $Read)))
      (export "read" (func (type $Signature)))))
    (core func $read (canon lower (func $schema "read")))
    (core module $entry
      (import "" "read" (func $read (param i32) (result i32)))
      (func (export "run") (result i32) (call $read (i32.const 41))))
    (core instance $entry (instantiate $entry (with "" (instance (export "read" (func $read))))))
    (func (export "run") (result u32) (canon lift (core func $entry "run"))))
  (instance $run (instantiate $consumer (with "schema" (instance $schema))))
  (func (export "run") (alias export $run "run")))

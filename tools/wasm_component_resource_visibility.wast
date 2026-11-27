;; Re-export a method that uses the enclosing component's named resource.
;; The same name is substituted through the child import and governs both
;; exports. Dropping the relayed owner calls the parent's destructor.
(component
  (core module $stats
    (global $dropped (mut i32) (i32.const 0))
    (func (export "destroy") (param i32)
      (global.set $dropped (i32.add (global.get $dropped) (local.get 0))))
    (func (export "dropped") (result i32) (global.get $dropped)))
  (core instance $stats-instance (instantiate $stats))
  (type $r (resource (rep i32) (dtor (core func $stats-instance "destroy"))))
  (export $named "r" (type $r))
  (component $child
    (import "r" (type $incoming (sub resource)))
    (core func $drop (canon resource.drop $incoming))
    (func $consume (param "value" (own $incoming)) (canon lift (core func $drop)))
    (instance $api (export "consume" (func $consume)))
    (export "api" (instance $api)))
  (instance $child-instance (instantiate $child (with "r" (type $named))))
  (export $api "api" (instance $child-instance "api"))
  (export $consume "consume" (func $api "consume"))
  (core func $new (canon resource.new $r))
  (core func $consume (canon lower (func $consume)))
  (core module $main
    (import "" "new" (func $new (param i32) (result i32)))
    (import "" "consume" (func $consume (param i32)))
    (import "" "dropped" (func $dropped (result i32)))
    (func (export "run") (result i32)
      (call $consume (call $new (i32.const 42)))
      (call $dropped)))
  (core instance $main-instance (instantiate $main
    (with "" (instance
      (export "new" (func $new))
      (export "consume" (func $consume))
      (export "dropped" (func $stats-instance "dropped"))))))
  (func (export "run") (result u32)
    (canon lift (core func $main-instance "run"))))

(assert_return (invoke "run") (u32.const 42))
(assert_return (invoke "run") (u32.const 84))

;; The nominal type is the same, but the raw name supplied to the child
;; has never been published in the parent.
(assert_invalid
  (component
    (type $r (resource (rep i32)))
    (export "r" (type $r))
    (component $child
      (import "r" (type $incoming (sub resource)))
      (core func $drop (canon resource.drop $incoming))
      (func $consume (param "value" (own $incoming)) (canon lift (core func $drop)))
      (instance $api (export "consume" (func $consume)))
      (export "api" (instance $api)))
    (instance $child-instance (instantiate $child (with "r" (type $r))))
    (export "api" (instance $child-instance "api")))
  "instance not valid to be used as export")

;; A child's annotated constructor import binds by its declared name and
;; returns an owner of the resource supplied by its parent.
(component
  (type $ticket (resource (rep i32)))
  (core func $new (canon resource.new $ticket))
  (func $make (param "value" u32) (result (own $ticket)) (canon lift (core func $new)))
  (component $consumer
    (import "ticket" (type $ticket (sub resource)))
    (import "[constructor]ticket" (func $make (param "value" u32) (result (own $ticket))))
    (core func $new (canon lower (func $make)))
    (core func $drop (canon resource.drop $ticket))
    (core module $m
      (import "" "new" (func $new (param i32) (result i32)))
      (import "" "drop" (func $drop (param i32)))
      (func (export "answer") (result i32)
        (call $drop (call $new (i32.const 42)))
        (i32.const 42)))
    (core instance $i (instantiate $m
      (with "" (instance (export "new" (func $new)) (export "drop" (func $drop))))))
    (func (export "answer") (result u32) (canon lift (core func $i "answer"))))
  (instance $i (instantiate $consumer
    (with "ticket" (type $ticket)) (with "[constructor]ticket" (func $make))))
  (export "answer" (func $i "answer")))

(assert_return (invoke "answer") (u32.const 42))

;; Value and function types also preserve the name used to bind a resource.
(component definition
  (type $r (resource (rep i32)))
  (export $named "r" (type $r))
  (component $child
    (import "r" (type $incoming (sub resource)))
    (type $list (list (own $incoming)))
    (type $fn (func (param "r" (own $incoming))))
    (export "list" (type $list))
    (export "fn" (type $fn)))
  (instance $i (instantiate $child (with "r" (type $named))))
  (export "list" (type $i "list"))
  (export "fn" (type $i "fn")))

(assert_invalid
  (component
    (type $r (resource (rep i32)))
    (export "r" (type $r))
    (component $child
      (import "r" (type $incoming (sub resource)))
      (type $list (list (own $incoming)))
      (export "list" (type $list)))
    (instance $i (instantiate $child (with "r" (type $r))))
    (export "list" (type $i "list")))
  "type not valid to be used as export")

(assert_invalid
  (component
    (import "r" (type $r (sub resource)))
    (export $exported "r" (type $r))
    (import "alias" (type (eq $exported))))
  "type not valid to be used as import")

;; Earlier nested members contribute their resource names to the export.
(component definition
  (type $r (resource (rep i32)))
  (core func $drop (canon resource.drop $r))
  (func $consume (param "value" (own $r)) (canon lift (core func $drop)))
  (instance $types (export "r" (type $r)))
  (instance $api
    (export "types" (instance $types))
    (export "consume" (func $consume)))
  (export "api" (instance $api)))

(assert_invalid
  (component
    (type $r (resource (rep i32)))
    (core func $drop (canon resource.drop $r))
    (func $consume (param "value" (own $r)) (canon lift (core func $drop)))
    (instance $types (export "r" (type $r)))
    (instance $api
      (export "consume" (func $consume))
      (export "types" (instance $types)))
    (export "api" (instance $api)))
  "instance not valid to be used as export")

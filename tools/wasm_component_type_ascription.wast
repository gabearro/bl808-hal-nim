;; An explicitly equality-bound resource export and an ordinary export
;; refer to the same resource. A handle created through one name can be
;; passed to a component linked through the other and dropped there.
(component
  (component $provider
    (core module $m
      (global $observed (mut i32) (i32.const 0))
      (func (export "drop") (param i32)
        (global.set $observed (i32.add (global.get $observed) (local.get 0))))
      (func (export "status") (result i32) (global.get $observed)))
    (core instance $i (instantiate $m))
    (type $ticket (resource (rep i32) (dtor (core func $i "drop"))))
    (export $primary "primary" (type $ticket))
    (export $equal "equal" (type $ticket) (type (eq $primary)))
    (core func $make (canon resource.new $ticket))
    (func (export "make") (param "value" u32) (result (own $equal))
      (canon lift (core func $make)))
    (func (export "status") (result u32) (canon lift (core func $i "status"))))
  (instance $p (instantiate $provider))
  (component $consumer
    (import "r" (type $r (sub resource)))
    (import "make" (func $make (param "value" u32) (result (own $r))))
    (core func $make (canon lower (func $make)))
    (core func $drop (canon resource.drop $r))
    (core module $m
      (import "" "make" (func $make (param i32) (result i32)))
      (import "" "drop" (func $drop (param i32)))
      (func (export "run") (call $drop (call $make (i32.const 42)))))
    (core instance $i (instantiate $m (with "" (instance
      (export "make" (func $make)) (export "drop" (func $drop))))))
    (func (export "run") (canon lift (core func $i "run"))))
  (instance $c (instantiate $consumer
    (with "r" (type $p "primary")) (with "make" (func $p "make"))))
  (export "run" (func $c "run"))
  (export "status" (func $p "status")))

(assert_return (invoke "status") (u32.const 0))
(assert_return (invoke "run"))
(assert_return (invoke "status") (u32.const 42))
(assert_return (invoke "run"))
(assert_return (invoke "status") (u32.const 84))

;; Separately declared value types are structurally equal. Resource handles
;; nested inside an equal shape still compare by the resource's identity.
(component definition
  (type $ticket (resource (rep i32)))
  (export $r "ticket" (type $ticket))
  (export $alias "alias" (type $r) (type (eq $r)))
  (type $provided (record (field "value" (option (own $r)))))
  (type $expected (record (field "value" (option (own $alias)))))
  (export "value" (type $provided) (type (eq $expected))))

(assert_invalid
  (component
    (type $first (resource (rep i32)))
    (type $second (resource (rep i32)))
    (export "invalid" (type $first) (type (eq $second))))
  "resource type export annotation identity mismatch")

(assert_invalid
  (component
    (type $first (resource (rep i32)))
    (type $second u32)
    (export "invalid" (type $first) (type (eq $second))))
  "component type export annotation sort mismatch")

(assert_invalid
  (component
    (type $first (record (field "value" u32)))
    (type $second (record (field "label" u32)))
    (export "invalid" (type $first) (type (eq $second))))
  "value type export annotation shape mismatch")

(assert_invalid
  (component
    (type $r1 (export "first") (resource (rep i32)))
    (type $r2 (export "second") (resource (rep i32)))
    (type $first (record (field "value" (option (own $r1)))))
    (type $second (record (field "value" (option (own $r2)))))
    (export "invalid" (type $first) (type (eq $second))))
  "value type export annotation resource mismatch")

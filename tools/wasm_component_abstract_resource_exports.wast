;; The pinned Component Model text defines subtype-bound exports as fresh
;; abstract types backed by the resource being exported. wasm-tools 1.263.0
;; can assemble these cases but rejects the abstract ascription itself.
(component
  (component $provider
    (core module $m
      (global $observed (mut i32) (i32.const 0))
      (func (export "drop") (param i32)
        (global.set $observed (i32.add (global.get $observed) (local.get 0))))
      (func (export "status") (result i32) (global.get $observed)))
    (core instance $i (instantiate $m))
    (type $ticket (resource (rep i32) (dtor (core func $i "drop"))))
    (export $hidden "hidden" (type $ticket) (type (sub resource)))
    (core func $make (canon resource.new $ticket))
    (func (export "make") (param "value" u32) (result (own $hidden))
      (canon lift (core func $make)))
    (func (export "status") (result u32) (canon lift (core func $i "status"))))
  (instance $p (instantiate $provider))
  (alias export $p "hidden" (type $from-child))
  (export $relay "relay" (type $from-child) (type (sub resource)))
  (export $same "relay-alias" (type $relay) (type (eq $relay)))
  (core func $make (canon lower (func $p "make")))
  (func $make-relayed (param "value" u32) (result (own $same))
    (canon lift (core func $make)))
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
  (instance $c (instantiate $consumer (with "r" (type $relay))
    (with "make" (func $make-relayed))))
  (export "run" (func $c "run"))
  (export "status" (func $p "status")))

(assert_return (invoke "status") (u32.const 0))
(assert_return (invoke "run"))
(assert_return (invoke "status") (u32.const 42))
(assert_return (invoke "run"))
(assert_return (invoke "status") (u32.const 84))

;; Smaller instance graph for LP's 16 KiB writable budget.
(component
  (core module $stats
    (global $observed (mut i32) (i32.const 0))
    (func (export "drop") (param i32)
      (global.set $observed (i32.add (global.get $observed) (local.get 0))))
    (func (export "status") (result i32) (global.get $observed)))
  (core instance $s (instantiate $stats))
  (type $ticket (resource (rep i32) (dtor (core func $s "drop"))))
  (export $hidden "hidden" (type $ticket) (type (sub resource)))
  (export $same "equal" (type $hidden) (type (eq $hidden)))
  (core func $new (canon resource.new $ticket))
  (core func $drop (canon resource.drop $same))
  (core module $calls
    (import "" "new" (func $new (param i32) (result i32)))
    (import "" "drop" (func $drop (param i32)))
    (func (export "run") (call $drop (call $new (i32.const 42)))))
  (core instance $c (instantiate $calls (with "" (instance
    (export "new" (func $new)) (export "drop" (func $drop))))))
  (func (export "run") (canon lift (core func $c "run")))
  (func (export "status") (result u32) (canon lift (core func $s "status"))))

(assert_return (invoke "run"))
(assert_return (invoke "status") (u32.const 42))
(assert_return (invoke "run"))
(assert_return (invoke "status") (u32.const 84))

(assert_invalid
  (component
    (type $t (resource (rep i32)))
    (export $first "first" (type $t) (type (sub resource)))
    (export $second "second" (type $t) (type (sub resource)))
    (export "invalid" (type $first) (type (eq $second))))
  "resource type export annotation identity mismatch")

(assert_invalid
  (component
    (type $t (resource (rep i32)))
    (export $opaque "opaque" (type $t) (type (sub resource)))
    (core func (canon resource.new $opaque)))
  "canonical function requires a local resource type")

(assert_invalid
  (component
    (type $t (resource (rep i32)))
    (export $opaque "opaque" (type $t) (type (sub resource)))
    (core func (canon resource.rep $opaque)))
  "canonical function requires a local resource type")

(assert_invalid
  (component
    (type $t (list u8))
    (export "invalid" (type $t) (type (sub resource))))
  "component type export subtype bound requires a resource")

(component
  (type $ticket (resource (rep i32)))
  (canon resource.new $ticket (core func $new))
  (canon resource.rep $ticket (core func $rep))
  (canon resource.drop $ticket (core func $drop))

  (component $consumer
    (import "ticket" (type $ticket (sub resource)))
    (export $public "ticket-type" (type $ticket))
    (canon resource.drop $ticket (core func $drop))
    (core module $guest
      (import "" "drop" (func $drop (param i32)))
      (func (export "release") (param $borrow i32) (result i32)
        (if (i32.ne (local.get $borrow) (i32.const 1)) (then unreachable))
        (call $drop (local.get $borrow))
        (local.get $borrow))
      (func (export "leak") (param i32)))
    (core instance $guest (instantiate $guest
      (with "" (instance (export "drop" (func $drop))))))
    (func (export "release") (param "ticket" (borrow $public)) (result u32)
      (canon lift (core func $guest "release")))
    (func (export "leak") (param "ticket" (borrow $public))
      (canon lift (core func $guest "leak"))))

  (instance $consumer (instantiate $consumer (with "ticket" (type $ticket))))
  (canon lower (func $consumer "release") (core func $release))
  (canon lower (func $consumer "leak") (core func $leak))
  (core module $caller
    (import "" "new" (func $new (param i32) (result i32)))
    (import "" "rep" (func $rep (param i32) (result i32)))
    (import "" "drop" (func $drop (param i32)))
    (import "" "release" (func $release (param i32) (result i32)))
    (import "" "leak" (func $leak (param i32)))
    (func (export "run") (result i32)
      (local $owner i32)
      (local.set $owner (call $new (i32.const 41)))
      (call $release (local.get $owner))
      ;; A second call must reuse the released borrow slot with the owner intact.
      (drop (call $release (local.get $owner)))
      (call $rep (local.get $owner))
      (i32.add)
      (call $drop (local.get $owner)))
    (func (export "leak") (call $leak (call $new (i32.const 41)))))
  (core instance $caller (instantiate $caller (with "" (instance
    (export "new" (func $new)) (export "rep" (func $rep)) (export "drop" (func $drop))
    (export "release" (func $release)) (export "leak" (func $leak))))))
  (func (export "run") (result u32) (canon lift (core func $caller "run")))
  (func (export "leak") (canon lift (core func $caller "leak"))))

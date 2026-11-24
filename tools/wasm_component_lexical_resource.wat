(component
  (type $unused (resource (rep i32)))
  (type $owner-api (instance
    (alias outer 1 $unused (type $private))
    (export "ticket" (type $ticket (sub resource)))
    (export "make" (func (result (own $ticket))))))
  (type $run-type (func (result u32)))
  (component $provider
    (type $ticket (resource (rep i32)))
    (export $public "ticket" (type $ticket))
    (type $request (record (field "ticket" (borrow $public))))
    (export $public-request "request" (type $request))
    (core func $new (canon resource.new $ticket))
    (core module $methods
      (import "" "new" (func $new (param i32) (result i32)))
      (func (export "make") (result i32) (call $new (i32.const 42)))
      (func (export "read") (param i32 i32) (result i32)
        local.get 0
        if (result i32)
          local.get 1
        else
          i32.const 0
        end))
    (core instance $methods (instantiate $methods
      (with "" (instance (export "new" (func $new))))))
    (func $make (result (own $public)) (canon lift (core func $methods "make")))
    (func $read (param "value" (option $public-request)) (result u32)
      (canon lift (core func $methods "read")))
    (instance $inner (export "ticket" (type $public)) (export "make" (func $make)))
    (instance $details
      (export "ticket" (type $public))
      (export "request" (type $public-request))
      (export "read" (func $read)))
    (instance $mirror (export "details" (instance $details)))
    (instance $api
      (export "inner" (instance $inner))
      (export "request" (type $public-request))
      (export "mirror" (instance $mirror)))
    (export "api" (instance $api)))
  (component $consumer
    (alias outer 1 $owner-api (type $owner-api))
    (alias outer 1 $run-type (type $run-type))
    (import "api" (instance $api
      (alias outer 1 $owner-api (type $owner))
      (export "inner" (instance $inner (type $owner)))
      (alias export $inner "ticket" (type $ticket))
      (type $request (record (field "ticket" (borrow $ticket))))
      (export "request" (type $public-request (eq $request)))
      (type $maybe (option $public-request))
      (type $read-type (func (param "value" $maybe) (result u32)))
      (type $details (instance
        (alias outer 1 $ticket (type $same))
        (export "ticket" (type (eq $same)))
        (alias outer 1 $public-request (type $request))
        (export "request" (type (eq $request)))
        (alias outer 1 $read-type (type $read))
        (export "read" (func (type $read)))))
      (export "mirror" (instance
        (alias outer 1 $details (type $details))
        (export "details" (instance (type $details)))))))
    (alias export $api "inner" (instance $inner))
    (alias export $api "mirror" (instance $mirror))
    (alias export $mirror "details" (instance $details))
    (alias export $details "ticket" (type $ticket))
    (core func $make (canon lower (func $inner "make")))
    (core func $read (canon lower (func $details "read")))
    (core func $drop (canon resource.drop $ticket))
    (core module $code
      (import "" "make" (func $make (result i32)))
      (import "" "read" (func $read (param i32 i32) (result i32)))
      (import "" "drop" (func $drop (param i32)))
      (func (export "run") (result i32) (local $ticket i32)
        (local.set $ticket (call $make))
        (call $read (i32.const 1) (local.get $ticket))
        (call $drop (local.get $ticket))))
    (core instance $code (instantiate $code (with "" (instance
      (export "make" (func $make))
      (export "read" (func $read))
      (export "drop" (func $drop))))))
    (func (export "run") (type $run-type) (canon lift (core func $code "run"))))
  (instance $provider (instantiate $provider))
  (instance $consumer (instantiate $consumer (with "api" (instance $provider "api"))))
  (func (export "run") (alias export $consumer "run")))

(component
  (import "observe-drop" (func $observe (param "value" u32)))
  (core func $observe (canon lower (func $observe)))
  (core module $destructor
    (import "" "observe" (func $observe (param i32)))
    (func (export "destroy") (param i32)
      local.get 0
      call $observe))
  (core instance $dst (instantiate $destructor
    (with "" (instance (export "observe" (func $observe))))))
  (type $counter-impl (resource (rep i32) (dtor (core func $dst "destroy"))))
  (export $counter "counter" (type $counter-impl))
  (type $other (resource (rep i32)))
  (core func $new (canon resource.new $counter-impl))
  (core func $rep (canon resource.rep $counter-impl))
  (core func $drop (canon resource.drop $counter-impl))
  (core func $wrong-rep (canon resource.rep $other))
  (core module $kernel
    (import "" "new" (func $new (param i32) (result i32)))
    (import "" "rep" (func $rep (param i32) (result i32)))
    (import "" "drop" (func $drop (param i32)))
    (import "" "wrong-rep" (func $wrong-rep (param i32) (result i32)))
    (func (export "new") (param i32) (result i32)
      local.get 0
      call $new)
    (func (export "rep") (param i32) (result i32)
      local.get 0
      call $rep)
    (func (export "drop") (param i32)
      local.get 0
      call $drop)
    (func (export "wrong-rep") (param i32) (result i32)
      local.get 0
      call $wrong-rep)
    (func (export "representation") (param i32) (result i32)
      local.get 0)
    (func (export "conflict") (param i32 i32)
      local.get 1
      call $drop))
  (core instance $k (instantiate $kernel
    (with "" (instance
      (export "new" (func $new)) (export "rep" (func $rep))
      (export "drop" (func $drop)) (export "wrong-rep" (func $wrong-rep))))))
  (func (export "make") (param "value" u32) (result u32)
    (canon lift (core func $k "new")))
  (func (export "read") (param "handle" u32) (result u32)
    (canon lift (core func $k "rep")))
  (func (export "drop") (param "handle" u32) (canon lift (core func $k "drop")))
  (func (export "read-wrong") (param "handle" u32) (result u32)
    (canon lift (core func $k "wrong-rep")))
  (func (export "make-owner") (param "value" u32) (result (own $counter))
    (canon lift (core func $k "new")))
  (func (export "inspect") (param "loan" (borrow $counter)) (result u32)
    (canon lift (core func $k "representation")))
  (func (export "take") (param "owner" (own $counter))
    (canon lift (core func $k "drop")))
  (func (export "conflict") (param "loan" (borrow $counter))
    (param "owner" (own $counter)) (canon lift (core func $k "conflict"))))

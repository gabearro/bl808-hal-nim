(component
  (component $work
    (core module $code
      (global $calls (mut i32) (i32.const 41))
      (func (export "extra") (result i32) (i32.const 0))
      (func (export "run") (result i32)
        (global.set $calls (i32.add (global.get $calls) (i32.const 1)))
        (global.get $calls)))
    (core instance $core (instantiate $code))
    (func (export "extra") (result u32) (canon lift (core func $core "extra")))
    (func (export "run") (result u32) (canon lift (core func $core "run"))))
  (component $relay
    (import "task" (component $task (export "run" (func (result u32)))))
    (component $unused)
    (export "unused" (component $unused) (component))
    (export "selected" (component $task) (component (export "run" (func (result u32))))))
  (component $consumer
    (type $Task (component
      (export "extra" (func (result u32)))
      (export "run" (func (result u32)))))
    (import "factory" (component $factory
      (alias outer 1 $Task (type $Work))
      (import "unused" (component))
      (import "task" (component (type $Work)))
      (export "selected" (component (export "run" (func (result u32)))))))
    (import "task" (component $task (type $Task)))
    (instance $made (instantiate $factory
      (with "unused" (component $task)) (with "task" (component $task))))
    (alias export $made "selected" (component $selected))
    (export "selected" (component $selected)))
  (instance $consumer (instantiate $consumer
    (with "factory" (component $relay)) (with "task" (component $work))))
  (alias export $consumer "selected" (component $selected))
  (instance $result (instantiate $selected))
  (instance $second (instantiate $selected))
  (export $direct "direct" (component $work) (component (export "run" (func (result u32)))))
  (instance $third (instantiate $direct))
  (func (export "run") (alias export $result "run"))
  (func (export "run-second") (alias export $second "run"))
  (func (export "run-direct") (alias export $third "run")))

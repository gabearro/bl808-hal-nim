(component $root
  (type $Work (component (export "run" (func (result u32)))))
  (core type $Engine (module (export "run" (func (result i32)))))
  (import "worker" (component $worker (type $Work)))
  (import "engine" (core module $engine (type $Engine)))

  (component $publisher
    (import "worker" (component $worker (type $Work)))
    (import "engine" (core module $engine (type $Engine)))
    (export "worker" (component $worker))
    (export "engine" (core module $engine)))
  (instance $published (instantiate $publisher
    (with "worker" (component $worker)) (with "engine" (core module $engine))))
  (alias export $published "worker" (component $source-worker))
  (alias export $published "engine" (core module $source-engine))

  (component $relay
    (component $task
      (alias outer 2 $source-worker (component $worker))
      (alias outer 2 $source-engine (core module $engine))
      (alias outer 2 $source-engine (core module $same-engine))
      (instance $work (instantiate $worker))
      (core func $work (canon lower (func $work "run")))
      (core instance $engine (instantiate $same-engine))
      (core module $sum
        (import "" "work" (func $work (result i32)))
        (import "" "engine" (func $engine (result i32)))
        (func (export "run") (result i32) (i32.add (call $work) (call $engine))))
      (core instance $sum (instantiate $sum (with "" (instance
        (export "work" (func $work)) (export "engine" (func $engine "run"))))))
      (func (export "run") (result u32) (canon lift (core func $sum "run"))))
    (component $forward
      (alias outer 1 $task (component $task))
      (export "task" (component $task) (component (export "run" (func (result u32))))))
    (instance $forwarded (instantiate $forward))
    (alias export $forwarded "task" (component $relayed))
    (instance $api (export "task" (component $relayed)))
    (export "api" (instance $api)))

  (instance $relay (instantiate $relay))
  (alias export $relay "api" (instance $api))
  (alias export $api "task" (component $task))
  (instance $first (instantiate $task))
  (instance $second (instantiate $task))
  (func (export "run") (alias export $first "run"))
  (func (export "run-second") (alias export $second "run")))

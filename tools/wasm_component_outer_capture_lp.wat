(component
  (type $Work (component (export "run" (func (result u32)))))
  (import "worker" (component $worker (type $Work)))
  (component $relay
    (alias outer 1 $worker (component $worker))
    (export "worker" (component $worker)))
  (instance $relayed (instantiate $relay))
  (alias export $relayed "worker" (component $actual-worker))
  (instance $work (instantiate $actual-worker))
  (func (export "run") (alias export $work "run")))

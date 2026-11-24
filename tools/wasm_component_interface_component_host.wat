(component
  (type $Task (component (export "run" (func (result u32)))))
  (import "package" (instance $package
    (export "port" (instance (export "task" (component (type $Task)))))))
  (import "task" (component $direct (type $Task)))
  (alias export $package "port" (instance $port))
  (alias export $port "task" (component $nested))
  (instance $nested (instantiate $nested))
  (instance $direct (instantiate $direct))
  (func (export "run") (alias export $nested "run"))
  (func (export "run-direct") (alias export $direct "run")))

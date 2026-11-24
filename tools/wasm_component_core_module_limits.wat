(component
  (core module $provider
    (import "env" "memory" (memory $memory 1 4))
    (export "memory" (memory $memory)))
  (component $consumer
    (import "memory-module" (core module
      (import "env" "memory" (memory 2 3))
      (export "memory" (memory 1 5)))))
  (instance (instantiate $consumer (with "memory-module" (core module $provider)))))

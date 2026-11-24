(component
  (type $Provider (component
    (export "first" (type $R (sub resource)))
    (export "second" (type (eq $R)))))
  (component $consumer
    (type $Required (component
      (export "first" (type $R (sub resource)))
      (export "second" (type (eq $R)))))
    (import "shape" (type (eq $Required))))
  (instance (instantiate $consumer (with "shape" (type $Provider)))))

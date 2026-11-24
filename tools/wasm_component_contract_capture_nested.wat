(component
  (type $left (resource (rep i32)))
  (export $Left "left" (type $left))
  (type $right (resource (rep i32)))
  (export $Right "right" (type $right))
  (type $Provided (component
    (type $Inner (component
      (alias outer 2 $Left (type $Captured))
      (export "ticket" (type (eq $Captured)))))
    (export "inner" (type (eq $Inner)))))
  (type $Required (component
    (type $Inner (component
      (alias outer 2 $Left (type $Captured))
      (export "ticket" (type (eq $Captured)))))
    (export "inner" (type (eq $Inner)))))
  (export "shape" (type $Provided) (type (eq $Required)))
  (component $consumer
    (import "choice" (type $Chosen (sub resource)))
    (type $Required (component
      (type $Inner (component
        (alias outer 2 $Chosen (type $Captured))
        (export "ticket" (type (eq $Captured)))))
      (export "inner" (type (eq $Inner)))))
    (import "contract" (type (eq $Required))))
  (instance (instantiate $consumer
    (with "contract" (type $Provided))
    (with "choice" (type $Left)))))

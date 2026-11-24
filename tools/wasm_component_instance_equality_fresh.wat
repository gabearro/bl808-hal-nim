(component
  (type $Slot (instance (export "token" (type (sub resource)))))
  (import "first" (instance $first (type $Slot)))
  (import "second" (instance $second (type $Slot)))
  (alias export $first "token" (type $First))
  (alias export $second "token" (type $Second))
  (type $Used (instance
    (alias outer 1 $First (type $Resource))
    (export "token" (type (eq $Resource)))))
  (type $Expected (instance
    (alias outer 1 $First (type $Resource))
    (export "token" (type (eq $Resource)))))
  (export "shape" (type $Used) (type (eq $Expected)))
  (type $Nested (instance
    (alias outer 1 $Slot (type $Child))
    (export "child" (instance (type $Child)))))
  (type $OtherNested (instance
    (alias outer 1 $Slot (type $Child))
    (export "child" (instance (type $Child)))))
  (export "nested" (type $Nested) (type (eq $Nested))))

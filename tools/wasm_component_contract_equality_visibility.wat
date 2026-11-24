(component
  (type $Record (record (field "value" u32)))
  (export $public "record" (type $Record))
  (type $Contract (component
    (alias outer 1 $public (type $Captured))
    (export "record" (type $Inside (eq $Captured)))
    (export "read" (func (result $Inside)))))
  (export "contract" (type $Contract)))

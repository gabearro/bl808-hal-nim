(component
  (type $other (resource (rep i32)))
  (export $Other "other" (type $other))
  (type $token (resource (rep i32)))
  (export $Token "token" (type $token))
  (type $Declared (instance (export "resource" (type (sub resource)))))
  (type $Unrelated (instance (export "resource" (type (sub resource)))))
  (component $nominal
    (alias outer 1 $Declared (type $Local))
    (import "shape" (type (eq $Local))))
  (instance (instantiate $nominal (with "shape" (type $Declared))))

  (component $provider
    (import "token" (type $Token (sub resource)))
    (type $Nested (instance
      (type $Capture (instance
        (alias outer 2 $Token (type $Type))
        (export "token" (type $Visible (eq $Type)))
        (export "read" (func (param "value" (borrow $Visible))))))
      (export "capture" (type (eq $Capture)))))
    (instance $box (export "shape" (type $Nested)))
    (export "box" (instance $box)))
  (type $Contract (component
    (import "decoy" (type $Decoy (sub resource)))
    (import "token" (type $Token (sub resource)))
    (type $Nested (instance
      (type $Capture (instance
        (alias outer 2 $Token (type $Type))
        (export "token" (type $Visible (eq $Type)))
        (export "read" (func (param "value" (borrow $Visible))))))
      (export "capture" (type (eq $Capture)))))
    (export "box" (instance
      (alias outer 1 $Nested (type $Type))
      (export "shape" (type (eq $Type)))))))
  (component $relay
    (alias outer 1 $Contract (type $Contract))
    (import "provider" (component $provider (type $Contract)))
    (import "token" (type $Token (sub resource)))
    (import "decoy" (type $Decoy (sub resource)))
    (instance $box (instantiate $provider (with "token" (type $Token))
      (with "decoy" (type $Decoy))))
    (export "box" (instance $box "box")))
  (instance $provider (instantiate $relay (with "provider" (component $provider))
    (with "token" (type $Token)) (with "decoy" (type $Other))))
  (alias export $provider "box" (instance $box))
  (alias export $box "shape" (type $Shape))
  (export "shape" (type $Shape))
  (component $consumer
    (import "token" (type $Token (sub resource)))
    (type $Nested (instance
      (type $Capture (instance
        (alias outer 2 $Token (type $Type))
        (export "token" (type $Visible (eq $Type)))
        (export "read" (func (param "value" (borrow $Visible))))))
      (export "capture" (type (eq $Capture)))))
    (import "shape" (type (eq $Nested))))
  (instance (instantiate $consumer (with "shape" (type $Shape)) (with "token" (type $Token)))))

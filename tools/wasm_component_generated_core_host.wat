(component
  (import "adjust" (func $adjust (param "enabled" bool) (result u32)))
  (core func $lower (canon lower (func $adjust)))
  (core instance $exports (export "adjust" (func $lower)))
  (alias core export $exports "adjust" (core func $alias))
  (func (export "run") (param "enabled" u32) (result u32)
    (canon lift (core func $alias))))

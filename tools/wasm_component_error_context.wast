(assert_invalid
  (component (core func (canon error-context.new)))
  "canonical error-context requires memory")

(assert_invalid
  (component
    (core module $m (memory (export "mem") 0))
    (core instance $m (instantiate $m))
    (core func (canon error-context.debug-message (memory (core memory $m "mem")))))
  "canonical error-context debug-message requires realloc")

(assert_invalid
  (component
    (core module $m (memory (export "mem") 0))
    (core instance $m (instantiate $m))
    (core func (canon error-context.new (memory (core memory $m "mem"))
                 string-encoding=utf8 string-encoding=utf16)))
  "duplicate canonical string encoding")

(assert_invalid
  (component (type (map error-context u32)))
  "invalid map key type")

(module
  (memory (export "memory") 1 1)

  ;; This fixture makes at most one allocation per call. Its scratch
  ;; buffer is aligned for the u64 field of each map entry.
  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
    i32.const 128)

  (func (export "roundtrip") (param $entries i32) (param $count i32) (result i32)
    i32.const 0
    local.get $entries
    i32.store
    i32.const 4
    local.get $count
    i32.store
    i32.const 0))

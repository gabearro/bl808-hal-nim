;; These draft isolation rules are broader than wasm-tools 1.263 validation.
(assert_invalid
  (module
    (type $shared (shared (func)))
    (func (type $shared) (local funcref)))
  "shared core function has an unshared local")

(assert_invalid
  (module
    (type $shared (shared (func)))
    (func (type $shared) (drop (ref.null func))))
  "shared core function uses an unshared reference")

(assert_invalid
  (module
    (type $shared (shared (func (result i32))))
    (memory 1)
    (func (type $shared) (i32.load (i32.const 0))))
  "shared core function accesses an unshared memory")

(assert_invalid
  (module
    (global $unshared i32 (i32.const 42))
    (global (shared i32) (global.get $unshared)))
  "shared initializer accesses an unshared global")

(assert_invalid
  (module
    (type $entry (shared (func (result i32))))
    (memory 1 2)
    (func (type $entry) (memory.size)))
  "shared core function accesses an unshared memory")

(assert_invalid
  (module
    (type $entry (shared (func)))
    (memory $shared 1 2 shared)
    (memory $private 1 2)
    (func (type $entry)
      (memory.copy $shared $private (i32.const 0) (i32.const 0) (i32.const 1))))
  "shared core function accesses an unshared memory")

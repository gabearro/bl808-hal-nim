(module
  (type $entry (shared (func (param i32) (result i32))))
  (func $double (type $entry) (i32.mul (local.get 0) (i32.const 2)))
  (table $table shared 1 (ref null $entry))
  (elem $late (ref null $entry) (ref.func $double))
  (func (export "run") (type $entry)
    (table.init $table $late (i32.const 0) (i32.const 0) (i32.const 1))
    (elem.drop $late)
    (call_ref $entry (local.get 0) (table.get $table (i32.const 0)))))

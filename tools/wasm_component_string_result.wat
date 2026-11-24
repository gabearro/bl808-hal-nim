(module
  (memory (export "cm32p2_memory") 1)
  (data (i32.const 128) "Hello, Ox64")
  (data (i32.const 144) "Post called")
  (global $posts (mut i32) (i32.const 0))
  (func (export "cm32p2_realloc") (param i32 i32 i32 i32) (result i32)
    i32.const 256)
  (func (export "cm32p2||greet") (result i32)
    i32.const 256
    global.get $posts
    if (result i32)
      i32.const 144
    else
      i32.const 128
    end
    i32.store
    i32.const 256
    i32.const 4
    i32.add
    i32.const 11
    i32.store
    i32.const 256)
  (func (export "cm32p2||greet_post") (param i32)
    global.get $posts
    i32.const 1
    i32.add
    global.set $posts)
)

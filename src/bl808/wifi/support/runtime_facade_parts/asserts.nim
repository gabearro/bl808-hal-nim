proc assertFunc*(file: cstring; line: cint; fn: cstring; expr: cstring)
    {.exportc: "__assert_func", cdecl.} =
  osAssert(file, line, fn, expr)

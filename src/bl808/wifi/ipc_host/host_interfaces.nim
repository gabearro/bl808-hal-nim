proc c_memset(s: pointer, c: cint, n: csize_t): pointer
  {.importc: "memset", header: "<string.h>", cdecl.}
proc c_memcpy(dest, src: pointer, n: csize_t): pointer
  {.importc: "memcpy", header: "<string.h>", cdecl.}

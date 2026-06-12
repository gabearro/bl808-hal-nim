## Freestanding C runtime shims for the enclave (bare-metal, -nostdlib).
##
## The enclave runtime copies objects, sets, and buffers, which the compiler
## lowers to memcpy/memset/memmove. Kernel-mode builds already link these from
## baremetal_libc.c, so only define them for the (rare) non-kernel enclave
## build to avoid a duplicate-symbol clash.

when not defined(bl808kernel):
  proc encMemcpy(dest, src: pointer, n: csize_t): pointer {.exportc: "memcpy", cdecl.} =
    let d = cast[ptr UncheckedArray[byte]](dest)
    let s = cast[ptr UncheckedArray[byte]](src)
    var i = 0
    while i.csize_t < n:
      d[i] = s[i]
      inc i
    dest

  proc encMemset(dest: pointer, c: cint, n: csize_t): pointer {.exportc: "memset", cdecl.} =
    let d = cast[ptr UncheckedArray[byte]](dest)
    let b = (c and 0xFF).byte
    var i = 0
    while i.csize_t < n:
      d[i] = b
      inc i
    dest

  proc encMemmove(dest, src: pointer, n: csize_t): pointer {.exportc: "memmove", cdecl.} =
    let d = cast[ptr UncheckedArray[byte]](dest)
    let s = cast[ptr UncheckedArray[byte]](src)
    if cast[uint](dest) < cast[uint](src):
      var i = 0
      while i.csize_t < n:
        d[i] = s[i]
        inc i
    else:
      var i = n.int - 1
      while i >= 0:
        d[i] = s[i]
        dec i
    dest

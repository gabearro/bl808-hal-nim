## Native-code relocation record shared by the compiler and host AOT cache.
## This type is pure so a bare-metal compiler does not pull in filesystem I/O.

type
  RelocKind* = enum
    relocDispatch = 0    ## address of tier2CallIndirectDispatch
    relocCallCache = 1   ## fresh ptr CallIndirectCache

  Relocation* = object
    offset*: uint32
    kind*: RelocKind
    siteIdx*: uint32

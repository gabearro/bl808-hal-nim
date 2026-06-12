# Type alias for the platform log function used throughout the firmware.
# Calling convention: log(level, severity, file_str, line_num, ...)
type
  PlatformLogFunc* = proc(level: uint32, sev: uint32, file: pointer,
                           line: uint32) {.cdecl, varargs.}

# Helper: get a platform operation function pointer from g_bl_ops_funcs.
proc blOpsFunc(operationSlotByteOffset: int): pointer {.inline.} =
  cast[ptr pointer](cast[uint](addr g_bl_ops_funcs) + operationSlotByteOffset.uint)[]

proc getLogFunc(logFunctionSlotByteOffset: int): PlatformLogFunc {.inline.} =
  cast[PlatformLogFunc](blOpsFunc(logFunctionSlotByteOffset))

# Forward declare memset for zero-init
proc c_memset(s: pointer, c: cint, n: csize_t): pointer {.importc: "memset", header: "<string.h>".}
proc c_memmove(dst, src: pointer, n: csize_t): pointer {.importc: "memmove", header: "<string.h>".}
proc c_strlen(s: pointer): csize_t {.importc: "strlen", header: "<string.h>".}
proc c_snprintf(buf: pointer, size: csize_t, fmt: cstring): cint {.importc: "snprintf", header: "<stdio.h>", varargs.}
proc c_sprintf(buf: pointer, fmt: cstring): cint {.importc: "sprintf", header: "<stdio.h>", varargs, discardable.}

proc copyIeBytes(ieDestCursor: pointer; ieSourceBytes: pointer; byteCount: uint): pointer {.inline.} =
  if byteCount != 0:
    discard c_memcpy(ieDestCursor, ieSourceBytes, byteCount.csize_t)
  ieCursorAfter(ieDestCursor, byteCount)

when not isMainModule:
  {.emit: "void NimMain(void);".}

## Console, assertion, and critical-section adapter callbacks.

proc osPrintf(fmt: cstring) {.importc: "bl808_nim_os_printf", cdecl, varargs.}
proc osPuts(s: cstring) {.cdecl.} = vendorPutsRaw(s)
proc osAssert(file: cstring; line: cint; fn: cstring; expr: cstring) {.cdecl.} =
  vendorPutsRaw("[WIFI] assert ")
  vendorPutsRaw(file)
  vendorPrintChar(':')
  vendorPrintU32(line.uint32, 10)
  vendorPrintChar(' ')
  vendorPutsRaw(fn)
  vendorPrintChar(' ')
  vendorPutsRaw(expr)
  vendorPutsRaw("\r\n")
  while true:
    rawDelay(1000)

proc osEnterCritical(): uint32 {.cdecl.} =
  {.emit: ["asm volatile(\"csrrci %0, mstatus, 8\" : \"=r\"(", result, ") :: \"memory\");"].}

proc osExitCritical(level: uint32) {.cdecl.} =
  if (level and 8'u32) != 0:
    {.emit: "asm volatile(\"csrsi mstatus, 8\" ::: \"memory\");".}

proc arch_delay_us*(us: uint32) {.exportc, cdecl.} =
  var caller: uint32
  {.emit: ["asm volatile(\"mv %0, ra\" : \"=r\"(", caller, "));"].}
  nimWifiDbgDelayCallerRa = caller
  delayMtimeUs(us)

proc udelay*(us: uint32) {.exportc, cdecl.} =
  var caller: uint32
  {.emit: ["asm volatile(\"mv %0, ra\" : \"=r\"(", caller, "));"].}
  nimWifiDbgDelayCallerRa = caller
  delayMtimeUs(us)

proc wrapWaitUs*(us: uint32) {.exportc: "__wrap_wait_us", cdecl.} =
  arch_delay_us(us)

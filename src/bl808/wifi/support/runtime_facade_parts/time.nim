type OsTime {.bycopy.} = object
  sec: clong
  usec: clong

proc os_sleep*(sec: clong; usec: clong) {.exportc, cdecl.} =
  var ms = sec * 1000 + usec div 1000
  if ms <= 0: ms = 1
  discard osMsleep(ms)

proc os_get_time*(t: ptr OsTime): cint {.exportc, cdecl.} =
  if t == nil: return -1
  let ms = osGetTimeMs()
  t.sec = clong(ms div 1000)
  t.usec = clong((ms mod 1000) * 1000)
  0

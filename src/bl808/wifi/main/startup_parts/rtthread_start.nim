proc bl_main_rtthread_start*(blHwOut: ptr ptr BlHw): cint {.exportc, cdecl.} =
  if blHwOut == nil:
    return -1
  bl_main_lowlevel_init()
  blHwOut[] = hwPtr()
  result = cfg80211_init(hwPtr())
  if result != 0:
    return result
  result = bl_open(blHwOut[])

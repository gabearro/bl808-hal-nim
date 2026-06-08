proc vTaskDelay*(ticks: uint32) {.exportc, cdecl.} =
  discard osMsleep(clong(if ticks != 0: ticks else: 1))

proc xTaskGetTickCount*(): uint32 {.exportc, cdecl.} = osGetTick()

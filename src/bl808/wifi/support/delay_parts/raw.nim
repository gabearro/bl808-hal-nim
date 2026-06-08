proc rawDelay(loops: uint32) =
  for _ in 0'u32 ..< loops:
    {.emit: "__asm__ volatile(\"nop\");".}

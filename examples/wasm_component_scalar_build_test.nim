## Build-only firmware entry for the WIT-derived scalar component. Generate the
## fixture with tools/run_wasm_component.py before cross-linking this image.
import bl808/[startup, core, mmio]
import bl808/kernel/alloc
import cps/wasm/component
when defined(bl808lp):
  import bl808/wasm_lp_softfloat
when defined(bl808m0) or defined(bl808d0):
  import bl808/memmap

const Fixture = staticRead("../build/wasm-component/arithmetic.component.wasm")

when defined(bl808m0):
  const StatusAddr = XramBase + 0x3F30'u
elif defined(bl808d0):
  const StatusAddr = XramBase + 0x3F40'u
elif defined(bl808lp):
  const StatusAddr = 0x40002EA0'u
else:
  {.error: "select a BL808 core".}

proc main() {.exportc, cdecl, noreturn.} =
  systemInit()
  heapInit()
  regWrite(StatusAddr, 0x5743467F'u32)
  try:
    let plan = decodeComponent(cast[seq[byte]](Fixture))
    let instance = instantiateComponent(plan)
    let values = instance.invoke("add", [componentValue(cpS32, 19),
                                         componentValue(cpS32, 23)])
    if values.len == 1 and values[0].bits == 42:
      regWrite(StatusAddr, 0x57434600'u32)
    else:
      regWrite(StatusAddr, 0x57434601'u32)
  except ComponentError:
    regWrite(StatusAddr, 0x57434602'u32)
  when defined(bl808d0):
    dcacheFlushAll()
    fenceIo()
  while true: wfi()

## Check that a large component is refused before allocating parser metadata
## under LP's 16 KiB writable budget. Run as a host test with -d:bl808lp and
## --skipProjCfg so this exercises the LP admission constants without linking
## a bare-metal image.
when not defined(bl808lp):
  {.error: "build with -d:bl808lp".}

import cps/wasm/component

doAssert MaxComponentBytes == 768
var oversized = newSeq[byte](MaxComponentBytes + 1)
oversized[0] = 0
oversized[1] = 0x61
oversized[2] = 0x73
oversized[3] = 0x6d
oversized[4] = 0x0d
oversized[6] = 1
var rejected = false
try:
  discard decodeComponent(oversized)
except ComponentError:
  rejected = true
doAssert rejected
echo "component LP admission:ok"

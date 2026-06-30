## Cooperative WASM task scheduling smoke helpers.

import cps/wasm/flash_image
import cps/wasm/runtime_int

const
  WasmTaskSmokeOk* = 0x57535400'u32
  WasmTaskSmokeParseFailed* = 0x57535401'u32
  WasmTaskSmokeInstantiateFailed* = 0x57535402'u32
  WasmTaskSmokeInitFailed* = 0x57535403'u32
  WasmTaskSmokeTrap* = 0x57535404'u32
  WasmTaskSmokeNoYield* = 0x57535405'u32
  WasmTaskSmokeResultMismatch* = 0x57535406'u32
  WasmTaskSmokeTimeout* = 0x57535407'u32

  TaskSwitchMin* = 4'u32

  SumModule* = [
    byte 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7F, 0x01, 0x7F,
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x07, 0x01, 0x03, 0x73, 0x75, 0x6D, 0x00, 0x00,
    0x0A, 0x2D, 0x01, 0x2B, 0x01, 0x02, 0x7F,
    0x41, 0x00,       # i32.const 0
    0x21, 0x01,       # local.set 1  (sum)
    0x41, 0x00,       # i32.const 0
    0x21, 0x02,       # local.set 2  (i)
    0x02, 0x40,       # block
    0x03, 0x40,       # loop
    0x20, 0x02,       # local.get 2
    0x20, 0x00,       # local.get 0
    0x4E,             # i32.ge_s
    0x0D, 0x01,       # br_if 1
    0x20, 0x01,       # local.get 1
    0x20, 0x02,       # local.get 2
    0x6A,             # i32.add
    0x21, 0x01,       # local.set 1
    0x20, 0x02,       # local.get 2
    0x41, 0x01,       # i32.const 1
    0x6A,             # i32.add
    0x21, 0x02,       # local.set 2
    0x0C, 0x00,       # br 0
    0x0B,             # end loop
    0x0B,             # end block
    0x20, 0x01,       # local.get 1
    0x0B              # end function
  ]

proc runWasmTaskSmoke*(): uint32 =
  var module: FlashWasmModule
  try:
    module = parseFlashWasmModule(SumModule)
  except CatchableError:
    return WasmTaskSmokeParseFailed

  var vm = initIntWasmVM()
  var moduleIdx: int
  try:
    moduleIdx = vm.instantiateFlashIntOnly(module)
  except CatchableError:
    return WasmTaskSmokeInstantiateFailed

  var a: IntWasmTask
  var b: IntWasmTask
  try:
    a = vm.initIntWasmTaskI32(moduleIdx, "sum", [10'i32])
    b = vm.initIntWasmTaskI32(moduleIdx, "sum", [12'i32])
  except CatchableError:
    return WasmTaskSmokeInitFailed

  var switches = 0'u32
  var yielded = 0'u32
  for _ in 0 ..< 256:
    if a.state != intTaskExited:
      let state = vm.resumeIntWasmTask(a, 3)
      inc switches
      if state == intTaskTrapped:
        return WasmTaskSmokeTrap
      if state == intTaskYielded:
        inc yielded
    if b.state != intTaskExited:
      let state = vm.resumeIntWasmTask(b, 4)
      inc switches
      if state == intTaskTrapped:
        return WasmTaskSmokeTrap
      if state == intTaskYielded:
        inc yielded
    if a.state == intTaskExited and b.state == intTaskExited:
      if yielded < TaskSwitchMin:
        return WasmTaskSmokeNoYield
      if a.result != 45'i32 or b.result != 66'i32:
        return WasmTaskSmokeResultMismatch
      return WasmTaskSmokeOk

  WasmTaskSmokeTimeout

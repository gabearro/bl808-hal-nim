"""Regression tests for BL808 flash-resident WASM program images."""

from __future__ import annotations

import subprocess
import textwrap
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def test_fatfs_exfat_configuration_enabled() -> None:
    config = (REPO_ROOT / "vendor/fatfs/ffconf.h").read_text()
    assert "#define FF_USE_LFN\t\t2" in config
    assert "#define FF_LFN_UNICODE\t2" in config
    assert "#define FF_FS_EXFAT\t\t1" in config


def test_wasm_store_image_load_invoke_unload(tmp_path: Path) -> None:
    source = tmp_path / "wasm_store_check.nim"
    source.write_text(
        textwrap.dedent(
            """
            import strutils
            import bl808/wasm_store
            import bl808/wasm_control
            import bl808/wasm_manager
            import bl808/wasm_cps_http
            import bl808/wasm_http
            import bl808/wasm_os
            import bl808/memmap
            import cps/wasm/runtime_int

            let addModule = @[
              byte 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
              0x01, 0x07, 0x01, 0x60, 0x02, 0x7F, 0x7F, 0x01, 0x7F,
              0x03, 0x02, 0x01, 0x00,
              0x07, 0x07, 0x01, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00,
              0x0A, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6A, 0x0B
            ]

            let slot0 = wasmProgramSlot(0)
            doAssert slot0.valid
            doAssert slot0.flashOffset == 0x0070_0000'u32
            doAssert slot0.slotSize == Ox64WasmSlotSize.uint32
            doAssert wasmProgramSlot(Ox64WasmSlotCount.uint32).valid == false
            doAssert slotPayloadCapacity(slot0) == Ox64WasmSlotSize.uint32 - WasmProgramHeaderLen

            var image = newSeq[byte](WasmProgramHeaderLen.int + addModule.len)
            doAssert initWasmProgramImage(
              cast[ptr UncheckedArray[byte]](addr image[0]),
              image.len.uint32,
              addModule,
              generation = 7'u32,
            ) == wasmProgramOk

            var program: LoadedWasmProgram
            doAssert loadWasmProgramFromView(
              cast[ptr UncheckedArray[byte]](addr image[0]),
              image.len.uint32,
              program,
            ) == wasmProgramOk
            doAssert program.loaded
            doAssert program.header.generation == 7'u32
            doAssert program.header.imageLen == addModule.len.uint32
            doAssert program.header.wasmProgramChecksum == wasmPayloadCrc32(addModule)

            var vm = initIntWasmVM()
            let moduleIdx = vm.instantiateFlashIntOnly(program.module)
            doAssert vm.invokeI32(moduleIdx, "add", [20'i32, 22'i32]) == 42'i32

            program.unload()
            doAssert not program.loaded

            var handle: WasmProgramHandle
            doAssert handle.invokeI32("add", [1'i32, 2'i32]).status == wasmManagerNotLoaded
            doAssert openWasmProgramImage(
              handle,
              cast[ptr UncheckedArray[byte]](addr image[0]),
              image.len.uint32,
            ) == wasmManagerOk
            let run = handle.invokeI32("add", [7'i32, 35'i32])
            doAssert run.status == wasmManagerOk
            doAssert run.value == 42'i32
            handle.close()
            doAssert not handle.loaded

            image[0] = 0
            doAssert loadWasmProgramFromView(
              cast[ptr UncheckedArray[byte]](addr image[0]),
              image.len.uint32,
              program,
            ) == wasmProgramBadHeader

            doAssert initWasmProgramImage(
              cast[ptr UncheckedArray[byte]](addr image[0]),
              image.len.uint32,
              addModule,
              generation = 8'u32,
            ) == wasmProgramOk
            image[WasmProgramHeaderLen.int + addModule.high] =
              image[WasmProgramHeaderLen.int + addModule.high] xor 0x01'u8
            doAssert loadWasmProgramFromView(
              cast[ptr UncheckedArray[byte]](addr image[0]),
              image.len.uint32,
              program,
            ) == wasmProgramChecksumMismatch

            var headerOnly = newSeq[byte](WasmProgramHeaderLen.int)
            doAssert writeWasmProgramHeader(
              cast[ptr UncheckedArray[byte]](addr headerOnly[0]),
              headerOnly.len.uint32,
              imageLen = 1'u32,
              checksum = 0'u32,
            ) == wasmProgramOk
            doAssert loadWasmProgramFromView(
              cast[ptr UncheckedArray[byte]](addr headerOnly[0]),
              headerOnly.len.uint32,
              program,
            ) == wasmProgramTooLarge

            let notFound = handleWasmHttpRequest(wasmHttpGet, "/wasm/nope", [])
            doAssert notFound.statusCode == 404'u16

            let coresUnavailable = handleWasmHttpRequest(wasmHttpGet, "/wasm/cores", [])
            doAssert coresUnavailable.statusCode == 404'u16

            proc testCoreStatus(): string =
              "[{\\"name\\":\\"m0\\",\\"status\\":1464628736,\\"heartbeat\\":8,\\"add\\":42,\\"sum\\":190,\\"expectedSum\\":190,\\"ok\\":true}]"

            setWasmHttpCoreStatusProvider(testCoreStatus)
            let cores = handleWasmHttpRequest(wasmHttpGet, "/wasm/cores", [])
            doAssert cores.statusCode == 200'u16
            doAssert cores.body == "{\\"cores\\":" & testCoreStatus() & "}"

            let capsWithCores = handleWasmHttpRequest(wasmHttpGet, "/wasm/capabilities", [])
            doAssert capsWithCores.statusCode == 200'u16
            doAssert capsWithCores.body.contains("\\"cores\\":[{\\"name\\":\\"m0\\"")

            proc httpBytes(s: string): seq[byte] =
              result = @[]
              for ch in s:
                result.add(byte(ch))

            let invokeArgs = @[byte('1'), byte('8'), byte(','), byte('2'), byte('4')]

            let system = handleWasmHttpRequest(wasmHttpGet, "/wasm/system", [])
            doAssert system.statusCode == 200'u16
            doAssert system.body.contains("\\"remotePlacement\\":\\"peer-mailbox\\"")
            doAssert system.body.contains("\\"asyncHostCalls\\"")
            doAssert system.body.contains("/wasm/placement")
            doAssert system.body.contains("/wasm/net/status")

            let placementPolicy = handleWasmHttpRequest(wasmHttpGet, "/wasm/placement", [])
            doAssert placementPolicy.statusCode == 200'u16
            doAssert placementPolicy.body.contains("\\"order\\"")

            let placementDecision = handleWasmHttpRequest(
              wasmHttpPost,
              "/wasm/placement",
              httpBytes("name=netdemo\\nimports=http,net\\ncores=m0,d0,lp\\n"),
            )
            doAssert placementDecision.statusCode == 200'u16
            doAssert placementDecision.body.contains("\\"core\\":\\"m0\\"")

            let netStatus = handleWasmHttpRequest(wasmHttpGet, "/wasm/net/status", [])
            doAssert netStatus.statusCode == 200'u16
            doAssert netStatus.body.contains("\\"available\\":false")

            let eventStream = handleWasmHttpRequest(wasmHttpGet, "/wasm/events/stream", [])
            doAssert eventStream.statusCode == 200'u16

            let remoteStart = handleWasmHttpRequest(
              wasmHttpPost,
              "/wasm/cores/lp/programs/0/start/add",
              invokeArgs,
            )
            doAssert remoteStart.statusCode == 400'u16

            let localPlacedBadSlot = handleWasmHttpRequest(
              wasmHttpPost,
              "/wasm/cores/m0/programs/999/start/add",
              invokeArgs,
            )
            doAssert localPlacedBadSlot.statusCode == 501'u16

            let events = handleWasmHttpRequest(wasmHttpGet, "/wasm/events", [])
            doAssert events.statusCode == 200'u16
            doAssert events.body.contains("\\"events\\"")

            let traps = handleWasmHttpRequest(wasmHttpGet, "/wasm/traps", [])
            doAssert traps.statusCode == 200'u16
            doAssert traps.body.contains("\\"traps\\"")

            let allTasks = handleWasmHttpRequest(wasmHttpGet, "/wasm/tasks/all", [])
            doAssert allTasks.statusCode == 200'u16
            doAssert allTasks.body.contains("\\"tasks\\"")

            let manifest = parseWasmOsManifest(
              "name=demo\\nversion=1\\npreferredCore=lp\\ncores=m0,lp,enclave\\n" &
              "imports=time,log,storage\\nmaxFuel=2048\\nallowStorage=true\\n" &
              "requireEnclave=true\\n"
            )
            doAssert manifest.valid
            doAssert manifest.name == "demo"
            doAssert manifest.preferredCore == wasmOsCoreLP
            doAssert (manifest.coreMask and WasmOsCoreLPBit) != 0
            doAssert (manifest.importMask and importFlagBit(wasmImportStorage)) != 0
            doAssert manifest.limits.maxFuel == 2048'u32
            doAssert manifest.limits.allowStorage
            doAssert manifest.signatureRequired

            discard appendWasmOsEvent(wasmEventHttpRequest, taskId = 7, slot = 3, code = 99)
            discard appendWasmOsTrap(wasmOsCoreM0, 7, 3, 123, 456, wasmTaskTrapped)
            let eventsAfter = handleWasmHttpRequest(wasmHttpGet, "/wasm/events", [])
            doAssert eventsAfter.body.contains("\\"taskId\\":7")
            let trapsAfter = handleWasmHttpRequest(wasmHttpGet, "/wasm/traps", [])
            doAssert trapsAfter.body.contains("\\"trapCode\\":123")

            let badInstall = handleWasmHttpRequest(wasmHttpPost, "/wasm/programs/999", [])
            doAssert badInstall.statusCode == 400'u16
            doAssert badInstall.control.status == wasmControlBadSlot

            let httpInvoke = handleWasmHttpRequest(
              wasmHttpPost,
              "/wasm/programs/999/invoke/add",
              invokeArgs,
            )
            doAssert httpInvoke.statusCode == 500'u16
            doAssert httpInvoke.control.status == wasmControlBadSlot

            let badInvokeArgs = handleWasmHttpRequest(
              wasmHttpPost,
              "/wasm/programs/999/invoke/add",
              @[byte('1'), byte(','), byte(',')],
            )
            doAssert badInvokeArgs.statusCode == 400'u16

            let rawBad = handleWasmHttpBytes(httpBytes(
              "POST /wasm/programs/999 HTTP/1.1\\r\\n" &
              "Content-Length: 0\\r\\n\\r\\n"
            ))
            doAssert rawBad.statusCode == 400'u16
            doAssert rawBad.control.status == wasmControlBadSlot

            let rawMissing = handleWasmHttpBytes(httpBytes(
              "GET /nope HTTP/1.1\\r\\n\\r\\n"
            ))
            doAssert rawMissing.statusCode == 404'u16

            let formatted = formatWasmHttpResponse(notFound)
            doAssert formatted.len > 12
            doAssert formatted[0] == 'H'

            let cpsRaw = handleWasmCpsHttpBytes(httpBytes(
              "GET /wasm/capabilities HTTP/1.1\\r\\nHost: test\\r\\n\\r\\n"
            ), "root")
            doAssert cpsRaw.startsWith("HTTP/1.1 200 OK")
            doAssert cpsRaw.contains("Content-Type: application/json")
            doAssert cpsRaw.contains("\\"supportsI32\\":true")

            let cpsRoot = handleWasmCpsHttpBytes(httpBytes(
              "GET / HTTP/1.1\\r\\nHost: test\\r\\n\\r\\n"
            ), "root from cps")
            doAssert cpsRoot.startsWith("HTTP/1.1 200 OK")
            doAssert cpsRoot.contains("root from cps")

            let cpsBad = handleWasmCpsHttpBytes(httpBytes(
              "POST /wasm/programs/0 HTTP/1.1\\r\\nContent-Length: 5\\r\\n\\r\\nabc"
            ), "root")
            doAssert cpsBad.startsWith("HTTP/1.1 400 Bad Request")
            """
        )
    )

    subprocess.run(
        ["nim", "c", "-r", "--path:src", str(source)],
        cwd=REPO_ROOT,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )

import std/[os, osproc, streams, monotimes, times, strutils]

proc main() =
  if paramCount() != 2: quit("usage: test_zkbuild_native_qemu QEMU ELF", 1)
  let emulator = startProcess(paramStr(1), args = ["-machine", "virt", "-bios", "none",
    "-nographic", "-no-reboot", "-kernel", absolutePath(paramStr(2))],
    options = {poUsePath, poStdErrToStdOut})
  defer: emulator.close()
  let deadline = getMonoTime() + initDuration(seconds = 60)
  while emulator.running():
    if getMonoTime() >= deadline:
      emulator.terminate()
      discard emulator.waitForExit()
      quit("RV32 native proof test timed out", 1)
    sleep(20)
  let output = emulator.outputStream.readAll()
  stdout.write output
  if emulator.waitForExit() != 0 or output.contains("[FAIL]"):
    quit("RV32 native proof test failed", 1)
  for marker in ["scalar canonical encodings", "scalar word packing", "scalar decode boundaries", "scalar reject unchanged",
      "word carry arithmetic",
      "FIPS complete schedule",
      "CIOS complete schedule",
      "scalar Montgomery constants", "scalar Montgomery residues",
      "native key prepared", "native artifact admitted", "native execution",
      "native i32 wrap", "native snapshot isolation", "native substitution rejected",
      "WASM substitution rejected", "proof mutation rejected", "wrong key rejected"]:
    if not output.contains("[PASS] " & marker): quit("missing RV32 marker: " & marker, 1)
  if not output.contains("=== RV32 proved native execution complete ==="):
    quit("missing RV32 completion marker", 1)
  echo "zkbuild actual RV32 proof-gated execution: PASS"

main()

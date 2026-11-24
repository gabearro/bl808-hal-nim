import std/[os, osproc, strutils]
import zkbuild_cios_cases

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc values(line, kind: string, count: int): seq[uint32] =
  let parts = line.splitWhitespace()
  require(parts.len == count+1 and parts[0] == kind, "CIOS fixture row")
  for i in 1..<parts.len:
    let number = parseBiggestUInt(parts[i])
    require(number <= uint64(high(uint32)), "CIOS fixture word overflow")
    result.add uint32(number)

proc main() =
  require(paramCount() == 2, "usage: test_zkbuild_cios EXPORTER WORK_DIR")
  let exporter = absolutePath(paramStr(1))
  let work = absolutePath(paramStr(2))
  createDir(work)
  let path = work / "cios-vectors.txt"
  let generated = execCmdEx(quoteShell(exporter) & " " & quoteShell(path))
  require(generated.exitCode == 0, "CIOS oracle failed: " & generated.output)
  let reference = open(path)
  defer: reference.close()
  require(reference.readLine() == "ZKCIOS1 512 73 13", "CIOS fixture header")
  for index in 0..<512:
    let inputs = values(reference.readLine(), "I", 16)
    var test: CiosCase
    for i in 0..<8:
      test.input[i] = inputs[i]
      test.expected[i] = inputs[i+8]
    for row in 0..<73:
      let data = values(reference.readLine(), "T", 13)
      for i in 0..<13: test.trace[row][i] = data[i]
    require(checkCiosCase(test), "CIOS trace/result differs from Lean at case " & $index &
      "; recorded rows=" & $recordedCount)
    if index == 0:
      var changed = test
      changed.trace[0][2] = changed.trace[0][2] xor 1'u32
      require(not checkCiosCase(changed), "changed CIOS trace accepted")
      changed = test
      changed.expected[0] = changed.expected[0] xor 1'u32
      require(not checkCiosCase(changed), "changed CIOS result accepted")
  require(reference.endOfFile(), "trailing CIOS fixtures")
  echo "zkbuild CIOS schedule: PASS (512 inputs, 37376 complete array/carry rows, independent modular results and changed-fixture rejection)"

main()

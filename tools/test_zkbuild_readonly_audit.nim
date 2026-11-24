## Test the full matrix, immutable-table semantics and attached interfaces.
import std/[os,osproc,strutils]

proc run(executable: string, args: openArray[string], succeeds = true): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let checked = execCmdEx(command)
  doAssert (checked.exitCode == 0) == succeeds,command & "\n" & checked.output
  checked.output

proc main() =
  if paramCount() != 5: quit("usage: test_readonly BASELINE AUDITED CHECKER MODULE_CHECKER DIRECTORY",1)
  let baseline = absolutePath(paramStr(1))
  let audited = absolutePath(paramStr(2))
  let checker = absolutePath(paramStr(3))
  let moduleChecker = absolutePath(paramStr(4))
  let directory = absolutePath(paramStr(5))
  createDir(directory)
  for mode in ["empty","inactive","no-queries","fresh8","cached8","literal8","fresh32","fresh64","literal64","module","full"]:
    let before = directory / (mode & "-baseline.meta")
    let after = directory / (mode & ".meta")
    let audit = directory / (mode & ".audit")
    discard run(baseline,[mode,before,"-"])
    discard run(audited,[mode,after,audit])
    doAssert readFile(before) == readFile(after),"immutable-table audit changed circuit/witness: " & mode
    let check = if mode in ["module","full"]: moduleChecker else: checker
    stdout.write mode & ": " & run(check,[audit])
    stdout.flushFile()
  for mode in ["bad-value","bad-missing","bad-duplicate","bad-order","bad-gap"]:
    doAssert "rejected invalid table witness" in run(audited,[mode,"-","-"])
  let original = readFile(directory / "fresh8.audit").splitLines()
  let header = original[0].splitWhitespace()
  let first = 1+3*parseInt(header[3])
  doAssert original[first].startsWith("I ")
  let fields = original[first].splitWhitespace()
  let entryCount = parseInt(fields[3])
  let queryCount = parseInt(fields[4])
  let firstOrder = first+1+3*(entryCount+queryCount)
  doAssert original[firstOrder] == "D"
  var memory = firstOrder
  while not original[memory].startsWith("M "): inc memory
  var rejected = 5
  proc reject(name: string, data: seq[string]) =
    let path = directory / (name & ".audit")
    writeFile(path,data.join("\n"))
    discard run(checker,[path],false)
    inc rejected
  for offset in 1..5:
    var changed = original
    var fields = changed[first].splitWhitespace()
    fields[offset] = $(parseInt(fields[offset])+1)
    changed[first] = fields.join(" ")
    reject("table-header-" & $offset,changed)
  for offset in 0..<3:
    var changed = original
    changed[first+1+offset] = "1 0:" & repeat('0',64)
    reject("initializer-field-" & $offset,changed)
    changed = original
    changed[first+1+3*entryCount+offset] = "1 0:" & repeat('0',64)
    reject("query-field-" & $offset,changed)
  var changed = original
  changed[firstOrder+1] = "1 0:" & repeat('0',64)
  reject("order-delta",changed)
  changed = original
  # The RAM write flag for a query cannot be rebound to its active wire.
  let queryMemory = memory+1+7*entryCount
  doAssert original[queryMemory].startsWith("A ")
  changed[queryMemory+2] = changed[queryMemory+1]
  reject("query-becomes-write",changed)
  changed = original
  changed[1] = "1 0:" & repeat('0',64)
  reject("order-matrix",changed)
  changed = original
  changed.add "trailing"
  reject("trailing",changed)
  changed = original
  changed.setLen(changed.len-5)
  reject("truncated",changed)
  let module = readFile(directory / "module.audit").splitLines()
  var packed = -1
  for i,line in module:
    if line.startsWith("F "): packed = i; break
  doAssert packed > 0
  for name in ["packed-binding","packed-count"]:
    var changed = module
    if name == "packed-binding": changed[packed+2] = "1 0:" & repeat('0',64)
    else:
      var header = changed[0].splitWhitespace()
      header[7] = $(parseInt(header[7])+1)
      changed[0] = header.join(" ")
    let path = directory / (name & ".audit")
    writeFile(path,changed.join("\n"))
    discard run(moduleChecker,[path],false)
    inc rejected
  echo "immutable-table audit PASS: 11 full matrices, ",rejected," invalid witnesses/forgeries rejected"
main()

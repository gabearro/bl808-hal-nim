## Authenticate the complete envelope matrix and reject detached evidence.
import std/[os,osproc,strutils]

proc run(executable: string, args: openArray[string], succeeds = true): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let checked = execCmdEx(command)
  doAssert (checked.exitCode == 0) == succeeds,command & "\n" & checked.output
  checked.output

proc main() =
  if paramCount() != 4: quit("usage: test_envelope BASELINE AUDITED CHECKER DIRECTORY",1)
  let baseline = absolutePath(paramStr(1))
  let audited = absolutePath(paramStr(2))
  let checker = absolutePath(paramStr(3))
  let directory = absolutePath(paramStr(4))
  createDir(directory)
  for mode in ["header","padded","custom","policy","module","full"]:
    let before = directory / (mode & "-baseline.meta")
    let after = directory / (mode & ".meta")
    let audit = directory / (mode & ".audit")
    discard run(baseline,[mode,before,"-"])
    discard run(audited,[mode,after,audit])
    doAssert readFile(before) == readFile(after),"envelope audit changed circuit/witness: " & mode
    stdout.write mode & ": " & run(checker,[audit])
    stdout.flushFile()
  for mode in ["bad-header","unknown","duplicate","reordered","truncated","overrun"]:
    discard run(audited,[mode,directory / (mode & ".meta"),"-"],false)
  let original = readFile(directory / "custom.audit").splitLines()
  var envelope,firstRow,lookup = -1
  for i,line in original:
    if line.startsWith("E "): envelope = i
    if line.startsWith("J ") and firstRow < 0: firstRow = i
    if line.startsWith("L ") and lookup < 0: lookup = i
  doAssert envelope > 0 and firstRow > envelope and lookup > firstRow
  var rejected = 6
  proc reject(name: string, data: seq[string]) =
    let path = directory / (name & ".audit")
    writeFile(path,data.join("\n"))
    discard run(checker,[path],false)
    inc rejected
  for offset in 1..7:
    var changed = original
    var fields = changed[envelope].splitWhitespace()
    fields[offset] = if offset == 1: "0" elif offset == 2: $(parseInt(original[0].splitWhitespace()[1])+1) else: $(parseInt(fields[offset])+1)
    changed[envelope] = fields.join(" ")
    reject("envelope-" & $offset,changed)
  for offset in 1..5:
    var changed = original
    var fields = changed[firstRow].splitWhitespace()
    fields[offset] = $(parseInt(fields[offset])+1)
    changed[firstRow] = fields.join(" ")
    reject("row-" & $offset,changed)
  for offset in 1..7:
    var changed = original
    changed[firstRow+offset] = "1 0:" & repeat('0',64)
    reject("section-field-" & $offset,changed)
  var changed = original
  changed[envelope+1] = "1 0:" & repeat('0',64)
  reject("detached-source",changed)
  changed = original
  var h = changed[envelope+2].splitWhitespace()
  h[1] = h[2]
  changed[envelope+2] = h.join(" ")
  reject("header-token-swap",changed)
  changed = original
  let lastOutput = original.len-2
  changed[lastOutput] = "1 0:" & repeat('0',64)
  reject("detached-directory",changed)
  changed = original
  var fields = changed[lookup].splitWhitespace()
  fields[5] = $(parseInt(fields[5])+1)
  changed[lookup] = fields.join(" ")
  reject("lookup-root",changed)
  let startGate = parseInt(original[envelope].splitWhitespace()[3])
  changed = original
  changed[1+3*startGate] = "1 0:" & repeat('0',64)
  reject("envelope-gate",changed)
  changed = original
  changed.add "trailing"
  reject("trailing",changed)
  changed = original
  changed.setLen(changed.len-10)
  reject("truncated-evidence",changed)
  echo "envelope audit PASS: 6 complete matrices, ",rejected," malformed modules/forgeries rejected"
main()

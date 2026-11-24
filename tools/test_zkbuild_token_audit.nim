## Full primitive/variant reader matrix conformance and detached-interface tests.
import std/[os,osproc,strutils]

proc run(executable: string, args: openArray[string], succeeds = true): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let checked = execCmdEx(command)
  doAssert (checked.exitCode == 0) == succeeds,command & "\n" & checked.output
  checked.output

proc main() =
  if paramCount() != 4: quit("usage: test_token_audit BASELINE AUDITED CHECKER DIRECTORY",1)
  let baseline = absolutePath(paramStr(1))
  let audited = absolutePath(paramStr(2))
  let checker = absolutePath(paramStr(3))
  let directory = absolutePath(paramStr(4))
  createDir(directory)
  for mode in ["zero","empty-table","table","active","inactive","module","full"]:
    let before = directory / (mode & "-baseline.meta")
    let after = directory / (mode & ".meta")
    let audit = directory / (mode & ".audit")
    discard run(baseline,[mode,before,"-"])
    discard run(audited,[mode,after,audit])
    doAssert readFile(before) == readFile(after),"token audit changed circuit/witness: " & mode
    stdout.write mode & ": " & run(checker,[audit])
    stdout.flushFile()
  doAssert readFile(directory / "active.meta").splitLines()[1] == readFile(directory / "inactive.meta").splitLines()[1]
  let detached = directory / "detached.audit"
  discard run(audited,["detached",directory / "detached.meta",detached])
  discard run(checker,[detached],false)
  let original = readFile(directory / "active.audit").splitLines()
  let header = original[0].splitWhitespace()
  let sourceStart = 1+3*parseInt(header[3])
  let source = original[sourceStart].splitWhitespace()
  let sourceRange = sourceStart+2+parseInt(source[6])+parseInt(source[7])
  let hashStart = sourceRange+34
  let memoryStart = hashStart+4+parseInt(original[hashStart].splitWhitespace()[5])+34
  let memory = original[memoryStart].splitWhitespace()
  let n = parseInt(memory[4])
  let first = memoryStart+1+17*n+1+2*n+3*parseInt(header[4])
  doAssert original[first].startsWith("T ")
  var rangeStarts, useStarts, rows, tokenStarts: seq[int]
  proc rangeEnd(start: int): int =
    rangeStarts.add start
    let fields = original[start].splitWhitespace()
    doAssert fields[0] == "R"
    start+1+parseInt(fields[8])+parseInt(fields[9])
  proc useEnd(start: int): int =
    useStarts.add start
    doAssert original[start].startsWith("U ")
    result = rangeEnd(start+1)
    if original[start] == "U 1": result = rangeEnd(result)
  var cursor = first
  for _ in 0..<parseInt(header[5]):
    tokenStarts.add cursor
    let fields = original[cursor].splitWhitespace()
    cursor += 6
    for _ in 0..<3: cursor = useEnd(cursor)
    for _ in 0..<parseInt(fields[9]):
      rows.add cursor
      doAssert original[cursor].startsWith("D ")
      cursor += 5
      cursor = useEnd(cursor)
      cursor = useEnd(cursor)
  doAssert cursor == original.len-1
  var rejected = 1
  proc reject(name: string, data: seq[string]) =
    let path = directory / (name & ".audit")
    writeFile(path,data.join("\n"))
    discard run(checker,[path],false)
    inc rejected
  for offset in [1,2,3,4,5,7]:
    var changed = original
    var fields = original[first].splitWhitespace()
    fields[offset] = if offset == 2: "0" elif offset == 3: $(parseInt(header[1])+1) else: $(parseInt(fields[offset])+1)
    changed[first] = fields.join(" ")
    reject("token-header-" & $offset,changed)
  for offset in 1..5:
    var changed = original
    changed[first+offset] = "1 0:" & repeat('0',64)
    reject("token-input-" & $offset,changed)
  for offset in 1..4:
    var changed = original
    changed[rows[0]+offset] = "1 0:" & repeat('0',64)
    reject("row-input-" & $offset,changed)
  let variant = tokenStarts[1]
  doAssert original[variant].splitWhitespace()[1] == "7"
  for offset in [6,7,8]:
    var changed = original
    var fields = original[variant].splitWhitespace()
    fields[offset] = $(parseInt(fields[offset])+1)
    changed[variant] = fields.join(" ")
    reject("variant-offset-" & $offset,changed)
  for start in [first,variant]:
    let token = original[start].splitWhitespace()
    for gate in [parseInt(token[4]),parseInt(token[5])-1]:
      var changed = original
      changed[1+3*gate] = "1 0:" & repeat('0',64)
      reject("gate-" & $gate,changed)
  var changed = original
  var fields = original[rangeStarts[0]].splitWhitespace()
  fields[1] = "9"
  changed[rangeStarts[0]] = fields.join(" ")
  reject("missing-range-origin",changed)
  changed = original
  fields = original[rangeStarts[0]].splitWhitespace()
  fields[5] = $(parseInt(fields[5])+1)
  changed[rangeStarts[0]] = fields.join(" ")
  reject("range-gate-shift",changed)
  changed = original
  changed[rangeStarts[0]+2] = "1 0:" & repeat('0',64)
  reject("range-bit-rebinding",changed)
  changed = original
  # Delete a whole valid token record; the remaining token proofs remain valid.
  fields = header
  fields[5] = $(parseInt(fields[5])-1)
  changed[0] = fields.join(" ")
  changed = changed[0..<first] & changed[tokenStarts[1]..<changed.len]
  reject("omitted-token",changed)
  changed = original
  changed[1] = "1 0:" & repeat('f',64)
  reject("noncanonical",changed)
  changed = original
  changed.setLen(changed.len-5)
  reject("truncated",changed)
  changed = original
  changed.add "trailing"
  reject("trailing",changed)
  echo "token audit PASS: 7 full matrices; all primitive/variant kinds; ",rejected," forgeries rejected"

main()

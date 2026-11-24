## Independently check emitted lookup circuits and exhaustive table semantics.
import std/[os,osproc,strutils]

proc run(executable: string, args: openArray[string], succeeds = true): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let checked = execCmdEx(command)
  doAssert (checked.exitCode == 0) == succeeds,command & "\n" & checked.output
  checked.output

proc main() =
  if paramCount() != 4: quit("usage: test_lookup BASELINE AUDITED CHECKER DIRECTORY",1)
  let baseline = absolutePath(paramStr(1))
  let audited = absolutePath(paramStr(2))
  let checker = absolutePath(paramStr(3))
  let directory = absolutePath(paramStr(4))
  createDir(directory)
  for mode in ["fresh-0","fresh-13","cached-6","literal-12","fresh-14","cached-255","literal-65535"]:
    let before = directory / (mode & "-baseline.meta")
    let after = directory / (mode & ".meta")
    let audit = directory / (mode & ".audit")
    discard run(baseline,[mode,before,"-"])
    discard run(audited,[mode,after,audit])
    doAssert readFile(before) == readFile(after),"lookup audit changed circuit/witness: " & mode
    stdout.write mode & ": " & run(checker,[audit])
    stdout.flushFile()
  let original = readFile(directory / "fresh-13.audit").splitLines()
  let header = original[0].splitWhitespace()
  let record = 1+3*parseInt(header[3])
  doAssert original[record].startsWith("L ")
  var rejected = 0
  proc reject(name: string, data: seq[string]) =
    let path = directory / (name & ".audit")
    writeFile(path,data.join("\n"))
    discard run(checker,[path],false)
    inc rejected
  for offset in 1..7:
    var changed = original
    var fields = changed[record].splitWhitespace()
    fields[offset] = $(parseInt(fields[offset])+1)
    changed[record] = fields.join(" ")
    reject("record-" & $offset,changed)
  for offset in 1..3:
    var changed = original
    changed[record+offset] = "1 0:" & repeat('0',64)
    reject("binding-" & $offset,changed)
  for i,line in original:
    if not line.startsWith("N "): continue
    var changed = original
    var fields = line.splitWhitespace()
    fields[^1] = $(parseInt(fields[^1])+1)
    changed[i] = fields.join(" ")
    reject("payload",changed)
    break
  var changed = original
  changed[1] = "1 0:" & repeat('0',64)
  reject("matrix",changed)
  changed = original
  changed.add "trailing"
  reject("trailing",changed)
  echo "lookup audit PASS: 7 circuits, exhaustive 16-bit policy, ",rejected," forgeries rejected"
main()

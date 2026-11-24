## Complete matrix binding for shared length ranges and embedded SHA blocks.
import std/[os,osproc,strutils]

proc run(executable: string, args: openArray[string], succeeds = true): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let execution = execCmdEx(command)
  doAssert (execution.exitCode == 0) == succeeds,command & "\n" & execution.output
  execution.output

proc main() =
  if paramCount() != 4: quit("usage: test_sha_embedded BASELINE AUDITED CHECKER DIRECTORY",1)
  let baseline = absolutePath(paramStr(1))
  let audited = absolutePath(paramStr(2))
  let checker = absolutePath(paramStr(3))
  let directory = absolutePath(paramStr(4))
  createDir(directory)
  for mode in ["fresh","cached","gap","module","full"]:
    let oldMeta = directory / (mode & "-baseline.meta")
    let newMeta = directory / (mode & ".meta")
    let audit = directory / (mode & ".audit")
    discard run(baseline,[mode,oldMeta,"-"])
    discard run(audited,[mode,newMeta,audit])
    doAssert readFile(oldMeta) == readFile(newMeta),"SHA instrumentation changed matrix or witness: " & mode
    stdout.write mode & ": " & run(checker,[audit])
  doAssert readFile(directory / "fresh.meta") == readFile(directory / "cached.meta"),
    "eager/cached length decomposition changed the circuit"
  let original = readFile(directory / "fresh.audit").splitLines()
  let header = original[0].splitWhitespace()
  let gates = parseInt(header[3])
  let recordStart = 1+gates*3
  let record = original[recordStart].splitWhitespace()
  let capacity = parseInt(record[5])
  let firstGate = parseInt(record[3])
  let lastGate = parseInt(record[4])
  let rangeStart = recordStart+4+capacity
  let range = original[rangeStart].splitWhitespace()
  var rejected = 0
  proc reject(name: string, data: seq[string]) =
    let path = directory / (name & ".audit")
    writeFile(path,data.join("\n"))
    discard run(checker,[path],false)
    inc rejected
  for test in [("range-gate",parseInt(range[5])),("hash-gate",firstGate+(lastGate-firstGate) div 2),
               ("digest-gate",lastGate-1)]:
    var changed = original
    let index = 1+3*test[1]
    changed[index] = if changed[index] == "1 0:" & repeat('0',64):
        "1 0:" & repeat('0',63) & "1" else: "1 0:" & repeat('0',64)
    reject(test[0],changed)
  for test in [("first-wire",1),("last-wire",2),("first-gate",3),("last-gate",4)]:
    var changed = original
    var fields = record
    fields[test[1]] = $(parseInt(fields[test[1]])+1)
    changed[recordStart] = fields.join(" ")
    reject(test[0],changed)
  for test in [("range-kind",1),("range-width",2),("range-first-wire",3),("range-first-gate",5)]:
    var changed = original
    var fields = range
    fields[test[1]] = $(parseInt(fields[test[1]])+1)
    changed[rangeStart] = fields.join(" ")
    reject(test[0],changed)
  var changed = original
  changed[rangeStart+1] = original[recordStart+4]
  reject("range-input",changed)
  changed = original
  changed[rangeStart+2] = original[rangeStart+3]
  reject("cached-bit-output",changed)
  changed = original
  swap(changed[recordStart+4],changed[recordStart+5])
  reject("source-order",changed)
  changed = original
  changed[recordStart+1] = original[recordStart+4]
  reject("length-binding",changed)
  changed = original
  changed[recordStart+2] = original[recordStart+3]
  reject("digest-binding",changed)
  changed = original
  var fields = header
  fields[2] = "3"
  changed[0] = fields.join(" ")
  reject("public-count",changed)
  changed = original
  fields = header
  fields[4] = "0"
  changed[0] = fields.join(" ")
  reject("missing-hash",changed)
  changed = original
  changed[1] = "1 0:" & repeat('f',64)
  reject("noncanonical",changed)
  changed = original
  changed.setLen(changed.len-5)
  reject("truncated",changed)
  changed = original
  changed.add "trailing"
  reject("trailing",changed)
  echo "embedded SHA regression PASS: five full matrices; unchanged ordinary/audited fingerprints; ",rejected," forgeries rejected"

main()

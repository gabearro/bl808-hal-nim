## Audited/ordinary full-circuit identity, pure checker, and forged traces.
import std/[os,osproc,strutils]

proc run(executable: string, args: openArray[string], expected = 0): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let checked = execCmdEx(command)
  doAssert checked.exitCode == expected,command & "\n" & checked.output
  checked.output

proc main() =
  if paramCount() != 4: quit("usage: test_gadget_audit BASELINE AUDITED CHECKER DIRECTORY",1)
  let baseline = absolutePath(paramStr(1))
  let audited = absolutePath(paramStr(2))
  let checker = absolutePath(paramStr(3))
  let directory = absolutePath(paramStr(4))
  createDir(directory)
  for mode in ["core","invalid","module","full"]:
    let ordinaryMeta = directory / (mode & "-baseline.meta")
    let auditMeta = directory / (mode & ".meta")
    let audit = directory / (mode & ".audit")
    discard run(baseline,[mode,ordinaryMeta,"-"])
    discard run(audited,[mode,auditMeta,audit])
    doAssert readFile(ordinaryMeta) == readFile(auditMeta),"auditing changed the circuit or witness: " & mode
    let checked = run(checker,[audit])
    stdout.write checked
    if mode == "core": doAssert "covered=64 unclassified=1" in checked
    if mode == "module":
      doAssert "matrix=539483 records=115380 covered=513122 unclassified=26361" in checked
    if mode == "full":
      doAssert "matrix=2425294 records=687533 covered=2298007 unclassified=127287" in checked
  let original = readFile(directory / "core.audit").splitLines()
  let head = original[0].splitWhitespace()
  let gates = parseInt(head[3])
  let count = parseInt(head[4])
  var starts: seq[int]
  var fields: seq[seq[string]]
  var position = 1+3*gates
  for _ in 0..<count:
    starts.add position
    let row = original[position].splitWhitespace()
    fields.add row
    position += 1+parseInt(row[8])+parseInt(row[9])
  var rejected = 0
  proc reject(name: string, data: seq[string]) =
    let path = directory / (name & ".audit")
    writeFile(path,data.join("\n"))
    let output = run(checker,[path],1)
    doAssert "error" in output.toLowerAscii() or "uncaught exception" in output.toLowerAscii()
    inc rejected
  var changed = original
  changed[1] = changed[1].replace(repeat('0',63) & "1",repeat('0',63) & "2")
  reject("gate",changed)
  changed = original
  var row = fields[0]
  row[3] = "0"
  changed[starts[0]] = row.join(" ")
  reject("wire-bound",changed)
  changed = original
  row = fields[0]
  row[1] = "11"
  changed[starts[0]] = row.join(" ")
  reject("unknown-kind",changed)
  changed = original
  row = fields[0]
  row[5] = $gates
  row[6] = $(gates+1)
  changed[starts[0]] = row.join(" ")
  reject("span",changed)
  var reused = -1
  var fresh = -1
  var literal = -1
  for i,r in fields:
    case parseInt(r[1])
    of 8: fresh = i
    of 9: reused = i
    of 10: literal = i
    else: discard
  doAssert reused >= 0 and fresh >= 0 and literal >= 0
  changed = original
  row = fields[reused]
  row[7] = $(reused+1)
  changed[starts[reused]] = row.join(" ")
  reject("forward-reference",changed)
  changed = original
  row = fields[reused]
  row[7] = "1"
  changed[starts[reused]] = row.join(" ")
  reject("wrong-reference-kind",changed)
  changed = original
  row = fields[fresh]
  row[2] = $(parseInt(row[2])+1)
  changed[starts[fresh]] = row.join(" ")
  reject("range-width",changed)
  changed = original
  let output = starts[reused]+1+parseInt(fields[reused][8])
  changed[output] = "1 0:" & repeat('0',64)
  reject("cached-output",changed)
  changed = original
  let input = starts[literal]+1
  changed[input] = "1 1:" & repeat('0',63) & "1"
  reject("nonconstant-literal",changed)
  changed = original
  row = fields[1]
  row[5] = "0"
  changed[starts[1]] = row.join(" ")
  reject("overlap",changed)
  changed = original
  changed[1] = "1 0:" & repeat('f',64)
  reject("noncanonical",changed)
  changed = original
  changed.setLen(changed.len-5)
  reject("truncated",changed)
  changed = original
  changed.add "extra"
  reject("trailing",changed)
  echo "gadget audit PASS: ordinary/audited matrix and witness identity; ",rejected," forged audits rejected"

main()

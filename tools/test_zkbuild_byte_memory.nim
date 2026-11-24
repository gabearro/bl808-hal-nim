## Check the composed byte source/hash/RAM theorem on emitted Nim matrices.
import std/[os,osproc,strutils]

proc run(executable: string, args: openArray[string], succeeds = true): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let checked = execCmdEx(command)
  doAssert (checked.exitCode == 0) == succeeds,command & "\n" & checked.output
  checked.output

proc main() =
  if paramCount() != 4: quit("usage: test_byte_memory BASELINE AUDITED CHECKER DIRECTORY",1)
  let baseline = absolutePath(paramStr(1))
  let audited = absolutePath(paramStr(2))
  let checker = absolutePath(paramStr(3))
  let directory = absolutePath(paramStr(4))
  createDir(directory)
  for mode in ["zero","empty-table","table","active","inactive","module","full"]:
    let before = directory / (mode & "-baseline.meta")
    let after = directory / (mode & ".meta")
    let path = directory / (mode & ".audit")
    discard run(baseline,[mode,before,"-"])
    discard run(audited,[mode,after,path])
    doAssert readFile(before) == readFile(after),"byte memory audit changed circuit/witness: " & mode
    stdout.write mode & ": " & run(checker,[path])
    stdout.flushFile()
  doAssert readFile(directory / "active.meta").splitLines()[1] ==
    readFile(directory / "inactive.meta").splitLines()[1],"byte memory matrix depends on witness activity"
  let detached = directory / "detached.audit"
  discard run(audited,["detached",directory / "detached.meta",detached])
  let result = run(checker,[detached],false)
  doAssert "source/query/RAM interface rejected" in result,result
  let original = readFile(directory / "active.audit").splitLines()
  let header = original[0].splitWhitespace()
  let sourceStart = 1+3*parseInt(header[3])
  let source = original[sourceStart].splitWhitespace()
  let sourceRange = sourceStart+2+parseInt(source[6])+parseInt(source[7])
  let hashStart = sourceRange+34
  let hash = original[hashStart].splitWhitespace()
  let memoryStart = hashStart+4+parseInt(hash[5])+34
  let memory = original[memoryStart].splitWhitespace()
  doAssert memory[0] == "M"
  let n = parseInt(memory[4])
  let inputStart = memoryStart+1
  let firstQuery = inputStart+7*parseInt(source[5])
  let sortedStart = inputStart+7*n
  let networkStart = sortedStart+10*n
  let queryStart = networkStart+1+2*n
  doAssert original[networkStart].startsWith("P ")
  doAssert original.len == queryStart+3*parseInt(header[4])+1
  var rejected = 1
  proc reject(name: string, data: seq[string], message = "") =
    let path = directory / (name & ".audit")
    writeFile(path,data.join("\n"))
    let response = run(checker,[path],false)
    if message.len > 0: doAssert message in response,response
    inc rejected
  for test in [("declared-query-active",queryStart),("declared-query-address",queryStart+1),
               ("declared-query-value",queryStart+2)]:
    var changed = original
    changed[test[1]] = "1 0:" & repeat('0',64)
    reject(test[0],changed,"source/query/RAM interface rejected")
  var changed = original
  # Swap two complete declared queries without touching the sound RAM proof.
  for i in 0..<3:
    changed[queryStart+i] = original[queryStart+3+i]
    changed[queryStart+3+i] = original[queryStart+i]
  reject("reordered-queries",changed,"source/query/RAM interface rejected")
  for test in [("source-byte",sourceStart+2+parseInt(source[6])+2),
               ("hash-byte",hashStart+4),("initializer-value",inputStart+4),
               ("initializer-write",inputStart+2),("RAM-query-value",firstQuery+4),
               ("RAM-query-write",firstQuery+2),("RAM-padding-write",inputStart+7*(n-1)+2)]:
    changed = original
    changed[test[1]] = "1 0:" & repeat('0',63) & "1"
    reject(test[0],changed)
  for test in [("source-gate",parseInt(source[3])),("hash-gate",parseInt(hash[3])),
               ("RAM-gate",parseInt(original[firstQuery].splitWhitespace()[1])),
               ("permutation-gate",parseInt(original[networkStart].splitWhitespace()[4]))]:
    changed = original
    changed[1+3*test[1]] = "1 0:" & repeat('0',64)
    reject(test[0],changed)
  changed = original
  var fields = header
  fields[4] = $(parseInt(fields[4])-1)
  changed[0] = fields.join(" ")
  changed.setLen(changed.len-3)
  reject("omitted-query",changed,"source/query/RAM interface rejected")
  changed = original
  changed[1] = "1 0:" & repeat('f',64)
  reject("noncanonical-scalar",changed)
  changed = original
  changed.setLen(changed.len-5)
  reject("truncated",changed)
  changed = original
  changed.add "trailing"
  reject("trailing",changed)
  echo "byte source/hash/RAM regression PASS: 7 matrices; identical fingerprints; ",rejected," forgeries rejected"

main()

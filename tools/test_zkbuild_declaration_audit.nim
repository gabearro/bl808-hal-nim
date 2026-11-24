import std/[os,osproc,strutils]

proc run(executable: string, args: openArray[string], succeeds = true): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let checked = execCmdEx(command)
  doAssert (checked.exitCode == 0) == succeeds,command & "\n" & checked.output
  checked.output

proc main() =
  if paramCount() != 4: quit("usage: test_declarations BASELINE AUDITED CHECKER DIRECTORY",1)
  let baseline = absolutePath(paramStr(1))
  let audited = absolutePath(paramStr(2))
  let checker = absolutePath(paramStr(3))
  let directory = absolutePath(paramStr(4))
  createDir(directory)
  for mode in ["module","padded","nonminimal","multi","empty","tag","full"]:
    let before = directory / (mode & "-baseline.meta")
    let after = directory / (mode & ".meta")
    let audit = directory / (mode & ".audit")
    discard run(baseline,[mode,before,"-"])
    discard run(audited,[mode,after,audit])
    doAssert readFile(before) == readFile(after),"declaration instrumentation changed the circuit: " & mode
    stdout.write mode & ": " & run(checker,[audit])
    stdout.flushFile()
  let nonminimal = readFile(directory / "nonminimal.meta").splitLines()
  for mode in ["multi","empty","tag"]:
    let other = readFile(directory / (mode & ".meta")).splitLines()
    doAssert nonminimal[1] == other[1],"same profile changed the matrix"
    doAssert nonminimal[2] != other[2],"different source retained the same witness"
  let original = readFile(directory / "module.audit").splitLines()
  var declaration,firstType,firstVector,firstFunction = -1
  for i,line in original:
    if line.startsWith("C "): declaration = i
    if declaration >= 0 and line.startsWith("Y ") and firstType < 0: firstType = i
    if declaration >= 0 and line.startsWith("V ") and firstVector < 0: firstVector = i
    if declaration >= 0 and line.startsWith("F ") and firstFunction < 0: firstFunction = i
  doAssert declaration > 0 and firstType > declaration and firstVector > firstType and firstFunction > firstVector
  var rejected = 0
  proc reject(name: string, data: seq[string]) =
    let path = directory / (name & ".audit")
    writeFile(path,data.join("\n"))
    discard run(checker,[path],false)
    removeFile(path) # Keep failing evidence; successful forgeries need not occupy hundreds of MB.
    inc rejected
  for offset in 1..5:
    var changed = original
    var fields = changed[declaration].splitWhitespace()
    fields[offset] = $(parseInt(fields[offset])+1)
    changed[declaration] = fields.join(" ")
    reject("counts-" & $offset,changed)
  for offset in 1..6:
    var changed = original
    var fields = changed[firstType].splitWhitespace()
    fields[offset] = $(parseInt(fields[offset])+1)
    changed[firstType] = fields.join(" ")
    reject("type-metadata-" & $offset,changed)
  for offset in 1..7:
    var changed = original
    changed[firstType+offset] = "1 0:" & repeat('0',64)
    reject("type-field-" & $offset,changed)
  for offset in [1,2,3,4,5,6,7,8,9]:
    var changed = original
    var fields = changed[firstVector].splitWhitespace()
    fields[offset] = $(parseInt(fields[offset])+1)
    changed[firstVector] = fields.join(" ")
    reject("vector-metadata-" & $offset,changed)
  for offset in 1..3:
    var changed = original
    var fields = changed[firstFunction].splitWhitespace()
    fields[offset] = $(parseInt(fields[offset])+1)
    changed[firstFunction] = fields.join(" ")
    reject("function-metadata-" & $offset,changed)
  var changed = original
  changed[declaration+2] = "1 0:" & repeat('0',64)
  reject("detached-type-source",changed)
  changed = original
  changed.add "trailing"
  reject("trailing",changed)
  let tagData = readFile(directory / "tag.audit").splitLines()
  var tagRow = -1
  for i,line in tagData:
    if line.startsWith("G "): tagRow = i; break
  doAssert tagRow > 0
  for offset in [3,4]:
    var changed = tagData
    var fields = changed[tagRow].splitWhitespace()
    fields[offset] = $(parseInt(fields[offset])+1)
    changed[tagRow] = fields.join(" ")
    reject("tag-token-" & $offset,changed)
  echo "declaration audit PASS: 7 full matrices; ",rejected," forgeries rejected"
main()

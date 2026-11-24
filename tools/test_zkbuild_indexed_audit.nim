import std/[os,osproc,strutils]

proc run(executable: string, args: openArray[string], succeeds = true): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let result = execCmdEx(command)
  doAssert (result.exitCode == 0) == succeeds,command & "\n" & result.output
  result.output

proc main() =
  if paramCount() != 4: quit("usage: test_indexed BASELINE AUDITED CHECKER DIRECTORY",1)
  let baseline = absolutePath(paramStr(1))
  let audited = absolutePath(paramStr(2))
  let checker = absolutePath(paramStr(3))
  let directory = absolutePath(paramStr(4))
  createDir(directory)
  for mode in ["module","padded","nonminimal","multi","empty","tag","alltypes","full"]:
    let before = directory / (mode & "-baseline.meta")
    let after = directory / (mode & ".meta")
    let audit = directory / (mode & ".audit")
    discard run(baseline,[mode,before,"-"])
    discard run(audited,[mode,after,audit])
    doAssert readFile(before) == readFile(after),"indexed instrumentation changed circuit/witness: " & mode
    stdout.write mode & ": " & run(checker,[audit])
    stdout.flushFile()
  let profile = readFile(directory / "nonminimal.meta").splitLines()
  for mode in ["multi","empty","tag"]:
    let other = readFile(directory / (mode & ".meta")).splitLines()
    doAssert profile[1] == other[1],"same indexed profile changed matrix"
    doAssert profile[2] != other[2],"different module retained witness"
  let original = readFile(directory / "module.audit").splitLines()
  var header,nilSpan,tables,lengthRow,member,close,metadata,singleton = -1
  for i,line in original:
    if line.startsWith("X "): header = i
    if header < 0: continue
    if line.startsWith("N "): nilSpan = i
    if line.startsWith("B "): tables = i
    if line.startsWith("L ") and lengthRow < 0: lengthRow = i
    if line.startsWith("M ") and member < 0: member = i
    if line.startsWith("J ") and close < 0: close = i
    if line.startsWith("H ") and metadata < 0: metadata = i
    if line.startsWith("S ") and singleton < 0: singleton = i
  doAssert header > 0 and singleton > metadata and metadata > close and close > member and member > lengthRow and lengthRow > tables
  var rejected = 0
  proc reject(name: string, data: seq[string]) =
    let path = directory / (name & ".audit")
    writeFile(path,data.join("\n"))
    discard run(checker,[path],false)
    removeFile(path)
    inc rejected
  for (label,row,last) in [("counts",header,4),("nil",nilSpan,2),("tables",tables,4),
      ("length",lengthRow,4),("member",member,9),("close",close,2),("metadata",metadata,3),("singleton",singleton,2)]:
    for offset in 1..last:
      var changed = original
      var fields = changed[row].splitWhitespace()
      fields[offset] = $(parseInt(fields[offset])+1)
      changed[row] = fields.join(" ")
      reject(label & "-" & $offset,changed)
  for (label,row,last) in [("length-field",lengthRow,7),("member-field",member,10),("metadata-field",metadata,9),("singleton-field",singleton,6)]:
    for offset in 1..last:
      var changed = original
      changed[row+offset] = "1 0:" & repeat('0',64)
      # A zero fixture field is already canonical: mutate it to one instead.
      if changed[row+offset] == original[row+offset]:
        changed[row+offset] = "1 0:01" & repeat('0',62)
      reject(label & "-" & $offset,changed)
  var trailing = original
  trailing.add "trailing"
  reject("trailing",trailing)
  echo "indexed audit PASS: 8 full matrices; ",rejected," forgeries rejected"

main()

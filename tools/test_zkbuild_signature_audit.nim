import std/[os,osproc,strutils]

proc run(executable: string, args: openArray[string], succeeds = true): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let result = execCmdEx(command)
  doAssert (result.exitCode == 0) == succeeds,command & "\n" & result.output
  result.output

proc main() =
  if paramCount() != 4: quit("usage: test_signatures BASELINE AUDITED CHECKER DIRECTORY",1)
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
    doAssert readFile(before) == readFile(after),"signature instrumentation changed circuit/witness: " & mode
    stdout.write mode & ": " & run(checker,[audit])
    stdout.flushFile()
  let profile = readFile(directory / "nonminimal.meta").splitLines()
  for mode in ["multi","empty","tag"]:
    let other = readFile(directory / (mode & ".meta")).splitLines()
    doAssert profile[1] == other[1] and profile[2] != other[2],"signature profile/witness regression"
  let original = readFile(directory / "module.audit").splitLines()
  var header,tables,metadata,reference,node,space,row = -1
  for i,line in original:
    if line.startsWith("S ") and line.splitWhitespace().len == 5:
      header = i
      tables = -1
      metadata = -1
      reference = -1
      node = -1
      space = -1
      row = -1
    if header < 0: continue
    if line.startsWith("B "): tables = i
    if line.startsWith("M ") and metadata < 0: metadata = i
    if line.startsWith("R ") and reference < 0: reference = i
    if line.startsWith("N ") and node < 0: node = i
    if line.startsWith("D "): space = i
    if line.startsWith("Q ") and row < 0: row = i
  doAssert header > 0 and tables > header and metadata > tables and reference > metadata and node > reference and space > node and row > space
  var rejected = 0
  proc reject(name: string, data: seq[string]) =
    let path = directory / (name & ".audit")
    writeFile(path,data.join("\n"))
    discard run(checker,[path],false)
    removeFile(path)
    inc rejected
    if rejected mod 16 == 0:
      echo "signature audit: ",rejected," altered artifacts rejected"
      stdout.flushFile()
  for (label,index,last) in [("counts",header,4),("tables",tables,2),("metadata",metadata,3),
      ("reference",reference,1),("node",node,4),("namespace",space,9),("namespace-row",row,2)]:
    for offset in 1..last:
      var changed = original
      var fields = changed[index].splitWhitespace()
      fields[offset] = $(parseInt(fields[offset])+1)
      changed[index] = fields.join(" ")
      reject(label & "-" & $offset,changed)
  for (label,index,last) in [("metadata-field",metadata,4),("reference-field",reference,3),
      ("node-field",node,4),("namespace-field",space,4),("namespace-row-field",row,3)]:
    for offset in 1..last:
      var changed = original
      changed[index+offset] = "1 0:" & repeat('0',64)
      if changed[index+offset] == original[index+offset]: changed[index+offset] = "1 0:01" & repeat('0',62)
      reject(label & "-" & $offset,changed)
  doAssert original[space+5].startsWith("U ") and original[space+6].startsWith("R ")
  for offset in [1,2,3,4,5,6,8,9]:
    var changed = original
    var fields = changed[space+6].splitWhitespace()
    fields[offset] = $(parseInt(fields[offset])+1)
    changed[space+6] = fields.join(" ")
    reject("imported-range-" & $offset,changed)
  for offset in [7,8]:
    var changed = original
    changed[space+offset] = "1 0:" & repeat('0',64)
    if changed[space+offset] == original[space+offset]: changed[space+offset] = "1 0:01" & repeat('0',62)
    reject("imported-range-field-" & $offset,changed)
  var legacy = original
  legacy[0] = legacy[0].replace("ZKSIGNATURES2","ZKSIGNATURES1")
  reject("legacy-without-import-boundary",legacy)
  var trailing = original
  trailing.add "trailing"
  reject("trailing",trailing)
  echo "signature audit PASS: 8 full matrices; ",rejected," forgeries rejected"
main()

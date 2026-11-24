## Full payload-loop evidence, including flattened and legacy element items.
import std/[os,osproc,strutils]
proc run(executable: string, args: openArray[string], success = true): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let checked = execCmdEx(command)
  doAssert (checked.exitCode == 0) == success,command & "\n" & checked.output
  checked.output
proc main() =
  if paramCount() notin 4..5 or (paramCount() == 5 and paramStr(5) != "--reuse-fixtures"):
    quit("usage: test_segment_payload BASELINE AUDITED CHECKER DIRECTORY [--reuse-fixtures]",1)
  let baseline = absolutePath(paramStr(1))
  let audited = absolutePath(paramStr(2))
  let checker = absolutePath(paramStr(3))
  let directory = absolutePath(paramStr(4))
  createDir(directory)
  let reuse = paramCount() == 5
  var accepted,forgeries = 0
  for mode in ["segments","segments-legacy","module","full","full-legacy","padded","empty","name-unicode"]:
    let before = directory / (mode & "-baseline.meta")
    let after = directory / (mode & ".meta")
    let audit = directory / (mode & ".audit")
    if not reuse or not (fileExists(before) and fileExists(after) and fileExists(audit)):
      discard run(baseline,[mode,before,"-"])
      discard run(audited,[mode,after,audit])
    doAssert readFile(before) == readFile(after),"instrumentation changed circuit/witness: " & mode
    let prior = parentDir(directory) / "scalar-payload-tests" / (mode & ".meta")
    if fileExists(prior):
      doAssert readFile(after) == readFile(prior),"segment implementation changed prior circuit/witness: " & mode
    stdout.write mode & ": " & run(checker,[audit])
    stdout.flushFile()
    inc accepted
  for mode in ["segments","segments-legacy"]:
    let originalLines = readFile(directory / (mode & ".audit")).splitLines()
    var start = -1
    for i,line in originalLines:
      if line.startsWith("V ") and line.splitWhitespace().len == 14: start = i
    doAssert start >= 0
    var original = originalLines[start..^1]
    while original.len > 0 and original[^1].len == 0: original.setLen(original.len-1)
    let caseDir = directory / (mode & "-cases")
    createDir(caseDir)
    var manifest,expected: seq[string]
    proc save(label: string, candidate: seq[string], accept = false) =
      let path = caseDir / (label & ".payload")
      writeFile(path,candidate.join("\n") & "\n")
      manifest.add path
      expected.add (if accept: "ACCEPT " else: "REJECT ") & path
    proc numberMutation(label: string,index,field: int) =
      var changed = original
      var words = changed[index].splitWhitespace()
      words[field] = $(parseInt(words[field])+1)
      changed[index] = words.join(" ")
      save(label,changed)
    proc fieldMutation(label: string,index: int) =
      var changed = original
      changed[index] = "1 0:" & repeat('0',64)
      if changed[index] == original[index]: changed[index] = "1 0:" & repeat('0',63) & "1"
      save(label,changed)
    save("unchanged",original,true)
    for i in 1..13: numberMutation("header-" & $i,0,i)
    var begins: seq[int]
    for i,line in original:
      if line.startsWith("B "): begins.add i
    begins.add original.len
    let counts = original[0].splitWhitespace()
    var firstRow = 0
    for group in 0..4:
      let count = if group == 4: 1 else: parseInt(counts[group+4])
      if count == 0: continue
      let a = begins[firstRow]
      let b = begins[firstRow+1]
      let header = original[a].splitWhitespace()
      for j in [1,2,4,5,6,7,8,9]: numberMutation("group-" & $group & "-header-" & $j,a,j)
      if group == 3: numberMutation("custom-heads",a,3)
      let fields = parseInt(header[4])
      for j in 1..fields: fieldMutation("group-" & $group & "-field-" & $j,a+j)
      for j in a+fields+1..<b:
        let words = original[j].splitWhitespace()
        if words[0] in ["Z","I"]:
          for k in 1..<words.len: numberMutation("group-" & $group & "-index-" & $j & "-" & $k,j,k)
        elif words[0] == "R" and words.len == 2:
          numberMutation("group-" & $group & "-token-" & $j,j,1)
        elif words[0] == "R" and words.len == 10:
          numberMutation("group-" & $group & "-range-" & $j,j,2)
        elif words[0][0] in {'0'..'9'}:
          fieldMutation("group-" & $group & "-linear-" & $j,j)
      if group < 4:
        var dropped = original[0..<a] & original[b..^1]
        var h = dropped[0].splitWhitespace()
        h[group+4] = $(count-1)
        dropped[0] = h.join(" ")
        save("missing-row-" & $group,dropped)
        var duplicated = original[0..<a] & original[a..<b] & original[a..^1]
        h[group+4] = $(count+1)
        duplicated[0] = h.join(" ")
        save("duplicate-row-" & $group,duplicated)
        var omitted = original[0..<a] & original[begins[firstRow+count]..^1]
        h[group+4] = "0"
        omitted[0] = h.join(" ")
        save("omitted-group-" & $group,omitted)
        if count > 1:
          save("swapped-rows-" & $group,original[0..<a] & original[b..<begins[firstRow+2]] & original[a..<b] & original[begins[firstRow+2]..^1])
      firstRow += count
    save("truncated",original[0..^2])
    save("trailing",original & @["trailing"])
    let path = caseDir / "manifest.txt"
    writeFile(path,manifest.join("\n") & "\n")
    let result = run(checker,[directory / (mode & ".audit"),"--segment-cases",path])
    var actual: seq[string]
    for line in result.splitLines():
      if line.startsWith("ACCEPT ") or line.startsWith("REJECT "): actual.add line
    doAssert actual == expected,"unexpected segment acceptance\n" & result
    forgeries += expected.len-1
    echo mode," hostile payloads rejected=",expected.len-1
    stdout.flushFile()
  echo "segment payload audit PASS: ",accepted," matrices; ",forgeries," forged payloads rejected"
main()

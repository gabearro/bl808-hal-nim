## Full module-context replay, source interfaces, and hostile audit records.
import std/[os,osproc,strutils,sets]
proc run(executable: string,args: openArray[string]): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let checked = execCmdEx(command)
  doAssert checked.exitCode == 0,command & "\n" & checked.output
  checked.output
proc main() =
  if paramCount() notin 4..6: quit("usage: test_module_context_audit BASELINE AUDITED CHECKER DIRECTORY [--reuse-fixtures] [--cases-only]",1)
  let baseline = absolutePath(paramStr(1))
  let audited = absolutePath(paramStr(2))
  let checker = absolutePath(paramStr(3))
  let directory = absolutePath(paramStr(4))
  let reuse = paramCount() >= 5 and paramStr(5) == "--reuse-fixtures"
  let casesOnly = paramCount() == 6 and paramStr(6) == "--cases-only"
  doAssert paramCount() == 4 or reuse
  doAssert paramCount() < 6 or casesOnly
  createDir(directory)
  var accepted,forgeries = 0
  if not casesOnly:
    for mode in ["module","legacy","full","full-legacy","scalar","scalar-nonminimal","padded","empty"]:
      let before = directory / (mode & "-baseline.meta")
      let after = directory / (mode & ".meta")
      let audit = directory / (mode & ".audit")
      if not reuse or not fileExists(before): discard run(baseline,[mode,before,"-"])
      if not reuse or not (fileExists(after) and fileExists(audit)): discard run(audited,[mode,after,audit])
      doAssert readFile(before) == readFile(after),"instrumentation changed matrix/witness: " & mode
      let prior = parentDir(directory) / "segment-payload-tests" / (mode & ".meta")
      if fileExists(prior): doAssert readFile(after) == readFile(prior),"changed previous matrix/witness: " & mode
      stdout.write mode & ": " & run(checker,[audit])
      stdout.flushFile()
      inc accepted
  for mode in ["full","full-legacy"]:
    var original: seq[string]
    for line in lines(directory / (mode & ".audit")):
      if line.startsWith("M ") and line.splitWhitespace().len == 6: original.setLen(0); original.add line
      elif original.len > 0: original.add line
    doAssert original.len > 15
    let caseDir = directory / (mode & "-context-cases")
    createDir(caseDir)
    var manifest,expected: seq[string]
    proc save(label: string,candidate: seq[string],accept = false) =
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
    for j in 1..5: numberMutation("header-" & $j,0,j)
    for i in 1..14: fieldMutation("counter-" & $i,i)
    var cursor = 15
    proc arrayRows(label: string,skipValue = false) =
      doAssert original[cursor].startsWith("A ")
      let count = parseInt(original[cursor].splitWhitespace()[1])
      numberMutation(label & "-length",cursor,1)
      inc cursor
      for row in 0..<count:
        doAssert original[cursor].startsWith("D ")
        let width = parseInt(original[cursor].splitWhitespace()[1])
        inc cursor
        for column in 0..<width:
          if not (skipValue and column == 2): fieldMutation(label & "-" & $row & "-" & $column,cursor)
          inc cursor
    arrayRows("memories")
    arrayRows("tables")
    arrayRows("globals")
    doAssert original[cursor].startsWith("E ")
    let elements = parseInt(original[cursor].splitWhitespace()[1])
    numberMutation("elements-length",cursor,1)
    inc cursor
    for i in 0..<elements:
      arrayRows("element-" & $i)
      arrayRows("element-items-" & $i)
    arrayRows("flat-items")
    arrayRows("data")
    arrayRows("exports")
    arrayRows("unique")
    arrayRows("bodies",true) # SIMD vector counts are consumed by the instruction circuit.
    arrayRows("bulk")
    doAssert original[cursor].startsWith("H ")
    let heads = parseInt(original[cursor].splitWhitespace()[1])
    inc cursor
    for i in 0..<heads: fieldMutation("head-" & $i,cursor); inc cursor
    doAssert original[cursor].startsWith("T ")
    for i in 2..<original[cursor].splitWhitespace().len: numberMutation("bank-" & $i,cursor,i)
    inc cursor
    doAssert original[cursor].startsWith("P ")
    numberMutation("program-count",cursor,1)
    var kinds: HashSet[string]
    var priorOperation = -1
    for i in cursor+1..<original.len:
      let words = original[i].splitWhitespace()
      if words[0] == "K":
        for j in 1..3: numberMutation("program-" & $i & "-" & $j,i,j)
      elif words[0] == "U":
        priorOperation = i
      elif words[0] == "R" and words[1] notin kinds:
        kinds.incl words[1]
        if words[1] == "9":
          var renamed = original
          var header = words
          header[7] = $(parseInt(header[7])+1)
          renamed[i] = header.join(" ")
          save("valid-prior-index-renaming",renamed,true)
        for j in 1..9:
          # Reused ranges carry the complete checked prior certificate. Its
          # diagnostic builder index is not part of the mathematical claim.
          if not (words[1] == "9" and j == 7):
            numberMutation("primitive-" & words[1] & "-" & $j,i,j)
        let width = parseInt(words[8])+parseInt(words[9])
        for j in 0..<width: fieldMutation("primitive-" & words[1] & "-field-" & $j,i+j+1)
        var truncated = original[0..<i]
        save("truncated-primitive-" & words[1],truncated)
    doAssert priorOperation > 0
    save("truncated-final",original[0..<priorOperation])
    var trailing = original
    trailing.add "unexpected"
    save("trailing",trailing)
    writeFile(caseDir / "manifest.txt",manifest.join("\n") & "\n")
    let response = run(checker,[directory / (mode & ".audit"),"--module-cases",caseDir / "manifest.txt"])
    writeFile(caseDir / "results.log",response)
    for line in expected: doAssert line in response,line & "\n" & response
    var rejected = 0
    for line in expected:
      if line.startsWith("REJECT "): inc rejected
    forgeries += rejected
    echo mode & ": " & $(expected.len-rejected) & " valid controls accepted; " & $rejected & " hostile records rejected"
  echo "module context audit: " & $accepted & " fixtures; " & $forgeries & " hostile records rejected"
main()

## Code-body, compressed-local, helper-boundary, and source-alias regressions.
import std/[os,osproc,strutils,sets]
proc run(executable: string,args: openArray[string]): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let resultCode = execCmdEx(command)
  doAssert resultCode.exitCode == 0,command & "\n" & resultCode.output
  resultCode.output
proc main() =
  if paramCount() notin 4..6: quit("usage: test_body_source BASELINE AUDITED CHECKER DIRECTORY [--reuse-fixtures] [--cases-only]",1)
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
    for mode in ["module","body-legacy","body-locals","body-locals-nonminimal","body-locals-big",
        "body-locals-legacy","body-locals-big-legacy","empty","full","full-legacy"]:
      let before = directory / (mode & "-baseline.meta")
      let after = directory / (mode & ".meta")
      let audit = directory / (mode & ".audit")
      if not reuse or not fileExists(before): discard run(baseline,[mode,before,"-"])
      if not reuse or not (fileExists(after) and fileExists(audit)): discard run(audited,[mode,after,audit])
      doAssert readFile(before) == readFile(after),"instrumentation changed matrix or assignment: " & mode
      let prior = parentDir(directory) / "module-context-tests" / (mode & ".meta")
      if fileExists(prior): doAssert readFile(after) == readFile(prior),"prior matrix or assignment changed: " & mode
      stdout.write mode & ": " & run(checker,[audit])
      stdout.flushFile()
      inc accepted
    let small = readFile(directory / "body-locals.meta").splitLines()
    let large = readFile(directory / "body-locals-big.meta").splitLines()
    doAssert small[0] == large[0] and small[1] == large[1],"large local counts changed the fixed-profile circuit"
  for mode in ["body-locals","body-locals-legacy"]:
    var original: seq[string]
    for line in lines(directory / (mode & ".audit")):
      if line.startsWith("Y ") and line.splitWhitespace().len == 3: original = @[line]
      elif original.len > 0: original.add line
    doAssert original.len > 20
    let caseDir = directory / (mode & "-cases")
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
    numberMutation("mode",0,1)
    numberMutation("body-count",0,2)
    fieldMutation("first-function",1)
    var inProgram = false
    var program = 0
    var kinds: HashSet[string]
    var helpers: HashSet[string]
    var renamed = false
    for i in 2..<original.len:
      let words = original[i].splitWhitespace()
      if words.len == 0: continue
      if words[0] in ["L","Z"]:
        inProgram = false
      elif words[0] == "P":
        inProgram = true
        inc program
        kinds.clear()
        helpers.clear()
        for j in 1..4: numberMutation("program-" & $program & "-" & $j,i,j)
      elif not inProgram:
        if words[0] == "A": numberMutation("array-" & $i,i,1)
        elif words[0] == "D": numberMutation("width-" & $i,i,1)
        elif words[0] == "T":
          for j in 2..<words.len: numberMutation("table-" & $i & "-" & $j,i,j)
        else: fieldMutation("field-" & $i,i)
      elif words[0] == "R" and words[1] notin kinds:
        kinds.incl words[1]
        for j in 1..9:
          if not (words[1] == "9" and j == 7): numberMutation("primitive-" & $program & "-" & words[1] & "-" & $j,i,j)
        let count = parseInt(words[8])+parseInt(words[9])
        for j in 0..<count: fieldMutation("operand-" & $program & "-" & words[1] & "-" & $j,i+j+1)
        if words[1] == "9" and not renamed:
          var candidate = original
          var header = words
          header[7] = $(parseInt(header[7])+1)
          candidate[i] = header.join(" ")
          save("valid-prior-index-renaming",candidate,true)
          renamed = true
      elif words[0] == "X" and words[1] notin helpers:
        helpers.incl words[1]
        for j in 1..6: numberMutation("helper-" & $program & "-" & words[1] & "-" & $j,i,j)
    save("truncated",original[0..<original.len-1])
    var trailing = original
    trailing.add "unexpected"
    save("trailing",trailing)
    writeFile(caseDir / "manifest.txt",manifest.join("\n") & "\n")
    let response = run(checker,[directory / (mode & ".audit"),"--body-cases",caseDir / "manifest.txt"])
    writeFile(caseDir / "results.log",response)
    for line in expected: doAssert line in response,line & "\n" & response
    var rejected = 0
    for line in expected:
      if line.startsWith("REJECT "): inc rejected
    forgeries += rejected
    echo mode & ": " & $(expected.len-rejected) & " valid controls accepted; " & $rejected & " hostile records rejected"
  echo "body source audit: " & $accepted & " fixtures; " & $forgeries & " hostile records rejected"
main()

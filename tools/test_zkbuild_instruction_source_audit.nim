## Complete instruction/controller matrix replay, layout coverage and hostile evidence.
import std/[os,osproc,strutils,sets]
proc run(executable: string,args: openArray[string]): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let resultCode = execCmdEx(command)
  doAssert resultCode.exitCode == 0,command & "\n" & resultCode.output
  resultCode.output
proc main() =
  if paramCount() notin 4..6: quit("usage: test_instruction_source_audit BASELINE AUDITED CHECKER DIRECTORY [--reuse-fixtures] [--cases-only]",1)
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
  var requests,allExpected: seq[string]
  if not casesOnly:
    var modes = @["module","body-legacy","body-locals","body-locals-legacy","empty","full"]
    for kind in ["control","branch","catch","catch-all","catch-ref","catch-all-ref","values","simd","bulk"]:
      modes.add "instructions-" & kind
      modes.add "instructions-" & kind & "-legacy"
    for mode in modes:
      let before = directory / (mode & "-baseline.meta")
      let after = directory / (mode & ".meta")
      let audit = directory / (mode & ".audit")
      if not reuse or not fileExists(before): discard run(baseline,[mode,before,"-"])
      if not reuse or not (fileExists(after) and fileExists(audit)): discard run(audited,[mode,after,audit])
      doAssert readFile(before) == readFile(after),"instrumentation changed matrix or assignment: " & mode
      let prior = parentDir(directory) / "body-source-tests" / (mode & ".meta")
      if fileExists(prior): doAssert readFile(after) == readFile(prior),"retained matrix changed: " & mode
      requests.add audit
      echo mode & ": matrix and witness match"
      inc accepted
  for mode in ["instructions-branch","instructions-catch-legacy"]:
    var original: seq[string]
    for line in lines(directory / (mode & ".audit")):
      if line.startsWith("K ") and line.splitWhitespace().len == 2: original = @[line]
      elif original.len > 0: original.add line
    doAssert original.len > 30
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
    var phase = 0
    var program = 0
    var insideProgram = false
    var primitives,helpers,headers: HashSet[string]
    for i in 0..<original.len:
      let words = original[i].splitWhitespace()
      if words.len == 0: continue
      if words[0] == "D" and words.len == 2 and phase == 0: phase = 1
      if words[0] == "I":
        phase = 2
        insideProgram = false
      if words[0] == "M":
        phase = 3
        insideProgram = false
      if words[0] == "P" and phase in [1,2]:
        insideProgram = true
        inc program
        for j in 1..4: numberMutation("program-" & $program & "-" & $j,i,j)
      elif insideProgram:
        # Exercise every primitive/helper shape once in each controller and decoder family.
        let key = $phase & ":" & words[0] & ":" & words[1]
        if words[0] == "R" and key notin primitives:
          primitives.incl key
          for j in 1..9:
            if not (words[1] == "9" and j == 7): numberMutation("primitive-" & $i & "-" & $j,i,j)
          for j in 0..<parseInt(words[8])+parseInt(words[9]): fieldMutation("operand-" & $i & "-" & $j,i+j+1)
        elif words[0] == "X" and key notin helpers:
          helpers.incl key
          for j in 1..6: numberMutation("helper-" & $i & "-" & $j,i,j)
      elif phase == 0:
        if words[0] in ["K","J","L","N"] and words[0] notin headers:
          headers.incl words[0]
          for j in 1..<words.len: numberMutation("catalog-" & $i & "-" & $j,i,j)
      elif phase in [1,2]:
        if words[0] in ["D","I","B","R","A","T"]:
          for j in 1..<words.len: numberMutation("header-" & $i & "-" & $j,i,j)
        elif words[0] notin ["U"]: fieldMutation("field-" & $i,i)
      elif phase == 3 and words[0] in ["M","A","S","R","P"] and words[0] notin headers:
        headers.incl words[0]
        for j in 1..<words.len: numberMutation("memory-" & $i & "-" & $j,i,j)
    save("truncated",original[0..<original.len-1])
    save("trailing",original & @["unexpected"])
    writeFile(caseDir / "manifest.txt",manifest.join("\n") & "\n")
    requests.add directory / (mode & ".audit") & "\t" & caseDir / "manifest.txt"
    allExpected.add expected
    for line in expected:
      if line.startsWith("REJECT "): inc forgeries
    echo mode & ": " & $expected.len & " evidence cases queued"
  let workers = parseInt(getEnv("ZKBUILD_AUDIT_JOBS","2"))
  doAssert workers in 1..8,"ZKBUILD_AUDIT_JOBS must be between 1 and 8"
  var expanded: seq[string]
  for request in requests:
    let fields = request.split('\t')
    if fields.len == 1:
      expanded.add request
    else:
      var parts = newSeq[seq[string]](workers)
      var index = 0
      for path in lines(fields[1]):
        if path.len != 0:
          parts[index mod workers].add path
          inc index
      for worker,paths in parts:
        let chunk = fields[1] & "." & $worker
        writeFile(chunk,paths.join("\n") & "\n")
        expanded.add fields[0] & "\t" & chunk
  var batches = newSeq[seq[string]](workers)
  for i,request in expanded: batches[i mod workers].add request
  var processes: seq[Process]
  var logs: seq[string]
  for worker,requests in batches:
    let batch = directory / ("batch-" & $worker & ".txt")
    let log = directory / ("batch-" & $worker & ".log")
    writeFile(batch,requests.join("\n") & "\n")
    logs.add log
    let command = quoteShell(checker) & " --batch " & quoteShell(batch) & " > " & quoteShell(log) & " 2>&1"
    processes.add startProcess(command,options = {poEvalCommand})
  var response: string
  for worker,process in processes:
    let code = process.waitForExit()
    process.close()
    let output = readFile(logs[worker])
    doAssert code == 0,"instruction audit worker " & $worker & " failed: " & output
    response.add output
  writeFile(directory / "batch-results.log",response)
  for line in allExpected: doAssert line in response,line & "\n" & response
  for line in response.splitLines():
    if line.startsWith("instruction source PASS:"): echo line
  echo "instruction source audit: " & $accepted & " fixtures; " & $forgeries & " hostile records rejected"
main()

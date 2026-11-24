## Source-linked validation-event matrix replay and hostile evidence.
import std/[os,osproc,strutils,sets]
proc run(executable: string,args: openArray[string]): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let resultCode = execCmdEx(command)
  doAssert resultCode.exitCode == 0,command & "\n" & resultCode.output
  resultCode.output
proc main() =
  if paramCount() notin 4..6: quit("usage: test_validation_event_audit BASELINE AUDITED CHECKER DIRECTORY [--reuse-fixtures] [--cases-only]",1)
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
  for mode in ["module","instructions-catch-legacy"]:
    var original: seq[string]
    for line in lines(directory / (mode & ".audit")):
      if line.startsWith("V ") and line.splitWhitespace().len == 3: original = @[line]
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
    proc header(pos: int,label: string) =
      let words = original[pos].splitWhitespace()
      for j in 1..<words.len: numberMutation(label & "-" & $pos & "-" & $j,pos,j)
    proc rows(pos: var int,label: string,change: bool) =
      let count = parseInt(original[pos].splitWhitespace()[1])
      if change: header(pos,label & "-rows")
      inc pos
      for row in 0..<count:
        let width = parseInt(original[pos].splitWhitespace()[1])
        if change and row in [0,count-1]:
          header(pos,label & "-width")
          for j in 0..<width: fieldMutation(label & "-field-" & $(pos+j+1),pos+j+1)
        pos += 1+width
    proc primitive(pos: var int,label: string,change: bool) =
      let words = original[pos].splitWhitespace()
      if change:
        for j in 1..9:
          if not (words[1] == "9" and j == 7): numberMutation(label & "-" & $pos & "-" & $j,pos,j)
        for j in 0..<parseInt(words[8])+parseInt(words[9]): fieldMutation(label & "-arg-" & $(pos+j+1),pos+j+1)
      pos += 1+parseInt(words[8])+parseInt(words[9])
    proc operation(pos: var int,label: string,change: bool) =
      let reused = original[pos].splitWhitespace()[1] == "1"
      if change: header(pos,label & "-use")
      inc pos
      primitive(pos,label,change)
      if reused: primitive(pos,label & "-prior",change)
    let counts = original[0].splitWhitespace()
    header(0,"catalog-counts")
    var pos = 1
    for i in 0..<parseInt(counts[1]):
      let change = i == 0
      if change: header(pos,"static-id")
      inc pos
      let n = parseInt(original[pos].splitWhitespace()[6])
      if change: header(pos,"static-span")
      inc pos
      rows(pos,"static",change)
      operation(pos,"opcode-range",change)
      operation(pos,"type-range",change)
      var nodeKinds: HashSet[string]
      for _ in 0..<n:
        let kind = original[pos].splitWhitespace()[1]
        if change and kind notin nodeKinds:
          header(pos,"node")
          nodeKinds.incl kind
        inc pos
    for i in 0..<parseInt(counts[2]):
      let change = i == 0
      if change: header(pos,"admission-id")
      inc pos
      let words = original[pos].splitWhitespace()
      let columns = parseInt(words[6]); let n = parseInt(words[7])
      if change: header(pos,"admission-span")
      inc pos
      if change:
        for j in 0..columns: fieldMutation("admission-field-" & $(pos+j),pos+j)
      pos += 1+columns
      operation(pos,"admission-range",change)
      if change: header(pos,"admission-node")
      pos += n
    let stages = parseInt(original[pos].splitWhitespace()[1])
    header(pos,"stage-count")
    inc pos
    fieldMutation("first-function",pos)
    inc pos
    rows(pos,"events",true)
    for stage in 0..<stages:
      header(pos,"stage-kind")
      inc pos
      # Only control uses this field; the others are canonical empty values.
      fieldMutation("stage-first-" & $stage,pos)
      inc pos
      for part in 0..<4: rows(pos,"stage-" & $stage & "-" & $part,true)
      let words = original[pos].splitWhitespace()
      let operations = parseInt(words[3]); let helpers = parseInt(words[4])
      header(pos,"program")
      inc pos
      var kinds: HashSet[string]
      for _ in 0..<operations:
        let kind = original[pos+1].splitWhitespace()[1]
        operation(pos,"primitive",kind notin kinds)
        kinds.incl kind
      var kinds2: HashSet[string]
      for _ in 0..<helpers:
        let kind = original[pos].splitWhitespace()[1]
        if kind notin kinds2: header(pos,"helper")
        kinds2.incl kind
        inc pos
    var headers: HashSet[string]
    for i in pos..<original.len:
      let words = original[i].splitWhitespace()
      if words[0] in ["M","A","S","R","P"] and words[0] notin headers:
        header(i,"memory")
        headers.incl words[0]
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
    doAssert code == 0,"validation audit worker " & $worker & " failed: " & output
    response.add output
  writeFile(directory / "batch-results.log",response)
  for line in allExpected: doAssert line in response,line & "\n" & response
  for line in response.splitLines():
    if line.startsWith("validation events PASS:"): echo line
  echo "validation event audit: " & $accepted & " fixtures; " & $forgeries & " hostile records rejected"
main()

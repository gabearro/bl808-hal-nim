## Check branch-list semantics against complete Nim-emitted circuit audits.
import std/[os, osproc, strutils]

proc main() =
  doAssert paramCount() in [3, 4],
    "usage: test_branch_semantics CHECKER RETAINED_DIRECTORY BINDING_DIRECTORY [RESULTS_LOG]"
  let checker = absolutePath(paramStr(1))
  let retained = absolutePath(paramStr(2))
  let fixtures = absolutePath(paramStr(3))
  let base = parentDir(retained)
  var requests: seq[string]
  var modes = @["module"]
  for kind in ["local", "global", "table", "direct", "indirect", "tail-direct", "tail-indirect", "multi"]:
    modes.add "typing-" & kind
  for mode in modes:
    let paths = [base / "dynamic-typing-tests" / (mode & ".audit"),
      base / "structured-control-tests" / (mode & ".control"), retained / (mode & ".context")]
    for path in paths:
      doAssert fileExists(path), "missing retained certificate: " & path
    requests.add paths.join("\t")
  for name in ["memory", "bulk", "reference", "lanes"]:
    let path = fixtures / (name & ".audit")
    doAssert fileExists(path), "missing complete fixture: " & path
    requests.add path
  for name in ["instructions-branch", "instructions-branch-legacy", "instructions-control", "instructions-control-legacy"]:
    let paths = [base / "validation-event-tests" / (name & ".audit"),
      base / "structured-control-tests" / (name & ".control"), retained / (name & ".context")]
    for path in paths:
      doAssert fileExists(path), "missing branch/control fixture: " & path
    requests.add paths.join("\t")
  let output = base / "branch-semantics-tests"
  createDir(output)
  let manifest = output / "batch.txt"
  writeFile(manifest, requests.join("\n") & "\n")
  var resultText: string
  if paramCount() == 4:
    resultText = readFile(paramStr(4))
  else:
    let run = execCmdEx(quoteShell(checker) & " --mutations --batch " & quoteShell(manifest))
    doAssert run.exitCode == 0, run.output
    resultText = run.output
  writeFile(output / "results.log", resultText)
  var accepted, rejected, rows, banks, nodes, withCalls, activeLists = 0
  var typed, typedRows, typedRejected = 0
  for line in resultText.splitLines:
    if line.startsWith("branch typing certificate PASS:"):
      let fields = line.splitWhitespace()
      let rowCount = parseInt(fields[4].split('=')[1])
      let mutations = parseInt(fields[5].split('=')[1])
      doAssert rowCount > 0 and mutations == 251*rowCount
      inc typed
      typedRows += rowCount
      typedRejected += mutations
    if line.startsWith("branch matrix PASS:"):
      let fields = line.splitWhitespace()
      let rowCount = parseInt(fields[3].split('=')[1])
      let bankCount = parseInt(fields[4].split('=')[1])
      let nodeCount = parseInt(fields[5].split('=')[1])
      let mutations = parseInt(fields[6].split('=')[1])
      # Programs without br_table legitimately have no list nodes or banks.
      doAssert rowCount > 0 and bankCount >= 0 and nodeCount >= 0
      doAssert mutations == 47*rowCount + 9*bankCount + 19*nodeCount
      if fields[7] == "calls=true": inc withCalls
      if nodeCount > 0: inc activeLists
      inc accepted
      rows += rowCount
      banks += bankCount
      nodes += nodeCount
      rejected += mutations
  doAssert accepted == requests.len and withCalls == 13 and activeLists == 3
  doAssert typed == accepted and typedRows == rows
  echo "branch matrix: PASS (", accepted, " complete modules; ", rejected,
    " mutations rejected; ", rows, " event rows; ", banks, " bank entries; ", nodes,
    " list nodes; ", withCalls, " combined call certificates)"
  echo "branch typing certificate: PASS (", typed, " complete modules; ",
    typedRejected, " mutations rejected; ", typedRows, " event rows)"

main()

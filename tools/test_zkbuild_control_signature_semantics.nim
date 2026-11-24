## Check control-signature lookup semantics against complete Nim-emitted circuit audits.
import std/[os, osproc, strutils]

proc main() =
  doAssert paramCount() in [3, 4],
    "usage: test_control_signature_semantics CHECKER RETAINED_DIRECTORY BINDING_DIRECTORY [RESULTS_LOG]"
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
  let output = base / "control-signature-semantics-tests"
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
  var accepted, rejected, rows, contexts = 0
  for line in resultText.splitLines:
    if line.startsWith("control signature certificate PASS:"):
      let fields = line.splitWhitespace()
      let rowCount = parseInt(fields[4].split('=')[1])
      let mutations = parseInt(fields[5].split('=')[1])
      doAssert rowCount > 0 and mutations == 48*rowCount
      inc accepted
      rows += rowCount
      rejected += mutations
    if line.startsWith("runtime context PASS:"): inc contexts
  doAssert accepted == requests.len and contexts == requests.len
  echo "control signature certificate: PASS (", accepted, " complete modules; ",
    rejected, " mutations rejected; ", rows, " event rows)"

main()

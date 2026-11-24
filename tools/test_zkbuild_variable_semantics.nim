## Check the variable-stage gate certificate against complete retained audits.
import std/[os, osproc, strutils]

proc main() =
  doAssert paramCount() in [3,4], "usage: test_variable_semantics CHECKER RETAINED_DIRECTORY BINDING_DIRECTORY [RESULTS_LOG]"
  let checker = absolutePath(paramStr(1))
  let retained = absolutePath(paramStr(2))
  let fixtures = absolutePath(paramStr(3))
  var requests: seq[string]
  var modes = @["module"]
  for kind in ["local", "global", "table", "direct", "indirect", "tail-direct", "tail-indirect", "multi"]:
    modes.add "typing-" & kind
  for mode in modes:
    let base = parentDir(retained)
    let source = base / "dynamic-typing-tests" / (mode & ".audit")
    let control = base / "structured-control-tests" / (mode & ".control")
    let context = retained / (mode & ".context")
    for path in [source, control, context]:
      doAssert fileExists(path), "missing retained certificate: " & path
    requests.add [source, control, context].join("\t")
  for name in ["memory", "bulk", "reference", "lanes"]:
    let path = fixtures / (name & ".audit")
    doAssert fileExists(path), "missing complete fixture: " & path
    requests.add path
  let output = parentDir(fixtures) / "variable-semantics-tests"
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
  var accepted, rejected, rows = 0
  for line in resultText.splitLines:
    if line.startsWith("variable matrix PASS:"):
      let fields = line.splitWhitespace()
      let count = parseInt(fields[3].split('=')[1])
      let mutations = parseInt(fields[4].split('=')[1])
      doAssert count > 0 and mutations == 106*count
      inc accepted
      rows += count
      rejected += mutations
  doAssert accepted == requests.len
  echo "variable matrix: PASS (", accepted, " complete modules; ", rejected, " mutations rejected; ", rows, " event rows)"

main()

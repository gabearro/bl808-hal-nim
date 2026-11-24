## Additional complete context fixtures: full source -> all audit layers.
import std/[os,osproc,strutils]
proc run(executable: string,args: openArray[string]): string =
  var cmd = quoteShell(executable)
  for arg in args: cmd.add " " & quoteShell(arg)
  let outcome = execCmdEx(cmd)
  doAssert outcome.exitCode == 0,cmd & "\n" & outcome.output
  outcome.output
proc main() =
  doAssert paramCount() == 4,"usage: context_binding BASELINE AUDITED CHECKER DIRECTORY"
  let baseline = absolutePath(paramStr(1))
  let audited = absolutePath(paramStr(2))
  let checker = absolutePath(paramStr(3))
  let directory = absolutePath(paramStr(4))
  createDir(directory)
  for mode in ["memory","bulk","reference","lanes"]:
    let stem = directory / mode
    discard run(baseline,["context-" & mode,stem & "-baseline.meta","-"])
    discard run(audited,["context-" & mode,stem & ".meta",stem & ".audit"])
    doAssert readFile(stem & "-baseline.meta") == readFile(stem & ".meta"),"context matrix changed: " & mode
    stdout.write run(checker,[stem & ".audit"])
    echo mode & ": source and complete context matrix PASS"
main()

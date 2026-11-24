import VariableTyping

open ZkBuild.VariableTyping

def main (args : List String) : IO UInt32 := do
  match args with
  | [path] =>
    let handle ← IO.FS.Handle.mk path IO.FS.Mode.write
    handle.putStrLn "ZKVARIABLE1 1024 7 45"
    for code in List.range 1024 do
      for declared in List.range 7 do
        match signature code declared with
        | none => handle.putStrLn s!"{code} {declared} {environment code} 0 0 0 0 0 0 0"
        | some rule =>
          let out := rule.output.getD 0
          let count := if rule.output.isSome then 1 else 0
          handle.putStrLn s!"{code} {declared} {environment code} 1 {rule.inputs.length} {count} {out} {rule.inputs[0]?.getD 0} {rule.inputs[1]?.getD 0} {rule.inputs[2]?.getD 0}"
    return 0
  | _ =>
    IO.eprintln "usage: export_variable_typing OUTPUT"
    return 1

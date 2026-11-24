import StaticTyping

open ZkBuild.StaticTyping

def main (args : List String) : IO UInt32 := do
  match args with
  | [path] =>
    let handle ← IO.FS.Handle.mk path IO.FS.Mode.write
    handle.putStrLn "ZKSTATIC1 2048 245"
    for code in List.range 2048 do
      match signature code with
      | none => handle.putStrLn s!"{code} 0 0 0 0 0 0 0 0"
      | some rule =>
        let out := rule.output.getD 0
        let count := if rule.output.isSome then 1 else 0
        handle.putStrLn s!"{code} 1 {rule.inputs.length} {count} {out} {rule.clears.toNat} {rule.inputs[0]?.getD 0} {rule.inputs[1]?.getD 0} {rule.inputs[2]?.getD 0}"
    return 0
  | _ =>
    IO.eprintln "usage: export_static_typing OUTPUT"
    return 1

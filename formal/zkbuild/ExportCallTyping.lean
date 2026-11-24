import CallEvents

open ZkBuild.CallEvents

def main (args : List String) : IO UInt32 := do
  match args with
  | [path] =>
    let handle ← IO.FS.Handle.mk path IO.FS.Mode.write
    handle.putStrLn "ZKCALL1 6048"
    for code in [0x10, 0x11, 0x12, 0x13] do
      for p in List.range 9 do
        for r in List.range 6 do
          for seed in List.range 7 do
            let params := (List.range p).map fun i => (i+seed)%7
            let results := (List.range r).map fun i => (3*i+seed+1)%7
            for mismatch in [false, true] do
              let current := if mismatch then (if results = [] then [0] else []) else results
              for tableTag in [5, 6] do
                let start := s!"{code} {p} {r} {seed} {mismatch.toNat} {tableTag}"
                match callSignature code params results current tableTag with
                | none => handle.putStrLn s!"{start} 0 0 0"
                | some (inputs, outputs) =>
                  let rest := String.intercalate " " ((inputs ++ outputs).map toString)
                  handle.putStrLn s!"{start} 1 {inputs.length} {outputs.length} {rest}"
    return 0
  | _ =>
    IO.eprintln "usage: export_call_typing OUTPUT"
    return 1

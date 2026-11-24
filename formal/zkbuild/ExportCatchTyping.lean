import CatchTyping

open ZkBuild.CatchTyping

def targetVectors : List (List Nat) := [[], [0], [1], [6], [0, 1], [0, 1, 6]]

def main (args : List String) : IO UInt32 := do
  match args with
  | [path] =>
    let handle ← IO.FS.Handle.mk path IO.FS.Mode.write
    handle.putStrLn "ZKCATCH1 7560"
    for kind in List.range 5 do
      for count in List.range 4 do
        for seed in List.range 7 do
          let params := (List.range count).map (fun i => (seed+i) % 7)
          for label in List.range 6 do
            for depth in List.range 3 do
              for state in List.range 3 do
                let tag := if state = 0 then none else some (params, if state = 1 then [] else [0])
                let ok := check kind tag [targetVectors[label]?.getD [], []] depth
                handle.putStrLn s!"{kind} {count} {seed} {label} {depth} {state} {ok.toNat}"
    return 0
  | _ => IO.eprintln "usage: export_catch_typing OUTPUT"; return 1

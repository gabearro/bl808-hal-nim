import BulkContext

open ZkBuild.BulkContext

def configurations : List (List Nat) := [[], [5], [6], [5, 6]]

def main (args : List String) : IO UInt32 := do
  match args with
  | [path, orders] =>
    let handle ← IO.FS.Handle.mk path IO.FS.Mode.write
    handle.putStrLn "ZKBULK1 36288"
    for code in [264, 265, 266, 267, 268, 269, 270] do
      for memory in List.range 2 do
        for has in [false, true] do
          for declared in List.range 3 do
            for data in List.range 3 do
              for ei in List.range 4 do
                for ti in List.range 4 do
                  for p in List.range 3 do
                    for s in List.range 3 do
                      let accepted := check code memory has declared data
                        (configurations[ei]?.getD []) (configurations[ti]?.getD []) p s
                      handle.putStrLn s!"{code} {memory} {has.toNat} {declared} {data} {ei} {ti} {p} {s} {accepted.toNat}"
    let sections ← IO.FS.Handle.mk orders IO.FS.Mode.write
    sections.putStrLn "ZKSECTIONS1 256"
    for id in List.range 256 do sections.putStrLn s!"{id} {sectionOrder id}"
    return 0
  | _ =>
    IO.eprintln "usage: export_bulk_context OUTPUT SECTIONS"
    return 1

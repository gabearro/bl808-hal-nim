import ReferenceContext

open ZkBuild.ReferenceContext

def main (args : List String) : IO UInt32 := do
  match args with
  | [path] =>
    let handle ← IO.FS.Handle.mk path IO.FS.Mode.write
    handle.putStrLn "ZKREF1 2560"
    for code in [1, 210, 466, 65535] do
      for functions in List.range 5 do
        for mask in List.range 16 do
          let declared := (List.range 4).filter (fun i => (mask / 2^i) % 2 = 1)
          for primary in List.range 8 do
            let accepted := check code primary functions declared
            handle.putStrLn s!"{code} {functions} {mask} {primary} {accepted.toNat}"
    return 0
  | _ =>
    IO.eprintln "usage: export_reference_context OUTPUT"
    return 1

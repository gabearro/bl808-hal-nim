import ThrowEvents

open ZkBuild.ThrowEvents ZkBuild.StaticEvents

def main (args : List String) : IO UInt32 := do
  match args with
  | [path] =>
    let handle ← IO.FS.Handle.mk path IO.FS.Mode.write
    handle.putStrLn "ZKTHROW1 16128"
    for code in [8, 10] do
      for count in List.range 3 do
        for seed in List.range 7 do
          let params := (List.range count).map (fun i => (i + seed) % 7)
          let expected := if code = 10 then [6] else params.reverse
          for first in List.range 8 do
            for second in List.range 8 do
              for pattern in List.range 6 do
                let tokens := match pattern with
                  | 0 => [.clear]
                  | 1 => [.pop first, .clear]
                  | 2 => [.pop first, .pop second, .clear]
                  | 3 => [.clear, .pop first]
                  | 4 => [.push first, .clear]
                  | _ => [.pop first]
                let ok := run expected false tokens
                handle.putStrLn s!"{code} {count} {seed} {first} {second} {pattern} {ok.toNat}"
    return 0
  | _ => IO.eprintln "usage: export_throw_events OUTPUT"; return 1

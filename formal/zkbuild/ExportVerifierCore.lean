import VerifierCore

open ZkBuild.VerifierCore

def main (args : List String) : IO Unit := do
  let [destination] := args | throw (IO.userError "usage: export_verifier_core OUTPUT")
  let output ← IO.FS.Handle.mk destination .write
  output.putStrLn "ZKVERIFY1 33"
  for count in [:33] do
    output.putStrLn s!"CASE {count}"
    for (coefficient, input) in schedule count do
      output.putStrLn s!"TERM {coefficient} {input}"
    for pair in pairingSchedule do
      output.putStrLn s!"PAIR {pair.sign} {pair.left} {pair.right}"
    output.putStrLn "END"

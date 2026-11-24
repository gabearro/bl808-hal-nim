import RowCompleteness

open ZkBuild.ByteStream ZkBuild.RowCompleteness

/- Test artifact generated from the same reference function whose refinement
   theorem is checked by Lean. The 40 auxiliary wires come from the symbolic
   witness construction proved in canonical_row_witness_holds. This executable
   is not part of the device or prover runtime. -/
def main (args : List String) : IO Unit := do
  let [path] := args | throw (IO.userError "usage: export_rows OUTPUT")
  let out ← IO.FS.Handle.mk path .write
  for phase in List.finRange 8 do
    for height in List.finRange 9 do
      for byte in List.finRange 256 do
        let suffix := match referenceRow phase.val height.val byte.val with
          | none => "-1 -1"
          | some (nextPhase, nextHeight) => s!"{nextPhase} {nextHeight}"
        let witness := canonicalRowWitness phase height byte
        if witness.length != 66 then throw (IO.userError "invalid symbolic row witness")
        let auxiliary := String.intercalate " " ((witness.drop 26).map toString)
        out.putStrLn s!"{phase.val} {height.val} {byte.val} {suffix} {auxiliary}"

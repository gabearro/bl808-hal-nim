import FftSchedule

open ZkBuild.FftLayout

def emitPermutation (out : IO.FS.Handle) (bits : Nat) : IO Unit := do
  let mut current := 0
  for i in List.finRange (2^bits) do
    if i.val > 0 then
      current := ZkBuild.FftCounter.counterTransition bits current
      out.putStrLn s!"P {2^bits} 0 {i.val} {current} 0"

def emitCounterCases (out : IO.FS.Handle) : IO Unit := do
  out.putStrLn "COUNTERS"
  for bits in [:33] do
    let n := 2^bits
    -- Every possible length of the leading-one run, including wraparound.
    for run in [:bits+1] do
      let value := n - (n >>> run)
      out.putStrLn s!"C {bits} {value} {ZkBuild.FftCounter.counterTransition bits value}"
    out.putStrLn s!"C {bits} {n-1} {ZkBuild.FftCounter.counterTransition bits (n-1)}"
    -- Deterministic interior states, independent of array allocation.
    let mut seed := 0x6a09e667
    for _ in [:8] do
      seed := (seed*1664525+1013904223)%n
      out.putStrLn s!"C {bits} {seed} {ZkBuild.FftCounter.counterTransition bits seed}"
  out.putStrLn "ENDCOUNTERS"

def emitStages (out : IO.FS.Handle) (bits : Nat) (inverse : Bool) : IO Unit := do
  let n := 2^bits
  let widths := if inverse then ZkBuild.FftSchedule.backwardWidths n else ZkBuild.FftSchedule.forwardWidths n 2
  for width in widths do
    for start in ZkBuild.FftSchedule.blockStarts n width 0 do
      for offset in List.range (width/2) do
        out.putStrLn s!"{if inverse then "I" else "F"} {n} {width} {start+offset} {start+offset+width/2} {offset}"

def emitWidthCases (out : IO.FS.Handle) : IO Unit := do
  out.putStrLn "WIDTHS"
  for bits in [:33] do
    for inverse in [false, true] do
      let widths := if inverse then ZkBuild.FftSchedule.backwardWidths (2^bits)
        else ZkBuild.FftSchedule.forwardWidths (2^bits) 2
      let values := String.intercalate " " (widths.map toString)
      out.putStrLn s!"W {bits} {if inverse then 1 else 0} {widths.length} {values}"
  out.putStrLn "ENDWIDTHS"

def main (args : List String) : IO Unit := do
  let [path] := args | throw (IO.userError "usage: export_fft OUTPUT")
  let out ← IO.FS.Handle.mk path .write
  out.putStrLn "ZKFFT4 15 33"
  for depth in [:33] do
    out.putStrLn s!"R {depth} {ZkBuild.ScalarRoots.rootResidue depth}"
  emitCounterCases out
  emitWidthCases out
  for bits in [:15] do
    out.putStrLn s!"T {2^bits} 0"
    emitPermutation out bits
    emitStages out bits false
    out.putStrLn "E"
    out.putStrLn s!"T {2^bits} 1"
    emitStages out bits true
    emitPermutation out bits
    out.putStrLn "E"

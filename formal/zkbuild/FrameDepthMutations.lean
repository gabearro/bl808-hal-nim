import FrameDepthCheck
set_option autoImplicit false
namespace ZkBuild.FrameDepthMutations
open CircuitShape DeclarationMatrix

def candidates (matrix : Shape) (r : FrameDepthCheck.Record) : List FrameDepthCheck.Record :=
  let bad : Linear := [(matrix.wires+1,1)]
  [{r with input := bad},
   {r with branch := {r.branch with value := bad}},
   {r with branch := {r.branch with low := bad}},
   {r with branch := {r.branch with high := bad}},
   {r with branch := {r.branch with lowWidth := 31}},
   {r with branch := {r.branch with highWidth := 31}},
   {r with branch := {r.branch with range := {r.branch.range with call := {r.branch.range.call with width := 255}}}},
   {r with handler := {r.handler with value := bad}},
   {r with handler := {r.handler with low := bad}},
   {r with handler := {r.handler with high := bad}},
   {r with handler := {r.handler with lowWidth := 31}},
   {r with handler := {r.handler with highWidth := 31}},
   {r with handler := {r.handler with range := {r.handler.range with call := {r.handler.range.call with width := 255}}}},
   {r with input := bad++r.handler.high, branch := {r.branch with low := bad}},
   {r with input := r.branch.low++bad, handler := {r.handler with high := bad}}]

def run (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (r : StructuredMatrix.Record) : IO Nat := do
  let mut rejected := 0
  for i in List.range (StructuredMatrix.stage r 3).rows.length do
    let changes := candidates matrix (FrameDepthCheck.record splits tables r i)
    if changes.length != 15 then throw (IO.userError "frame depth mutation coverage drift")
    for j in List.range changes.length do
      if FrameDepthCheck.check matrix (changes.getD j default) then
        throw (IO.userError s!"frame depth mutation accepted: row={i} change={j}")
      rejected := rejected+1
  pure rejected
end ZkBuild.FrameDepthMutations

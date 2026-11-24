import RuntimeContextCli
import EventSemanticMutations
import FunctionTraceSound
import InstructionSemanticMutations
set_option autoImplicit false
open ZkBuild ZkBuild.CircuitShape ZkBuild.GadgetShape

def controlCandidates (matrix : Shape) (r : ControlRowCheck.Record) : List ControlRowCheck.Record :=
  let foreign : Linear := [(matrix.wires+1,1)]
  [1,2,3,5,6,7].map (fun i => {r with row := r.row.set i foreign}) ++
  [0,2,3,4,5,6,8,10].map (fun i => {r with tags := r.tags.set i foreign}) ++
  (List.range 4).map (fun i => {r with read := r.read.set i foreign}) ++
  (List.range 4).map (fun i => {r with write := r.write.set i foreign}) ++
  [{r with input := [foreign]},{r with beforeDepth := foreign},{r with beforeHeight := foreign},
   {r with empty := foreign},{r with reciprocal := foreign},{r with pushed := foreign},
   {r with cleared := foreign},{r with opened := foreign},{r with index := foreign},
   {r with afterOpen := foreign},{r with afterIndex := foreign},
   {r with depthRange := {r.depthRange with call := {r.depthRange.call with width := 255}}},
   {r with first := matrix.gates.size+1},{r with last := matrix.gates.size+1},
   {r with row := []},{r with tags := []},{r with read := []},{r with write := []}]

def main (args : List String) : IO Unit := do
  let testing := args.head? == some "--mutations"
  let args := if testing then args.drop 1 else args
  RuntimeContextCli.runWithStatics args fun matrix statics events => do
    if !InstructionSemanticSound.check matrix statics events then
      throw (IO.userError "combined operand/control/instruction certificate rejected")
    let operand := ValidationEventCheck.stage events 1
    let control := ValidationEventCheck.stage events 2
    let mut rejected := 0
    if testing then
      for i in [:operand.rows.length] do
        for (bad,j) in (candidates matrix (OperandRowCheck.record operand i)).zipIdx do
          if OperandRowCheck.check matrix bad then
            throw (IO.userError s!"operand mutation accepted at row {i}, mutation {j}")
          rejected := rejected+1
      for i in [:control.rows.length] do
        for (bad,j) in (controlCandidates matrix (ControlRowCheck.record control i)).zipIdx do
          if ControlRowCheck.check matrix bad then
            throw (IO.userError s!"control mutation accepted at row {i}, mutation {j}")
          rejected := rejected+1
      let instruction := ValidationEventCheck.stage events 3
      for i in [:instruction.rows.length] do
        for (bad,j) in (InstructionSemanticMutations.candidates matrix (InstructionCertificate.record statics instruction i)).zipIdx do
          if InstructionRowCheck.check matrix bad then
            throw (IO.userError s!"instruction mutation accepted at row {i}, mutation {j}")
          rejected := rejected+1
    IO.println s!"event semantics PASS: rows={operand.rows.length} rejected={rejected}"
    return true
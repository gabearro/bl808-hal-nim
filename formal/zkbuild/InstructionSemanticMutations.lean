import InstructionSemanticSource
set_option autoImplicit false
namespace ZkBuild.InstructionSemanticMutations
open CircuitShape

def candidates (matrix : Shape) (r : InstructionRowCheck.Record) : List InstructionRowCheck.Record :=
  let foreign : Linear := [(matrix.wires+1,1)]
  [4,8,9].map (fun i => {r with row := r.row.set i foreign}) ++
  (List.range 11).map (fun i => {r with tags := r.tags.set i foreign}) ++
  (List.range 7).map (fun i => {r with before := r.before.set i foreign}) ++
  (List.range 18).map (fun i => {r with after := r.after.set i foreign}) ++
  (List.range 7).map (fun i => {r with rule := {r.rule with outputs := r.rule.outputs.set i foreign}}) ++
  (List.range 3).map (fun i => {r with rule := {r.rule with inputs := r.rule.inputs.set i foreign}}) ++
  [{r with pcRange := {r.pcRange with call := {r.pcRange.call with width := 255}}},
   {r with rule := {r.rule with opcodeRange := {r.rule.opcodeRange with call := {r.rule.opcodeRange.call with width := 255}}}},
   {r with first := matrix.gates.size+1},{r with middle := matrix.gates.size+1},
   {r with tailFirst := matrix.gates.size+1},{r with last := matrix.gates.size+1},
   {r with row := []},{r with tags := []},{r with before := []},{r with after := []}]

example (matrix : Shape) (r : InstructionRowCheck.Record) : (candidates matrix r).length = 59 := by
  simp [candidates]
end ZkBuild.InstructionSemanticMutations

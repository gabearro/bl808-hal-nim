import ValidationParametric
set_option autoImplicit false
set_option synthInstance.maxSize 1024
namespace ZkBuild.ValidationEventCheck
open CircuitShape DeclarationMatrix SourceProgram ValidationEventMatrix

def stageRows (r : ValidationEventMatrix.Record) (s : Stage) : List Fields :=
  r.rows.map fun row => row.take (if s.kind = 1 then 7 else if s.kind = 2 then 8 else 10)
def stage (r : ValidationEventMatrix.Record) (kind : Nat) : Stage := (r.stages.find? (fun s => s.kind == kind)).getD default

def links (r : ValidationEventMatrix.Record) (source : InstructionStreamMatrix.Record) : Bool :=
  decide (r.stages.map (·.kind) = [0,1,2,3,4] ∧ r.rows.length > 0 ∧
    r.rows.all (fun row => row.length == 13) = true ∧
    ModuleProgram.sameInputs [r.firstFunction] [source.firstFunction] ∧
    normalized source.events = normalized (r.rows.map (fun row => [f row 0,f row 1,f row 9,f row 8,f row 10,f row 11,f row 12])) ∧
    r.stages.all (fun s => decide (normalized s.rows = normalized (stageRows r s) ∧ (s.kind = 2 ∨ s.firstFunction = []))) = true ∧
    r.stages.all (fun s => decide (if s.kind = 0 then s.flags = [] ∧ s.inputs = [] ∧ s.outputs = []
      else s.flags.length = r.rows.length ∧ s.flags.all (fun row => row.length == 11) = true)) = true ∧
    (stage r 1).inputs = [] ∧ (stage r 1).outputs.length = r.rows.length ∧
    normalized (stage r 2).inputs = normalized (stage r 1).outputs ∧
    ModuleProgram.sameInputs [(stage r 2).firstFunction] [r.firstFunction] ∧
    ([2,3,4] : List Nat).all (fun k => decide (normalized (stage r k).flags = normalized (stage r 1).flags)) = true ∧
    (stage r 2).outputs.length = 2*r.rows.length ∧
    (stage r 3).inputs = [] ∧ (stage r 3).outputs = [] ∧
    normalized (stage r 4).inputs = normalized (r.rows.map (fun row => [f row 10])) ∧ (stage r 4).outputs = [])

def memory (matrix : Shape) (m : MemoryEmbedded.Record) (expected : List Fields) (width : Nat) : Bool :=
  decide (m.addressBits = 64 ∧ m.valueBits = width ∧ m.inputs.length = expected.length ∧
    m.inputs.map (fun r => BinaryReadMemory.normalizedPayload r.fields) =
      (List.range expected.length).map (fun i => let row := expected.getD i []
        BinaryReadMemory.normalizedPayload ⟨f row 0,f row 1,f row 2,f row 3,n i⟩)) &&
  MemoryEmbedded.check matrix m

def replay (matrix : Shape) (statics : StaticCatalog) (admitted : LookupCatalog) (s : Stage) : Eval Unit := do
  if s.kind = 0 then
    let _ ← replayAdmission matrix admitted s
  else if s.kind = 1 then
    let (flags,accesses) ← replayOperands matrix s
    require (decide (normalized flags = normalized s.flags ∧ normalized accesses = normalized s.outputs)) "operand projection output rejected"
  else if s.kind = 2 then
    let accesses ← replayControl matrix s
    require (decide (normalized accesses = normalized s.outputs)) "control projection output rejected"
  else if s.kind = 3 then replayInstructions matrix statics s
  else if s.kind = 4 then ValidationParametric.replay matrix s
  else throw "unknown validation stage"

def checkStage (matrix : Shape) (statics : StaticCatalog) (admitted : LookupCatalog) (s : Stage) : Bool :=
  match (replay matrix statics admitted s).run (init s.program) with
  | .error _ => false
  | .ok (_,state) => decide (finished s.program state) && auditState matrix [] [] state

def admissionRecord (admitted : LookupCatalog) (r : ValidationEventMatrix.Record) (i : Nat) : Option (Nat × LookupEmbedded.Record) :=
  let helper := (stage r 0).program.blocks.getD i default
  admitted.find? (fun pair => pair.1 == helper.index)

-- Expose the admission conclusion directly for every canonical event row.
-- These are the same equalities already consumed by replayAdmission.
def admissionBinding (matrix : Shape) (admitted : LookupCatalog) (r : ValidationEventMatrix.Record) (i : Nat) : Bool :=
  match admissionRecord admitted r i with
  | none => false
  | some (_,rule) =>
    decide (ModuleProgram.sameInputs [f (rowAt r.rows i) 8] [rule.input]) &&
    MemoryEvidence.checkSpan matrix rule.lastGate (rule.lastGate+1) [GadgetShape.eqGate (rule.outputs.getD 0 []) o]

def admissionBindings (matrix : Shape) (admitted : LookupCatalog) (r : ValidationEventMatrix.Record) : Bool :=
  (List.range r.rows.length).all (admissionBinding matrix admitted r)

def staticRecord (statics : StaticCatalog) (r : ValidationEventMatrix.Record) (i : Nat) : Option (Nat × StaticLookupEmbedded.Record) :=
  let helper := (stage r 3).program.blocks.getD i default
  statics.find? (fun pair => pair.1 == helper.index)

def staticBinding (statics : StaticCatalog) (r : ValidationEventMatrix.Record) (i : Nat) : Bool :=
  match staticRecord statics r i with
  | none => false
  | some (_,rule) => decide (ModuleProgram.sameInputs [f (rowAt r.rows i) 8,f (rowAt r.rows i) 4]
      [rule.inputs.getD 0 [],rule.inputs.getD 2 []])

def staticBindings (statics : StaticCatalog) (r : ValidationEventMatrix.Record) : Bool :=
  (List.range r.rows.length).all (staticBinding statics r)

def check (matrix : Shape) (statics : StaticCatalog) (admitted : LookupCatalog) (source : InstructionStreamMatrix.Record) (r : ValidationEventMatrix.Record) : Bool :=
  links r source && statics.all (fun (_,r) => StaticLookupEmbedded.check matrix r) &&
  admitted.all (fun (_,r) => LookupEmbedded.check matrix r) && r.stages.all (checkStage matrix statics admitted) &&
  memory matrix r.operand (stage r 1).outputs 3 && memory matrix r.control (stage r 2).outputs 33 &&
  admissionBindings matrix admitted r && staticBindings statics r
end ZkBuild.ValidationEventCheck

import DynamicCallMatrix
import DynamicSelectors
set_option autoImplicit false
set_option synthInstance.maxSize 1024
namespace ZkBuild.DynamicTypingCheck
open CircuitShape GadgetShape DeclarationMatrix SourceProgram ValidationEventMatrix DynamicTypingMatrix

def stage (r : DynamicTypingMatrix.Record) (kind : Nat) : DynamicTypingMatrix.Stage := (r.stages.find? (fun s => s.kind == kind)).getD default
def shape (xs : List Fields) (length width : Nat) : Bool :=
  xs.length == length && xs.all (fun row => row.length == width)
def entries (xs : List ReadOnlyMatrix.Entry) := xs.map entry

def links (tables : List ReadOnlyMatrix.Record) (context : ModuleContextMatrix.Record)
    (locals : LocalRangeMatrix.Record) (events : ValidationEventMatrix.Record) (r : DynamicTypingMatrix.Record) : Bool :=
  let count := events.rows.length
  let selectors := stage r 0
  let environment := stage r 1
  let variables := stage r 2
  let calls := stage r 3
  decide (r.stages.map (·.kind) = [0,1,2,3]) &&
  r.stages.all (fun s => same s.rows (events.rows.map (·.take 10))) &&
  shape selectors.outputs count 14 &&
  decide (selectors.flags = [] ∧ selectors.selectors = [] ∧ selectors.inputs = [] ∧ selectors.auxiliary = [] ∧ selectors.banks = []) &&
  ([environment,variables,calls].all (fun s => same s.flags (ValidationEventCheck.stage events 1).flags)) &&
  same environment.selectors selectors.outputs && same variables.selectors selectors.outputs &&
  same environment.inputs (events.rows.map (fun row => [f row 10])) &&
  shape environment.outputs count 1 && environment.banks.length == 2 &&
  shape environment.auxiliary (bank tables environment 1).entries.length 2 &&
  same variables.inputs environment.outputs &&
  decide (variables.outputs = [] ∧ variables.auxiliary = [] ∧ variables.banks = []) &&
  same calls.inputs (events.rows.map (fun row => [f row 10,f row 11])) &&
  shape calls.auxiliary count 3 && calls.banks.length == 1 &&
  decide (calls.selectors = [] ∧ calls.outputs = []) &&
  r.stages.all (fun s => s.banks.all (fun b => b < tables.length)) &&
  decide ((bank tables environment 0).memory.addressBits = 64 ∧ (bank tables environment 0).memory.valueBits = 3 ∧
    (bank tables environment 1).memory.addressBits = 33 ∧ (bank tables environment 1).memory.valueBits = 4 ∧
    (bank tables calls 0).memory.addressBits = 33 ∧ (bank tables calls 0).memory.valueBits = 4) &&
  same (entries (bank tables environment 0).entries) (entries locals.locals) &&
  same (entries (bank tables environment 1).entries) (entries (ModuleContextMatrix.bank tables context 0).entries) &&
  same (entries (bank tables calls 0).entries) (entries (ModuleContextMatrix.bank tables context 0).entries)

def replay (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (signature : SignatureMatrix.Record) (s : DynamicTypingMatrix.Stage) : Eval Unit := do
  if s.kind = 0 then
    let outputs ← replaySelectors matrix s
    require (same outputs s.outputs) "variable selector outputs rejected"
  else if s.kind = 1 then
    let (outputs,locals,objects) ← replayEnvironment matrix tables s
    require (same outputs s.outputs && same locals (entries (bank tables s 0).queries) &&
      same objects (entries (bank tables s 1).queries)) "type environment outputs rejected"
    require (s.program.base.lastGate == (bank tables s 0).firstGate) "type environment table boundary rejected"
  else if s.kind = 2 then replayVariables matrix s
  else if s.kind = 3 then
    let (metadata,nodes,objects) ← DynamicCallMatrix.replay matrix splits s
    require (same metadata (entries signature.extraMetadata) && same nodes (entries signature.extraOperands) &&
      same objects (entries (bank tables s 0).queries)) "call query interfaces rejected"
  else throw "unknown dynamic typing stage"

def checkStage (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (signature : SignatureMatrix.Record) (s : DynamicTypingMatrix.Stage) : Bool :=
  match (replay matrix splits tables signature s).run (init s.program) with
  | .error _ => false
  | .ok (_,state) => decide (finished s.program state) && auditState matrix [] splits state

def check (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (signature : SignatureMatrix.Record) (context : ModuleContextMatrix.Record)
    (locals : LocalRangeMatrix.Record) (events : ValidationEventMatrix.Record) (r : DynamicTypingMatrix.Record) : Bool :=
  links tables context locals events r && r.stages.all (checkStage matrix splits tables signature) &&
  r.stages.all (fun s => s.banks.all (fun i => ReadOnlyMatrix.check matrix (tables.getD i default))) &&
  DynamicSelectors.check matrix (stage r 0)
end ZkBuild.DynamicTypingCheck

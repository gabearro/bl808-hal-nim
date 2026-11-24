import RuntimeContextMatrix
set_option autoImplicit false
namespace ZkBuild.RuntimeContextCheck
open CircuitShape GadgetShape DeclarationMatrix SourceProgram ValidationEventMatrix DynamicTypingMatrix RuntimeContextMatrix

def entries (xs : List ReadOnlyMatrix.Entry) := xs.map DynamicTypingMatrix.entry

def links (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record)
    (context : ModuleContextMatrix.Record) (instructions : InstructionStreamMatrix.Record)
    (events : ValidationEventMatrix.Record) (r : RuntimeContextMatrix.Record) : Bool :=
  let m := stage r 0
  let b := stage r 1
  let fstage := stage r 2
  let mc := f (rowAt m.auxiliary 0) 0
  let bc := rowAt b.auxiliary 0
  let fc := f (rowAt fstage.auxiliary 0) 0
  decide (r.stages.map (·.kind) = [0,1,2]) &&
  r.stages.all (fun s => s.banks.all (fun i => i < tables.length)) &&
  r.stages.all (fun s => same s.rows (events.rows.map (·.take 10)) &&
    same s.flags (ValidationEventCheck.stage events 1).flags && s.selectors.isEmpty && s.outputs.isEmpty) &&
  same m.inputs (events.rows.map fun row => [f row 10,f row 11]) && same b.inputs m.inputs &&
  same fstage.inputs (events.rows.map fun row => [f row 10]) &&
  DynamicTypingCheck.shape m.auxiliary 1 1 && DynamicTypingCheck.shape b.auxiliary 1 4 &&
  DynamicTypingCheck.shape fstage.auxiliary 1 1 &&
  same [[mc,f bc 0,fc,f bc 2]] [[ModuleContextMatrix.counter context 10,mc,ModuleContextMatrix.counter context 11,ModuleContextMatrix.counter context 13]] &&
  decide (m.banks.length = 1 ∧ b.banks.length = 2 ∧ fstage.banks.length = 1) &&
  same (entries (bank tables m 0).entries) (entries (InstructionStreamMatrix.bank tables instructions 5).entries) &&
  same (entries (bank tables b 0).entries) context.bulk &&
  same (entries (bank tables b 1).entries) (entries (ModuleContextMatrix.bank tables context 0).entries) &&
  same (entries (bank tables fstage 0).entries) (entries (ModuleContextMatrix.bank tables context 3).entries) &&
  r.stages.all (fun s => (List.range s.banks.length).all fun i =>
    let sizes := if s.kind == 0 then [(32,32)] else if s.kind == 1 then [(32,3),(33,4)] else [(32,1)]
    decide (((bank tables s i).memory.addressBits,(bank tables s i).memory.valueBits) = sizes.getD i (0,0))) &&
  MemoryEvidence.checkSpan matrix r.bindFirst r.bindLast
    [eqGate (get body.envelope.outputs 48) (f bc 1),eqGate (get body.envelope.outputs 49) (f bc 3)]

def replay (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (r : RuntimeContextMatrix.Record)
    (s : DynamicTypingMatrix.Stage) : Eval Unit := do
  if s.kind = 0 then
    let qs ← RuntimeContextMatrix.memory matrix tables r.catalog s
    require (same qs (entries (bank tables s 0).queries)) "memory metadata queries rejected"
  else if s.kind = 1 then
    let qs ← RuntimeContextMatrix.bulk matrix tables s
    require (same (qs.getD 0 []) (entries (bank tables s 0).queries) &&
      same (qs.getD 1 []) (entries (bank tables s 1).queries)) "bulk operation queries rejected"
  else if s.kind = 2 then
    let qs ← RuntimeContextMatrix.reference matrix tables s
    require (same qs (entries (bank tables s 0).queries)) "reference queries rejected"
  else throw "unknown runtime context stage"

def checkStage (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (r : RuntimeContextMatrix.Record)
    (s : DynamicTypingMatrix.Stage) : Bool :=
  match (replay matrix tables r s).run (init s.program) with
  | .error _ => false
  | .ok (_,state) => decide (finished s.program state) && auditState matrix [] [] state

def check (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record)
    (context : ModuleContextMatrix.Record) (instructions : InstructionStreamMatrix.Record)
    (events : ValidationEventMatrix.Record) (r : RuntimeContextMatrix.Record) : Bool :=
  links matrix body tables context instructions events r && r.stages.all (checkStage matrix tables r) &&
  r.stages.all (fun s => s.banks.all (fun i => ReadOnlyMatrix.check matrix (tables.getD i default))) &&
  r.catalog.all (fun item => LookupEmbedded.check matrix item.2)
end ZkBuild.RuntimeContextCheck

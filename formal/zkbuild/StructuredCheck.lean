import StructuredFrames
import StructuredTyping
import StructuredBranches
import StructuredMerge
import StructuredCatches
import StructuredExceptions
set_option autoImplicit false
set_option synthInstance.maxSize 1024
namespace ZkBuild.StructuredCheck
open CircuitShape GadgetShape DeclarationMatrix SourceProgram ValidationEventMatrix DynamicTypingMatrix StructuredMatrix
def entries (xs : List ReadOnlyMatrix.Entry) := xs.map DynamicTypingMatrix.entry
def queries (tables : List ReadOnlyMatrix.Record) (s : DynamicTypingMatrix.Stage) (outputs : List (List Fields)) : Bool :=
  outputs.length == s.banks.length && (List.range outputs.length).all (fun i => same (outputs.getD i []) (entries (bank tables s i).queries))
def sameFrames (r : StructuredMatrix.Record) (s : DynamicTypingMatrix.Stage) := same s.selectors (stage r 3).outputs
def memoryInterface (m : MemoryEmbedded.Record) (expected : List Fields) (addressBits valueBits : Nat) : Bool :=
  decide (m.addressBits = addressBits ∧ m.valueBits = valueBits ∧ m.inputs.length = expected.length ∧
    m.inputs.map (fun a => BinaryReadMemory.normalizedPayload a.fields) =
      (List.range expected.length).map (fun i => let row := expected.getD i []
        BinaryReadMemory.normalizedPayload ⟨f row 0,f row 1,f row 2,f row 3,n i⟩))
def links (tables : List ReadOnlyMatrix.Record) (events : ValidationEventMatrix.Record)
    (instructions : InstructionStreamMatrix.Record) (signature : SignatureMatrix.Record) (indexed : IndexedMatrix.Record)
    (declaration : DeclarationMatrix.Record) (r : StructuredMatrix.Record) : Bool :=
  let c := stage r 0
  let b := stage r 2
  let fstage := stage r 3
  let ct := stage r 4
  let bt := stage r 5
  let mt := stage r 6
  let catchTypes := stage r 7
  let reverse := stage r 8
  let throwing := stage r 9
  let count := events.rows.length
  let flags := (ValidationEventCheck.stage events 1).flags
  decide (r.stages.map (·.kind) = [0,1,2,3,4,5,6,9,8,7]) &&
  r.stages.all (fun s => s.banks.all (fun i => i < tables.length)) &&
  r.stages.all (fun s => s.kind == 9 || s.auxiliary.isEmpty) &&
  ([c,stage r 1,b,fstage,ct,bt,mt,throwing].all (fun s => same s.rows (events.rows.map (·.take 10)))) &&
  ([c,stage r 1,fstage,ct,throwing].all (fun s => same s.flags flags)) &&
  same b.flags (stage r 1).outputs && same bt.flags (stage r 1).outputs &&
  same c.inputs (events.rows.map fun row => [f row 11]) &&
  same b.inputs (events.rows.map fun row => [f row 10]) &&
  same fstage.inputs ((List.range count).map fun i => let row := rowAt events.rows i
    [f row 10,f row 12,f (rowAt b.outputs i) 0++f (rowAt c.outputs i) 1]) &&
  DynamicTypingCheck.shape c.outputs count 5 && DynamicTypingCheck.shape b.outputs count 2 &&
  DynamicTypingCheck.shape fstage.outputs count 22 &&
  sameFrames r ct && sameFrames r bt && sameFrames r catchTypes &&
  same bt.inputs (b.outputs.map fun row => [f row 1]) &&
  same mt.selectors ct.outputs && same mt.inputs bt.outputs &&
  same catchTypes.inputs c.outputs &&
  same throwing.inputs (events.rows.map fun row => [f row 10]) &&
  same throwing.auxiliary (declaration.tags.map fun tag => [tag.typeIndex]) &&
  same ((bank tables throwing 1).entries.map fun e => [e.active]) (declaration.tags.map fun tag => [tag.active]) &&
  decide (catchTypes.rows = [] ∧ catchTypes.flags = [] ∧ catchTypes.outputs = [] ∧
    c.selectors = [] ∧ b.selectors = [] ∧ fstage.selectors = [] ∧
    (stage r 1).selectors = [] ∧ (stage r 1).inputs = [] ∧ (stage r 1).banks = [] ∧
    ct.inputs = [] ∧ ct.banks = [] ∧ bt.banks = [] ∧ mt.flags = [] ∧
    reverse.rows = [] ∧ reverse.flags = [] ∧ reverse.selectors = [] ∧ reverse.inputs = [] ∧ reverse.outputs = [] ∧
    throwing.selectors = [] ∧ throwing.outputs = []) &&
  decide (c.banks.length = 3 ∧ b.banks.length = 2 ∧ fstage.banks = [] ∧ mt.banks.length = 1 ∧ catchTypes.banks.length = 5 ∧
    reverse.banks.length = 3 ∧ throwing.banks.length = 3) &&
  same (entries (bank tables c 0).entries) (entries (InstructionStreamMatrix.bank tables instructions 7).entries) &&
  same (entries (bank tables c 1).entries) (entries (InstructionStreamMatrix.bank tables instructions 9).entries) &&
  same (entries (bank tables c 2).entries) (entries (InstructionStreamMatrix.bank tables instructions 10).entries) &&
  same (entries (bank tables b 0).entries) (entries (InstructionStreamMatrix.bank tables instructions 6).entries) &&
  same (entries (bank tables b 1).entries) (entries (InstructionStreamMatrix.bank tables instructions 8).entries) &&
  same (entries (bank tables mt 0).entries) (entries (SignatureMatrix.table tables signature 0).entries) &&
  same (entries (bank tables catchTypes 0).entries) (entries (SignatureMatrix.table tables signature 0).entries) &&
  same (entries (bank tables catchTypes 1).entries) (entries (IndexedMatrix.table tables indexed 2).entries) &&
  same (entries (bank tables catchTypes 4).entries) (entries (SignatureMatrix.table tables signature 1).entries) &&
  same (entries (bank tables catchTypes 2).entries) (entries (bank tables throwing 1).entries) &&
  same (entries (bank tables catchTypes 3).entries) (entries (bank tables reverse 0).entries) &&
  same (entries (bank tables reverse 1).entries) (entries (IndexedMatrix.table tables indexed 0).entries) &&
  same (entries (bank tables reverse 2).entries) (entries (IndexedMatrix.table tables indexed 1).entries) &&
  same (entries (bank tables throwing 0).entries) (entries (SignatureMatrix.table tables signature 0).entries) &&
  same (entries (bank tables throwing 2).entries) (entries (SignatureMatrix.table tables signature 1).entries) &&
  r.stages.all (fun s => (List.range s.banks.length).all fun i =>
    let sizes := if s.kind == 0 then [(64,32),(32,34),(32,64)]
      else if s.kind == 2 then [(64,32),(32,64)]
      else if s.kind == 6 then [(33,64)]
      else if s.kind == 7 then [(33,64),(3,32),(32,64),(32,32),(32,35)]
      else if s.kind == 8 then [(32,32),(32,32),(64,35)]
      else if s.kind == 9 then [(33,64),(32,64),(32,35)] else []
    decide (((bank tables s i).memory.addressBits,(bank tables s i).memory.valueBits) = sizes.getD i (0,0)))

def replay (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (indexed : IndexedMatrix.Record) (r : StructuredMatrix.Record) (s : DynamicTypingMatrix.Stage) : Eval Unit := do
  if s.kind = 0 then
    let (out,qs) ← catchEnvironment matrix splits tables s
    require (same out s.outputs && queries tables s qs) "catch environment outputs rejected"
  else if s.kind = 1 then
    let out ← filterLabels matrix s
    require (same out s.outputs) "branch label projection rejected"
  else if s.kind = 2 then
    let (out,qs) ← branchEnvironment matrix splits tables s
    require (same out s.outputs && queries tables s qs) "branch environment outputs rejected"
  else if s.kind = 3 then
    let (out,accesses) ← StructuredFrames.replay matrix r.frames s
    require (same out s.outputs && memoryInterface r.frames accesses 64 36) "signature frame outputs rejected"
  else if s.kind = 4 then
    let out ← StructuredTyping.replay matrix splits s
    require (same out s.outputs) "control typing queries rejected"
  else if s.kind = 5 then
    let (out,accesses) ← StructuredBranches.replay matrix splits s
    require (same out s.outputs) "branch typing queries rejected"
    require (memoryInterface r.scratch accesses 32 3) "branch restoration memory rejected"
  else if s.kind = 6 then
    let out ← StructuredMerge.replay matrix s
    require (same out s.outputs) "merged queries rejected"
    require (same (out.map fun row => qAt row 0) (entries (bank tables s 0).queries) &&
      same (out.flatMap fun row => [qAt row 3,qAt row 12]) (entries indexed.extraLengths) &&
      same (out.flatMap fun row => [qAt row 6,qAt row 15]) (entries indexed.extraMembers) &&
      same (out.map fun row => qAt row 9) (entries indexed.extraSingletons)) "merged signature interfaces rejected"
  else if s.kind = 7 then
    let qs ← StructuredCatches.replay matrix splits tables s
    require (queries tables s qs) "catch type queries rejected"
  else if s.kind = 8 then
    let qs ← StructuredExceptions.reversals matrix splits tables s
    require (queries tables s qs) "signature reversal queries rejected"
  else if s.kind = 9 then
    let qs ← StructuredExceptions.throws matrix splits tables s
    require (queries tables s qs) "throw/tag queries rejected"
  else throw "unknown structured control stage"

def checkStage (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (indexed : IndexedMatrix.Record) (r : StructuredMatrix.Record) (s : DynamicTypingMatrix.Stage) : Bool :=
  match (replay matrix splits tables indexed r s).run (init s.program) with
  | .error _ => false
  | .ok (_,state) => decide (finished s.program state) && auditState matrix [] splits state
def check (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (events : ValidationEventMatrix.Record) (instructions : InstructionStreamMatrix.Record)
    (signature : SignatureMatrix.Record) (indexed : IndexedMatrix.Record) (declaration : DeclarationMatrix.Record) (r : StructuredMatrix.Record) : Bool :=
  links tables events instructions signature indexed declaration r && r.stages.all (checkStage matrix splits tables indexed r) &&
  r.stages.all (fun s => s.banks.all (fun i => ReadOnlyMatrix.check matrix (tables.getD i default))) &&
  MemoryEmbedded.check matrix r.frames && MemoryEmbedded.check matrix r.scratch
end ZkBuild.StructuredCheck

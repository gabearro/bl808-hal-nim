import BodySourceAuditIO
set_option autoImplicit false
set_option synthInstance.maxSize 512
namespace ZkBuild.BodySourceSound
open CircuitShape DeclarationMatrix BodySourceMatrix

def links (tables : List ReadOnlyMatrix.Record) (space : SignatureNamespace.Record) (indexed : IndexedMatrix.Record)
    (locals : LocalDeclarationMatrix.Record) (r : BodySourceMatrix.Record) : Bool :=
  decide (r.banks.length = (if r.flat then 7 else 5) ∧ (∀ i ∈ r.banks, i < tables.length) ∧
    ModuleProgram.sameInputs [r.firstFunction] [space.firstFunction] ∧
    r.spans.length = r.bodies.length ∧
    r.bodies.all (fun body => body.fields.length == 6 && body.locals.all (fun row => row.length == 2)) = true ∧
    r.locals.all (fun row => row.length == 6) = true ∧ r.spans.all (fun row => row.length == 3) = true ∧
    (if r.flat then r.bodies.all (fun body => body.locals.length == 0) = true
      else r.locals.length = 0 ∧ r.bodies.all (fun body => decide (ModuleProgram.sameInputs [f body.fields 0] [o])) = true) ∧
    normalizedEntries (table tables r 2).entries = normalizedEntries (space.rows.map (·.entry)) ∧
    normalizedEntries (table tables r 3).entries = normalizedEntries (indexed.lengths.map (·.entry)) ∧
    normalizedEntries (table tables r 4).entries = normalizedEntries locals.totals ∧
    normalizedEntries (table tables r 5).entries = normalizedEntries locals.ranges ∧
    normalizedEntries (table tables r 6).entries = normalizedEntries locals.tags) &&
  (List.range r.banks.length).all (fun i =>
    let bank := tables.getD (r.banks.getD i 0) default
    let sizes := if r.flat then [(32,64),(32,64),(33,64),(32,32),(32,64),(64,64),(64,3)]
      else [(33,64),(32,32),(64,64),(64,3),(32,64)]
    decide ((bank.memory.addressBits,bank.memory.valueBits) = sizes.getD i (0,0)))

def outputLinks (tables : List ReadOnlyMatrix.Record) (r : BodySourceMatrix.Record) (result : BodySourceMatrix.Result) : Bool :=
  decide (normalized r.spans = normalizedEntries result.spans) &&
  ((if r.flat then List.range 7 else [2,3,4,5,6]).all (fun i =>
    decide (normalizedEntries (result.queries.getD i []) = normalizedEntries (table tables r i).queries))) &&
  (if r.flat then decide (normalizedEntries result.positions = normalizedEntries (table tables r 0).entries ∧
    normalizedEntries result.counts = normalizedEntries (table tables r 1).entries) else true)

def checkCode (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (space : SignatureNamespace.Record) (indexed : IndexedMatrix.Record) (locals : LocalDeclarationMatrix.Record) (r : BodySourceMatrix.Record) : Bool :=
  links tables space indexed locals r && match BodySourceMatrix.replay matrix body.tokens splits tables body r with
  | .error _ => false
  | .ok (result,state) => decide (SourceProgram.finished r.program state ∧
      r.program.base.lastGate = (tables.getD (r.banks.getD 0 0) default).firstGate) &&
      outputLinks tables r result && SourceProgram.auditState matrix body.tokens splits state

def check (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (space : SignatureNamespace.Record) (indexed : IndexedMatrix.Record) (context : ModuleContextMatrix.Record) (locals : LocalDeclarationMatrix.Record)
    (ranges : LocalRangeMatrix.Record) (code : BodySourceMatrix.Record) : Bool :=
  LocalRangeMatrix.check matrix body splits tables locals ranges &&
  LocalDeclarationMatrix.check matrix body splits tables space indexed context locals &&
  checkCode matrix body splits tables space indexed locals code
end ZkBuild.BodySourceSound

import InstructionStreamFlat
import InstructionStreamLegacy
set_option autoImplicit false
namespace ZkBuild.InstructionStreamCheck
open CircuitShape DeclarationMatrix SourceProgram InstructionStreamMatrix

def links (tables : List ReadOnlyMatrix.Record) (context : ModuleContextMatrix.Record)
    (body : BodySourceMatrix.Record) (decoders : List InstructionDecodeMatrix.Record) (r : InstructionStreamMatrix.Record) : Bool :=
  decide (r.banks.length = (if r.flat then 16 else 11) ∧ (∀ i ∈ r.banks, i < tables.length) ∧
    r.flat = body.flat ∧ ModuleProgram.sameInputs [r.firstFunction] [body.firstFunction] ∧
    ModuleContextMatrix.normalizedEntries r.spans = ModuleContextMatrix.normalized body.spans ∧
    r.rows.all (fun row => row.fields.length == 9) = true ∧
    r.events.all (fun row => row.length == 7) = true ∧
    r.rows.length = decoders.length ∧ r.rows.map (·.decoder) = List.range decoders.length ∧
    (if r.flat then r.functions.length = r.spans.length ∧ r.bodySizes = [] ∧
        r.functions.all (fun row => row.length == 12) = true ∧
        r.labels.all (fun row => row.length == 5) = true ∧ r.catches.all (fun row => row.length == 5) = true ∧
        r.rows.all (fun row => row.labels == 0 && row.catches == 0) = true ∧
        ModuleContextMatrix.normalizedEntries (bank tables r 0).entries = ModuleContextMatrix.normalizedEntries r.spans
      else r.functions = [] ∧ r.labels = [] ∧ r.catches = [] ∧ r.bodySizes.length = r.spans.length ∧
        r.bodySizes.all (fun n => n > 0) = true ∧ r.bodySizes.foldl (·+·) 0 = r.rows.length) ∧
    ModuleContextMatrix.normalizedEntries (bank tables r 5).entries = ModuleContextMatrix.normalized context.bodies) &&
  (List.range r.banks.length).all (fun i =>
    let sizes := if r.flat then [(32,64),(32,32),(32,32),(32,32),(32,32),(32,32),(64,32),(64,32),(32,64),(32,34),(32,64),(64,49),(64,64),(32,64),(32,35),(32,32)]
      else [(64,32),(32,64),(64,32),(32,34),(32,64),(32,32),(64,49),(64,64),(32,32),(32,32),(32,32)]
    let t := tables.getD (r.banks.getD i 0) default
    decide ((t.memory.addressBits,t.memory.valueBits) = sizes.getD i (0,0)))

def outputLinks (tables : List ReadOnlyMatrix.Record) (r : InstructionStreamMatrix.Record) (a : Acc) : Bool :=
  (if r.flat then List.range 16 else [1,2,3,5,6,7,8,9,10,11,12]).all (fun i =>
    decide (ModuleContextMatrix.normalizedEntries (a.queries.getD i []) = ModuleContextMatrix.normalizedEntries (bank tables r i).queries)) &&
  (if r.flat then [1,2,3,4,11,12,13,14,15] else [1,2,3,11,12]).all (fun i =>
    decide (ModuleContextMatrix.normalizedEntries (a.entries.getD i []) = ModuleContextMatrix.normalizedEntries (bank tables r i).entries))

def run (matrix : Shape) (tokens : Tokens) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (catalog : InstructionDecodeMatrix.Catalog) (decoders : List InstructionDecodeMatrix.Record) (r : InstructionStreamMatrix.Record) :=
  (if r.flat then InstructionStreamFlat.replay matrix tokens splits tables catalog decoders r
    else InstructionStreamLegacy.replay matrix tokens splits tables catalog decoders r).run (init r.program)

def checkPayload (matrix : Shape) (tokens : Tokens) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (context : ModuleContextMatrix.Record) (body : BodySourceMatrix.Record)
    (catalog : InstructionDecodeMatrix.Catalog) (decoders : List InstructionDecodeMatrix.Record) (r : InstructionStreamMatrix.Record) : Bool :=
  links tables context body decoders r &&
  decoders.all (InstructionDecodeMatrix.check matrix tokens splits catalog) &&
  match run matrix tokens splits tables catalog decoders r with
  | .error _ => false
  | .ok (a,state) => decide (finished r.program state ∧ r.program.base.lastGate = (tables.getD (r.banks.getD 0 0) default).firstGate) &&
    outputLinks tables r a && frameCheck matrix r a && auditState matrix tokens splits state
def check (matrix : Shape) (tokens : Tokens) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (context : ModuleContextMatrix.Record) (body : BodySourceMatrix.Record)
    (catalog : InstructionDecodeMatrix.Catalog) (decoders : List InstructionDecodeMatrix.Record) (r : InstructionStreamMatrix.Record) : Bool :=
  InstructionDecodeMatrix.catalogCheck catalog && checkPayload matrix tokens splits tables context body catalog decoders r
end ZkBuild.InstructionStreamCheck

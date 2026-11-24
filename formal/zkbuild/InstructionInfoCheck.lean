import InstructionEventSound
set_option autoImplicit false
namespace ZkBuild.InstructionInfoCheck
open CircuitShape GadgetShape DeclarationMatrix ValidationEventMatrix

structure Record where
  fields : Fields
  opcode : RangeUse.Record
  primary : RangeUse.Record
  secondary : RangeUse.Record
  pad : RangeUse.Record
  deriving Inhabited

def check (matrix : Shape) (r : Record) : Bool :=
  decide (r.fields.length=9) && RangeUse.check matrix r.opcode (f r.fields 3) 16 &&
  RangeUse.check matrix r.primary (f r.fields 4) 32 && RangeUse.check matrix r.secondary (f r.fields 5) 32 &&
  RangeUse.check matrix r.pad (f r.fields 6) 33

def record (catalog : InstructionDecodeMatrix.Catalog) (decoders : List InstructionDecodeMatrix.Record)
    (s : InstructionStreamMatrix.Record) (i : Nat) : Record :=
  let row := s.rows.getD i default
  let d := decoders.getD row.decoder default
  let lookup := InstructionDecodeMatrix.lookupRecord catalog (d.program.blocks.getD 0 default).index
  ⟨row.fields,lookup.range,d.program.base.operations.getD 2 default,
   d.program.base.operations.getD 3 default,d.program.base.operations.getD 4 default⟩
def key (row : InstructionStreamMatrix.Row) := scale (f row.fields 1) (Int.ofNat (2^32))++f row.fields 2
def entry (row : InstructionStreamMatrix.Row) (info : Bool) : ReadOnlyMatrix.Entry :=
  ⟨f row.fields 0,key row,
   if info then f row.fields 3++scale (f row.fields 6) 65536
   else f row.fields 4++scale (f row.fields 5) (Int.ofNat (2^32))⟩
def checkStage (matrix : Shape) (tables : List ReadOnlyMatrix.Record)
    (catalog : InstructionDecodeMatrix.Catalog) (decoders : List InstructionDecodeMatrix.Record)
    (s : InstructionStreamMatrix.Record) : Bool :=
  DynamicTypingMatrix.same (DynamicTypingCheck.entries (InstructionStreamMatrix.bank tables s 11).entries)
    (DynamicTypingCheck.entries (s.rows.map (fun row => entry row true))) &&
  DynamicTypingMatrix.same (DynamicTypingCheck.entries (InstructionStreamMatrix.bank tables s 12).entries)
    (DynamicTypingCheck.entries (s.rows.map (fun row => entry row false))) &&
  (List.range s.rows.length).all (fun i => check matrix (record catalog decoders s i))
end ZkBuild.InstructionInfoCheck

import BranchTypeCertificate
set_option autoImplicit false
namespace ZkBuild.BranchLookupCheck
open CircuitShape DeclarationMatrix ValidationEventMatrix

def bank (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (r : StructuredMatrix.Record) (family : Nat) : ReadOnlyMatrix.Record :=
  if family = 0 then DynamicTypingMatrix.bank tables (StructuredMatrix.stage r 6) 0
  else IndexedMatrix.table tables indexed (family-1)
def position (indexed : IndexedMatrix.Record) (i family : Nat) : Nat :=
  if family = 1 then indexed.members.length+2*indexed.metadata.length+indexed.singletons.length+2*i
  else if family = 2 then indexed.lengths.length+2*i else i
def query (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (r : StructuredMatrix.Record) (i family : Nat) : ReadOnlyMatrix.Entry :=
  (bank tables indexed r family).queries.getD (position indexed i family) default
def addressBits (family : Nat) : Nat := ([33,32,64,3] : List Nat).getD family 0
def valueBits (family : Nat) : Nat := ([64,32,35,32] : List Nat).getD family 0
def row (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (r : StructuredMatrix.Record) (i family : Nat) : Bool :=
  decide (position indexed i family < (bank tables indexed r family).queries.length ∧
    ModuleProgram.sameInputs (DynamicTypingMatrix.entry (BranchMergeCheck.record r i family).merged)
      (DynamicTypingMatrix.entry (query tables indexed r i family)))
def check (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (r : StructuredMatrix.Record) : Bool :=
  decide (indexed.tables.length = 4 ∧ (StructuredMatrix.stage r 6).banks.length = 1) &&
  (List.range 4).all (fun family =>
    let b := bank tables indexed r family
    decide (b.memory.addressBits = addressBits family ∧ b.memory.valueBits = valueBits family) && ReadOnlyMatrix.check matrix b) &&
  (List.range (StructuredMatrix.stage r 5).rows.length).all (fun i =>
    (List.range 4).all (fun family => row tables indexed r i family))
end ZkBuild.BranchLookupCheck

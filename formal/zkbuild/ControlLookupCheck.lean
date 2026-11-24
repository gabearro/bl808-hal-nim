import BranchLookupSound
import ControlTypeCertificate
set_option autoImplicit false
namespace ZkBuild.ControlLookupCheck
open CircuitShape DeclarationMatrix ValidationEventMatrix

def familyBank (family : Nat) := if family=4 then 1 else if family=5 then 2 else family
def bank (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (r : StructuredMatrix.Record) (family : Nat) := BranchLookupCheck.bank tables indexed r (familyBank family)
def position (indexed : IndexedMatrix.Record) (i family : Nat) :=
  BranchLookupCheck.position indexed i (familyBank family)+(if family<4 then 0 else 1)
def query (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (r : StructuredMatrix.Record) (i family : Nat) :=
  (bank tables indexed r family).queries.getD (position indexed i family) default
def control (r : StructuredMatrix.Record) (i family : Nat) := BranchMergeCheck.queryAt (StructuredMatrix.stage r 4) i family
def direct (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (r : StructuredMatrix.Record) (i family : Nat) : Bool :=
  decide (position indexed i family<(bank tables indexed r family).queries.length ∧
    ModuleProgram.sameInputs (DynamicTypingMatrix.entry (control r i family))
      (DynamicTypingMatrix.entry (query tables indexed r i family)))
def check (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (r : StructuredMatrix.Record) : Bool :=
  BranchLookupCheck.check matrix tables indexed r && BranchMergeCheck.checkStage matrix r &&
  (List.range (StructuredMatrix.stage r 4).rows.length).all
    (fun i => (List.range 2).all (fun j => direct tables indexed r i (j+4)))

def row (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (r : StructuredMatrix.Record) (i family : Nat) : Bool :=
  if family<4 then BranchMergeCheck.check matrix (BranchMergeCheck.record r i family) &&
    BranchLookupCheck.row tables indexed r i family
  else direct tables indexed r i family

theorem family_bound (family : Nat) (fb : family<6) : familyBank family<4 := by
  unfold familyBank
  split
  · omega
  · split <;> omega
theorem family_small (family : Nat) (fb : family<4) : familyBank family=family := by
  simp [familyBank,show family≠4 by omega,show family≠5 by omega]
end ZkBuild.ControlLookupCheck

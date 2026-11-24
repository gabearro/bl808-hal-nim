import BranchComplete
import StructuredOrigins
set_option autoImplicit false
namespace ZkBuild.BranchOrigins
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix
attribute [local instance] Ring.intCast Semiring.natCast

/-- The authenticated list cells and bank selections originate in the checked
    instruction stream. Raw byte-vector refinement is a separate obligation. -/
def Origins {F : Type} [Field F] (values : Nat → F) (tables : List ReadOnlyMatrix.Record)
    (instructions : InstructionStreamMatrix.Record) (r : StructuredMatrix.Record) : Prop :=
  (∀ id cell, BranchStore.table values (DynamicTypingMatrix.bank tables (StructuredMatrix.stage r 2) 1) id = some cell →
    ∃ source ∈ (InstructionStreamMatrix.bank tables instructions 8).entries,
      E values source.active = 1 ∧ E values source.address = (id : F) ∧ E values source.value = (BranchLists.pack cell : F)) ∧
  (∀ q ∈ (DynamicTypingMatrix.bank tables (StructuredMatrix.stage r 2) 0).queries, E values q.active = 1 →
    ∃ source ∈ (InstructionStreamMatrix.bank tables instructions 6).entries,
      E values source.active = 1 ∧ E values source.address = E values q.address ∧ E values source.value = E values q.value)

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (events : ValidationEventMatrix.Record) (instructions : InstructionStreamMatrix.Record)
    (signature : SignatureMatrix.Record) (indexed : IndexedMatrix.Record) (declaration : DeclarationMatrix.Record)
    (r : StructuredMatrix.Record)
    (checked : StructuredCheck.check matrix splits tables events instructions signature indexed declaration r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    Origins values tables instructions r := by
  constructor
  · intro id cell found
    obtain ⟨_,_,_,q,qm,qa,qk,qv⟩ := BranchStore.witness values _ id cell found
    obtain ⟨source,sm,sa,sk,sv⟩ := StructuredOrigins.control_origins matrix splits tables events instructions
      signature indexed declaration r checked values one satisfied 2 1 8 (by decide) q qm qa
    exact ⟨source,sm,sa,sk.trans qk,sv.trans qv⟩
  · intro q qm qa
    exact StructuredOrigins.control_origins matrix splits tables events instructions
      signature indexed declaration r checked values one satisfied 2 0 6 (by decide) q qm qa

#print axioms sound
end ZkBuild.BranchOrigins

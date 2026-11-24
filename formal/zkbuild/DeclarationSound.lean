import DeclarationVector
import DeclarationAuditIO
namespace ZkBuild.DeclarationSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix ModuleAuditIO
attribute [local instance] Ring.intCast Semiring.natCast

def check (matrix : Shape) (body : SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits) (r : DeclarationMatrix.Record) : Bool :=
  ModuleTables.check matrix body tables splits && DeclarationMatrix.check matrix body.tokens splits tables body.envelope r

theorem type_member (matrix : Shape) (tokens : Tokens) (splits : Splits) (endPos : Linear)
    (rows : List TypeRow) (index : Nat) (prior : List Linear) (previous : Linear)
    (accepted : checkTypes matrix tokens splits endPos rows index prior previous = true)
    (r : TypeRow) (member : r ∈ rows) : ∃ i p v, checkType matrix tokens splits r i p v endPos = true := by
  induction rows generalizing index prior previous with
  | nil => simp at member
  | cons row rows ih =>
    have parts := Bool.and_eq_true_iff.mp accepted
    rcases List.mem_cons.mp member with rfl | later
    · exact ⟨index,prior,previous,parts.1⟩
    · exact ih (index+1) row.counts (get row.fields 0) parts.2 later

theorem vector_member (matrix : Shape) (tokens : Tokens) (splits : Splits) (reverse : Bool)
    (rows : List VectorRow) (index : Nat) (previous address count : Linear)
    (accepted : checkVectors matrix tokens splits reverse rows index previous address count = true)
    (r : VectorRow) (member : r ∈ rows) : ∃ i p a c, checkVector matrix tokens splits r reverse i p a c = true := by
  induction rows generalizing index previous address count with
  | nil => simp at member
  | cons row rows ih =>
    have parts := Bool.and_eq_true_iff.mp accepted
    rcases List.mem_cons.mp member with rfl | later
    · exact ⟨index,previous,address,count,parts.1⟩
    · exact ih (index+1) (get row.fields 0) (get row.fields 1) row.count parts.2 later

theorem checked_source_types {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits) (r : DeclarationMatrix.Record)
    (accepted : check matrix body tables splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ message : List Sha256.Byte,
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      (∀ other, BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length other → other = message) ∧
      (∀ row ∈ r.types, ∃ d : DeclarationType.Decoded, DeclarationType.Represents values row d ∧ DeclarationType.Bounded d ∧
        (d.active = true → d.start < message.length ∧ (message.getD d.start 0).toNat = 96)) ∧
      (∀ row ∈ r.params++r.results, E values (get row.fields 0) = 1 → ∃ (tag : Fin 7) (position : Nat), position < message.length ∧
        E values (get row.fields 2) = (tag.val : F) ∧ E values row.position = (position : F) ∧
        (message.getD position 0).toNat = BinaryDeclarations.encodedType tag) := by
  have acceptedParts := Bool.and_eq_true_iff.mp accepted
  have envelope := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp acceptedParts.1).1).1
  have tokenCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp envelope).1).1
  have tokenChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp tokenCheck).1).1).2
  obtain ⟨message,meaning,d0,d1,unique,decoded⟩ := BinaryTokenSound.checked_decoding matrix body.source body.hash body.memory body.queries body.tokens tokenCheck values oneValue satisfied
  have typeChecks : checkTypes matrix body.tokens splits r.typeEnd r.types 0 (typeSeed r.typeStart) o = true := by
    have checks := acceptedParts.2
    simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at checks
    grind only
  have paramChecks : checkVectors matrix body.tokens splits true r.params 0 o z z = true := by
    have checks := acceptedParts.2
    simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at checks
    grind only
  have resultChecks : checkVectors matrix body.tokens splits false r.results 0 o z z = true := by
    have checks := acceptedParts.2
    simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at checks
    grind only
  refine ⟨message,meaning,d0,d1,unique,?_,?_⟩
  · intro row member
    obtain ⟨i,p,v,checked⟩ := type_member matrix body.tokens splits r.typeEnd r.types 0 (typeSeed r.typeStart) o typeChecks row member
    obtain ⟨d,represented,bounded⟩ := DeclarationType.decode matrix body.tokens splits row i p v r.typeEnd checked values oneValue satisfied
    exact ⟨d,represented,bounded,fun active => DeclarationHeader.type_header matrix body.tokens splits tokenChecks row i p v r.typeEnd checked values oneValue satisfied d represented bounded active message decoded⟩
  · intro row member active
    rcases List.mem_append.mp member with param | result
    · obtain ⟨i,p,a,c,checked⟩ := vector_member matrix body.tokens splits true r.params 0 o z z paramChecks row param
      exact DeclarationVector.source_type_byte matrix body.tokens splits tokenChecks row true i p a c checked values oneValue satisfied active message decoded
    · obtain ⟨i,p,a,c,checked⟩ := vector_member matrix body.tokens splits false r.results 0 o z z resultChecks row result
      exact DeclarationVector.source_type_byte matrix body.tokens splits tokenChecks row false i p a c checked values oneValue satisfied active message decoded

#print axioms checked_source_types
end ZkBuild.DeclarationSound

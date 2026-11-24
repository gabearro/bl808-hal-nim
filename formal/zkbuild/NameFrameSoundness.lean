import NameFrameSource
import OwnedSoundness
set_option autoImplicit false
namespace ZkBuild.NameFrameSoundness
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix NameFrameMatrix NameFrameSource ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

/-- All frame and byte-reader results use the same uniquely committed message. -/
theorem module_verified {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record) (names : NameFrameMatrix.Record)
    (checked : NameFrameSound.check matrix body tables splits declaration indexed signature space imports owned names = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ message : List Sha256.Byte,
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      (∀ other, BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length other → other = message) ∧
      (∀ h ∈ names.headers, E values (hget h 0) = 1 → Framed values h message) ∧
      (∀ b ∈ names.bytes, E values (bget b 0) = 1 → ∃ p, p < 2^32 ∧ p < message.length ∧
        E values (bget b 3) = (p : F) ∧ E values (bget b 4) = ((p+1 : Nat) : F) ∧
        E values (EnvelopeMatrix.token body.tokens b.token).value = ((message.getD p 0).toNat : F)) ∧
      (∀ r ∈ owned, OwnedSoundness.Coverage values r) := by
  have checks := Bool.and_eq_true_iff.mp checked
  have ownedParts := Bool.and_eq_true_iff.mp checks.1
  have signatureCheck := (Bool.and_eq_true_iff.mp ownedParts.1).1
  have indexedCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp signatureCheck).1).1
  have moduleCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp indexedCheck).1).1
  have tableChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp moduleCheck).1).2
  have splitChecks := (Bool.and_eq_true_iff.mp moduleCheck).2
  have envelopeCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp moduleCheck).1).1
  have tokenCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp envelopeCheck).1).1
  have tokenChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp tokenCheck).1).1).2
  obtain ⟨message,meaning,d0,d1,unique,decoded⟩ := BinaryTokenSound.checked_decoding matrix body.source body.hash body.memory body.queries body.tokens tokenCheck values oneValue satisfied
  refine ⟨message,meaning,d0,d1,unique,?_,?_,(OwnedSoundness.module_verified matrix body tables splits declaration indexed signature space imports owned checks.1 values oneValue satisfied).2⟩
  · intro h hm active
    cases flat : names.flat with
    | false => exact legacy_headers matrix body.tokens tokenChecks tables imports owned names checks.2 flat values oneValue satisfied message decoded h hm
    | true =>
      obtain ⟨i,ib,hi⟩ := List.mem_iff_getElem.mp hm
      have same : names.headers.getD i default = h := by rw [← List.getElem_eq_getD default]; exact hi
      simpa only [same] using flat_headers matrix body.tokens tokenChecks tables tableChecks splits splitChecks imports owned ownedParts.2 names checks.2 flat values oneValue satisfied message decoded i ib (by simpa only [same] using active)
  · intro b bm active
    have bc := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checks.2).1).2
    exact NameFrameRules.byte_read matrix body.tokens tokenChecks names.flat b (List.all_eq_true.mp bc b bm) values oneValue satisfied active message decoded

/-- The import name table really contains the framed producer entries. It
    cannot be replaced by an independently self-consistent span table. -/
theorem query_frame {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (tables : List ReadOnlyMatrix.Record) (imports : ImportMatrix.Record)
    (owned : List OwnedMatrix.Record) (names : NameFrameMatrix.Record)
    (checked : NameFrameMatrix.check matrix tokens tables imports owned names = true)
    (tableChecked : ReadOnlyMatrix.check matrix (ImportMatrix.table tables imports 0) = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (message : List Sha256.Byte) (frames : ∀ h ∈ names.headers, E values (hget h 0) = 1 → Framed values h message)
    (q : Entry) (member : q ∈ (ImportMatrix.table tables imports 0).queries) (active : E values q.active = 1) :
    ∃ h i, (h,i) ∈ names.headers.zipIdx ∧ Framed values h message ∧
      E values (entry h i).address = E values q.address ∧ E values (entry h i).value = E values q.value := by
  have links := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).1
  obtain ⟨_,_,_,_,_,_,_,_,lookup⟩ := ReadOnlySound.checked_membership matrix _ tableChecked values oneValue satisfied
  obtain ⟨e,em,ea,ek,ev⟩ := lookup q member active
  rw [links.2.1] at em
  obtain ⟨pair,pm,same⟩ := List.mem_map.mp em
  have hm : pair.1 ∈ names.headers := by
    have m := List.mem_zipIdx pm
    rw [m.2.2]
    exact List.getElem_mem _
  have enabled : E values (hget pair.1 0) = 1 := by simpa only [← same,entry] using ea
  exact ⟨pair.1,pair.2,pm,frames _ hm enabled,by simpa only [← same] using ek,by simpa only [← same] using ev⟩

#print axioms module_verified
#print axioms query_frame
end ZkBuild.NameFrameSoundness

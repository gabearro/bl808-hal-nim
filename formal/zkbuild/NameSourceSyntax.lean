import NameSourceConsumers
import BinaryTokenSyntax
set_option autoImplicit false

namespace ZkBuild.NameSourceSyntax
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix NameSourceShared ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def HeaderSyntax {F : Type} [Field F] (values : Nat → F) (h : NameFrameMatrix.Header) (message : List Sha256.Byte) : Prop :=
  ∃ position length, position < 2^32 ∧ position+length ≤ message.length ∧
    E values (NameFrameMatrix.hget h 2) = (position : F) ∧
    E values (NameFrameMatrix.hget h 3) = ((position+length : Nat) : F) ∧
    BinaryTokenSyntax.U32 length (fun i => (message.getD (position+i) 0).toNat)

theorem header_checked (matrix : Shape) (tokens : Tokens) (tables : List ReadOnlyMatrix.Record)
    (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record) (frame : NameFrameMatrix.Record)
    (checked : NameFrameMatrix.check matrix tokens tables imports owned frame = true)
    (h : NameFrameMatrix.Header) (member : h ∈ frame.headers) :
    NameFrameMatrix.checkHeader matrix tokens frame.flat h = true := by
  cases flat : frame.flat with
  | true =>
    simpa only [flat] using List.all_eq_true.mp (NameFrameFlat.parts matrix tokens tables imports owned frame checked flat).2.1 h member
  | false =>
    have legacy : NameFrameMatrix.legacyHeaders matrix tokens frame.bytes frame.headers 0 0 = true := by
      have c := checked
      simp only [NameFrameMatrix.check,flat,Bool.false_eq_true,↓reduceIte,Bool.and_eq_true_iff] at c
      exact c.2.2
    simpa only [flat] using (NameSourceHeaders.frame_member matrix tokens frame.bytes frame.headers 0 0 legacy h member).1

theorem header_syntax {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (tables : List ReadOnlyMatrix.Record)
    (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record) (frame : NameFrameMatrix.Record)
    (checked : NameFrameMatrix.check matrix tokens tables imports owned frame = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (message : List Sha256.Byte)
    (grammar : ∀ r ∈ tokens, r.kind = 1 → E values r.activeMode = 1 →
      ∃ position length, position < 2^32 ∧ position+length ≤ message.length ∧
        E values r.position = (position : F) ∧ E values r.length = (length : F) ∧
        BinaryTokenSyntax.U32 length (fun i => (message.getD (position+i) 0).toNat))
    (h : NameFrameMatrix.Header) (member : h ∈ frame.headers) (active : E values (NameFrameMatrix.hget h 0) = 1) :
    HeaderSyntax values h message := by
  have hc := header_checked matrix tokens tables imports owned frame checked h member
  have shape := NameFrameRules.header_shape matrix tokens frame.flat h hc
  have tm : EnvelopeMatrix.token tokens h.token ∈ tokens := by
    rw [EnvelopeMatrix.token,← List.getElem_eq_getD default]
    exact List.getElem_mem shape.2.1
  obtain ⟨p,l,pb,inside,pi,li,valid⟩ := grammar _ tm shape.2.2.1 (by rw [shape.2.2.2.1]; exact active)
  have start : E values (NameFrameMatrix.hget h 2) = (p : F) := by rw [← shape.2.2.2.2.1]; exact pi
  have finish := NameFrameRules.header_step matrix tokens frame.flat h hc values oneValue satisfied
  refine ⟨p,l,pb,inside,start,?_,valid⟩
  rw [finish,start,li,Semiring.natCast_add]

/-- Source-name strings and their concrete U32 syntax are certified against
    the same public digest. No continuation or overflow bit is assumed. -/
theorem module_verified {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record)
    (frame : NameFrameMatrix.Record) (graph : NameGraphMatrix.Record) (source : NameSourceMatrix.Record)
    (checked : NameSourceSound.check matrix body tables splits declaration indexed signature space imports owned frame graph source = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ message : List Sha256.Byte,
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      (∀ i, i < frame.headers.length → E values (NameFrameMatrix.hget (frame.headers.getD i default) 0) = 1 →
        BoundName values (NameGraphMatrix.table tables graph 0) (frame.headers.getD i default) (source.headers.getD i default) message) ∧
      ∀ h ∈ frame.headers, E values (NameFrameMatrix.hget h 0) = 1 → HeaderSyntax values h message := by
  obtain ⟨message,meaning,d0,d1,unique,_,names⟩ := NameSourceSoundness.module_verified matrix body tables splits declaration indexed signature space imports owned frame graph source checked values oneValue satisfied
  have gp := Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1
  have fp := Bool.and_eq_true_iff.mp gp.1
  have op := Bool.and_eq_true_iff.mp fp.1
  have signatureCheck := (Bool.and_eq_true_iff.mp op.1).1
  have indexedCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp signatureCheck).1).1
  have moduleCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp indexedCheck).1).1
  have envelopeCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp moduleCheck).1).1
  have tokenCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp envelopeCheck).1).1
  obtain ⟨other,otherMeaning,_,_,grammar⟩ := BinaryTokenSyntax.checked_u32 matrix body.source body.hash body.memory body.queries body.tokens tokenCheck values oneValue satisfied
  have same := unique other otherMeaning
  subst other
  exact ⟨message,meaning,d0,d1,names,header_syntax matrix body.tokens tables imports owned frame fp.2 values oneValue satisfied message grammar⟩

#print axioms header_checked
#print axioms header_syntax
#print axioms module_verified
end ZkBuild.NameSourceSyntax

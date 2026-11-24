import ShaHashSound
import GadgetAudit

namespace ZkBuild.ShaEmbedded

open Lean.Grind CircuitShape FullMatrix GadgetShape ShaProgram ShaHash ShaHashSound
attribute [local instance] Ring.intCast Semiring.natCast

theorem cached_bounded_sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (one : values 0 = 1) (source : List Linear) (length : Linear)
    (bits : Fin 32 → Linear) (digest : Fin 2 → Linear) (message : List Sha256.Byte)
    (capacity : source.length < 2^32) (bounded : message.length < 2^32)
    (image : E values length = (message.length : F))
    (sourceImages : ∀ position, position < message.length →
      E values (inputByte source position) = ((message.getD position 0).toNat : F))
    (certificate : RangeReuse.Certificate 32 (E values length) ((List.ofFn bits).map (E values))) :
    Ensures values (cachedM source length bits digest) (fun _ =>
      message.length ≤ source.length ∧ E values (digest 0) = (digestLimb message 0 : F) ∧ E values (digest 1) = (digestLimb message 1 : F)) := by
  rw [image] at certificate
  obtain ⟨meaning,represented,bitValue⟩ := ShaScalar.certificate_rep values 32 message.length bits
    (by decide) bounded certificate
  unfold cachedM
  apply bind_sound values _ _ _ _ (ShaHashLength.prepare_bits_sound values one source.length message.length
    length bits meaning capacity bounded image represented bitValue)
  intro context prepared
  constructor
  intro start holds
  have finished := (finish_sound values one source length digest context message meaning capacity prepared.2.2.1
    image sourceImages prepared.1 prepared.2.1 prepared.2.2.2).run start holds
  exact ⟨prepared.2.2.1,finished⟩

theorem cached_sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (one : values 0 = 1) (source : List Linear) (length : Linear)
    (bits : Fin 32 → Linear) (digest : Fin 2 → Linear) (message : List Sha256.Byte)
    (capacity : source.length < 2^32) (fits : message.length ≤ source.length)
    (image : E values length = (message.length : F))
    (sourceImages : ∀ position, position < message.length →
      E values (inputByte source position) = ((message.getD position 0).toNat : F))
    (certificate : RangeReuse.Certificate 32 (E values length) ((List.ofFn bits).map (E values))) :
    Ensures values (cachedM source length bits digest) (fun _ =>
      E values (digest 0) = (digestLimb message 0 : F) ∧ E values (digest 1) = (digestLimb message 1 : F)) := by
  constructor
  intro start holds
  exact ((cached_bounded_sound values one source length bits digest message capacity (by omega) image
    sourceImages certificate).run start holds).2

structure Record where
  range : GadgetAudit.Record
  firstWire : Nat
  lastWire : Nat
  firstGate : Nat
  lastGate : Nat
  source : List Linear
  length : Linear
  digestOutputs : List Linear
  deriving Inhabited

def bits (r : Record) : Fin 32 → Linear := fun i => r.range.outputs.getD i.val (constant 0)
def digest : Fin 2 → Linear := fun i => wire (i.val+1)

def program (r : Record) : Step HashState := cachedM r.source r.length (bits r) digest r.firstWire

def span (r : Record) : GadgetAudit.Record :=
  { kind := 0, width := 0, firstWire := r.firstWire, lastWire := r.lastWire,
    firstGate := r.firstGate, lastGate := r.lastGate, reference := 0, inputs := [], outputs := [wire 1,wire 2] }

def expected (r : Record) : Artifact :=
  ⟨{ wires := (program r).next, gates := (program r).gates.toArray },[wire 1,wire 2]⟩

def metadata (matrix : Shape) (r : Record) : Prop :=
  matrix.publicCount = 2 ∧ r.range.kind = 8 ∧ r.range.width = 32 ∧
  r.range.inputs = [r.length] ∧ r.range.outputs.length = 32 ∧
  r.range.lastWire ≤ r.firstWire ∧ r.range.lastGate ≤ r.firstGate ∧
  0 < r.firstWire ∧ r.firstWire ≤ r.lastWire ∧ r.lastWire ≤ matrix.wires ∧
  r.firstGate ≤ r.lastGate ∧ r.lastGate ≤ matrix.gates.size ∧ r.source.length < 2^32 ∧
  r.digestOutputs = [wire 1,wire 2]

instance (matrix : Shape) (r : Record) : Decidable (metadata matrix r) := by
  unfold metadata
  infer_instance

def check (matrix : Shape) (r : Record) : Bool :=
  decide (metadata matrix r) && (GadgetAudit.check matrix r.range none &&
    conforms (GadgetAudit.fragment matrix (span r)) (expected r))

private theorem list_bits (r : Record) (size : r.range.outputs.length = 32) :
    List.ofFn (bits r) = r.range.outputs := by
  apply List.ext_getElem
  · simp [size]
  · intro i left right
    simp only [bits,List.getElem_ofFn]
    exact (List.getElem_eq_getD (constant 0)).symm

theorem checked_digest {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : Record) (accepted : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (message : List Sha256.Byte) (fits : message.length ≤ r.source.length)
    (image : E values r.length = (message.length : F))
    (sourceImages : ∀ position, position < message.length →
      E values (inputByte r.source position) = ((message.getD position 0).toNat : F)) :
    values 1 = (digestLimb message 0 : F) ∧ values 2 = (digestLimb message 1 : F) := by
  have acceptedParts := Bool.and_eq_true_iff.mp accepted
  have shape : metadata matrix r := _root_.of_decide_eq_true acceptedParts.1
  have checks := Bool.and_eq_true_iff.mp acceptedParts.2
  obtain ⟨_,kind,width,input,size,_,_,_,_,_,_,_,capacity,_⟩ := shape
  have certificate := GadgetAudit.checked_unsigned matrix r.range r.length kind input checks.1 values one satisfied
  rw [width,← list_bits r size] at certificate
  have relation := conformance_relation (GadgetAudit.fragment matrix (span r)) (expected r) checks.2 values
  have holds : AllHold values (program r).gates := by
    have model := relation.1.mp (GadgetAudit.fragment_satisfied matrix (span r) values satisfied)
    simpa [expected,Satisfied,AllHold,Holds] using model
  have result := (cached_sound values one r.source r.length (bits r) digest message capacity fits image
    sourceImages certificate).run r.firstWire holds
  simpa only [digest,eval_wire,Fin.val_zero,Fin.val_one] using result

#print axioms cached_bounded_sound
#print axioms cached_sound
#print axioms checked_digest

end ZkBuild.ShaEmbedded

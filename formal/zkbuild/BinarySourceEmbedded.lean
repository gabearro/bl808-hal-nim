import BinarySourceMatrix

namespace ZkBuild.BinarySourceEmbedded

open Lean.Grind CircuitShape FullMatrix GadgetShape ShaProgram BinarySourceMatrix
attribute [local instance] Ring.intCast Semiring.natCast

structure Record where
  range : GadgetAudit.Record
  firstWire : Nat
  lastWire : Nat
  firstGate : Nat
  lastGate : Nat
  capacity : Nat
  length : Linear
  limbs : List Linear
  outputs : List Linear
  deriving Inhabited

def span (r : Record) : GadgetAudit.Record :=
  { kind := 0,width := 0,firstWire := r.firstWire,lastWire := r.lastWire,
    firstGate := r.firstGate,lastGate := r.lastGate,reference := 0,inputs := [],outputs := r.outputs }

def expected (r : Record) : Artifact := BinarySourceMatrix.artifact r.firstWire r.capacity r.length r.limbs

def metadata (matrix : Shape) (r : Record) : Prop :=
  r.range.kind = 8 ∧ r.range.width = 32 ∧ r.range.inputs = [r.length] ∧
  r.range.lastWire ≤ r.firstWire ∧ r.range.lastGate ≤ r.firstGate ∧
  0 < r.firstWire ∧ r.firstWire ≤ r.lastWire ∧ r.lastWire ≤ matrix.wires ∧
  r.firstGate ≤ r.lastGate ∧ r.lastGate ≤ matrix.gates.size ∧ r.capacity < 2^32 ∧
  r.limbs.length = (r.capacity+30)/31 ∧ r.outputs = BinarySourceMatrix.outputs r.firstWire r.capacity

instance (matrix : Shape) (r : Record) : Decidable (metadata matrix r) := by
  unfold metadata
  infer_instance

def check (matrix : Shape) (r : Record) : Bool :=
  decide (metadata matrix r) && (GadgetAudit.check matrix r.range none &&
    conforms (GadgetAudit.fragment matrix (span r)) (expected r))

def byteInputs (r : Record) : List Linear :=
  (entries r.firstWire r.capacity).map Entry.value

theorem checked_holds {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : Record) (accepted : check matrix r = true)
    (values : Nat → F) (satisfied : Satisfied matrix values) :
    AllHold values (BinarySourceMatrix.gates r.firstWire r.capacity r.length r.limbs) := by
  have checks := Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp accepted).2
  have relation := conformance_relation (GadgetAudit.fragment matrix (span r)) (expected r) checks.2 values
  have model := relation.1.mp (GadgetAudit.fragment_satisfied matrix (span r) values satisfied)
  simpa [expected,BinarySourceMatrix.artifact,Satisfied,AllHold,Holds] using model

theorem checked_message {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : Record) (accepted : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ message : List Sha256.Byte, message.length ≤ r.capacity ∧ E values r.length = (message.length : F) ∧
      ∀ index, index < r.capacity →
        E values (entry r.firstWire index).active = (if index < message.length then 1 else 0) ∧
        E values (entry r.firstWire index).value = ((message.getD index 0).toNat : F) ∧
        E values (entry r.firstWire index).address = (if index < message.length then (index : F) else 0) :=
  source_message values one r.firstWire r.capacity r.length r.limbs (checked_holds matrix r accepted values satisfied)


theorem checked_unique_message {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : Record) (accepted : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ message : List Sha256.Byte, Message values r.firstWire r.capacity r.length message ∧
      ∀ other, Message values r.firstWire r.capacity r.length other → other = message := by
  have shape : metadata matrix r := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp accepted).1
  obtain ⟨_,_,_,_,_,_,_,_,_,_,capacity,_,_⟩ := shape
  exact unique_source values one r.firstWire r.capacity r.length r.limbs capacity
    (checked_holds matrix r accepted values satisfied)

def checkLinked (matrix : Shape) (source : Record) (hash : ShaEmbedded.Record) : Bool :=
  check matrix source && (ShaEmbedded.check matrix hash &&
    decide (hash.source = byteInputs source ∧ hash.length = source.length))

theorem linked_digest {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (source : Record) (hash : ShaEmbedded.Record)
    (accepted : checkLinked matrix source hash = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ message : List Sha256.Byte, message.length ≤ source.capacity ∧
      E values source.length = (message.length : F) ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      ∀ index, index < source.capacity →
        E values (entry source.firstWire index).active = (if index < message.length then 1 else 0) ∧
        E values (entry source.firstWire index).value = ((message.getD index 0).toNat : F) ∧
        E values (entry source.firstWire index).address = (if index < message.length then (index : F) else 0) := by
  have parts := Bool.and_eq_true_iff.mp accepted
  have rest := Bool.and_eq_true_iff.mp parts.2
  have linked : hash.source = byteInputs source ∧ hash.length = source.length := _root_.of_decide_eq_true rest.2
  obtain ⟨message,fit,lengthImage,rows⟩ := checked_message matrix source parts.1 values one satisfied
  have capacity : hash.source.length = source.capacity := by simp [linked.1,byteInputs,entries]
  have hashInputs : ∀ index, index < message.length → E values (ShaHash.inputByte hash.source index) =
      ((message.getD index 0).toNat : F) := by
    intro index inside
    have bound : index < source.capacity := by omega
    have point := (rows index bound).2.1
    simpa only [linked.1,ShaHash.inputByte,byteInputs,entries,List.map_map,Function.comp_def,
      List.getD_eq_getElem?_getD,List.getElem?_map,List.getElem?_range bound,Option.map_some,Option.getD_some] using point
  have result := ShaEmbedded.checked_digest matrix hash rest.1 values one satisfied message (by omega)
    (by simpa only [linked.2] using lengthImage) hashInputs
  exact ⟨message,fit,lengthImage,result.1,result.2,rows⟩


theorem linked_unique_digest {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (source : Record) (hash : ShaEmbedded.Record)
    (accepted : checkLinked matrix source hash = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ message : List Sha256.Byte, Message values source.firstWire source.capacity source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      ∀ other, Message values source.firstWire source.capacity source.length other → other = message := by
  obtain ⟨message,fit,lengthImage,d0,d1,rows⟩ := linked_digest matrix source hash accepted values one satisfied
  have meaning : Message values source.firstWire source.capacity source.length message := ⟨fit,lengthImage,rows⟩
  have checked := (Bool.and_eq_true_iff.mp accepted).1
  obtain ⟨unique,uniqueMeaning,uniqueness⟩ := checked_unique_message matrix source checked values one satisfied
  have same := uniqueness message meaning
  exact ⟨message,meaning,d0,d1,by intro other h; exact (uniqueness other h).trans same.symm⟩

#print axioms checked_message
#print axioms linked_digest
#print axioms checked_unique_message
#print axioms linked_unique_digest

end ZkBuild.BinarySourceEmbedded

import BinaryTokenMatrix
import BinaryReadMemory

namespace ZkBuild.BinaryTokenEmbedded

open Lean.Grind CircuitShape FullMatrix GadgetShape
attribute [local instance] Ring.intCast Semiring.natCast

def check (matrix : Shape) (source : BinarySourceEmbedded.Record) (hash : ShaEmbedded.Record)
    (memory : MemoryEmbedded.Record) (queries : List BinarySourceMatrix.Entry)
    (tokens : List BinaryTokenMatrix.Record) : Bool :=
  BinaryReadMemory.check matrix source hash memory queries && tokens.all (BinaryTokenMatrix.check matrix) &&
  decide (tokens.flatMap BinaryTokenMatrix.queries = queries) &&
  tokens.all (fun r => decide (r.sourceLength = source.length))

theorem checked_tokens {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (source : BinarySourceEmbedded.Record) (hash : ShaEmbedded.Record)
    (memory : MemoryEmbedded.Record) (queries : List BinarySourceMatrix.Entry)
    (tokens : List BinaryTokenMatrix.Record) (accepted : check matrix source hash memory queries tokens = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ message : List Sha256.Byte,
      BinarySourceMatrix.Message values source.firstWire source.capacity source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      (∀ other, BinarySourceMatrix.Message values source.firstWire source.capacity source.length other → other = message) ∧
      ∀ r ∈ tokens, AllHold values (BinaryTokenMatrix.gates r) ∧
        RangeReuse.Certificate (BinaryTokenMatrix.width r.kind) (E values r.value) ((RangeUse.bits r.valueRange).map (E values)) ∧
        RangeReuse.Certificate 4 (E values r.length) ((RangeUse.bits r.lengthRange).map (E values)) ∧
        (∀ row ∈ r.rows, RangeReuse.Certificate 8 (E values row.value) ((RangeUse.bits row.byteRange).map (E values))) ∧
        ∀ q ∈ BinaryTokenMatrix.queries r, E values q.active = 1 → ∃ index, index < message.length ∧
          E values q.address = (index : F) ∧ E values q.value = ((message.getD index 0).toNat : F) := by
  have parts : BinaryReadMemory.check matrix source hash memory queries = true ∧
      tokens.all (BinaryTokenMatrix.check matrix) = true ∧
      (tokens.flatMap BinaryTokenMatrix.queries = queries ∧ ∀ r ∈ tokens, r.sourceLength = source.length) := by
    simpa only [check,Bool.and_eq_true_iff,List.all_eq_true,decide_eq_true_eq,and_assoc] using accepted
  obtain ⟨message,meaning,d0,d1,unique,querySound⟩ := BinaryReadMemory.checked_queries matrix source hash memory queries parts.1 values one satisfied
  refine ⟨message,meaning,d0,d1,unique,?_⟩
  intro r member
  have acceptedToken := List.all_eq_true.mp parts.2.1 r member
  have ranges := BinaryTokenMatrix.checked_ranges matrix r acceptedToken values one satisfied
  refine ⟨BinaryTokenMatrix.checked_holds matrix r acceptedToken values satisfied,ranges.2.1,ranges.2.2.1,
    (by intro row rm; exact (ranges.2.2.2 row rm).1),?_⟩
  intro q qm active
  apply querySound q _ active
  rw [← parts.2.2.1]
  exact List.mem_flatMap.mpr ⟨r,member,qm⟩

#print axioms checked_tokens
end ZkBuild.BinaryTokenEmbedded

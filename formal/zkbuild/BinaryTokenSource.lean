import BinaryTokenSchedule

namespace ZkBuild.BinaryTokenSource

open Lean.Grind CircuitShape FullMatrix GadgetShape BinaryTokenMatrix
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Semiring.natCast_zero Semiring.natCast_one Ring.intCast_zero Ring.intCast_one

theorem indexes (i : Nat) (present : Linear) (rows : List Row) :
    (rowInputs i present rows).map Prod.fst = List.range' i rows.length := by
  induction rows generalizing i present with
  | nil => rfl
  | cons row rest ih => simp only [rowInputs,List.map_cons,List.length_cons,List.range'_succ,ih]

/-- Each reader's active bytes form a consecutive in-bounds span of the unique
    message whose SHA-256 digest is public. No decoded metadata is assumed. -/
theorem checked_spans {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (source : BinarySourceEmbedded.Record) (hash : ShaEmbedded.Record)
    (memory : MemoryEmbedded.Record) (queries : List BinarySourceMatrix.Entry)
    (tokens : List Record) (accepted : BinaryTokenEmbedded.check matrix source hash memory queries tokens = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ message : List Sha256.Byte,
      BinarySourceMatrix.Message values source.firstWire source.capacity source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      (∀ other, BinarySourceMatrix.Message values source.firstWire source.capacity source.length other → other = message) ∧
      ∀ r ∈ tokens, ∃ position length : Nat,
        position < 2^32 ∧ length ≤ capacity r.kind ∧
        E values r.position = (position : F) ∧ E values r.length = (length : F) ∧
        E values (active r) = (if length = 0 then 0 else 1) ∧
        (0 < length → position+length ≤ message.length) ∧
        ∀ item ∈ rowInputs 0 (active r) r.rows, item.1 < length →
          position+item.1 < message.length ∧
          E values item.2.2.value = ((message.getD (position+item.1) 0).toNat : F) := by
  have parts : BinaryReadMemory.check matrix source hash memory queries = true ∧
      tokens.all (BinaryTokenMatrix.check matrix) = true ∧
      tokens.flatMap BinaryTokenMatrix.queries = queries ∧
      ∀ r ∈ tokens, r.sourceLength = source.length := by
    simpa only [BinaryTokenEmbedded.check,Bool.and_eq_true_iff,List.all_eq_true,decide_eq_true_eq,and_assoc] using accepted
  obtain ⟨message,meaning,d0,d1,unique,tokenSound⟩ := BinaryTokenEmbedded.checked_tokens matrix source hash memory queries tokens accepted values oneValue satisfied
  have linkedCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts.1).1).1
  have sourceCheck := (Bool.and_eq_true_iff.mp linkedCheck).1
  have metadata : BinarySourceEmbedded.metadata matrix source := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp sourceCheck).1
  have sourceCap : source.capacity < 2^32 := metadata.2.2.2.2.2.2.2.2.2.2.1
  refine ⟨message,meaning,d0,d1,unique,?_⟩
  intro r member
  have tokenCheck := List.all_eq_true.mp parts.2.1 r member
  obtain ⟨length,lenBound,lenImage,activity,schedule⟩ := BinaryTokenSchedule.checked_schedule matrix r tokenCheck values oneValue satisfied
  have ranges := BinaryTokenMatrix.checked_ranges matrix r tokenCheck values oneValue satisfied
  obtain ⟨position,posBound,posImage⟩ := RangeReuse.certificate_sound _ _ _ ranges.1
  have facts := tokenSound r member
  have cap : capacity r.kind ≤ 10 := by unfold capacity; grind
  have readByte (item : Nat × Linear × Row) (inside : item ∈ rowInputs 0 (active r) r.rows) (used : item.1 < length) :
      position+item.1 < message.length ∧ E values item.2.2.value = ((message.getD (position+item.1) 0).toNat : F) := by
    have step := schedule item inside
    let q : BinarySourceMatrix.Entry := ⟨item.2.1,item.2.2.address,item.2.2.value⟩
    have qm : q ∈ BinaryTokenMatrix.queries r := List.mem_map.mpr ⟨item,inside,rfl⟩
    have qa : E values q.active = 1 := by simpa [q,used] using step.1
    obtain ⟨index,indexBound,addressImage,byte⟩ := facts.2.2.2.2 q qm qa
    have sumImage : E values item.2.2.address = ((position+item.1 : Nat) : F) := by
      rw [step.2,step.1,ite_eq_left used,posImage,Semiring.one_mul,Semiring.natCast_add]
    have smallSum : position+item.1 < scalarModulus := by
      have big : 2^32+10 < scalarModulus := by decide
      omega
    have smallIndex : index < scalarModulus := by
      have big := RangeConstraints.power_below_modulus 32 (by decide)
      have fit := meaning.1
      omega
    have equal : (position+item.1 : Nat) = index :=
      (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus smallSum smallIndex).mp (sumImage.symm.trans addressImage)
    exact ⟨by simpa [equal] using indexBound,by simpa [q,equal] using byte⟩
  refine ⟨position,length,posBound,lenBound,posImage,lenImage,activity,?_,readByte⟩
  intro nonzero
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp
    (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp tokenCheck).1).1).1).1).1
  have size : r.rows.length = capacity r.kind := shape.2.1
  have image : (rowInputs 0 (active r) r.rows).map Prod.fst = List.range r.rows.length := by
    simpa [List.range_eq_range'] using indexes 0 (active r) r.rows
  have included : length-1 ∈ (rowInputs 0 (active r) r.rows).map Prod.fst := by
    rw [image]
    apply List.mem_range.mpr
    omega
  obtain ⟨item,itemMember,index⟩ := List.mem_map.mp included
  have last := readByte item itemMember (by omega)
  omega

#print axioms checked_spans
end ZkBuild.BinaryTokenSource

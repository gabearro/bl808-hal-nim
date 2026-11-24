import BinaryTokenDecoded

namespace ZkBuild.BinaryTokenSound
open Lean.Grind CircuitShape FullMatrix GadgetShape BinaryTokenMatrix BinaryVariantFields
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def Result {F : Type} [Field F] (values : Nat → F) (r : Record) (message : List Sha256.Byte)
    (position length : Nat) : Prop :=
  position < 2^32 ∧ length ≤ 10 ∧ E values r.position = (position : F) ∧ E values r.length = (length : F) ∧
  ((length = 0 ∧ E values r.value = 0) ∨
    ∃ kind : Nat, kind < 7 ∧ 0 < length ∧ length ≤ capacity kind ∧ position+length ≤ message.length ∧
      E values r.value = (TokenInteger.decode kind length (fun i => (message.getD (position+i) 0).toNat) : F) ∧
      ((r.kind = 7 ∧ E values r.activeMode = ((kind+1 : Nat) : F)) ∨ r.kind = kind))

/-- Every audited reader returns zero when absent, or the selected integer
    decoded from an in-bounds span of the unique public-digest message. -/
theorem checked_decoding {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (source : BinarySourceEmbedded.Record) (hash : ShaEmbedded.Record)
    (memory : MemoryEmbedded.Record) (queries : List BinarySourceMatrix.Entry) (tokens : List Record)
    (accepted : BinaryTokenEmbedded.check matrix source hash memory queries tokens = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ message : List Sha256.Byte,
      BinarySourceMatrix.Message values source.firstWire source.capacity source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      (∀ other, BinarySourceMatrix.Message values source.firstWire source.capacity source.length other → other = message) ∧
      ∀ r ∈ tokens, ∃ position length, Result values r message position length := by
  have parts : BinaryReadMemory.check matrix source hash memory queries = true ∧
      tokens.all (BinaryTokenMatrix.check matrix) = true ∧ tokens.flatMap BinaryTokenMatrix.queries = queries ∧
      ∀ r ∈ tokens, r.sourceLength = source.length := by
    simpa only [BinaryTokenEmbedded.check,Bool.and_eq_true_iff,List.all_eq_true,decide_eq_true_eq,and_assoc] using accepted
  obtain ⟨message,meaning,d0,d1,unique,spans⟩ := BinaryTokenSource.checked_spans matrix source hash memory queries tokens accepted values oneValue satisfied
  refine ⟨message,meaning,d0,d1,unique,?_⟩
  intro r member
  have check := List.all_eq_true.mp parts.2.1 r member
  obtain ⟨position,length,posBound,lenBound,posImage,lenImage,activity,spanBound,bytes⟩ := spans r member
  have cap : capacity r.kind ≤ 10 := by unfold capacity; grind
  refine ⟨position,length,posBound,by omega,posImage,lenImage,?_⟩
  by_cases absent : length = 0
  · left
    refine ⟨absent,?_⟩
    apply BinaryTokenDecoded.zero_length_value matrix r check values oneValue satisfied
    simpa [absent] using lenImage
  · right
    have positive : 0 < length := by omega
    let input := fun i => (message.getD (position+i) 0).toNat
    have sourceBytes : ∀ item ∈ rowInputs 0 (active r) r.rows, item.1 < length →
        input item.1 < 256 ∧ E values item.2.2.value = (input item.1 : F) := by
      intro item im used
      exact ⟨BitVec.isLt _,(bytes item im used).2⟩
    by_cases variant : r.kind = 7
    · obtain ⟨mode,modeBound,modeImage,absentImage,_⟩ := BinaryTokenSchedule.checked_variant_mode matrix r check variant values oneValue satisfied
      have modePositive : 0 < mode := by
        by_cases isZero : mode = 0
        · have pro : AllHold values (prologue r) := by
            intro g gm; exact checked_holds matrix r check values satisfied g (List.mem_append_left _ gm)
          have gm : eqGate (BinaryTokenMatrix.absent r ++ active r) one ∈ prologue r := by
            simp only [prologue,variant,↓reduceIte,List.mem_append,List.mem_cons]; grind
          have total := equality_sound values oneValue _ _ (pro _ gm)
          have addition : E values (BinaryTokenMatrix.absent r ++ active r) = E values (BinaryTokenMatrix.absent r)+E values (active r) := eval_cat values _ _
          have oneImage : E values one = 1 := by simp [one,eval_constant values oneValue]
          rw [addition,oneImage,activity,ite_eq_right absent,absentImage,ite_eq_left isZero] at total
          have impossible : (0 : F) = 1 := by grind
          exact False.elim (Field.zero_ne_one impossible)
        · omega
      let kind := mode-1
      have small : kind < 7 := by dsimp [kind]; omega
      have image : E values r.activeMode = ((kind+1 : Nat) : F) := by
        have same : kind+1 = mode := by dsimp [kind]; omega
        simpa [same] using modeImage
      obtain ⟨actual,_,actualBound,actualImage,_⟩ := BinaryVariantFormat.checked_length matrix r check variant kind small values oneValue satisfied image
      have ck : capacity kind ≤ 10 := by unfold capacity; grind
      have same : actual = length := BinaryTokenDecoded.small_nat_unique actual length (by omega) (by omega) (actualImage.symm.trans lenImage)
      have bound : length ≤ capacity kind := by simpa [same] using actualBound
      refine ⟨kind,small,positive,bound,spanBound positive,?_,Or.inl ⟨variant,image⟩⟩
      exact BinaryTokenDecoded.variant_value matrix r check variant kind small values oneValue satisfied image length (by omega) lenImage input sourceBytes
    · have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp
        (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp check).1).1).1).1).1
      have small : r.kind < 7 := by have upper := shape.1; omega
      refine ⟨r.kind,small,positive,lenBound,spanBound positive,?_,Or.inr rfl⟩
      exact BinaryTokenDecoded.normal_value matrix r check variant values oneValue satisfied length positive lenBound lenImage input sourceBytes

#print axioms checked_decoding
end ZkBuild.BinaryTokenSound

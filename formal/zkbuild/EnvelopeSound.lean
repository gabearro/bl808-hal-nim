import EnvelopePayload

namespace ZkBuild.EnvelopeSound
open Lean.Grind CircuitShape FullMatrix GadgetShape EnvelopeMatrix EnvelopeRanges
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

/-- A raw byte decoder preserves the entire byte, including its high bit. -/
theorem decode_byte (bytes : Nat → Nat) (bound : bytes 0 < 256) :
    TokenInteger.decode 0 1 bytes = bytes 0 := by
  apply Nat.eq_of_testBit_eq
  intro i
  rw [TokenInteger.decode,TokenInteger.packed_testBit]
  by_cases small : i < 8
  · simp [TokenInteger.map_getD, List.getD_eq_getElem?_getD, List.getElem?_range,
      BinaryTokenMatrix.width, TokenInteger.decodedBit,BinaryTokenMatrix.leb,small,
      Nat.div_eq_of_lt small,Nat.mod_eq_of_lt small]
  · have power : 2^8 ≤ 2^i := Nat.pow_le_pow_right (by decide) (by omega)
    have high : (bytes 0).testBit i = false := Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le bound power)
    simp [BinaryTokenMatrix.width,List.getD_eq_getElem?_getD,List.getElem?_map,
      List.getElem?_range,small,high]

theorem byte_result {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : BinaryTokenMatrix.Record) (accepted : BinaryTokenMatrix.check matrix r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (message : List Sha256.Byte) (position length index expected : Nat)
    (indexBound : index < 2^32) (expectedBound : expected < 256)
    (shape : tokenMatches r 0 BinaryTokenMatrix.one (BinaryTokenMatrix.nat index) (BinaryTokenMatrix.nat expected))
    (result : BinaryTokenSound.Result values r message position length) :
    index < message.length ∧ (message.getD index 0).toNat = expected := by
  rcases shape with ⟨kind,active,positionTerm,valueTerm⟩
  obtain ⟨actual,actualBound,actualImage,activity,_⟩ := BinaryTokenSchedule.checked_length matrix r accepted values oneValue satisfied
  have enabled : E values (BinaryTokenMatrix.active r) = 1 := by
    simp [BinaryTokenMatrix.active,kind,active,BinaryTokenMatrix.one,eval_constant values oneValue,Ring.intCast_natCast]
  have actualPositive : actual ≠ 0 := by
    intro zero
    rw [zero] at activity
    have impossible : (0 : F) = 1 := by simpa only [ite_true] using activity.symm.trans enabled
    exact Field.zero_ne_one impossible
  have actualOne : actual = 1 := by
    have short : actual ≤ 1 := by simpa [kind,BinaryTokenMatrix.capacity] using actualBound
    omega
  rcases result with ⟨posBound,lenBound,posImage,lenImage,body⟩
  have sameLength : actual = length := BinaryTokenDecoded.small_nat_unique actual length (by omega) (by omega) (actualImage.symm.trans lenImage)
  have lengthOne : length = 1 := by omega
  have posConst : E values r.position = (index : F) := by
    rw [positionTerm]; simp [BinaryTokenMatrix.nat,eval_constant values oneValue,Ring.intCast_natCast]
  have big : 2^32 < scalarModulus := by decide
  have samePosition : position = index := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (by omega) (by omega)).mp (posImage.symm.trans posConst)
  rcases body with absent | ⟨decodedKind,_,positive,_,inside,decoded,selected⟩
  · omega
  · have decodedZero : decodedKind = 0 := by
      rcases selected with variant | normal
      · omega
      · omega
    have valueConst : E values r.value = (expected : F) := by
      rw [valueTerm]; simp [BinaryTokenMatrix.nat,eval_constant values oneValue,Ring.intCast_natCast]
    have byteBound := (message.getD index 0).isLt
    rw [samePosition,lengthOne,decodedZero,decode_byte _ byteBound] at decoded
    have same : (message.getD index 0).toNat = expected :=
      (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (Nat.lt_trans byteBound (by decide)) (Nat.lt_trans expectedBound (by decide))).mp
        (decoded.symm.trans valueConst)
    exact ⟨by omega,same⟩

/-- Authenticate the byte source, header, section spans, ordering and directory.
    Payload grammar and instruction typing are separate layers. -/
def check (matrix : Shape) (source : BinarySourceEmbedded.Record) (hash : ShaEmbedded.Record)
    (memory : MemoryEmbedded.Record) (queries : List BinarySourceMatrix.Entry)
    (tokens : List BinaryTokenMatrix.Record) (envelope : EnvelopeMatrix.Record) : Bool :=
  BinaryTokenEmbedded.check matrix source hash memory queries tokens &&
    decide (envelope.sourceLength = source.length) && EnvelopeMatrix.check matrix envelope tokens

theorem checked_envelope {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (source : BinarySourceEmbedded.Record) (hash : ShaEmbedded.Record)
    (memory : MemoryEmbedded.Record) (queries : List BinarySourceMatrix.Entry)
    (tokens : List BinaryTokenMatrix.Record) (envelope : EnvelopeMatrix.Record)
    (accepted : check matrix source hash memory queries tokens envelope = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ (message : List Sha256.Byte) (sections : List Decoded),
      BinarySourceMatrix.Message values source.firstWire source.capacity source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      (∀ other, BinarySourceMatrix.Message values source.firstWire source.capacity source.length other → other = message) ∧
      (∀ r ∈ tokens, ∃ position length, BinaryTokenSound.Result values r message position length) ∧
      (∀ i, i < 8 → (message.getD i 0).toNat = header.getD i 0) ∧
      ShaProgram.Related (EnvelopeRanges.Represents values) envelope.rows sections ∧
      (∀ d ∈ sections, Bounded d) ∧ BinaryEnvelope.Chain 8 (activeSpans sections) message.length ∧ EnvelopeOrder.OrderedFrom 0 sections ∧
      ∃ cs : List EnvelopeDirectory.Contribution, cs.map EnvelopeDirectory.Contribution.entry = sections ∧
        (∀ c ∈ cs, c.wordLength ≤ 5) ∧ (∀ c ∈ cs, EnvelopePayload.Fits c) ∧ envelope.outputs.map (E values) = EnvelopeDirectory.outputValues cs := by
  have parts : BinaryTokenEmbedded.check matrix source hash memory queries tokens = true ∧
      envelope.sourceLength = source.length ∧ EnvelopeMatrix.check matrix envelope tokens = true := by
    simpa only [check,Bool.and_eq_true_iff,decide_eq_true_eq,and_assoc] using accepted
  obtain ⟨message,meaning,d0,d1,unique,decoded⟩ := BinaryTokenSound.checked_decoding matrix source hash memory queries tokens parts.1 values oneValue satisfied
  have tokenParts := Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts.1).1).1
  have tokenChecks := tokenParts.2
  have linked := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp tokenParts.1).1).1
  have sourceCheck := (Bool.and_eq_true_iff.mp linked).1
  have sourceShape : BinarySourceEmbedded.metadata matrix source := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp sourceCheck).1
  have capacityBound : source.capacity < 2^32 := sourceShape.2.2.2.2.2.2.2.2.2.2.1
  have lengthBound : message.length < 2^32 := Nat.lt_of_le_of_lt meaning.1 capacityBound
  have envelopeParts := Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts.2.2).1
  have headers := (Bool.and_eq_true_iff.mp envelopeParts.1).2
  have rows := envelopeParts.2
  have all := EnvelopeMatrix.checked_holds matrix envelope tokens parts.2.2 values satisfied
  have chainGates : AllHold values (walk envelope.sourceLength tokens envelope.rows (BinaryTokenMatrix.nat 8) (BinaryTokenMatrix.nat 0) BinaryTokenMatrix.one initialTotals) := by
    intro g gm; exact all g (List.mem_append_right _ gm)
  have sourceImage : E values envelope.sourceLength = (message.length : F) := by rw [parts.2.1]; exact meaning.2.1
  have cursorImage : E values (BinaryTokenMatrix.nat 8) = ((8 : Nat) : F) := by
    exact (eval_constant values oneValue (Int.ofNat 8)).trans (Ring.intCast_natCast 8)
  obtain ⟨sections,represented,bounds,chain⟩ := EnvelopeChain.walk_chain matrix tokens tokenChecks envelope.sourceLength envelope.rows rows values oneValue satisfied
    message.length 8 lengthBound (by decide) sourceImage _ _ _ _ cursorImage chainGates
  have rankImage : E values (BinaryTokenMatrix.nat 0) = ((0 : Nat) : F) := by simp [BinaryTokenMatrix.nat,eval_constant values oneValue]
  have ordered := EnvelopeOrder.walk_ordered matrix tokens tokenChecks envelope.sourceLength envelope.rows rows values oneValue satisfied sections represented bounds
    (BinaryTokenMatrix.nat 8) (BinaryTokenMatrix.nat 0) BinaryTokenMatrix.one initialTotals 0 (by decide) rankImage chainGates
  obtain ⟨cs,entries,contributions,lengths⟩ := EnvelopeDirectory.attach_lengths matrix tokens tokenChecks values oneValue satisfied envelope.rows sections rows represented bounds
  have fits := EnvelopePayload.payloads_fit matrix tokens tokenChecks values oneValue satisfied envelope.rows rows cs contributions lengths
    envelope.sourceLength (BinaryTokenMatrix.nat 8) (BinaryTokenMatrix.nat 0) BinaryTokenMatrix.one initialTotals chainGates
  have accumulated := EnvelopeDirectory.walk_directory values oneValue tokens envelope.rows cs contributions
    (envelope.sourceLength) (BinaryTokenMatrix.nat 8) (BinaryTokenMatrix.nat 0) BinaryTokenMatrix.one initialTotals chainGates
  rw [EnvelopeDirectory.endTotals_final] at accumulated
  have metadata := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp envelopeParts.1).1
  have outputImage : envelope.outputs.map (E values) = EnvelopeDirectory.outputValues cs := by
    rw [metadata.2.2.2.2]
    exact EnvelopeDirectory.outputs_values values oneValue envelope.rows cs accumulated
  refine ⟨message,sections,meaning,d0,d1,unique,decoded,?_,represented,bounds,chain,ordered,cs,entries,lengths,fits,outputImage⟩
  intro i small
  have headerMeta := _root_.of_decide_eq_true (List.all_eq_true.mp headers i (List.mem_range.mpr small))
  have member : token tokens (envelope.headerTokens.getD i 0) ∈ tokens := by
    rw [token,← List.getElem_eq_getD default]; exact List.getElem_mem headerMeta.1
  obtain ⟨position,length,result⟩ := decoded _ member
  have checked := EnvelopeChain.token_checked matrix tokens tokenChecks _ headerMeta.1
  have byteBound : header.getD i 0 < 256 := by
    have cases : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3 ∨ i = 4 ∨ i = 5 ∨ i = 6 ∨ i = 7 := by omega
    rcases cases with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> decide
  exact (byte_result matrix _ checked values oneValue satisfied message position length i (header.getD i 0) (by omega) byteBound headerMeta.2 result).2

#print axioms decode_byte
#print axioms byte_result
#print axioms checked_envelope
end ZkBuild.EnvelopeSound

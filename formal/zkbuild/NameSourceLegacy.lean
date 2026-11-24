import NameSourceShared
set_option autoImplicit false
namespace ZkBuild.NameSourceLegacy
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix NameSourceMatrix NameSourceRules NameSourceShared ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem chain {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (frame : NameFrameMatrix.Record) (flat : frame.flat = false) (graph : NameGraphMatrix.Record) (source : NameSourceMatrix.Record)
    (sourceCheck : NameSourceMatrix.check matrix tokens tables frame graph source = true)
    (graphCheck : NameGraphMatrix.check matrix tables graph = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (message : List Sha256.Byte) (decoded : ∀ t ∈ tokens, ∃ p length, BinaryTokenSound.Result values t message p length)
    (fs : List NameFrameMatrix.ByteRow) (bs : List ByteRow) (checks : Related (LegacyByte matrix tokens) fs bs)
    (members : ∀ b ∈ bs, b ∈ source.bytes) (owner ordinal : Nat) (cursor head finish : Linear)
    (frameLink : NameFrameMatrix.legacyLink fs owner ordinal cursor = true)
    (sourceLink : legacyLink bs head finish = true) (nilEnd : E values finish = 0)
    (bytes : List Nat) (represented : RepWire values (NameGraphMatrix.table tables graph 0) head bytes)
    (position : Nat) (positionImage : E values cursor = (position : F)) (bounded : position+fs.length < 2^32) :
    bytes.length = bs.length ∧ Matches message position bytes := by
  induction checks generalizing owner ordinal cursor head bytes position with
  | nil =>
    have same : head = finish := _root_.of_decide_eq_true sourceLink
    have empty := rep_zero values _ head bytes (by rw [same]; exact nilEnd) represented
    subst bytes
    exact ⟨rfl,by intro i ib; simp at ib⟩
  | @cons f b fs bs checked checks ih =>
    have fc := Bool.and_eq_true_iff.mp frameLink
    have shaped := _root_.of_decide_eq_true fc.1
    have sc := Bool.and_eq_true_iff.mp sourceLink
    have headLink := _root_.of_decide_eq_true sc.1
    have byteShape := byte_shape matrix tokens false f b 0 z z checked.1
    have enabled : E values (NameFrameMatrix.bget f 0) = 1 := by rw [shaped.1]; simp [o,eval_constant values oneValue]
    have nodeEnabled : E values b.nodeQuery.active = 1 := by rw [byteShape.2.1]; exact enabled
    have byteCheck : checkByte matrix tokens frame.flat f b 0 z z = true := by simpa only [flat] using checked.1
    obtain ⟨first,rest,equal,byteValue,tailRep⟩ := NameSourceNodes.read_node matrix tokens tables tableChecks frame graph source sourceCheck graphCheck values oneValue satisfied b (members b (by simp)) f 0 z z byteCheck nodeEnabled bytes
      (by rw [headLink]; exact represented)
    have firstBound : first < 256 := by
      obtain ⟨id,_,_,rep⟩ := represented
      exact rep_values_bound _ id bytes rep first (by rw [equal]; simp)
    obtain ⟨p,pb,inside,pi,finishImage,value⟩ := NameFrameRules.byte_read matrix tokens tokenChecks false f checked.2 values oneValue satisfied enabled message decoded
    have startImage : E values (NameFrameMatrix.bget f 3) = (position : F) := by rw [shaped.2.2.2]; exact positionImage
    have samePosition : p = position := DeclarationLocations.natural_equal (F := F) _ _ (by omega) (by simp only [List.length_cons] at bounded; omega) (pi.symm.trans startImage)
    subst p
    have expected : E values (EnvelopeMatrix.token tokens f.token).value = (first : F) := by rw [byteShape.2.2.1]; exact byteValue
    have byteSame : (message.getD position 0).toNat = first := DeclarationLocations.natural_equal (F := F) _ _
      (by have b := (message.getD position 0).isLt; omega) (by omega) (value.symm.trans expected)
    have next := ih (by intro row rm; exact members row (by simp [rm])) owner (ordinal+1) (NameFrameMatrix.bget f 4) (field b 1)
      fc.2 sc.2 rest tailRep (position+1) finishImage (by simp only [List.length_cons] at bounded; omega)
    rw [equal]
    exact ⟨by simpa using next.1,matches_cons message position first rest inside byteSame next.2⟩

#print axioms chain
end ZkBuild.NameSourceLegacy

import NameSourceCoverage
set_option autoImplicit false
namespace ZkBuild.NameSourceEnd
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix NameSourceMatrix NameSourceRules NameSourceShared NameSourceFlatFacts NameSourceLineage NameSourceCoverage ShaProgram OwnedRules
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem selected {F : Type} [Field F] (values : Nat → F) (matrix : Shape) (tokens : Tokens)
    (bank : ReadOnlyMatrix.Record) (pairs : List (NameFrameMatrix.ByteRow × ByteRow))
    (ps : List ParentValue) (ds : List ChildValue) (bounds : ∀ d ∈ ds, ChildBound d)
    (certified : Related (Certified values bank matrix tokens) pairs ds)
    (positions : ∀ d ∈ ds, OwnedUnit.Position ps d)
    (complete : BinaryDeclarations.vectorKeys 0 (ps.map ParentValue.count) ⊆ OwnedComplete.keys ds)
    (i j : Nat) (ib : i < ps.length) (jb : j < (ps.getD i default).count) :
    ∃ pair ∈ pairs, ∃ d, Certified values bank matrix tokens pair d ∧ d.active = true ∧ d.owner = i ∧ d.ordinal = j ∧
      d.start = (ps.getD i default).start+j := by
  have arity : (ps.map ParentValue.count).getD i 0 = (ps.getD i default).count := by
    simp only [List.getD_eq_getElem?_getD,List.getElem?_map,List.getElem?_eq_getElem ib,Option.map_some,Option.getD_some]
  have desired := DeclarationCompleteness.vector_keys_at (ps.map ParentValue.count) 0 i j (by simpa using ib) (by rw [arity]; exact jb)
  have present : (i,j) ∈ OwnedComplete.keys ds := complete (by simpa using desired)
  obtain ⟨entry,em,ea,ek⟩ := (DeclarationCompleteness.keys_member (ds.map OwnedOrder.entry) (i,j)).mp present
  obtain ⟨d,dm,same⟩ := List.mem_map.mp em
  subst entry
  have pair := (OwnedComplete.entry_key d (bounds d dm)).symm.trans ek
  have owner : d.owner = i := congrArg Prod.fst pair
  have ordinal : d.ordinal = j := congrArg Prod.snd pair
  obtain ⟨actual,am,ac⟩ := BinaryReadMemory.right_member _ _ _ certified d dm
  exact ⟨actual,am,d,ac,ea,owner,ordinal,by simpa [owner,ordinal] using (positions d dm ea).2.1⟩

theorem ending_member (matrix : Shape) (fs : List NameFrameMatrix.ByteRow) (bs : List ByteRow) (es : List Ending)
    (checked : checkEnds matrix fs bs es = true) (f : NameFrameMatrix.ByteRow) (b : ByteRow) (member : (f,b) ∈ fs.zip bs) :
    ∃ e ∈ es, checkEnding matrix f b e = true := by
  induction fs generalizing bs es with
  | nil => simp at member
  | cons first rest ih => cases bs with
    | nil => simp at member
    | cons head tail => cases es with
      | nil => simp [checkEnds] at checked
      | cons e es =>
        have parts := Bool.and_eq_true_iff.mp checked
        simp only [List.zip_cons_cons,List.mem_cons] at member
        rcases member with same | later
        · cases same; exact ⟨e,by simp,parts.1⟩
        · obtain ⟨next,nm,nc⟩ := ih tail es parts.2 later
          exact ⟨next,by simp [nm],nc⟩

theorem terminal {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (f : NameFrameMatrix.ByteRow) (b : ByteRow) (e : Ending) (i : Nat) (po pt : Linear)
    (byteCheck : checkByte matrix tokens true f b i po pt = true) (endingCheck : checkEnding matrix f b e = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (active : E values (NameFrameMatrix.bget f 0) = 1) (last : E values (NameFrameMatrix.bget f 2 ++ o) = E values e.countQuery.value) :
    E values (field b 1) = 0 := by
  obtain ⟨word,wb,wi,_,ti⟩ := byte_word matrix tokens true f b i po pt byteCheck values oneValue satisfied
  have checks := endingCheck
  simp only [checkEnding,Bool.and_eq_true_iff] at checks
  have rc : RangeUse.check matrix e.range b.nodeQuery.value 42 = true := by grind only
  obtain ⟨other,ob,oi,slices⟩ := NameBits.slices values e.range b.nodeQuery.value 42 (RangeUse.checked_certificate matrix _ _ _ rc values oneValue satisfied)
  have equal : other = word := DeclarationLocations.natural_equal (F := F) _ _ (by omega) (by omega) (oi.symm.trans wi)
  subst other
  have all := MemoryEvidence.span_sound matrix e.firstGate e.lastGate (endingGates f e) (Bool.and_eq_true_iff.mp endingCheck).2 values satisfied
  have packedEq := equality_sound values oneValue e.tail (packed e.range 8 32) (all _ (by simp [endingGates]))
  have add : E values (packed e.range 8 32) = E values z+E values (NameGraphMatrix.slice e.range 8 32) := eval_append values _ _
  have tailImage : E values e.tail = (NameGraphRules.tailOf word : F) := by
    rw [packedEq,add,z,eval_constant values oneValue,slices 8 32 (by decide)]
    simp only [NameGraphRules.tailOf,Ring.intCast_zero]
    grind
  have zeroInput : E values (sub (NameFrameMatrix.bget f 2 ++ o) e.countQuery.value) = 0 := by rw [eval_sub,last]; grind
  have zs := zero_sound values oneValue (sub (NameFrameMatrix.bget f 2 ++ o) e.countQuery.value) (wire e.zeroStart) (wire (e.zeroStart+1)) (by
    intro g gm
    apply all g
    simp only [endingGates,List.mem_append]
    exact Or.inl (Or.inr gm))
  have selector := multiply_sound values (NameFrameMatrix.bget f 0) (wire e.zeroStart) e.selector (all _ (by simp [endingGates]))
  have tailZero := all (gate e.selector e.tail) (by simp [endingGates])
  change E values e.selector*E values e.tail = E values z at tailZero
  rw [selector,active,zs,zeroInput,ite_eq_left rfl,z,eval_constant values oneValue] at tailZero
  rw [← tailImage] at ti
  grind

#print axioms selected
#print axioms terminal
end ZkBuild.NameSourceEnd

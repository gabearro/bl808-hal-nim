import NameGraphStrings
set_option autoImplicit false
namespace ZkBuild.NameGraphRoots
open Lean.Grind CircuitShape FullMatrix GadgetShape NameGraphMatrix NameGraphRules NameGraphTable
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem normalized_eval {F : Type} [Field F] [IsCharP F scalarModulus] (values : Nat → F)
    (a b : Linear) (same : normalizeLinear a = normalizeLinear b) : E values a = E values b := by
  have interpreted := congrArg (fun l => R1CS.eval values (interpretLinear (F := F) l)) same
  simpa only [normalized_linear_same_field,E,FullMatrix.evalLinear] using interpreted

theorem root_value {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (root : Root) (checked : checkRoot matrix root = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ head word : Nat, head < 2^32 ∧ word < 2^42 ∧ E values root.head = (head : F) ∧
      E values root.query.value = (word : F) ∧ E values root.query.address = (head : F) ∧
      E values root.query.active = (if head = 0 then 0 else 1) ∧ stateOf word = 0 := by
  have checks := checked
  simp only [checkRoot,Bool.and_eq_true_iff,decide_eq_true_eq] at checks
  have sh : root.ranges.length = 2 ∧ normalizeLinear root.query.active = normalizeLinear (sub DeclarationMatrix.o (wire root.zeroStart)) ∧ root.query.address = root.head := by grind only
  have hr : RangeUse.check matrix (root.ranges.getD 0 default) root.head 32 = true := by grind only
  have wr : RangeUse.check matrix (root.ranges.getD 1 default) root.query.value 42 = true := by grind only
  obtain ⟨head,hb,hi⟩ := RangeReuse.certificate_sound _ _ _ (RangeUse.checked_certificate matrix _ _ _ hr values oneValue satisfied)
  obtain ⟨word,wb,wi,ws⟩ := NameBits.slices values (root.ranges.getD 1 default) root.query.value 42 (RangeUse.checked_certificate matrix _ _ _ wr values oneValue satisfied)
  have all := MemoryEvidence.span_sound matrix root.firstGate root.lastGate (rootGates root) (Bool.and_eq_true_iff.mp checked).2 values satisfied
  have zi := zero_sound values oneValue root.head (wire root.zeroStart) (wire (root.zeroStart+1)) (by
    intro g gm
    exact all g (by simp only [rootGates,List.mem_append]; exact Or.inl (Or.inl (Or.inr gm))))
  have eq : E values root.head = 0 ↔ head = 0 := by
    rw [hi]
    have small : head < scalarModulus := by
      have b : 2^32 < scalarModulus := by decide
      omega
    simpa only [Semiring.natCast_zero] using IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus small (by decide : 0 < scalarModulus)
  simp only [eq] at zi
  have active : E values root.query.active = (if head = 0 then 0 else 1) := by
    have expression := normalized_eval values root.query.active (sub DeclarationMatrix.o (wire root.zeroStart)) sh.2.1
    rw [expression,eval_sub,DeclarationMatrix.o,eval_constant values oneValue,zi]
    by_cases empty : head = 0 <;> simp [empty] <;> grind
  have pack := equality_sound values oneValue root.state (slice (root.ranges.getD 1 default) 40 2) (all _ (by simp [rootGates]))
  have zero := equality_sound values oneValue root.state DeclarationMatrix.z (all _ (by simp [rootGates]))
  have stateImage : E values root.state = (stateOf word : F) := by
    simpa [stateOf] using pack.trans (ws 40 2 (by decide))
  have stateZero : stateOf word = 0 := DeclarationLocations.natural_equal (F := F) _ 0
    (by have h : stateOf word < 4 := Nat.mod_lt _ (by decide); omega) (by decide)
    (by rw [← stateImage,zero,DeclarationMatrix.z,eval_constant values oneValue]; simp)
  exact ⟨head,word,hb,wb,hi,wi,by rw [sh.2.2]; exact hi,active,stateZero⟩

/-- Every checked name root denotes a finite, well-formed UTF-8 sequence. -/
theorem root_valid {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (r : NameGraphMatrix.Record) (checked : NameGraphMatrix.check matrix tables r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (root : Root) (member : root ∈ r.roots) :
    ∃ head : Nat, ∃ bytes : List Nat, head < 2^32 ∧ E values root.head = (head : F) ∧
      NameLists.Represents (NameGraphTable.table values (NameGraphMatrix.table tables r 0)) head bytes ∧ Utf8Suffix.Valid bytes := by
  obtain ⟨head,word,hb,wb,hi,wi,qi,active,state⟩ := root_value matrix root (NameGraphLinks.root_checked matrix tables r checked root member) values oneValue satisfied
  by_cases empty : head = 0
  · exact ⟨head,[],hb,hi,by rw [empty]; exact NameLists.Represents.nil,Utf8Suffix.Valid.nil⟩
  · have qm : root.query ∈ (NameGraphMatrix.table tables r 0).queries := by
      rw [(NameGraphLinks.metadata matrix tables r checked).2.2.2.2.1]
      exact List.mem_append_right _ (List.mem_map.mpr ⟨root,member,rfl⟩)
    have atWord : WordAt values (NameGraphMatrix.table tables r 0) head word := ⟨hb,wb,root.query,qm,by simpa [empty] using active,qi,wi⟩
    obtain ⟨bytes,represented,run,_⟩ := NameGraphStrings.represented matrix tables tableChecks r checked values oneValue satisfied head word atWord
    rw [state] at run
    exact ⟨head,bytes,hb,hi,represented,Utf8Suffix.zero_sound bytes run⟩

#print axioms root_value
#print axioms root_valid
end ZkBuild.NameGraphRoots

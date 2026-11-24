import IndexedLookup

namespace ZkBuild.SourceListSelection
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix ShaProgram DeclarationLocations
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem type_at (matrix : Shape) (tokens : Tokens) (splits : Splits) (endPos : Linear)
    (rows : List TypeRow) (startIndex : Nat) (prior : List Linear) (previous : Linear)
    (checked : checkTypes matrix tokens splits endPos rows startIndex prior previous = true)
    (i : Nat) (bound : i < rows.length) :
    ∃ p v, checkType matrix tokens splits (rows.getD i default) (startIndex+i) p v endPos = true := by
  induction rows generalizing startIndex prior previous i with
  | nil => simp at bound
  | cons row rows ih =>
    have parts := Bool.and_eq_true_iff.mp checked
    cases i with
    | zero => exact ⟨prior,previous,by simpa using parts.1⟩
    | succ i =>
      obtain ⟨p,v,check⟩ := ih (startIndex+1) row.counts (get row.fields 0) parts.2 i (by simpa using bound)
      exact ⟨p,v,by simpa [Nat.add_assoc,Nat.add_left_comm,Nat.add_comm] using check⟩

theorem equal_heads {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (a b : PackedFields.Record) (ac : PackedFields.check matrix a = true) (bc : PackedFields.check matrix b = true)
    (al : a.lowWidth = 32) (ah : a.highWidth = 32) (bl : b.lowWidth = 32) (bh : b.highWidth = 32)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (same : E values a.value = E values b.value) : E values a.low = E values b.low ∧ E values a.high = E values b.high := by
  obtain ⟨av,alo,ahi,avb,alb,ahb,avi,ali,ahiI,ap,_,_⟩ := PackedFields.checked_split matrix a ac values oneValue satisfied
  obtain ⟨bv,blo,bhi,bvb,blb,bhb,bvi,bli,bhiI,bp,_,_⟩ := PackedFields.checked_split matrix b bc values oneValue satisfied
  have ab : av < 2^64 := by simpa [al,ah] using avb
  have bb : bv < 2^64 := by simpa [bl,bh] using bvb
  have eq := natural_equal (F := F) av bv ab bb (avi.symm.trans (same.trans bvi))
  have split := packed_unique alo ahi blo bhi (by simpa [al] using alb) (by simpa [bl] using blb)
    (by simpa [al,bl,ap,bp] using eq)
  exact ⟨ali.trans (by rw [split.1]; exact bli.symm),ahiI.trans (by rw [split.2]; exact bhiI.symm)⟩

theorem known_selection {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (r : DeclarationMatrix.Record) (accepted : DeclarationSound.check matrix body tables splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (types : List DeclarationType.Decoded) (images : Related (DeclarationType.Represents values) r.types types)
    (bounds : ∀ d ∈ types, DeclarationType.Bounded d)
    (params : Bool) (source : VectorRow) (member : source ∈ vectorRows r params)
    (index : Nat) (previous previousAddress count : Linear)
    (checked : checkVector matrix body.tokens splits source params index previous previousAddress count = true)
    (active : E values (get source.fields 0) = 1)
    (typeIndex sourceOrdinal : Nat) (typeBound : typeIndex < 2^32) (ordinalBound : sourceOrdinal < 2^32)
    (sourceKey : E values (get source.fields 1) = ((sourceOrdinal+2^32*typeIndex : Nat) : F)) :
    E values (split splits source.keySplit).high = (typeIndex : F) ∧
    E values (split splits source.keySplit).low = (sourceOrdinal : F) ∧
    E values (split splits source.spanSplit).high = (arity params (types.getD typeIndex default) : F) := by
  have parts := Bool.and_eq_true_iff.mp accepted
  have splitChecks := (Bool.and_eq_true_iff.mp parts.1).2
  have tableChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts.1).1).2
  have record := parts.2
  simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at record
  have links : checkLinks tables r = true := by grind only
  have shape : Metadata body.envelope r := _root_.of_decide_eq_true (by grind only)
  have location := location_links tables r links params
  have checkedTable := List.all_eq_true.mp tableChecks _ location.1
  have qm : source.location ∈ (locationTable tables r params).queries := by
    rw [location.2.2]; exact List.mem_map.mpr ⟨source,member,rfl⟩
  have rowShape := DeclarationVector.vector_metadata matrix body.tokens splits source params index previous previousAddress count checked
  obtain ⟨ti,ordinal,base,len,tib,ord,lenb,baseb,tii,oi,bi,li,_,queryIndex⟩ :=
    DeclarationSelection.selected_member matrix body.tokens splits splitChecks source params index previous previousAddress count checked values oneValue satisfied active
  have keyShape := rowShape.2.2.2.2.2.2.2.2.1
  have spanShape := rowShape.2.2.2.2.2.2.2.2.2.1
  have km : split splits source.keySplit ∈ splits := by rw [split,← List.getElem_eq_getD default]; exact List.getElem_mem rowShape.2.2.1
  have sm : split splits source.spanSplit ∈ splits := by rw [split,← List.getElem_eq_getD default]; exact List.getElem_mem rowShape.2.2.2.1
  have key := split_recombine matrix _ (List.all_eq_true.mp splitChecks _ km) keyShape.2.1 values oneValue satisfied
  rw [keyShape.1,oi,tii] at key
  have keyImage : E values (get source.fields 1) = ((ordinal+2^32*ti : Nat) : F) := by
    simpa only [Semiring.natCast_add,Semiring.natCast_mul] using key
  have ordBound : ordinal < 2^32 := Nat.lt_trans ord lenb
  have packed := natural_equal (F := F) (ordinal+2^32*ti) (sourceOrdinal+2^32*typeIndex) (by omega) (by omega) (keyImage.symm.trans sourceKey)
  have same := packed_unique ordinal ti sourceOrdinal typeIndex ordBound ordinalBound packed
  have span := split_recombine matrix _ (List.all_eq_true.mp splitChecks _ sm) spanShape.2.1 values oneValue satisfied
  rw [spanShape.1,bi,li] at span
  have spanImage : E values source.location.value = ((base+2^32*len : Nat) : F) := by simpa only [Semiring.natCast_add,Semiring.natCast_mul] using span
  have qa : source.location.active = get source.fields 0 := rowShape.2.2.2.2.2.2.2.2.2.2.2.2.1
  obtain ⟨_,_,_,sameLength⟩ := location_binding matrix r.types types params _ source.location checkedTable location.2.1 qm shape.1 values oneValue satisfied images bounds ti base len tib baseb lenb (by rw [qa]; exact active) queryIndex spanImage
  exact ⟨by simpa [same.2] using tii,by simpa [same.1] using oi,by simpa [sameLength,same.2] using li⟩

#print axioms known_selection
end ZkBuild.SourceListSelection

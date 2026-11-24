import DeclarationOrder
namespace ZkBuild.DeclarationCounts
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def typeActive : List DeclarationType.Decoded → Nat
  | [] => 0
  | d::rest => d.active.toNat+typeActive rest
def typeParams : List DeclarationType.Decoded → Nat
  | [] => 0
  | d::rest => d.params+typeParams rest
def typeResults : List DeclarationType.Decoded → Nat
  | [] => 0
  | d::rest => d.results+typeResults rest
def vectorActive : List MemoryTrace.Entry → Nat
  | [] => 0
  | d::rest => d.active.toNat+vectorActive rest

private theorem cat {F : Type} [CommRing F] (values : Nat → F) (a b : Linear) : E values (a++b) = E values a+E values b := FullMatrix.eval_append values a b

theorem type_counts {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (endPos : Linear) (rows : List TypeRow)
    (index : Nat) (prior : List Linear) (previous : Linear)
    (accepted : checkTypes matrix tokens splits endPos rows index prior previous = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ decoded : List DeclarationType.Decoded,
      Related (DeclarationType.Represents values) rows decoded ∧ (∀ d ∈ decoded, DeclarationType.Bounded d) ∧
      E values (get (typeFinal rows prior) 0) = E values (get prior 0)+(typeActive decoded : F) ∧
      E values (get (typeFinal rows prior) 1) = E values (get prior 1)+(typeParams decoded : F) ∧
      E values (get (typeFinal rows prior) 2) = E values (get prior 2)+(typeResults decoded : F) := by
  induction rows generalizing index prior previous with
  | nil => exact ⟨[],.nil,by simp,by simp [typeFinal,typeActive,Semiring.add_zero],by simp [typeFinal,typeParams,Semiring.add_zero],by simp [typeFinal,typeResults,Semiring.add_zero]⟩
  | cons row rows ih =>
    have parts := Bool.and_eq_true_iff.mp accepted
    obtain ⟨d,image,bound⟩ := DeclarationType.decode matrix tokens splits row index prior previous endPos parts.1 values oneValue satisfied
    obtain ⟨decoded,images,bounds,a,p,r⟩ := ih (index+1) row.counts (get row.fields 0) parts.2
    have holds := DeclarationType.type_holds matrix tokens splits row index prior previous endPos parts.1 values satisfied
    have out := DeclarationType.part_holds values tokens splits row index prior previous endPos holds 12 (by decide)
    have active := equality_sound values oneValue (get row.counts 0) (get prior 0++get row.fields 0) (out _ (by simp [typeParts]))
    have params := equality_sound values oneValue (get row.counts 1) (get prior 1++get row.fields 5) (out _ (by simp [typeParts]))
    have results := equality_sound values oneValue (get row.counts 2) (get prior 2++get row.fields 6) (out _ (by simp [typeParts]))
    rw [cat,image.1] at active
    rw [cat,image.2.2.2.2.2.1] at params
    rw [cat,image.2.2.2.2.2.2] at results
    refine ⟨d::decoded,.cons image images,?_,?_,?_,?_⟩
    · intro d member; rcases List.mem_cons.mp member with rfl | later; exact bound; exact bounds d later
    · simp only [typeFinal,typeActive,Semiring.natCast_add]; rw [a,active]; grind
    · simp only [typeFinal,typeParams,Semiring.natCast_add]; rw [p,params]; grind
    · simp only [typeFinal,typeResults,Semiring.natCast_add]; rw [r,results]; grind

theorem vector_counts {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (reverse : Bool) (rows : List VectorRow)
    (index : Nat) (previous previousAddress count : Linear)
    (accepted : checkVectors matrix tokens splits reverse rows index previous previousAddress count = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ decoded : List MemoryTrace.Entry, Related (DeclarationOrder.Represents values) rows decoded ∧
      (∀ e ∈ decoded, DeclarationOrder.Bounded e) ∧
      E values (vectorFinal rows count) = E values count+(vectorActive decoded : F) := by
  induction rows generalizing index previous previousAddress count with
  | nil => exact ⟨[],.nil,by simp,by simp [vectorFinal,vectorActive,Semiring.add_zero]⟩
  | cons row rows ih =>
    have parts := Bool.and_eq_true_iff.mp accepted
    obtain ⟨d,image,bound⟩ := DeclarationOrder.decode matrix tokens splits row reverse index previous previousAddress count parts.1 values oneValue satisfied
    obtain ⟨decoded,images,bounds,finalImage⟩ := ih (index+1) (get row.fields 0) (get row.fields 1) row.count parts.2
    have holds := DeclarationVector.vector_holds matrix tokens splits row reverse index previous previousAddress count parts.1 values satisfied
    have out := DeclarationVector.part_holds values tokens splits row reverse previous previousAddress count holds 18 (by decide)
    have count := equality_sound values oneValue row.count (count++get row.fields 0) (out _ (by simp [vectorParts]))
    rw [cat,image.1] at count
    refine ⟨d::decoded,.cons image images,?_,?_⟩
    · intro d member; rcases List.mem_cons.mp member with rfl | later; exact bound; exact bounds d later
    · simp only [vectorFinal,vectorActive,Semiring.natCast_add]; rw [finalImage,count]; grind

theorem params_bound (ds : List DeclarationType.Decoded) (bounds : ∀ d ∈ ds, DeclarationType.Bounded d)
    (size : ds.length < 2^32) : typeParams ds < 2^64 := by
  have sumBound : typeParams ds ≤ ds.length*2^32 := by
    induction ds with
    | nil => simp [typeParams]
    | cons d ds ih =>
      have p := bounds d (by simp)
      have head : d.params < 2^32 := p _ (by simp [DeclarationType.numbers])
      have rest := ih (by intro e em; exact bounds e (by simp [em])) (by simp at size; omega)
      simp only [typeParams,List.length_cons,Nat.add_mul,Nat.one_mul]
      omega
  omega

theorem results_bound (ds : List DeclarationType.Decoded) (bounds : ∀ d ∈ ds, DeclarationType.Bounded d)
    (size : ds.length < 2^32) : typeResults ds < 2^64 := by
  have sumBound : typeResults ds ≤ ds.length*2^32 := by
    induction ds with
    | nil => simp [typeResults]
    | cons d ds ih =>
      have p := bounds d (by simp)
      have head : d.results < 2^32 := p _ (by simp [DeclarationType.numbers])
      have rest := ih (by intro e em; exact bounds e (by simp [em])) (by simp at size; omega)
      simp only [typeResults,List.length_cons,Nat.add_mul,Nat.one_mul]
      omega
  omega

theorem vector_count_bound (ds : List MemoryTrace.Entry) : vectorActive ds ≤ ds.length := by
  induction ds with
  | nil => simp [vectorActive]
  | cons d ds ih =>
    have bit : d.active.toNat ≤ 1 := by cases d.active <;> decide
    simp only [vectorActive,List.length_cons]
    omega

theorem checked_counts {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (envelope : EnvelopeMatrix.Record)
    (r : DeclarationMatrix.Record) (accepted : DeclarationMatrix.check matrix tokens splits tables envelope r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ types : List DeclarationType.Decoded, ∃ params results : List MemoryTrace.Entry,
      Related (DeclarationType.Represents values) r.types types ∧ Related (DeclarationOrder.Represents values) r.params params ∧
      Related (DeclarationOrder.Represents values) r.results results ∧
      (∀ d ∈ types, DeclarationType.Bounded d) ∧ (∀ e ∈ params, DeclarationOrder.Bounded e) ∧ (∀ e ∈ results, DeclarationOrder.Bounded e) ∧
      vectorActive params = typeParams types ∧ vectorActive results = typeResults types ∧ E values r.typeCount = (typeActive types : F) := by
  have factors := accepted
  simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at factors
  have shape : Metadata envelope r := _root_.of_decide_eq_true (by grind only)
  have typeChecks : checkTypes matrix tokens splits r.typeEnd r.types 0 (typeSeed r.typeStart) o = true := by grind only
  have paramChecks : checkVectors matrix tokens splits true r.params 0 o z z = true := by grind only
  have resultChecks : checkVectors matrix tokens splits false r.results 0 o z z = true := by grind only
  obtain ⟨types,ti,tb,ta,tp,tr⟩ := type_counts matrix tokens splits r.typeEnd r.types 0 (typeSeed r.typeStart) o typeChecks values oneValue satisfied
  obtain ⟨params,pi,pb,pc⟩ := vector_counts matrix tokens splits true r.params 0 o z z paramChecks values oneValue satisfied
  obtain ⟨results,ri,rb,rc⟩ := vector_counts matrix tokens splits false r.results 0 o z z resultChecks values oneValue satisfied
  have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
  have countStart (j : Nat) (small : j < 3) : E values (get (typeSeed r.typeStart) j) = 0 := by
    have cases : j = 0 ∨ j = 1 ∨ j = 2 := by omega
    rcases cases with rfl | rfl | rfl <;> simpa [DeclarationMatrix.get,typeSeed] using zero
  rw [countStart 0 (by decide)] at ta
  rw [countStart 1 (by decide)] at tp
  rw [countStart 2 (by decide)] at tr
  rw [zero] at pc rc
  simp only [AddCommMonoid.zero_add] at ta tp tr pc rc
  have pm : r.paramTotal = get (typeFinal r.types (typeSeed r.typeStart)) 1 := by
    have h := shape; simp only [Metadata] at h; grind only
  have rm : r.resultTotal = get (typeFinal r.types (typeSeed r.typeStart)) 2 := by
    have h := shape; simp only [Metadata] at h; grind only
  have pSpan : MemoryEvidence.checkSpan matrix r.paramCloseStart r.paramCloseEnd [eqGate (vectorFinal r.params z) r.paramTotal] = true := by grind only
  have rSpan : MemoryEvidence.checkSpan matrix r.resultCloseStart r.resultCloseEnd [eqGate (vectorFinal r.results z) r.resultTotal] = true := by grind only
  have pEqual := equality_sound values oneValue (vectorFinal r.params z) r.paramTotal (MemoryEvidence.span_sound matrix _ _ _ pSpan values satisfied _ (by simp))
  have rEqual := equality_sound values oneValue (vectorFinal r.results z) r.resultTotal (MemoryEvidence.span_sound matrix _ _ _ rSpan values satisfied _ (by simp))
  have pImage : (vectorActive params : F) = (typeParams types : F) := by rw [pc,pm,tp] at pEqual; exact pEqual
  have rImage : (vectorActive results : F) = (typeResults types : F) := by rw [rc,rm,tr] at rEqual; exact rEqual
  have tl : types.length = r.types.length := (related_length _ _ _ ti).symm
  have pl : params.length = r.params.length := (related_length _ _ _ pi).symm
  have rl : results.length = r.results.length := (related_length _ _ _ ri).symm
  have pBound : typeParams types < 2^64 := params_bound types tb (by rw [tl]; exact shape.1)
  have rBound : typeResults types < 2^64 := results_bound types tb (by rw [tl]; exact shape.1)
  have paBound : vectorActive params < 2^64 := by have b := vector_count_bound params; have h := shape.2.1; rw [pl] at b; omega
  have raBound : vectorActive results < 2^64 := by have b := vector_count_bound results; have h := shape.2.2.1; rw [rl] at b; omega
  have big : 2^64 < scalarModulus := by decide
  have pSame := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (Nat.lt_trans paBound big) (Nat.lt_trans pBound big)).mp pImage
  have rSame := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (Nat.lt_trans raBound big) (Nat.lt_trans rBound big)).mp rImage
  have close : MemoryEvidence.checkSpan matrix r.typeCloseStart r.typeCloseEnd
      ([eqGate (get (typeFinal r.types (typeSeed r.typeStart)) 0) r.typeCount,eqGate (get (typeFinal r.types (typeSeed r.typeStart)) 3) r.typeEnd]++RangeUse.gates r.paramTotalRange++RangeUse.gates r.resultTotalRange) = true := by grind only
  have closed := MemoryEvidence.span_sound matrix _ _ _ close values satisfied
  have typeEqual := equality_sound values oneValue (get (typeFinal r.types (typeSeed r.typeStart)) 0) r.typeCount (closed _ (by simp))
  exact ⟨types,params,results,ti,pi,ri,tb,pb,rb,pSame,rSame,typeEqual.symm.trans ta⟩

#print axioms type_counts
#print axioms vector_counts
#print axioms checked_counts
end ZkBuild.DeclarationCounts

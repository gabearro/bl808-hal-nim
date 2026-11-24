import DeclarationMatrix

namespace ZkBuild.DeclarationType
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

structure Decoded where
  active : Bool
  start : Nat
  paramsStart : Nat
  resultsStart : Nat
  finish : Nat
  params : Nat
  results : Nat
  deriving Inhabited

def numbers (d : Decoded) := [d.start,d.paramsStart,d.resultsStart,d.finish,d.params,d.results]
def Bounded (d : Decoded) := ∀ value ∈ numbers d, value < 2^32

def Represents {F : Type} [CommRing F] (values : Nat → F) (r : TypeRow) (d : Decoded) : Prop :=
  E values (get r.fields 0) = (d.active.toNat : F) ∧
  E values (get r.fields 1) = (d.start : F) ∧ E values (get r.fields 2) = (d.paramsStart : F) ∧
  E values (get r.fields 3) = (d.resultsStart : F) ∧ E values (get r.fields 4) = (d.finish : F) ∧
  E values (get r.fields 5) = (d.params : F) ∧ E values (get r.fields 6) = (d.results : F)

theorem type_metadata (matrix : Shape) (tokens : Tokens) (splits : Splits) (r : TypeRow)
    (i : Nat) (prior : List Linear) (previous endPos : Linear)
    (accepted : checkType matrix tokens splits r i prior previous endPos = true) :
    r.fields.length = 7 ∧ r.ranges.length = 6 ∧ r.counts.length = 4 ∧
    r.headerToken < tokens.length ∧ r.paramToken < tokens.length ∧ r.resultToken < tokens.length ∧ r.heads < splits.length ∧
    tokenMatches (token tokens r.headerToken) 0 (get r.fields 0) (get r.fields 1) (scale (get r.fields 0) 96) ∧
    tokenMatches (token tokens r.paramToken) 1 (get r.fields 0) r.paramPosition (get r.fields 5) ∧
    tokenMatches (token tokens r.resultToken) 1 (get r.fields 0) r.resultPosition (get r.fields 6) ∧
    splitMatches (split splits r.heads) r.metadata.value 32 32 ∧
    r.metadata.active = get r.fields 0 ∧ r.paramLength.active = get r.fields 0 ∧ r.resultLength.active = get r.fields 0 := by
  exact _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp accepted).1).1).1

theorem type_holds {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (r : TypeRow)
    (i : Nat) (prior : List Linear) (previous endPos : Linear)
    (accepted : checkType matrix tokens splits r i prior previous endPos = true)
    (values : Nat → F) (satisfied : Satisfied matrix values) : AllHold values (typeGates tokens splits r i prior previous endPos) :=
  MemoryEvidence.span_sound matrix r.firstGate r.lastGate _ (Bool.and_eq_true_iff.mp accepted).2 values satisfied

theorem part_holds {F : Type} [Field F] (values : Nat → F) (tokens : Tokens) (splits : Splits) (r : TypeRow)
    (i : Nat) (prior : List Linear) (previous endPos : Linear)
    (holds : AllHold values (typeGates tokens splits r i prior previous endPos)) (part : Nat) (inside : part < 13) :
    AllHold values ((typeParts tokens splits r i prior previous endPos).getD part []) := by
  have bound : part < (typeParts tokens splits r i prior previous endPos).length := by simpa [typeParts] using inside
  have member : (typeParts tokens splits r i prior previous endPos).getD part [] ∈ typeParts tokens splits r i prior previous endPos := by
    rw [← List.getElem_eq_getD []]; exact List.getElem_mem bound
  intro g gm; exact holds g (List.mem_flatten.mpr ⟨_,member,gm⟩)

theorem field_range {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (r : TypeRow) (i : Nat)
    (prior : List Linear) (previous endPos : Linear) (accepted : checkType matrix tokens splits r i prior previous endPos = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) (j : Nat) (inside : j < 6) :
    ∃ n : Nat, n < 2^32 ∧ E values ((r.fields.drop 1).getD j z) = (n : F) := by
  have shape := type_metadata matrix tokens splits r i prior previous endPos accepted
  have rangeChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp accepted).1).1).2
  have member := EnvelopeRanges.zip_at (r.fields.drop 1) r.ranges z default j (by simp [shape.1,shape.2.1]) (by simp [shape.1]; omega)
  have checked := List.all_eq_true.mp rangeChecks _ member
  exact RangeReuse.certificate_sound _ _ _ (RangeUse.checked_certificate matrix _ _ 32 checked values oneValue satisfied)

theorem decode {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (r : TypeRow) (i : Nat)
    (prior : List Linear) (previous endPos : Linear) (accepted : checkType matrix tokens splits r i prior previous endPos = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ d : Decoded, Represents values r d ∧ Bounded d := by
  have shape := type_metadata matrix tokens splits r i prior previous endPos accepted
  obtain ⟨start,sb,si⟩ := field_range matrix tokens splits r i prior previous endPos accepted values oneValue satisfied 0 (by decide)
  obtain ⟨ps,pb,pi⟩ := field_range matrix tokens splits r i prior previous endPos accepted values oneValue satisfied 1 (by decide)
  obtain ⟨rs,rb,ri⟩ := field_range matrix tokens splits r i prior previous endPos accepted values oneValue satisfied 2 (by decide)
  obtain ⟨finish,fb,fi⟩ := field_range matrix tokens splits r i prior previous endPos accepted values oneValue satisfied 3 (by decide)
  obtain ⟨pc,pcb,pci⟩ := field_range matrix tokens splits r i prior previous endPos accepted values oneValue satisfied 4 (by decide)
  obtain ⟨rc,rcb,rci⟩ := field_range matrix tokens splits r i prior previous endPos accepted values oneValue satisfied 5 (by decide)
  have images : E values (get r.fields 1) = (start : F) ∧ E values (get r.fields 2) = (ps : F) ∧ E values (get r.fields 3) = (rs : F) ∧
      E values (get r.fields 4) = (finish : F) ∧ E values (get r.fields 5) = (pc : F) ∧ E values (get r.fields 6) = (rc : F) := by
    simpa [DeclarationMatrix.get,List.getD_eq_getElem?_getD,List.getElem?_drop] using And.intro si (And.intro pi (And.intro ri (And.intro fi (And.intro pci rci))))
  have holds := type_holds matrix tokens splits r i prior previous endPos accepted values satisfied
  have core := part_holds values tokens splits r i prior previous endPos holds 0 (by decide)
  change AllHold values [boolGate (get r.fields 0),gate (get r.fields 0) (sub o previous)] at core
  rcases boolean_sound values oneValue (get r.fields 0) (core _ (by simp)) with inactive | active
  · exact ⟨⟨false,start,ps,rs,finish,pc,rc⟩,⟨by simpa using inactive,images⟩,by simp [Bounded,numbers,sb,pb,rb,fb,pcb,rcb]⟩
  · exact ⟨⟨true,start,ps,rs,finish,pc,rc⟩,⟨by simpa using active,images⟩,by simp [Bounded,numbers,sb,pb,rb,fb,pcb,rcb]⟩

private theorem natural_equal {F : Type} [Field F] [IsCharP F scalarModulus]
    (a b : Nat) (ab : a < 2^34) (bb : b < 2^34) (same : (a : F) = (b : F)) : a = b := by
  have large : 2^34 < scalarModulus := by decide
  exact (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (by omega) (by omega)).mp same

theorem active_length {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (t : BinaryTokenMatrix.Record) (checked : BinaryTokenMatrix.check matrix t = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (kind : t.kind = 1) (enabled : E values t.activeMode = 1) :
    ∃ length : Nat, 0 < length ∧ length ≤ 5 ∧ E values t.length = (length : F) := by
  obtain ⟨length,bound,image,activity,_⟩ := BinaryTokenSchedule.checked_length matrix t checked values oneValue satisfied
  have a : E values (BinaryTokenMatrix.active t) = 1 := by simpa [BinaryTokenMatrix.active,kind] using enabled
  have positive : 0 < length := by
    by_cases zero : length = 0
    · have impossible : (1 : F) = 0 := by simpa [a,zero] using activity
      exact False.elim (Field.zero_ne_one impossible.symm)
    · omega
  exact ⟨length,positive,by simpa [kind,BinaryTokenMatrix.capacity] using bound,image⟩

def Layout (d : Decoded) (start endPos paramsLength resultsLength : Nat) : Prop :=
  d.start = start ∧ d.paramsStart = d.start+1+paramsLength ∧
  d.resultsStart = d.paramsStart+d.params+resultsLength ∧ d.finish = d.resultsStart+d.results ∧ d.finish ≤ endPos

theorem active_layout {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (checks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (r : TypeRow) (i : Nat) (prior : List Linear) (previous endPos : Linear)
    (accepted : checkType matrix tokens splits r i prior previous endPos = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (d : Decoded) (represented : Represents values r d) (bounded : Bounded d) (enabled : d.active = true)
    (start finish : Nat) (startBound : start < 2^32) (endBound : finish < 2^32)
    (startImage : E values (get prior 3) = (start : F)) (endImage : E values endPos = (finish : F)) :
    ∃ paramsLength resultsLength : Nat, 0 < paramsLength ∧ paramsLength ≤ 5 ∧ 0 < resultsLength ∧ resultsLength ≤ 5 ∧
      Layout d start finish paramsLength resultsLength ∧ E values (get r.counts 3) = (d.finish : F) := by
  have shape := type_metadata matrix tokens splits r i prior previous endPos accepted
  have a : E values (get r.fields 0) = 1 := by simpa [enabled] using represented.1
  have pm := shape.2.2.2.2.2.2.2.2.1
  have rm := shape.2.2.2.2.2.2.2.2.2.1
  obtain ⟨pl,plp,plb,pli⟩ := active_length matrix (token tokens r.paramToken) (EnvelopeChain.token_checked matrix tokens checks r.paramToken shape.2.2.2.2.1)
    values oneValue satisfied pm.1 (by rw [pm.2.1]; exact a)
  obtain ⟨rl,rlp,rlb,rli⟩ := active_length matrix (token tokens r.resultToken) (EnvelopeChain.token_checked matrix tokens checks r.resultToken shape.2.2.2.2.2.1)
    values oneValue satisfied rm.1 (by rw [rm.2.1]; exact a)
  have holds := type_holds matrix tokens splits r i prior previous endPos accepted values satisfied
  have sc := part_holds values tokens splits r i prior previous endPos holds 2 (by decide)
  change AllHold values [gate (get r.fields 0) (sub (get r.fields 1) (get prior 3))] at sc
  have sg := sc (gate (get r.fields 0) (sub (get r.fields 1) (get prior 3))) (by simp)
  change E values (get r.fields 0)*E values (sub (get r.fields 1) (get prior 3)) = E values z at sg
  have pc := part_holds values tokens splits r i prior previous endPos holds 6 (by decide)
  change AllHold values [gate (get r.fields 0) (sub (sub (sub (get r.fields 2) (get r.fields 1)) o) (token tokens r.paramToken).length),
    mulGate (get r.fields 0) (get r.fields 2++get r.fields 5) r.resultPosition] at pc
  have pg := pc (gate (get r.fields 0) (sub (sub (sub (get r.fields 2) (get r.fields 1)) o) (token tokens r.paramToken).length)) (by simp)
  change E values (get r.fields 0)*E values (sub (sub (sub (get r.fields 2) (get r.fields 1)) o) (token tokens r.paramToken).length) = E values z at pg
  have rc := part_holds values tokens splits r i prior previous endPos holds 8 (by decide)
  change AllHold values [gate (get r.fields 0) (sub (sub (sub (get r.fields 3) (get r.fields 2)) (get r.fields 5)) (token tokens r.resultToken).length),
    gate (get r.fields 0) (sub (sub (get r.fields 4) (get r.fields 3)) (get r.fields 6)),mulGate (get r.fields 0) (sub endPos (get r.fields 4)) r.remaining] at rc
  have rg := rc (gate (get r.fields 0) (sub (sub (sub (get r.fields 3) (get r.fields 2)) (get r.fields 5)) (token tokens r.resultToken).length)) (by simp)
  change E values (get r.fields 0)*E values (sub (sub (sub (get r.fields 3) (get r.fields 2)) (get r.fields 5)) (token tokens r.resultToken).length) = E values z at rg
  have fg := rc (gate (get r.fields 0) (sub (sub (get r.fields 4) (get r.fields 3)) (get r.fields 6))) (by simp)
  change E values (get r.fields 0)*E values (sub (sub (get r.fields 4) (get r.fields 3)) (get r.fields 6)) = E values z at fg
  have rangeCheck := (Bool.and_eq_true_iff.mp accepted).1 |> Bool.and_eq_true_iff.mp |>.2
  obtain ⟨remaining,remainingBound,remainingImage⟩ := RangeReuse.certificate_sound _ _ _ (RangeUse.checked_certificate matrix r.remainingRange r.remaining 32 rangeCheck values oneValue satisfied)
  have remainingGate := multiply_sound values (get r.fields 0) (sub endPos (get r.fields 4)) r.remaining (rc _ (by simp))
  have sb := bounded d.start (by simp [numbers])
  have psb := bounded d.paramsStart (by simp [numbers])
  have rsb := bounded d.resultsStart (by simp [numbers])
  have fb := bounded d.finish (by simp [numbers])
  have pcb := bounded d.params (by simp [numbers])
  have rcb := bounded d.results (by simp [numbers])
  have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
  have one : E values o = 1 := by simp [o,eval_constant values oneValue]
  rw [a,eval_sub,represented.2.1,startImage,zero] at sg
  have sameStart : d.start = start := natural_equal (F := F) _ _ (by omega) (by omega) (by grind)
  rw [a,eval_sub,eval_sub,eval_sub,represented.2.2.1,represented.2.1,one,pli,zero] at pg
  have sameParams : d.paramsStart = d.start+1+pl := natural_equal (F := F) _ _ (by omega) (by omega) (by simp only [Semiring.natCast_add,Semiring.natCast_one]; grind)
  rw [a,eval_sub,eval_sub,eval_sub,represented.2.2.2.1,represented.2.2.1,represented.2.2.2.2.2.1,rli,zero] at rg
  have sameResults : d.resultsStart = d.paramsStart+d.params+rl := natural_equal (F := F) _ _ (by omega) (by omega) (by simp only [Semiring.natCast_add]; grind)
  rw [a,eval_sub,eval_sub,represented.2.2.2.2.1,represented.2.2.2.1,represented.2.2.2.2.2.2,zero] at fg
  have sameFinish : d.finish = d.resultsStart+d.results := natural_equal (F := F) _ _ (by omega) (by omega) (by simp only [Semiring.natCast_add]; grind)
  rw [a,eval_sub,endImage,represented.2.2.2.2.1,remainingImage] at remainingGate
  have sameEnd : finish = d.finish+remaining := natural_equal (F := F) _ _ (by omega) (by omega) (by simp only [Semiring.natCast_add]; grind)
  have outputs := part_holds values tokens splits r i prior previous endPos holds 12 (by decide)
  have next := select_sound values (get r.fields 0) (get r.fields 4) (get prior 3) (get r.counts 3)
    (outputs _ (by simp [typeParts]))
  refine ⟨pl,rl,plp,plb,rlp,rlb,⟨sameStart,sameParams,sameResults,sameFinish,by omega⟩,?_⟩
  rw [next,a,represented.2.2.2.2.1]
  grind

theorem inactive_arities {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (r : TypeRow) (i : Nat)
    (prior : List Linear) (previous endPos : Linear) (accepted : checkType matrix tokens splits r i prior previous endPos = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (d : Decoded) (represented : Represents values r d) (bounded : Bounded d) (inactive : d.active = false) :
    d.params = 0 ∧ d.results = 0 := by
  have shape := type_metadata matrix tokens splits r i prior previous endPos accepted
  have holds := type_holds matrix tokens splits r i prior previous endPos accepted values satisfied
  have core := part_holds values tokens splits r i prior previous endPos holds 1 (by decide)
  have a : E values (get r.fields 0) = 0 := by simpa [inactive] using represented.1
  have fieldZero (j : Nat) (inside : j < 6) : E values ((r.fields.drop 1).getD j z) = 0 := by
    have member := EnvelopeRanges.zip_at (r.fields.drop 1) r.ranges z default j (by simp [shape.1,shape.2.1]) (by simp [shape.1]; omega)
    have used : gate (sub o (get r.fields 0)) ((r.fields.drop 1).getD j z) ∈ (typeParts tokens splits r i prior previous endPos).getD 1 [] := by
      apply List.mem_flatMap.mpr
      exact ⟨_,member,List.mem_append_right _ (by simp)⟩
    have g := core _ used
    change E values (sub o (get r.fields 0))*E values ((r.fields.drop 1).getD j z) = E values z at g
    have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
    have one : E values o = 1 := by simp [o,eval_constant values oneValue]
    rw [eval_sub,a,zero,one] at g
    grind
  have p : E values (get r.fields 5) = 0 := by simpa [DeclarationMatrix.get,List.getD_eq_getElem?_getD,List.getElem?_drop] using fieldZero 4 (by decide)
  have r : E values (get r.fields 6) = 0 := by simpa [DeclarationMatrix.get,List.getD_eq_getElem?_getD,List.getElem?_drop] using fieldZero 5 (by decide)
  rw [represented.2.2.2.2.2.1] at p
  rw [represented.2.2.2.2.2.2] at r
  have pb := bounded d.params (by simp [numbers])
  have rb := bounded d.results (by simp [numbers])
  exact ⟨(IsCharP.natCast_eq_zero_iff_of_lt scalarModulus (Nat.lt_trans pb (by decide))).mp p,
    (IsCharP.natCast_eq_zero_iff_of_lt scalarModulus (Nat.lt_trans rb (by decide))).mp r⟩

#print axioms decode
#print axioms active_layout
#print axioms inactive_arities
end ZkBuild.DeclarationType

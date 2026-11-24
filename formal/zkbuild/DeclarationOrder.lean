import DeclarationSelection
namespace ZkBuild.DeclarationOrder
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def Represents {F : Type} [CommRing F] (values : Nat → F) (r : VectorRow) (e : MemoryTrace.Entry) : Prop :=
  E values (get r.fields 0) = (e.active.toNat : F) ∧ E values (get r.fields 1) = (e.address : F) ∧
  E values (get r.fields 2) = (e.value : F)
def Bounded (e : MemoryTrace.Entry) : Prop := e.address < 2^64 ∧ e.value < 7

theorem decode {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (r : VectorRow) (reverse : Bool) (index : Nat)
    (previous previousAddress count : Linear) (accepted : checkVector matrix tokens splits r reverse index previous previousAddress count = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ e : MemoryTrace.Entry, Represents values r e ∧ Bounded e := by
  have addressCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp accepted).1).1).1).1 |> Bool.and_eq_true_iff.mp |>.2
  obtain ⟨address,bound,image⟩ := RangeReuse.certificate_sound _ _ _ (RangeUse.checked_certificate matrix r.addressRange (get r.fields 1) 64 addressCheck values oneValue satisfied)
  obtain ⟨tag,tagImage,_⟩ := DeclarationVector.tag_value matrix tokens splits r reverse index previous previousAddress count accepted values oneValue satisfied
  have holds := DeclarationVector.vector_holds matrix tokens splits r reverse index previous previousAddress count accepted values satisfied
  have core := DeclarationVector.part_holds values tokens splits r reverse previous previousAddress count holds 0 (by decide)
  change AllHold values [boolGate (get r.fields 0),gate (get r.fields 0) (sub o previous)] at core
  rcases boolean_sound values oneValue (get r.fields 0) (core _ (by simp)) with inactive | active
  · exact ⟨⟨false,false,address,tag.val,0⟩,⟨by simpa using inactive,image,tagImage⟩,bound,tag.isLt⟩
  · exact ⟨⟨true,true,address,tag.val,0⟩,⟨by simpa using active,image,tagImage⟩,bound,tag.isLt⟩

theorem step_order {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (r : VectorRow) (reverse : Bool) (index : Nat) (positive : 0 < index)
    (previous previousAddress count : Linear) (accepted : checkVector matrix tokens splits r reverse index previous previousAddress count = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (p e : MemoryTrace.Entry) (image : Represents values r e) (bounded : Bounded e) (pBound : p.address < 2^64)
    (pActive : E values previous = (p.active.toNat : F)) (pAddress : E values previousAddress = (p.address : F)) :
    e.active = true → p.active = true ∧ p.address < e.address := by
  intro enabled
  have shape := DeclarationVector.vector_metadata matrix tokens splits r reverse index previous previousAddress count accepted
  have hasOrder : r.hasOrder = true := by rw [shape.2.2.2.2.2.2.1]; simp; omega
  have orderCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp accepted).1).2
  simp only [hasOrder,↓reduceIte] at orderCheck
  obtain ⟨delta,db,di⟩ := RangeReuse.certificate_sound _ _ _ (RangeUse.checked_certificate matrix r.orderRange r.orderDelta 64 orderCheck values oneValue satisfied)
  have holds := DeclarationVector.vector_holds matrix tokens splits r reverse index previous previousAddress count accepted values satisfied
  have head := DeclarationVector.part_holds values tokens splits r reverse previous previousAddress count holds 0 (by decide)
  change AllHold values [boolGate (get r.fields 0),gate (get r.fields 0) (sub o previous)] at head
  have gate := head (DeclarationMatrix.gate (get r.fields 0) (sub o previous)) (by simp)
  change E values (get r.fields 0)*E values (sub o previous) = E values z at gate
  have a : E values (get r.fields 0) = 1 := by simpa [enabled] using image.1
  have one : E values o = 1 := by simp [o,eval_constant values oneValue]
  have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
  rw [a,eval_sub,one,zero,pActive] at gate
  have pa : p.active = true := by
    cases flag : p.active with
    | true => rfl
    | false =>
      simp only [flag,Bool.toNat_false,Semiring.natCast_zero] at gate
      have bad : (1 : F) = 0 := by grind
      exact False.elim (Field.zero_ne_one bad.symm)
  have order := DeclarationVector.part_holds values tokens splits r reverse previous previousAddress count holds 5 (by decide)
  have dg : Holds values (mulGate (get r.fields 0) (sub (sub (get r.fields 1) previousAddress) o) r.orderDelta) := by
    apply order
    simp [vectorParts,hasOrder]
  have equation := multiply_sound values (get r.fields 0) (sub (sub (get r.fields 1) previousAddress) o) r.orderDelta dg
  rw [di,a,eval_sub,eval_sub,image.2.1,pAddress,one] at equation
  exact ⟨pa,ReadOnlyMemory.order_gate (F := F) (2^64) p.address e.address delta pBound bounded.1 db (by decide) (by simpa [Semiring.one_mul] using equation.symm)⟩

theorem tail_order {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (reverse : Bool) (rows : List VectorRow)
    (index : Nat) (positive : 0 < index) (previous previousAddress count : Linear)
    (accepted : checkVectors matrix tokens splits reverse rows index previous previousAddress count = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (p : MemoryTrace.Entry) (pBound : p.address < 2^64)
    (pActive : E values previous = (p.active.toNat : F)) (pAddress : E values previousAddress = (p.address : F)) :
    ∃ entries : List MemoryTrace.Entry, Related (Represents values) rows entries ∧
      (∀ e ∈ entries, Bounded e) ∧ ReadOnlyMemory.InitializerOrder (some p) entries := by
  induction rows generalizing index previous previousAddress count p with
  | nil => exact ⟨[],.nil,by simp,True.intro⟩
  | cons row rows ih =>
    have parts := Bool.and_eq_true_iff.mp accepted
    obtain ⟨e,image,bound⟩ := decode matrix tokens splits row reverse index previous previousAddress count parts.1 values oneValue satisfied
    obtain ⟨entries,images,bounds,order⟩ := ih (index+1) (by omega) (get row.fields 0) (get row.fields 1) row.count parts.2 e bound.1 image.1 image.2.1
    have step := step_order matrix tokens splits row reverse index positive previous previousAddress count parts.1 values oneValue satisfied p e image bound pBound pActive pAddress
    refine ⟨e::entries,.cons image images,?_,?_⟩
    · intro a member; rcases List.mem_cons.mp member with rfl | later; exact bound; exact bounds a later
    · exact ⟨by intro before same active; cases same; exact step active,order⟩

theorem checked_order {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (reverse : Bool) (rows : List VectorRow)
    (accepted : checkVectors matrix tokens splits reverse rows 0 o z z = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ entries : List MemoryTrace.Entry, Related (Represents values) rows entries ∧
      (∀ e ∈ entries, Bounded e) ∧ ReadOnlyMemory.Unique entries := by
  cases rows with
  | nil => exact ⟨[],.nil,by simp,List.Pairwise.nil⟩
  | cons row rows =>
    have parts := Bool.and_eq_true_iff.mp accepted
    obtain ⟨e,image,bound⟩ := decode matrix tokens splits row reverse 0 o z z parts.1 values oneValue satisfied
    obtain ⟨entries,images,bounds,order⟩ := tail_order matrix tokens splits reverse rows 1 (by decide) (get row.fields 0) (get row.fields 1) row.count parts.2 values oneValue satisfied e bound.1 image.1 image.2.1
    have fullOrder : ReadOnlyMemory.InitializerOrder none (e::entries) := by
      refine ⟨?_,order⟩
      intro prior same
      cases same
    refine ⟨e::entries,.cons image images,?_,ReadOnlyMemory.strict_unique _ (ReadOnlyMemory.ordered_initializers _ _ fullOrder)⟩
    intro a member; rcases List.mem_cons.mp member with rfl | later; exact bound; exact bounds a later

theorem checked_declaration_order {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits) (r : DeclarationMatrix.Record)
    (accepted : DeclarationSound.check matrix body tables splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ params results : List MemoryTrace.Entry,
      Related (Represents values) r.params params ∧ Related (Represents values) r.results results ∧
      (∀ e ∈ params, Bounded e) ∧ (∀ e ∈ results, Bounded e) ∧
      ReadOnlyMemory.Unique params ∧ ReadOnlyMemory.Unique results := by
  have record := (Bool.and_eq_true_iff.mp accepted).2
  have paramChecks : checkVectors matrix body.tokens splits true r.params 0 o z z = true := by
    have checks := record
    simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at checks
    grind only
  have resultChecks : checkVectors matrix body.tokens splits false r.results 0 o z z = true := by
    have checks := record
    simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at checks
    grind only
  obtain ⟨params,pi,pb,pu⟩ := checked_order matrix body.tokens splits true r.params paramChecks values oneValue satisfied
  obtain ⟨results,ri,rb,ru⟩ := checked_order matrix body.tokens splits false r.results resultChecks values oneValue satisfied
  exact ⟨params,results,pi,ri,pb,rb,pu,ru⟩

#print axioms decode
#print axioms step_order
#print axioms checked_order
#print axioms checked_declaration_order
end ZkBuild.DeclarationOrder

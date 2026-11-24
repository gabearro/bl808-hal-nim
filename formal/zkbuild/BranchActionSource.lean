import BranchActionLayout
import BranchActionCounters
import BranchTypedOperands
import BranchTypeArity
set_option autoImplicit false
namespace ZkBuild.BranchActionSource
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

theorem arity (rows : List Row) (ops : List Nat) (data : Nat → BranchTypeData.Data)
    (guards : BranchTypeSemanticSound.Guards rows ops data)
    (first last : Nat) (span : InstructionSpans.Span rows first last)
    (j : Nat) (lo : first<j) (hi : j<last) (marked : BranchTypeState.mark (rows.getD j default).kind (ops.getD j 0)=true) :
    (data j).size.val=(BranchTypeTrace.state rows ops data last).arity := by
  have initial := BranchTypeArity.marked rows ops data guards j (by have := span.bounded; omega) marked
  have carried := BranchTypeArity.interval rows ops data (j+1) (last-j-1) (by
    intro i lower upper
    have middle := InstructionSpanState.interior rows first last span i (by omega) (by omega)
    simp only [BranchTypePending.reset,middle.1,middle.2.1,or_self,decide_false]) initial.1
  rw [show j+1+(last-j-1)=last from by omega] at carried
  exact initial.2.symm.trans carried.2.symm

def Complete {F : Type} [Field F] (values : Nat → F) (body : ModuleAuditIO.SourceEnvelope)
    (splits : Splits) (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record)
    (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (r : StructuredMatrix.Record) (rows : List Row) (ops : List Nat) : Prop :=
  ∀ first last, InstructionSpans.Span rows first last → ops.getD first 0=14 →
    ∃ count previous, count<2^32 ∧
      BranchActionSequence.kinds rows (first+1) (last-first-1)=BranchActionLanguage.plan count previous ∧
      BranchActionLayout.Layout rows first last count previous ∧
      CallEvents.InputOk 0 (rows.getD (first+1) default).valueType.val ∧
      ∀ group, group≤previous →
        let j := BranchActionLayout.label first count group
        ∃ token : Fin (2^36), ∃ head : Fin (2^32), ∃ tags : List Nat,
          FrameDescriptor.Image values (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) j) token.val ∧
          BranchLabelLists.Image values tables indexed (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) j) head tags ∧
          BranchLabelLists.Origin values body tables declaration indexed signature token tags ∧ tags.length=count ∧
          (∀ ordinal, ordinal<count → CallEvents.InputOk
            (tags.getD (BranchTypedOperands.index token.val tags.length ordinal) 0)
            (rows.getD (j+1+ordinal) default).valueType.val) ∧
          (group<previous → ∀ ordinal, ordinal<count →
            (rows.getD (j+1+count+ordinal) default).valueType=(rows.getD (j+1+(count-1-ordinal)) default).valueType)

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : BranchTypeCertificate.check matrix splits tables statics events r=true)
    (lookupChecked : BranchLookupCheck.check matrix tables indexed r=true)
    (frames : FrameCertificate.check matrix events r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (labels : BranchLabelLists.Complete values body splits tables declaration indexed signature r rows ops)
    (typed : BranchTypedOperands.Complete values body splits tables declaration indexed signature r rows ops) :
    Complete values body splits tables declaration indexed signature r rows ops := by
  obtain ⟨data,facts,guards⟩ := BranchTypeSemanticSound.sound matrix splits tables indexed statics events r checked lookupChecked
    values one satisfied rows ops images schedule
  have restores := BranchTypeRestoration.sound matrix splits tables statics events r checked values one satisfied rows ops images schedule data facts
  have alphabet := BranchActionAlphabet.sound matrix events r frames values one satisfied rows ops images schedule
  have sequences := BranchActionSequence.complete values events rows ops schedule data guards alphabet
  have conditions := BranchConditionTrace.sound matrix splits tables statics events r checked values one satisfied rows ops images schedule sequences
  intro first last span active
  let count := (BranchTypeTrace.state rows ops data last).arity
  obtain ⟨previous,plan⟩ := BranchActionSequence.for_span values events rows ops schedule data guards alphabet first last span active
  have layout := BranchActionLayout.sound rows first last count previous span.ordered plan
  have condition := conditions first last span active
  have endIndex := layout.endIndex
  refine ⟨count,previous,(BranchTypeTrace.bounds rows ops data last).2.1,plan,layout,condition.2.2.1,?_⟩
  intro group gb
  let j := BranchActionLayout.label first count group
  have product := Nat.mul_le_mul_right (BranchActionLayout.width count) gb
  have jl : first<j := by dsimp [j,BranchActionLayout.label]; omega
  have jh : j<last := by dsimp [j,BranchActionLayout.label]; omega
  have jb : j<rows.length := by have := span.bounded; omega
  have kind : (rows.getD j default).kind=.labelCheck := layout.labels group gb
  have code := (InstructionSpanState.opcodes values events rows ops schedule first last span j (by omega) (by omega)).trans active
  have size : (data j).size.val=count := arity rows ops data guards first last span j jl jh
    (by simp only [BranchTypeState.mark,kind,code,and_self,decide_true])
  obtain ⟨token,head,tags,frame,list,origin⟩ := labels j jb kind code
  have length : tags.length=count := (DeclarationLocations.natural_equal (F:=F) tags.length (data j).size.val
    (by have := list.2.2.1; omega) (by have := (data j).size.isLt; omega)
    (list.2.1.symm.trans (facts j jb).1.1)).trans size
  refine ⟨token,head,tags,frame,list,origin,length,?_,?_⟩
  · intro ordinal ob
    let i := j+1+ordinal
    have il : first+1<i := by dsimp [i]; omega
    have ih : i<last := by dsimp [i,j,BranchActionLayout.label]; omega
    have pop := layout.pops group gb ordinal ob
    obtain ⟨other,oi,otherKind,otherCode,otherToken,otherHead,otherTags,otherFrame,otherList,otherOrigin,_,ok,between⟩ :=
      typed i (by have := span.bounded; omega) (condition.2.2.2 i il ih pop)
    have sameLabel : other=j := by
      by_cases earlier : other<j
      · have bad := (between j earlier (by dsimp [i]; omega)).2
        simp only [BranchTypeState.mark,kind,code,and_self,decide_true] at bad
        contradiction
      by_cases later : j<other
      · have offset : other=j+1+(other-j-1) := by omega
        have known := layout.pops group gb (other-j-1) (by dsimp [i] at oi; omega)
        rw [← offset] at known
        rw [known] at otherKind
        contradiction
      omega
    subst other
    have sameToken : otherToken=token := Fin.ext (DeclarationLocations.natural_equal (F:=F) otherToken.val token.val
      (by have := otherToken.isLt; omega) (by have := token.isLt; omega) (otherFrame.value.symm.trans frame.value))
    have sameList := BranchLabelLists.identify values tables indexed _ otherHead head otherTags tags otherList list.1 list.2.2.2
    rw [sameToken,sameList.2] at ok
    have offset : i-j-1=ordinal := by dsimp [i]; omega
    simpa only [offset] using ok
  · intro nongroup ordinal ob
    have next := Nat.mul_le_mul_right (BranchActionLayout.width count) (Nat.succ_le_of_lt nongroup)
    rw [Nat.succ_mul] at next
    have limit : j+1+2*count≤last := by
      dsimp [j,BranchActionLayout.label] at ⊢
      have widthEq : BranchActionLayout.width count=1+2*count := rfl
      omega
    exact BranchActionCounters.restored rows ops data guards restores j count
      (by have := span.bounded; omega) kind code size (layout.pops group gb) (layout.pushes group nongroup)
      (by intro k kb; exact (InstructionSpanState.opcodes values events rows ops schedule first last span (j+1+k) (by omega) (by omega)).trans active)
      ordinal ob

#print axioms arity
#print axioms sound
end ZkBuild.BranchActionSource

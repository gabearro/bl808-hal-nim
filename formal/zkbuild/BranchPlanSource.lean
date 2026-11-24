import BranchValuePlan
set_option autoImplicit false
namespace ZkBuild.BranchPlanSource
open Lean.Grind OperandEvents BranchPlans BranchActionLayout

def expected (token : Nat) (tags : List Nat) : List Nat :=
  (List.range tags.length).map (fun i => tags.getD (BranchTypedOperands.index token tags.length i) 0)

theorem compatible_pointwise (left right : List Nat) (size : left.length=right.length)
    (typed : ∀ i, i<left.length → CallEvents.InputOk (left.getD i 0) (right.getD i 0)) :
    Compatible left right := by
  refine ⟨size,?_⟩
  intro pair member
  obtain ⟨i,ib,equal⟩ := List.mem_iff_getElem.mp member
  have lb : i<left.length := by have := ib; simp only [List.length_zip] at this; omega
  have rb : i<right.length := by omega
  have h := typed i lb
  have somePair := List.getElem?_eq_getElem ib
  rw [equal] at somePair
  obtain ⟨ae,be⟩ := List.getElem?_zip_eq_some.mp somePair
  simpa only [List.getD,ae,be,Option.getD_some] using h

structure Target where
  token : Fin (2^36)
  head : Fin (2^32)
  tags : List Nat
  deriving Inhabited

def Authenticated {F : Type} [Field F] (values : Nat → F) (body : ModuleAuditIO.SourceEnvelope)
    (splits : DeclarationMatrix.Splits) (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record)
    (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (r : StructuredMatrix.Record) (j : Nat) (target : Target) : Prop :=
  FrameDescriptor.Image values (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) j) target.token.val ∧
    BranchLabelLists.Image values tables indexed (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) j) target.head target.tags ∧
    BranchLabelLists.Origin values body tables declaration indexed signature target.token target.tags

def Complete {F : Type} [Field F] (values : Nat → F) (body : ModuleAuditIO.SourceEnvelope)
    (splits : DeclarationMatrix.Splits) (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record)
    (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (r : StructuredMatrix.Record) (rows : List Row) (ops : List Nat) : Prop :=
  ∀ first last, InstructionSpans.Span rows first last → ops.getD first 0=14 →
    ∃ count previous actual targets,
      actual.length=count ∧ targets.length=previous+1 ∧
      (∀ group, group≤previous → ∃ target : Target,
        Authenticated values body splits tables declaration indexed signature r (label first count group) target ∧
        target.tags.length=count ∧ targets.getD group []=expected target.token.val target.tags) ∧
      (∀ target ∈ targets, Compatible target actual) ∧
      BranchValuePlan.actions rows (first+1) (last-first-1)=
        Action.pop (rows.getD (first+1) default).valueType.val :: plan actual targets ∧
      check targets (BranchValuePlan.actions rows (first+1) (last-first-1))=true

theorem sound {F : Type} [Field F] (values : Nat → F) (body : ModuleAuditIO.SourceEnvelope)
    (splits : DeclarationMatrix.Splits) (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record)
    (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (r : StructuredMatrix.Record) (rows : List Row) (ops : List Nat)
    (actions : BranchActionSource.Complete values body splits tables declaration indexed signature r rows ops)
    (floorFacts : BranchFloorInvariant.Complete rows ops) (trace : OperandStackCertificate.Trace rows) :
    Complete values body splits tables declaration indexed signature r rows ops := by
  classical
  intro first last span active
  obtain ⟨count,previous,_,kindPlan,layout,condition,groups⟩ := actions first last span active
  obtain ⟨floor,floors,_,_⟩ := floorFacts first last span active
  have mirror (group : Nat) (gb : group<previous) := (groups group (Nat.le_of_lt gb)).choose_spec.choose_spec.choose_spec.2.2.2.2.2 gb
  have common := BranchCommonOperands.all_groups rows first last count previous floor layout trace span.bounded floors mirror
  let actual := BranchCommonOperands.vector rows first count 0
  have source (group : Nat) (gb : group≤previous) : ∃ target : Target,
      Authenticated values body splits tables declaration indexed signature r (label first count group) target ∧
      target.tags.length=count ∧ Compatible (expected target.token.val target.tags) (actual.map Fin.val) := by
    obtain ⟨token,head,tags,frame,list,origin,len,typed,_⟩ := groups group gb
    refine ⟨⟨token,head,tags⟩,⟨frame,list,origin⟩,len,compatible_pointwise _ _ ?_ ?_⟩
    · simp only [expected,List.length_map,List.length_range,actual,BranchCommonOperands.vector,BranchOperandRuns.length,len]
    · intro i ib
      have bound : i<count := by simpa only [expected,List.length_map,List.length_range,len] using ib
      have tag := typed i bound
      have point := BranchOperandRuns.point rows (label first count group+1) count i bound
      change (BranchCommonOperands.vector rows first count group).getD i 0=_ at point
      rw [common group gb] at point
      change actual.getD i 0=(rows.getD (label first count group+1+i) default).valueType at point
      have actualBound : i<actual.length := by simp only [actual,BranchCommonOperands.vector,BranchOperandRuns.length]; exact bound
      simp only [List.getD,List.getElem?_eq_getElem actualBound,Option.getD_some] at point
      have tagBound : i<tags.length := by omega
      simpa only [expected,List.getD,List.getElem?_map,List.getElem?_range tagBound,Option.map_some,Option.getD_some,
        List.getElem?_eq_getElem actualBound,List.getElem_map,point] using tag
  let chosen (group : Nat) : Target := if h : group≤previous then Classical.choose (source group h) else default
  have chosenSpec (group : Nat) (gb : group≤previous) :
      Authenticated values body splits tables declaration indexed signature r (label first count group) (chosen group) ∧
      (chosen group).tags.length=count ∧ Compatible (expected (chosen group).token.val (chosen group).tags) (actual.map Fin.val) := by
    simpa only [chosen,dite_eq_left gb] using Classical.choose_spec (source group gb)
  let targets := (List.range (previous+1)).map (fun g => expected (chosen g).token.val (chosen g).tags)
  have targetSize : targets.length=previous+1 := by simp only [targets,List.length_map,List.length_range]
  have typed : ∀ target ∈ targets, Compatible target (actual.map Fin.val) := by
    intro target member
    obtain ⟨g,gb,rfl⟩ := List.mem_map.mp member
    have bound : g≤previous := by have := List.mem_range.mp gb; omega
    exact (chosenSpec g bound).2.2
  have bodyPlan := BranchValuePlan.body rows (first+2) count previous actual
    (by intro g gb; exact layout.labels g gb)
    (by intro g gb; exact layout.pops g gb)
    (by intro g gb; exact layout.pushes g gb)
    (by intro g gb; exact common g gb)
    (by
      intro g gb
      have reverse := BranchOperandRuns.reversed rows (label first count g+1) (label first count g+1+count) count (mirror g gb)
      rw [show BranchOperandRuns.values rows (label first count g+1) count=actual from common g (Nat.le_of_lt gb)] at reverse
      exact reverse)
    (by
      have endIndex := layout.endIndex
      have location : first+2+previous*(1+2*count)+1+count=last-1 := by
        change last=first+4+previous*(1+2*count)+count at endIndex
        omega
      rw [location]
      exact layout.clear)
  have begin := BranchConditionTrace.first rows first last count previous span.ordered kindPlan
  have equality : BranchValuePlan.actions rows (first+1) (last-first-1)=
      Action.pop (rows.getD (first+1) default).valueType.val :: plan (actual.map Fin.val) targets := by
    have endIndex := layout.endIndex
    change last=first+4+previous*(1+2*count)+count at endIndex
    rw [show last-first-1=(previous*(1+2*count)+count+2)+1 from by omega,BranchValuePlan.actions]
    rw [BranchValuePlan.action,begin.2,show first+1+1=first+2 from by omega,bodyPlan]
    rw [BranchValuePlan.target_values_irrelevant _ targets previous targetSize]
  refine ⟨count,previous,actual.map Fin.val,targets,?_,targetSize,?_,typed,equality,?_⟩
  · simp only [List.length_map,actual,BranchCommonOperands.vector,BranchOperandRuns.length]
  · intro group gb
    refine ⟨chosen group,(chosenSpec group gb).1,(chosenSpec group gb).2.1,?_⟩
    simp only [targets,List.getD,List.getElem?_map,List.getElem?_range (show group<previous+1 by omega),Option.map_some,Option.getD_some]
  · rw [equality]
    exact check_complete targets _ _ (by intro empty; rw [empty] at targetSize; simp only [List.length_nil] at targetSize; omega) condition typed

#print axioms compatible_pointwise
#print axioms sound
end ZkBuild.BranchPlanSource

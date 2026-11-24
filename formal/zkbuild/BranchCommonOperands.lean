import BranchActionSource
import BranchFloorInvariant
import BranchOperandRuns
set_option autoImplicit false
namespace ZkBuild.BranchCommonOperands
open OperandEvents OperandStackTrace BranchActionLayout

def vector (rows : List Row) (first count group : Nat) :=
  BranchOperandRuns.values rows (label first count group+1) count

theorem adjacent (rows : List Row) (first last count previous floor group : Nat)
    (layout : Layout rows first last count previous)
    (trace : OperandStackCertificate.Trace rows) (lastBound : last<rows.length)
    (floors : ∀ i, first<i → i≤last → (rows.getD i default).floor=floor)
    (gb : group<previous)
    (mirror : ∀ i, i<count →
      (rows.getD (label first count group+1+count+i) default).valueType=
      (rows.getD (label first count group+1+(count-1-i)) default).valueType) :
    vector rows first count (group+1)=vector rows first count group := by
  by_cases empty : count=0
  · simp only [vector,empty,BranchOperandRuns.values]
  have positive : 0<count := by omega
  let j := label first count group
  let next := label first count (group+1)
  have adjacency : next=j+1+2*count := by dsimp [next,j,label,width]; rw [Nat.succ_mul]; omega
  have bounds : first<j ∧ next+count<last := by
    have product := Nat.mul_le_mul_right (width count) (Nat.succ_le_of_lt gb)
    change (group+1)*width count≤previous*width count at product
    have endIndex := layout.endIndex
    dsimp [j,next,label]
    omega
  have restored := BranchOperandRuns.pushes rows (j+1+count) count (layout.pushes group gb)
  have reversed := BranchOperandRuns.reversed rows (j+1) (j+1+count) count mirror
  rw [reversed] at restored
  have nextEq : stack rows (next+1)=stack rows (j+1+count)++(vector rows first count group).reverse := by
    have kind : (rows.getD next default).kind=.labelCheck := layout.labels (group+1) (by omega)
    rw [OperandStackTrace.stack,OperandStackRefinement.next,kind]
    simpa only [adjacency,show j+1+count+count=j+1+2*count from by omega,vector] using restored
  have lastPop := layout.pops group (by omega) (count-1) (by omega)
  have location : j+1+(count-1)=j+count := by omega
  change (rows.getD (j+1+(count-1)) default).kind=.pop at lastPop
  rw [location] at lastPop
  have lower := BranchOperandRuns.floor_after rows (j+count) lastPop (trace.2.2 (j+count) (by omega))
  have floorEq := floors (j+count) (by omega) (by omega)
  rw [floorEq,show j+count+1=j+1+count from by omega] at lower
  have nextGroup := BranchOperandRuns.restored rows (next+1) (stack rows (j+1+count))
    (vector rows first count group) nextEq
    (by intro i ib; exact layout.pops (group+1) (by omega) i (by simpa only [vector,BranchOperandRuns.length] using ib))
    (by intro i ib; simp only [vector,BranchOperandRuns.length] at ib; exact trace.2.2 (next+1+i) (by omega))
    (by
      intro i ib
      simp only [vector,BranchOperandRuns.length] at ib
      rw [floors (next+1+i) (by omega) (by omega)]
      exact lower)
  simpa only [vector,BranchOperandRuns.length] using nextGroup.1

theorem all_groups (rows : List Row) (first last count previous floor : Nat)
    (layout : Layout rows first last count previous)
    (trace : OperandStackCertificate.Trace rows) (lastBound : last<rows.length)
    (floors : ∀ i, first<i → i≤last → (rows.getD i default).floor=floor)
    (mirror : ∀ group, group<previous → ∀ i, i<count →
      (rows.getD (label first count group+1+count+i) default).valueType=
      (rows.getD (label first count group+1+(count-1-i)) default).valueType) :
    ∀ group, group≤previous → vector rows first count group=vector rows first count 0 := by
  intro group gb
  induction group with
  | zero => rfl
  | succ group ih =>
    exact (adjacent rows first last count previous floor group layout trace lastBound floors (by omega) (mirror group (by omega))).trans (ih (by omega))

def Complete (rows : List Row) (ops : List Nat) : Prop :=
  ∀ first last, InstructionSpans.Span rows first last → ops.getD first 0=14 →
    ∃ count previous, BranchActionLayout.Layout rows first last count previous ∧
      ∀ group, group≤previous → vector rows first count group=vector rows first count 0

theorem sound {F : Type} [Lean.Grind.Field F] (values : Nat → F) (body : ModuleAuditIO.SourceEnvelope)
    (splits : DeclarationMatrix.Splits) (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record)
    (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (r : StructuredMatrix.Record) (rows : List Row) (ops : List Nat)
    (actions : BranchActionSource.Complete values body splits tables declaration indexed signature r rows ops)
    (floorFacts : BranchFloorInvariant.Complete rows ops) (trace : OperandStackCertificate.Trace rows) :
    Complete rows ops := by
  intro first last span active
  obtain ⟨count,previous,_,_,layout,_,groups⟩ := actions first last span active
  obtain ⟨floor,floors,_,_⟩ := floorFacts first last span active
  refine ⟨count,previous,layout,all_groups rows first last count previous floor layout trace span.bounded floors ?_⟩
  intro group gb
  obtain ⟨token,head,tags,frame,list,origin,len,typed,mirror⟩ := groups group (by omega)
  exact mirror gb

#print axioms adjacent
#print axioms all_groups
#print axioms sound
end ZkBuild.BranchCommonOperands

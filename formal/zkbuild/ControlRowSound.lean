import ControlRowCheck
import OperandRowSound
set_option autoImplicit false
namespace ZkBuild.ControlRowSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

structure Represents {F : Type} [Field F] (values : Nat → F) (r : ControlRowCheck.Record)
    (row : OperandEvents.Row) : Prop where
  functionIndex : E values (f r.row 1) = (row.functionIndex : F)
  height : E values (f r.row 2) = (row.height : F)
  floor : E values (f r.row 3) = (row.floor : F)
  polymorphic : E values (f r.row 5) = OperandEvents.flag row.polymorphic
  unreachable : E values (f r.row 6) = OperandEvents.flag row.unreachable
  tags : ∀ (i : Nat), E values (f r.tags i) =
    (EventSelectors.codes.map (fun code => OperandEvents.flag (decide (code = OperandEvents.kindCode row.kind)))).getD i 0

theorem tag {F : Type} [Field F] (values : Nat → F) (r : ControlRowCheck.Record)
    (row : OperandEvents.Row) (image : Represents values r row) :
    E values (f r.tags 0) = ControlEvents.selected row.kind .functionBegin ∧
    E values (f r.tags 2) = ControlEvents.selected row.kind .push ∧
    E values (f r.tags 3) = ControlEvents.selected row.kind .pop ∧
    E values (f r.tags 4) = ControlEvents.selected row.kind .controlPush ∧
    E values (f r.tags 5) = ControlEvents.selected row.kind .controlPop ∧
    E values (f r.tags 6) = ControlEvents.selected row.kind .clear ∧
    E values (f r.tags 8) = ControlEvents.selected row.kind .functionEnd ∧
    E values (f r.tags 10) = ControlEvents.selected row.kind .padding := by
  have a := image.tags 0
  have b := image.tags 2
  have c := image.tags 3
  have d := image.tags 4
  have e := image.tags 5
  have f := image.tags 6
  have g := image.tags 8
  have h := image.tags 10
  cases k : row.kind <;> simpa [EventSelectors.codes,OperandEvents.kindCode,ControlEvents.selected,k] using
    And.intro a (And.intro b (And.intro c (And.intro d (And.intro e (And.intro f (And.intro g h))))))

def Facts {F : Type} [Field F] (values : Nat → F) (r : ControlRowCheck.Record) : Prop :=
  AllHold values (ControlRowCheck.stepGates r++ControlRowCheck.functionGates r++ControlRowCheck.accessGates r) ∧
  (∃ depth : Nat, depth < 2^32 ∧ E values (f r.row 7) = (depth : F)) ∧
  E values (f r.input 0) = E values (f r.tags 2++sub (f r.tags 3) (f r.row 5)) ∧
  E values (f r.read 0) = E values (sub o r.empty) ∧ E values (f r.read 1) = E values z ∧
  E values (f r.write 0) = E values (f r.tags 4++f r.tags 6) ∧
  E values (f r.write 1) = E values (f r.tags 4++f r.tags 6) ∧
  E values (f r.write 3) = E values (scale (r.pushed++r.cleared) 2++f r.tags 6)

theorem facts {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : ControlRowCheck.Record) (checked : ControlRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) : Facts values r := by
  have parts := checked
  simp only [ControlRowCheck.check,Bool.and_eq_true_iff,decide_eq_true_eq,and_assoc] at parts
  rcases parts with ⟨_,_,_,_,gates,range,inputs⟩
  have same := SourceProgramSound.normalized_inputs values _ _ inputs
  simp only [List.map_cons,List.map_nil,List.cons.injEq,and_true] at same
  have cert := RangeUse.checked_certificate matrix _ _ _ range values one satisfied
  obtain ⟨depth,db,di,_⟩ := TokenInteger.certificate_nat values one _ _ _ cert
  exact ⟨OperandRowSound.includes_sound matrix _ _ _ gates values satisfied,⟨depth,db,di⟩,same⟩

theorem step {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : ControlRowCheck.Record) (checked : ControlRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (before : Nat) (beforeBound : before < 2^32) (beforeImage : E values r.beforeDepth = (before : F))
    (row : OperandEvents.Row) (image : Represents values r row)
    (heightBound : row.height < 2^32) (floorBound : row.floor < 2^32) :
    ∃ after : Nat, after < 2^32 ∧ E values (f r.row 7) = (after : F) ∧
      ControlEvents.Spec before after row ∧
      E values r.empty = (if before = 0 then 1 else 0) := by
  have fs := facts matrix r checked values one satisfied
  obtain ⟨after,ab,ai⟩ := fs.2.1
  obtain ⟨t0,t2,t3,t4,t5,t6,t8,t10⟩ := tag values r row image
  have raw (a b : Linear) (h : Holds values (gate a b)) : E values a * E values b = 0 := by
    change E values a * E values b = E values z at h
    simpa [z,eval_constant values one,Ring.intCast_zero] using h
  have all := fs.1
  have h0 := raw r.beforeDepth r.empty (all _ (by simp [ControlRowCheck.stepGates]))
  have h1 := multiply_sound values r.beforeDepth r.reciprocal (sub o r.empty) (all _ (by simp [ControlRowCheck.stepGates]))
  have h2 := raw r.empty (scale (f r.row 3) 2++f r.row 6) (all _ (by simp [ControlRowCheck.stepGates]))
  have h3 := raw (f r.tags 5++f r.tags 6) r.empty (all _ (by simp [ControlRowCheck.stepGates]))
  have h4 := raw (f r.input 0++f r.row 5) r.empty (all _ (by simp [ControlRowCheck.stepGates]))
  have h5 := equality_sound values one (f r.row 7) (sub (r.beforeDepth++f r.tags 4) (f r.tags 5)) (all _ (by simp [ControlRowCheck.stepGates]))
  have h6 := raw (f r.tags 5) (sub (f r.row 2) (f r.row 3)) (all _ (by simp [ControlRowCheck.stepGates]))
  have h7 := raw (f r.tags 0++f r.tags 8++f r.tags 10) (f r.row 7) (all _ (by simp [ControlRowCheck.stepGates]))
  have active := fs.2.2.1
  have gates : ControlEvents.Gates before after row (E values r.empty) (E values r.reciprocal) := by
    simp only [eval_append,eval_sub,eval_scale,o,eval_constant values one,Ring.intCast_one,
      show ((2 : Int) : F) = 2 from Ring.intCast_ofNat 2,beforeImage,image.floor,image.unreachable,image.height,image.polymorphic,
      t0,t2,t3,t4,t5,t6,t8,t10,ai] at h0 h1 h2 h3 h4 h5 h6 h7 active
    exact ⟨h0,h1.symm,h2,h3,by grind only,h5,h6,h7⟩
  exact ⟨after,ab,ai,ControlEvents.step_sound before after row _ _ beforeBound ab floorBound heightBound gates,
    ControlEvents.empty_sound before beforeBound _ _ gates.zero gates.inverse⟩

theorem function_step {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : ControlRowCheck.Record) (checked : ControlRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (row : OperandEvents.Row) (image : Represents values r row)
    (opened : Bool) (index : Nat) (openImage : E values r.opened = OperandEvents.flag opened)
    (indexImage : E values r.index = (index : F))
    (indexBound : index ≤ 2^32) (rowBound : row.functionIndex < 2^32) :
    FunctionEvents.ScheduleOk opened row.kind ∧ (row.kind ≠ .padding → row.functionIndex = index) ∧
    E values r.afterOpen = OperandEvents.flag (FunctionEvents.nextOpen opened row.kind) ∧
    E values r.afterIndex = (FunctionEvents.nextIndex index row.kind : F) ∧
    FunctionEvents.nextIndex index row.kind ≤ 2^32 := by
  have fs := facts matrix r checked values one satisfied
  obtain ⟨t0,_,_,_,_,_,t8,t10⟩ := tag values r row image
  have raw (a b : Linear) (h : Holds values (gate a b)) : E values a * E values b = 0 := by
    change E values a * E values b = E values z at h
    simpa [z,eval_constant values one,Ring.intCast_zero] using h
  have h0 := raw (f r.tags 0++f r.tags 10) r.opened (fs.1 _ (by simp [ControlRowCheck.functionGates]))
  have h1 := raw (sub (sub o (f r.tags 0)) (f r.tags 10)) (sub o r.opened) (fs.1 _ (by simp [ControlRowCheck.functionGates]))
  have h2 := raw (sub o (f r.tags 10)) (sub (f r.row 1) r.index) (fs.1 _ (by simp [ControlRowCheck.functionGates]))
  have h3 := equality_sound values one r.afterOpen (sub (r.opened++f r.tags 0) (f r.tags 8)) (fs.1 _ (by simp [ControlRowCheck.functionGates]))
  have h4 := equality_sound values one r.afterIndex (r.index++f r.tags 8) (fs.1 _ (by simp [ControlRowCheck.functionGates]))
  have gates : FunctionEvents.Gates opened row.kind index row.functionIndex
      (E values r.afterOpen) (E values r.afterIndex) := by
    simp only [eval_append,eval_sub,o,eval_constant values one,Ring.intCast_one,
      image.functionIndex,openImage,indexImage,t0,t8,t10] at h0 h1 h2 h3 h4
    exact ⟨h0,h1,h2,h3,h4⟩
  exact FunctionEvents.step_sound opened row.kind index row.functionIndex _ _ indexBound rowBound gates

theorem accesses {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : ControlRowCheck.Record) (checked : ControlRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (before height : Nat) (beforeBound : before < 2^32)
    (beforeImage : E values r.beforeDepth = (before : F)) (heightImage : E values r.beforeHeight = (height : F))
    (row : OperandEvents.Row) (image : Represents values r row)
    (heightBound : row.height < 2^32) (floorBound : row.floor < 2^32) :
    E values (f r.read 0) = OperandEvents.flag (ControlEvents.readProject before row).active ∧
    E values (f r.read 1) = 0 ∧
    E values (f r.read 2) = ((ControlEvents.readProject before row).address : F) ∧
    E values (f r.read 3) = ((ControlEvents.readProject before row).value : F) ∧
    E values (f r.write 0) = OperandEvents.flag (ControlEvents.writeProject before height row).active ∧
    E values (f r.write 1) = OperandEvents.flag (ControlEvents.writeProject before height row).write ∧
    E values (f r.write 2) = ((ControlEvents.writeProject before height row).address : F) ∧
    E values (f r.write 3) = ((ControlEvents.writeProject before height row).value : F) := by
  have fs := facts matrix r checked values one satisfied
  obtain ⟨after,_,_,spec,empty⟩ := step matrix r checked values one satisfied before beforeBound beforeImage row image heightBound floorBound
  obtain ⟨_,_,_,t4,_,t6,_,_⟩ := tag values r row image
  have h0 := multiply_sound values (sub o r.empty)
    (sub (scale (f r.row 1) (Int.ofNat (2^32))++r.beforeDepth) o) (f r.read 2) (fs.1 _ (by simp [ControlRowCheck.accessGates]))
  have h1 := multiply_sound values (sub o r.empty) (scale (f r.row 3) 2++f r.row 6) (f r.read 3) (fs.1 _ (by simp [ControlRowCheck.accessGates]))
  have h2 := multiply_sound values (f r.tags 4++f r.tags 6)
    (sub (scale (f r.row 1) (Int.ofNat (2^32))++r.beforeDepth) (f r.tags 6)) (f r.write 2) (fs.1 _ (by simp [ControlRowCheck.accessGates]))
  have h3 := multiply_sound values (f r.tags 4) r.beforeHeight r.pushed (fs.1 _ (by simp [ControlRowCheck.accessGates]))
  have h4 := multiply_sound values (f r.tags 6) (f r.row 3) r.cleared (fs.1 _ (by simp [ControlRowCheck.accessGates]))
  have ra := fs.2.2.2.1
  have rw := fs.2.2.2.2.1
  have wa := fs.2.2.2.2.2.1
  have ww := fs.2.2.2.2.2.2.1
  have wv := fs.2.2.2.2.2.2.2
  have gates : ControlEvents.AccessGates before height row (E values r.empty)
      (E values (f r.read 0)) (E values (f r.read 2)) (E values (f r.read 3))
      (E values (f r.write 0)) (E values (f r.write 2)) (E values (f r.write 3)) := by
    simp only [eval_sub,eval_append,eval_scale,o,eval_constant values one,Ring.intCast_one,
      Int.ofNat_eq_natCast,Ring.intCast_natCast,show ((2 : Int) : F) = 2 from Ring.intCast_ofNat 2,
      image.functionIndex,image.floor,image.unreachable,beforeImage,heightImage,t4,t6] at h0 h1 h2 h3 h4 ra wa wv
    refine ⟨ra,?_,?_,wa,?_,?_⟩
    · unfold OperandEvents.bound; grind only
    · grind only
    · unfold OperandEvents.bound; grind only
    · grind only
  obtain ⟨ra',rd',rv',wa',wd',wv'⟩ := ControlEvents.projection_sound before height after row _ _ _ _ _ _ _ empty spec gates
  have readZero : E values (f r.read 1) = 0 := by simpa [z,eval_constant values one,Ring.intCast_zero] using rw
  have writeSame : E values (f r.write 1) = E values (f r.write 0) := ww.trans wa.symm
  have writeBit : (ControlEvents.writeProject before height row).write = (ControlEvents.writeProject before height row).active := by
    cases k : row.kind <;> simp [ControlEvents.writeProject,k]
  exact ⟨ra',readZero,rd',rv',wa',by rw [writeSame,wa',writeBit],wd',wv'⟩

#print axioms function_step
#print axioms accesses

#print axioms facts
#print axioms step
end ZkBuild.ControlRowSound

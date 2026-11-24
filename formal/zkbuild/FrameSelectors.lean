import FrameSound
set_option autoImplicit false
namespace ZkBuild.FrameSelectors
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

structure Tags {F : Type} [Field F] (values : Nat → F) (r : FrameRowCheck.Record) (kind : Kind) : Prop where
  functionBegin : E values (f r.flags 0) = flag (decide (kind = .functionBegin))
  instructionBegin : E values (f r.flags 1) = flag (decide (kind = .instructionBegin))
  controlPush : E values (f r.flags 4) = flag (decide (kind = .controlPush))
  controlPop : E values (f r.flags 5) = flag (decide (kind = .controlPop))
  label : E values (f r.flags 9) = flag (decide (kind = .labelCheck))

theorem tags {F : Type} [Field F] (values : Nat → F) (one : values 0 = 1)
    (r : FrameRowCheck.Record) (row : Row) (op : Nat) (image : FrameCertificate.Images values r row op) :
    Tags values r row.kind := by
  have zero : E values z = 0 := by simpa only [z,Ring.intCast_zero] using eval_constant values one 0
  have point (i : Nat) : E values (f r.flags i) =
      (EventSelectors.codes.map (fun c => flag (F:=F) (decide (c=kindCode row.kind)))).getD i 0 := by
    have h := congrArg (fun xs : List F => xs.getD i 0) image.tags
    rw [← zero,TokenInteger.map_getD] at h
    simpa only [f,DeclarationMatrix.get,zero] using h
  have t0 := point 0
  have t1 := point 1
  have t4 := point 4
  have t5 := point 5
  have t9 := point 9
  constructor
  all_goals cases k : row.kind <;> simp_all [EventSelectors.codes,kindCode]

def reads (kind : Kind) (code : Nat) : Bool :=
  (decide (kind = .instructionBegin) && (FrameOpcodes.branches code || FrameOpcodes.closes code)) || decide (kind = .labelCheck)

theorem active {F : Type} [Field F]
    (values : Nat → F) (r : FrameRowCheck.Record) (kind : Kind) (code : Nat)
    (tag : Tags values r kind) (op : FrameOpcodes.Categories values r code)
    (multiply : E values (f r.after 13) = E values (f r.flags 1)*E values (FrameRowCheck.branching r++FrameRowCheck.closing r)) :
    E values (FrameRowCheck.readActive r) = flag (reads kind code) := by
  have combined : E values (FrameRowCheck.branching r++FrameRowCheck.closing r) =
      flag (FrameOpcodes.branches code || FrameOpcodes.closes code) := by
    simp only [eval_append,op.isBranching,op.isClosing]
    have disjoint : FrameOpcodes.branches code = true → FrameOpcodes.closes code = false := by
      simp only [FrameOpcodes.branches,FrameOpcodes.closes,decide_eq_true_eq,decide_eq_false_iff_not]
      omega
    cases a : FrameOpcodes.branches code <;> cases b : FrameOpcodes.closes code <;>
      simp_all [flag,AddCommMonoid.zero_add,AddCommMonoid.add_zero]
  simp only [FrameRowCheck.readActive,eval_append,multiply,tag.instructionBegin,tag.label,combined]
  cases kind <;> cases c : (FrameOpcodes.branches code || FrameOpcodes.closes code) <;>
    simp [reads,flag,c,Semiring.zero_mul,Semiring.one_mul,AddCommMonoid.add_zero,AddCommMonoid.zero_add]

#print axioms tags
#print axioms active
end ZkBuild.FrameSelectors

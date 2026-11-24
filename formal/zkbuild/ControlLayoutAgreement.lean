import ControlValueBody
set_option autoImplicit false
namespace ZkBuild.ControlLayoutAgreement
open ControlPlans

def code : Mode → Nat
  | .blockOp => 2 | .loopOp => 3 | .ifOp => 4 | .elseOp => 5 | .endOp => 11
  | .brOp => 12 | .brIfOp => 13 | .returnOp => 15 | .tryOp => 31
def token (mode : Mode) (root loop : Bool) : Nat :=
  match mode with
  | .endOp => if root then 4 else 0
  | .brOp | .brIfOp => if loop then 1 else 0
  | .returnOp => 4
  | .loopOp => 1
  | .ifOp | .elseOp => 2
  | _ => 0
def parameters (mode : Mode) (params labels : List Nat) (loop : Bool) : List Nat :=
  match mode with
  | .brOp | .brIfOp => if loop then labels.reverse else params.reverse
  | _ => params.reverse
def results (mode : Mode) (values labels : List Nat) (loop : Bool) : List Nat :=
  match mode with
  | .brOp | .brIfOp => if loop then values else labels
  | _ => values

/-- Indexed parameter lists are stored in pop order. With the source frame's
    root/loop classification, the gate-derived layout equals the independent
    nine-mode control specification for arbitrary type vectors. -/
theorem layout (mode : Mode) (params values labels : List Nat) (root loop : Bool) :
    ControlValueBody.layout (code mode) (token mode root loop) (parameters mode params labels loop) (results mode values labels loop)=
      ControlPlans.layout mode params values labels root := by
  cases mode <;> cases root <;> cases loop <;>
    simp [code,token,parameters,results,ControlValueBody.layout,ControlPlans.layout,
      ControlTypeMasks.condition,ControlTypeGuards.opening,ControlTypeGuards.clearing,
      FrameOpcodes.opens,FrameOpcodes.closes,FrameOpcodes.branches,
      ControlValueTypes.inputs,ControlValueTypes.outputs,ControlValueTypes.orient,
      ControlMemberSource.inputTypes,ControlMemberSource.outputTypes,ControlMemberSource.inputMode,ControlMemberSource.outputMode,
      ControlMemberRouting.inputParams,ControlMemberRouting.outputParams,ControlListArity.outputCount,ControlListArity.resultMode]

#print axioms layout
end ZkBuild.ControlLayoutAgreement

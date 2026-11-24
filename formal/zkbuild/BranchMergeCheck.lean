import InactiveAddress
import BranchTypeRowImages
set_option autoImplicit false
namespace ZkBuild.BranchMergeCheck
open CircuitShape GadgetShape DeclarationMatrix ValidationEventMatrix

structure Record where
  control : ReadOnlyMatrix.Entry
  branch : ReadOnlyMatrix.Entry
  merged : ReadOnlyMatrix.Entry
  controlAddress : InactiveAddress.Record
  branchAddress : InactiveAddress.Record
  first : Nat
  last : Nat
  deriving Inhabited
def gates (r : Record) : List Gate :=
  [gate r.control.active r.branch.active,gate (sub o r.control.active) r.control.value,
   gate (sub o r.branch.active) r.branch.value]
def links (r : Record) : Prop :=
  ModuleProgram.sameInputs
    [r.merged.active,r.merged.address,r.merged.value,r.controlAddress.active,r.controlAddress.address,
     r.branchAddress.active,r.branchAddress.address]
    [r.control.active++r.branch.active,r.control.address++r.branch.address,r.control.value++r.branch.value,
     r.control.active,r.control.address,r.branch.active,r.branch.address]
instance (r : Record) : Decidable (links r) := by unfold links; infer_instance
def check (matrix : Shape) (r : Record) : Bool :=
  decide (links r) && MemoryEvidence.checkSpan matrix r.first r.last (gates r) &&
  InactiveAddress.check matrix r.controlAddress && InactiveAddress.check matrix r.branchAddress

def queryAt (s : DynamicTypingMatrix.Stage) (i family : Nat) := BranchTypeRowCheck.query (rowAt s.outputs i) (3*family)
def address (s : DynamicTypingMatrix.Stage) (i family stride : Nat) (branch : Bool) : InactiveAddress.Record :=
  let q := queryAt s i family
  let op := fun k => s.program.base.operations.getD (stride*i+k) default
  let indices := if branch then [15,22,39,17] else [2,9,41,4]
  let k := indices.getD family 0
  let term := fun index coefficient =>
    InactiveAddress.Term.mk coefficient ((op index).call.inputs.getD 1 []) ((op index).call.outputs.getD 0 [])
  ⟨q.active,q.address,if family = 2 then [term k (Int.ofNat (2^32)),term (k+1) 1] else [term k 1],
   (op 0).call.firstGate,if i+1 < s.rows.length then (op stride).call.firstGate else s.program.base.lastGate⟩

def record (r : StructuredMatrix.Record) (i family : Nat) : Record :=
  let control := StructuredMatrix.stage r 4
  let branch := StructuredMatrix.stage r 5
  let merged := StructuredMatrix.stage r 6
  ⟨queryAt control i family,queryAt branch i family,queryAt merged i family,
   address control i family 63 false,address branch i family 53 true,
   merged.program.base.firstGate+12*i+3*family,merged.program.base.firstGate+12*i+3*family+3⟩

def checkStage (matrix : Shape) (r : StructuredMatrix.Record) : Bool :=
  let c := StructuredMatrix.stage r 4
  let b := StructuredMatrix.stage r 5
  let m := StructuredMatrix.stage r 6
  decide (c.rows.length = b.rows.length ∧ m.rows.length = b.rows.length ∧
    c.program.base.operations.length = 63*c.rows.length ∧ b.program.base.operations.length = 53*b.rows.length ∧
    m.program.base.operations = [] ∧ m.program.base.lastGate = m.program.base.firstGate+12*b.rows.length) &&
  (List.range b.rows.length).all (fun i => (List.range 4).all (fun family => check matrix (record r i family)))
end ZkBuild.BranchMergeCheck

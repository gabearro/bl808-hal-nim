import OperandRowCheck
import ControlEvents
import FunctionEvents
set_option autoImplicit false
namespace ZkBuild.ControlRowCheck
open CircuitShape GadgetShape DeclarationMatrix ValidationEventMatrix

structure Record where
  row : Fields
  tags : Fields
  input : Fields
  read : Fields
  write : Fields
  beforeDepth : Linear
  beforeHeight : Linear
  empty : Linear
  reciprocal : Linear
  depthRange : RangeUse.Record
  pushed : Linear
  cleared : Linear
  opened : Linear
  index : Linear
  afterOpen : Linear
  afterIndex : Linear
  first : Nat
  last : Nat
  deriving Inhabited

def stepGates (r : Record) : List Gate :=
  [gate r.beforeDepth r.empty,
   mulGate r.beforeDepth r.reciprocal (sub o r.empty),
   gate r.empty (scale (f r.row 3) 2++f r.row 6),
   gate (f r.tags 5++f r.tags 6) r.empty,
   gate (f r.input 0++f r.row 5) r.empty,
   eqGate (f r.row 7) (sub (r.beforeDepth++f r.tags 4) (f r.tags 5)),
   gate (f r.tags 5) (sub (f r.row 2) (f r.row 3)),
   gate (f r.tags 0++f r.tags 8++f r.tags 10) (f r.row 7)]

def functionGates (r : Record) : List Gate :=
  [gate (f r.tags 0++f r.tags 10) r.opened,
   gate (sub (sub o (f r.tags 0)) (f r.tags 10)) (sub o r.opened),
   gate (sub o (f r.tags 10)) (sub (f r.row 1) r.index),
   eqGate r.afterOpen (sub (r.opened++f r.tags 0) (f r.tags 8)),
   eqGate r.afterIndex (r.index++f r.tags 8)]

def accessGates (r : Record) : List Gate :=
  let active := f r.tags 4++f r.tags 6
  let space := scale (f r.row 1) (Int.ofNat (2^32))
  [mulGate (sub o r.empty) (sub (space++r.beforeDepth) o) (f r.read 2),
   mulGate (sub o r.empty) (scale (f r.row 3) 2++f r.row 6) (f r.read 3),
   mulGate active (sub (space++r.beforeDepth) (f r.tags 6)) (f r.write 2),
   mulGate (f r.tags 4) r.beforeHeight r.pushed,
   mulGate (f r.tags 6) (f r.row 3) r.cleared]

def check (matrix : Shape) (r : Record) : Bool :=
  decide (r.row.length = 8 ∧ r.tags.length = 11 ∧ r.read.length = 4 ∧ r.write.length = 4) &&
  OperandRowCheck.includes matrix r.first r.last (stepGates r++functionGates r++accessGates r) &&
  RangeUse.check matrix r.depthRange (f r.row 7) 32 &&
  decide (ModuleProgram.sameInputs [f r.input 0,f r.read 0,f r.read 1,f r.write 0,f r.write 1,f r.write 3]
    [f r.tags 2++sub (f r.tags 3) (f r.row 5),sub o r.empty,z,
     f r.tags 4++f r.tags 6,f r.tags 4++f r.tags 6,scale (r.pushed++r.cleared) 2++f r.tags 6])

def op (s : Stage) (i k : Nat) := s.program.base.operations.getD (1+10*i+k) default

def record (s : Stage) (i : Nat) : Record :=
  ⟨rowAt s.rows i,rowAt s.flags i,rowAt s.inputs i,rowAt s.outputs (2*i),rowAt s.outputs (2*i+1),
   (if i = 0 then z else f (rowAt s.rows (i-1)) 7),
   (if i = 0 then z else f (rowAt s.rows (i-1)) 2),
   (op s i 1).call.outputs.getD 0 [],(op s i 1).call.outputs.getD 1 [],op s i 0,
   (op s i 8).call.outputs.getD 0 [],(op s i 9).call.outputs.getD 0 [],
   (if i = 0 then z else (op s (i-1) 3).call.outputs.getD 0 []),
   (if i = 0 then s.firstFunction else (op s (i-1) 4).call.outputs.getD 0 []),
   (op s i 3).call.outputs.getD 0 [],(op s i 4).call.outputs.getD 0 [],
   (op s i 0).call.firstGate,(op s i 9).call.lastGate⟩

def checkStage (matrix : Shape) (s : Stage) : Bool :=
  s.kind == 2 && s.program.blocks.isEmpty && s.program.base.operations.length == 10*s.rows.length+3 &&
  RangeUse.check matrix (s.program.base.operations.getD 0 default) s.firstFunction 32 &&
  OperandRowCheck.includes matrix (op s s.rows.length 0).call.firstGate (op s s.rows.length 1).call.lastGate
    [eqGate (if s.rows.isEmpty then z else f (rowAt s.rows (s.rows.length-1)) 7) z,
     eqGate (if s.rows.isEmpty then z else (op s (s.rows.length-1) 3).call.outputs.getD 0 []) z] &&
  (List.range s.rows.length).all (fun i => check matrix (record s i))
end ZkBuild.ControlRowCheck

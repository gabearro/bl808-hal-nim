import BranchTypeRowSound
import NameBits
set_option autoImplicit false
namespace ZkBuild.FrameRowCheck
open CircuitShape GadgetShape DeclarationMatrix ValidationEventMatrix

structure Record where
  index : Nat
  row : Fields
  flags : Fields
  inputs : Fields
  before : Fields
  after : Fields
  reciprocals : Fields
  ranges : List RangeUse.Record
  outputs : Fields
  read : MemoryPacking.Access
  write : MemoryPacking.Access
  first : Nat
  last : Nat
  deriving Inhabited

def codes : List Nat := [2,3,4,5,11,31,12,13,15]
def opening (r : Record) := f r.after 0++f r.after 1++f r.after 2++f r.after 5
def branching (r : Record) := f r.after 6++f r.after 7++f r.after 8
def closing (r : Record) := f r.after 3++f r.after 4
def reset (r : Record) := f r.flags 0++f r.flags 1
def readActive (r : Record) := f r.after 13++f r.flags 9
def space (r : Record) := scale (f r.row 1) (Int.ofNat (2^32))
def rootToken (r : Record) := scale (f r.row 1) 16++n 4
def bit (r : Record) (i : Nat) := f (RangeUse.bits (r.ranges.getD 4 default)) i
def singleton (r : Record) := ((List.range 7).map (fun i => f r.after (22+i))).flatten
def singletonKey (r : Record) := ((List.range 7).map (fun i => scale (f r.after (22+i)) (Int.ofNat (4*i+3)))).flatten
def blockKey (r : Record) := scale (f r.after 21) 2++singletonKey r++scale (f r.after 29) 4
def descriptor (r : Record) : Fields :=
  [f r.after 36,bit r 0++scale (bit r 1) 2,f r.after 38,f r.after 39,
   sub (sub o (bit r 2)) (bit r 3)++f r.after 40,
   sub (bit r 2) (f r.after 40),sub (bit r 3) (f r.after 40),f r.after 40]
def zeros (r : Record) : List (Linear × Nat) :=
  (List.range 9).map (fun i => (sub (f r.row 8) (n (codes.getD i 0)),i)) ++
  [(f r.before 0,12),(f r.after 20,21)] ++
  (List.range 7).map (fun i => (sub (f r.after 20) (n (i+1)),22+i))
def multiplies (r : Record) : List (Linear × Linear × Nat) :=
  [(f r.before 1,f r.flags 4,11),(f r.flags 1,branching r++closing r,13),
   (branching r,f r.inputs 0,14),(readActive r,f r.after 16,17),
   (readActive r,space r,19),(sub (sub o (f r.after 21)) (singleton r),sub (f r.after 20) (n 256),29),
   (opening r,f r.after 31,32),(branching r++closing r,r.read.value,33),
   (bit r 2,bit r 3,40),(f r.flags 1,f r.after 3,41),
   (f r.flags 4,space r++f r.before 0,44),(f r.flags 4,f r.after 43,45)]
def selects (r : Record) : List (Linear × Linear × Linear × Nat) :=
  [(f r.flags 9,f r.inputs 2,f r.after 14,15),
   (f r.after 8,z,sub (sub (f r.before 0) o) (f r.after 15),16),
   (reset r,f r.inputs 1,f r.before 2,20),
   (f r.flags 0,rootToken r,f r.after 32++f r.after 33,34),
   (reset r,f r.after 34,f r.before 3,35),(f r.flags 9,r.read.value,f r.after 35,36),
   (f r.after 3,scale (f r.after 38) 4++n 3,f r.after 31,42),
   (f r.after 11,rootToken r,f r.after 42,43)]
def equalities (r : Record) : List (Linear × Nat) :=
  [(scale (blockKey r) 4++f r.after 1++scale (f r.after 2) 2,31),
   (GadgetShape.pack (BitPacking.bitWeights 34) ((RangeUse.bits (r.ranges.getD 4 default)).drop 2),38),
   (GadgetShape.pack (BitPacking.bitWeights 32) ((RangeUse.bits (r.ranges.getD 4 default)).drop 4),39)]
def guards (r : Record) : List (Linear × Linear) :=
  [(sub o (f r.flags 1),f r.inputs 1),(sub o (f r.flags 1),f r.inputs 0),
   (f r.before 1,sub o (f r.flags 4)),
   (sub (f r.flags 4) (f r.after 11),sub (sub o (opening r)) (f r.after 3)),
   (f r.flags 5,sub o (closing r)),(readActive r,sub o (sub o (f r.after 12))),
   (f r.after 41,sub (f (descriptor r) 1) (n 2))]
def gates (r : Record) : List Gate :=
  (zeros r).flatMap (fun (input,i) => zeroGates input (f r.after i) (f r.reciprocals i)) ++
  (multiplies r).map (fun (a,b,i) => mulGate a b (f r.after i)) ++
  (selects r).map (fun (test,yes,no,i) => selectGate test yes no (f r.after i)) ++
  (equalities r).map (fun (input,i) => eqGate (f r.after i) input) ++
  (guards r).map (fun (a,b) => gate a b)
def rangeInputs (r : Record) : List (Linear × Nat) :=
  [(f r.inputs 1,33),(f r.inputs 0,32),(f r.after 17,32),(f r.after 29,32),(f r.after 36,36)]
def links (r : Record) : Prop :=
  r.row.length = 10 ∧ r.flags.length = 11 ∧ r.inputs.length = 3 ∧ r.before.length = 4 ∧
  r.after.length = 46 ∧ r.reciprocals.length = 46 ∧ r.ranges.length = 5 ∧
  ModuleProgram.sameInputs r.outputs (descriptor r++r.after.take 9++
    [opening r,branching r,closing r,opening r++branching r++closing r,f r.after 11]) ∧
  ModuleProgram.sameInputs [r.read.active,r.read.write,r.read.address,r.read.clock,
    r.write.active,r.write.write,r.write.address,r.write.value,r.write.clock]
    [readActive r,z,f r.after 19++f r.after 17,n (2*r.index),
     f r.flags 4,f r.flags 4,f r.after 44,f r.after 45,n (2*r.index+1)]
instance (r : Record) : Decidable (links r) := by unfold links; infer_instance
def check (matrix : Shape) (r : Record) : Bool :=
  decide (links r) && OperandRowCheck.includes matrix r.first r.last (gates r) &&
  (List.range 5).all (fun i => let (value,width) := (rangeInputs r).getD i (z,0)
    RangeUse.check matrix (r.ranges.getD i default) value width)

def op (s : DynamicTypingMatrix.Stage) (i k : Nat) := s.program.base.operations.getD (46*i+k) default
def record (memory : MemoryEmbedded.Record) (s : DynamicTypingMatrix.Stage) (i : Nat) : Record :=
  ⟨i,rowAt s.rows i,rowAt s.flags i,rowAt s.inputs i,
   [if i=0 then z else f (rowAt s.rows (i-1)) 7,
    if i=0 then z else f (rowAt s.flags (i-1)) 0,
    if i=0 then z else (op s (i-1) 20).call.outputs.getD 0 [],
    if i=0 then z else (op s (i-1) 36).call.outputs.getD 0 []],
   (List.range 46).map (fun k => (op s i k).call.outputs.getD 0 []),
   (List.range 46).map (fun k => (op s i k).call.outputs.getD 1 []),
   [9,10,18,30,37].map (op s i),rowAt s.outputs i,
   (memory.inputs.getD (2*i) default).fields,(memory.inputs.getD (2*i+1) default).fields,
   (op s i 0).call.firstGate,if i+1<s.rows.length then (op s (i+1) 0).call.firstGate else s.program.base.lastGate⟩
def checkStage (matrix : Shape) (memory : MemoryEmbedded.Record) (s : DynamicTypingMatrix.Stage) : Bool :=
  decide (s.kind = 3 ∧ s.program.base.operations.length = 46*s.rows.length+1 ∧
    s.program.blocks = [] ∧ s.flags.length = s.rows.length ∧ s.inputs.length = s.rows.length ∧
    s.outputs.length = s.rows.length ∧ memory.inputs.length = 2*s.rows.length ∧
    memory.addressBits = 64 ∧ memory.valueBits = 36) && MemoryEmbedded.check matrix memory &&
  OperandRowCheck.includes matrix (op s s.rows.length 0).call.firstGate s.program.base.lastGate
    [eqGate (if s.rows.isEmpty then z else f (rowAt s.flags (s.rows.length-1)) 0) z] &&
  (List.range s.rows.length).all (fun i => check matrix (record memory s i))
end ZkBuild.FrameRowCheck

import FrameWriteValue
set_option autoImplicit false
namespace ZkBuild.InstructionEventCheck
open CircuitShape GadgetShape DeclarationMatrix ValidationEventMatrix

structure Record where
  row : Fields
  begin : Linear
  ending : Linear
  beginInverse : Linear
  endInverse : Linear
  info : ReadOnlyMatrix.Entry
  immediate : ReadOnlyMatrix.Entry
  finish : ReadOnlyMatrix.Entry
  ranges : List RangeUse.Record
  first : Nat
  last : Nat
  deriving Inhabited

def key (r : Record) := scale (f r.row 1) (Int.ofNat (2^32))++f r.row 2
def gates (r : Record) : List Gate :=
  zeroGates (sub (f r.row 0) (n 1)) r.begin r.beginInverse ++
  zeroGates (sub (f r.row 0) (n 8)) r.ending r.endInverse ++
  [mulGate r.begin (key r) r.info.address,mulGate r.begin (key r) r.immediate.address,
   mulGate r.ending (f r.row 1) r.finish.address,
   gate r.begin (sub (sub r.info.value (f r.row 3)) (scale (f r.row 6) 65536)),
   gate r.begin (sub (sub r.immediate.value (f r.row 4)) (scale (f r.row 5) (Int.ofNat (2^32)))),
   gate r.ending (sub r.finish.value (f r.row 2))]
def widths : List Nat := [32,32,16,32,32,33]
def check (matrix : Shape) (r : Record) : Bool :=
  decide (r.row.length=7 ∧ r.ranges.length=6 ∧
    ModuleProgram.sameInputs [r.info.active,r.immediate.active,r.finish.active] [r.begin,r.begin,r.ending]) &&
  OperandRowCheck.includes matrix r.first r.last (gates r) &&
  (List.range 6).all (fun i => RangeUse.check matrix (r.ranges.getD i default) (f r.row (i+1)) (widths.getD i 0))

def offset (s : InstructionStreamMatrix.Record) := s.program.base.operations.length-11*s.events.length
def op (s : InstructionStreamMatrix.Record) (i k : Nat) := s.program.base.operations.getD (offset s+11*i+k) default
def tailQuery (tables : List ReadOnlyMatrix.Record) (s : InstructionStreamMatrix.Record) (family i : Nat) :=
  let bank := InstructionStreamMatrix.bank tables s family
  bank.queries.getD (bank.queries.length-s.events.length+i) default
def record (tables : List ReadOnlyMatrix.Record) (s : InstructionStreamMatrix.Record) (i : Nat) : Record :=
  ⟨rowAt s.events i,(op s i 6).call.outputs.getD 0 [],(op s i 7).call.outputs.getD 0 [],
   (op s i 6).call.outputs.getD 1 [],(op s i 7).call.outputs.getD 1 [],
   tailQuery tables s 11 i,tailQuery tables s 12 i,tailQuery tables s 1 i,
   (List.range 6).map (op s i),(op s i 0).call.firstGate,
   if i+1<s.events.length then (op s (i+1) 0).call.firstGate else s.program.base.lastGate⟩
def checkStage (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (s : InstructionStreamMatrix.Record) : Bool :=
  decide (11*s.events.length≤s.program.base.operations.length) &&
  [11,12,1].all (fun family => let b := InstructionStreamMatrix.bank tables s family
    decide (s.events.length≤b.queries.length) && ReadOnlyMatrix.check matrix b) &&
  (List.range s.events.length).all (fun i => check matrix (record tables s i))
end ZkBuild.InstructionEventCheck

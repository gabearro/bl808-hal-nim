import SourceProgramSemantics
import DynamicTypingMatrix
set_option autoImplicit false
namespace ZkBuild.OperandRowCheck
open CircuitShape GadgetShape DeclarationMatrix ValidationEventMatrix

def codes : List Nat := [0,1,2,3,4,5,6,7,8,9,15]
structure Record where
  row : Fields
  tags : Fields
  before : Linear
  available : Linear
  product : Linear
  discarded : Linear
  access : Fields
  ranges : List RangeUse.Record
  previousPadding : Linear
  boundaryFirst : Nat
  boundaryLast : Nat
  first : Nat
  last : Nat
  stepFirst : Nat
  stepLast : Nat
  accessFirst : Nat
  accessLast : Nat
  deriving Inhabited

def selectorGates (r : Record) : List Gate :=
  r.tags.map boolGate ++
  [eqGate (r.tags.foldl (·++·) []) o,
    eqGate (f r.row 0) ((codes.zip r.tags).drop 1 |>.foldl (fun a pair => a++scale pair.2 (Int.ofNat pair.1)) [])]

def stepGates (r : Record) : List Gate :=
  let row := r.row
  let push := f r.tags 2
  let pop := f r.tags 3
  let clear := f r.tags 6
  let poly := f row 5
  [boolGate poly,boolGate (f row 6),
   gate poly (sub o pop),gate poly (sub (f row 4) (n 7)),
   gate (sub (sub o push) pop) (sub (f row 4) (n 7)),
   gate poly (sub r.before (f row 3)),gate poly (sub o (f row 6)),
   mulGate (pop++clear) (sub r.before (f row 3)) r.product,
   mulGate clear (sub r.before (f row 3)) r.discarded,
   eqGate (f row 2) (sub (sub (r.before++push) (sub pop poly)) r.discarded)]

def accessGates (r : Record) : List Gate :=
  let active := f r.tags 2++sub (f r.tags 3) (f r.row 5)
  [mulGate active (sub (scale (f r.row 1) (Int.ofNat (2^32))++f r.row 2) (f r.tags 2)) (f r.access 2),
   mulGate active (f r.row 4) (f r.access 3)]

def boundaryGates (r : Record) : List Gate :=
  [gate (f r.tags 0++f r.tags 8) (f r.row 2),
   gate r.previousPadding (sub o (f r.tags 10)),
   gate (f r.tags 10) (f r.row 1),gate (f r.tags 10) (f r.row 3),
   gate (f r.tags 10) (f r.row 6)]

-- This certificate checks exact existing primitive gates. Its arbitrary spans
-- may include intervening range gadgets; membership certifies every requested
-- equation without adding a new equation to the production circuit.
def includes (matrix : Shape) (first last : Nat) (gates : List Gate) : Bool :=
  decide (first ≤ last ∧ last ≤ matrix.gates.size) &&
    gates.all (fun g => ((matrix.gates.extract first last).toList.map normalizeGate).contains (normalizeGate g))

def check (matrix : Shape) (r : Record) : Bool :=
  decide (r.row.length = 7 ∧ r.tags.length = 11 ∧ r.access.length = 4 ∧ r.ranges.length = 5) &&
  includes matrix r.first r.last (selectorGates r) &&
  includes matrix r.stepFirst r.stepLast (stepGates r) &&
  includes matrix r.accessFirst r.accessLast (accessGates r) &&
  decide (ModuleProgram.sameInputs [r.available,f r.access 0,f r.access 1]
    [sub r.product (sub (f r.tags 3) (f r.row 5)), f r.tags 2++sub (f r.tags 3) (f r.row 5),f r.tags 2]) &&
  includes matrix r.boundaryFirst r.boundaryLast (boundaryGates r) &&
  (List.range 5).all (fun i => RangeUse.check matrix (r.ranges.getD i default)
    ([f r.row 1,f r.row 2,f r.row 3,f r.row 4,r.available].getD i []) (if i == 3 then 3 else 32))

def operation (s : ValidationEventMatrix.Stage) (row offset : Nat) :=
  s.program.base.operations.getD (25*row+offset) default

def record (s : ValidationEventMatrix.Stage) (i : Nat) : Record :=
  let tags := (List.range 11).map (fun j => ((operation s i j).call.outputs).getD 0 [])
  let product := (operation s i 19).call.outputs.getD 0 []
  let available := (operation s i 20).call.inputs.getD 0 []
  let before := if i = 0 then z else f (rowAt s.rows (i-1)) 2
  ⟨rowAt s.rows i,tags,before,available,product,(operation s i 21).call.outputs.getD 0 [],
    rowAt s.outputs i,[operation s i 13,operation s i 14,operation s i 15,operation s i 16,operation s i 20],
    (if i = 0 then z else f (rowAt s.flags (i-1)) 10),
    (operation s i 22).call.lastGate,(operation s i 23).call.firstGate,
    (operation s i 0).call.firstGate,(operation s i 12).call.lastGate,
    (operation s i 17).call.firstGate,(operation s i 22).call.lastGate,
    (operation s i 23).call.firstGate,(operation s i 24).call.lastGate⟩

def checkStage (matrix : Shape) (s : ValidationEventMatrix.Stage) : Bool :=
  s.kind == 1 && s.program.blocks.isEmpty && s.program.base.operations.length == 25*s.rows.length+1 &&
  includes matrix (operation s s.rows.length 0).call.firstGate (operation s s.rows.length 0).call.lastGate
    [eqGate (if s.rows.isEmpty then z else f (rowAt s.rows (s.rows.length-1)) 2) z] &&
  (List.range s.rows.length).all (fun i =>
    check matrix (record s i) && DynamicTypingMatrix.same [(record s i).tags] [rowAt s.flags i])
end ZkBuild.OperandRowCheck

import OperandRowCheck
import InstructionSchedule
set_option autoImplicit false
namespace ZkBuild.InstructionRowCheck
open CircuitShape GadgetShape DeclarationMatrix ValidationEventMatrix

structure Record where
  row : Fields
  tags : Fields
  before : Fields
  after : Fields
  pcRange : RangeUse.Record
  rule : StaticLookupEmbedded.Record
  first : Nat
  middle : Nat
  tailFirst : Nat
  last : Nat
  deriving Inhabited

def modeGates (r : Record) : List Gate :=
  let opened := f r.before 0
  let pending := f r.before 1
  let begin := f r.tags 1
  let finish := f r.tags 7
  let middle := f r.tags 2++f r.tags 3++f r.tags 4++f r.tags 5++f r.tags 6++f r.tags 9
  [gate pending (sub o (f r.tags 4)),gate pending opened,gate begin opened,
   gate finish (sub o opened),gate (f r.tags 0++f r.tags 8++f r.tags 10) opened,
   gate (sub middle pending) (sub o opened)]

def bindingGates (r : Record) : List Gate :=
  [selectGate (f r.tags 0) z (f r.before 2) (f r.after 2),
   gate (sub o (f r.tags 10)) (sub (f r.row 9) (f r.after 2)++f r.tags 8),
   gate (f r.tags 10) (f r.row 9),
   eqGate (f r.after 3) (f r.after 2++f r.tags 7),
   selectGate (f r.tags 0++f r.tags 1) (f r.row 8) (f r.before 3) (f r.after 4),
   gate (sub o (f r.tags 10)) (sub (f r.row 8) (f r.after 4)),
   gate (f r.tags 0) (sub (f r.row 8) (n 2)),
   gate (f r.tags 8) (sub (f r.row 8) (n 11)),gate (f r.tags 10) (f r.row 8)]

def labelGates (r : Record) : List Gate :=
  zeroGates (sub (f r.row 8) (n 14)) (f r.after 0) (f r.after 16) ++
  zeroGates (sub (f r.row 8) (n 31)) (f r.after 1) (f r.after 17) ++
  [gate (f r.tags 9) (sub (sub o (f r.after 0)) (f r.after 1))]

def resets (r : Record) : List Gate :=
  [selectGate (f r.tags 0++f r.tags 1) z (f r.before 4) (f r.after 5),
   selectGate (f r.tags 0++f r.tags 1) z (f r.before 5) (f r.after 6),
   selectGate (f r.tags 0++f r.tags 1) z (f r.before 6) (f r.after 7)]

def updates (r : Record) : List Gate :=
  [eqGate (f r.after 12) (f r.after 5++f r.tags 3),
   eqGate (f r.after 13) (f r.after 6++f r.tags 2),
   eqGate (f r.after 14) (f r.after 7++f r.tags 6),
   eqGate (f r.after 15) (sub (f r.before 0++f r.tags 1) (f r.tags 7))]

def staticGates (r : Record) : List Gate :=
  let rule := r.rule.outputs
  let pop := f r.after 8
  let push := f r.after 9
  let clear := f r.after 10
  let finish := f r.after 11
  [mulGate (f rule 0) (f r.tags 3) pop,mulGate (f rule 0) (f r.tags 2) push,
   gate pop (sub (f r.after 5) (f rule 6)),gate pop (sub o (f rule 5)),gate pop (f r.after 6),
   gate push (sub (f r.row 4) (f rule 3)),gate push (sub o (f rule 2)),
   gate push (sub (f r.after 5) (f rule 1)),gate push (f r.after 6),
   gate (f rule 0) (f r.tags 4++f r.tags 5),
   mulGate (f rule 0) (f r.tags 6) clear,gate clear (sub o (f rule 4)),gate clear (f r.after 7),
   mulGate (f rule 0) (f r.tags 7) finish,gate finish (sub (f r.after 5) (f rule 1)),
   gate finish (sub (f r.after 6) (f rule 2)),gate finish (sub (f r.after 7) (f rule 4))]

def check (matrix : Shape) (r : Record) : Bool :=
  decide (r.row.length = 10 ∧ r.tags.length = 11 ∧ r.before.length = 7 ∧ r.after.length = 18 ∧ r.rule.outputs.length = 7) &&
  OperandRowCheck.includes matrix r.first r.middle (modeGates r++bindingGates r++labelGates r++resets r) &&
  OperandRowCheck.includes matrix r.tailFirst r.last (staticGates r++updates r) &&
  RangeUse.check matrix r.pcRange (f r.row 9) 32 &&
  RangeUse.check matrix r.rule.opcodeRange (r.rule.inputs.getD 0 []) 16 &&
  decide (ModuleProgram.sameInputs [f r.row 8,f r.after 5,f r.row 4] r.rule.inputs)

def op (s : Stage) (i k : Nat) := s.program.base.operations.getD (17*i+k) default

def rule (statics : StaticCatalog) (s : Stage) (i : Nat) : Option StaticLookupEmbedded.Record :=
  (statics.find? (fun pair => pair.1 == (s.program.blocks.getD i default).index)).map Prod.snd

def record (s : Stage) (i : Nat) (rule : StaticLookupEmbedded.Record) : Record :=
  ⟨rowAt s.rows i,rowAt s.flags i,
   [if i = 0 then z else (op s (i-1) 16).call.outputs.getD 0 [],
    if i = 0 then z else f (rowAt s.flags (i-1)) 0,
    if i = 0 then z else (op s (i-1) 4).call.outputs.getD 0 [],
    if i = 0 then n 2 else (op s (i-1) 5).call.outputs.getD 0 [],
    if i = 0 then z else (op s (i-1) 13).call.outputs.getD 0 [],
    if i = 0 then z else (op s (i-1) 14).call.outputs.getD 0 [],
    if i = 0 then z else (op s (i-1) 15).call.outputs.getD 0 []],
   ([1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16] : List Nat).map (fun k => (op s i k).call.outputs.getD 0 []) ++
     [(op s i 1).call.outputs.getD 1 [],(op s i 2).call.outputs.getD 1 []],
   op s i 0,rule,(op s i 0).call.firstGate,(op s i 8).call.lastGate,(op s i 9).call.firstGate,(op s i 16).call.lastGate⟩

def checkStage (matrix : Shape) (statics : StaticCatalog) (s : Stage) : Bool :=
  s.kind == 3 && decide (s.rows.length < 2^64) && s.program.base.operations.length == 17*s.rows.length+2 &&
  s.program.blocks.length == s.rows.length &&
  OperandRowCheck.includes matrix (op s s.rows.length 0).call.firstGate (op s s.rows.length 1).call.lastGate
    [eqGate (if s.rows.isEmpty then z else (op s (s.rows.length-1) 16).call.outputs.getD 0 []) z,
     eqGate (if s.rows.isEmpty then z else f (rowAt s.flags (s.rows.length-1)) 0) z] &&
  (List.range s.rows.length).all (fun i => match rule statics s i with
    | none => false
    | some r => check matrix (record s i r))
end ZkBuild.InstructionRowCheck

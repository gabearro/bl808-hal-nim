import BinarySourceMatrix
import RangeUse
import MemoryEvidence

namespace ZkBuild.BinaryTokenMatrix

open Lean.Grind CircuitShape FullMatrix GadgetShape
attribute [local instance] Ring.intCast Semiring.natCast

def width (kind : Nat) : Nat :=
  if kind = 0 then 8 else if kind = 3 then 33 else if kind = 4 ∨ kind = 6 ∨ kind = 7 then 64 else 32

def capacity (kind : Nat) : Nat :=
  if kind = 0 then 1 else if kind = 4 ∨ kind = 7 then 10 else if kind = 5 then 4 else if kind = 6 then 8 else 5

def signed (kind : Nat) : Bool := kind = 2 ∨ kind = 3 ∨ kind = 4
def leb (kind : Nat) : Bool := 1 ≤ kind ∧ kind ≤ 4

def zero : Linear := constant 0
def one : Linear := constant 1
def nat (n : Nat) : Linear := constant (Int.ofNat n)
def atBit (bits : List Linear) (i : Nat) : Linear := bits.getD i zero
def sum (xs : List Linear) : Linear := xs.foldl (·++·) zero
def gate (a b : Linear) : Gate := ⟨a,b,zero⟩

structure Row where
  value : Linear
  address : Linear
  remaining : Linear
  next : Linear
  byteRange : RangeUse.Record
  remainingRange : RangeUse.Record
  extrasStart : Nat
  deriving Inhabited

structure Record where
  kind : Nat
  firstWire : Nat
  lastWire : Nat
  firstGate : Nat
  lastGate : Nat
  selectorStart : Nat
  choiceStart : Nat
  signStart : Nat
  activeMode : Linear
  position : Linear
  value : Linear
  length : Linear
  sourceLength : Linear
  positionRange : RangeUse.Record
  valueRange : RangeUse.Record
  lengthRange : RangeUse.Record
  rows : List Row
  deriving Inhabited

def selector (r : Record) (k : Nat) : Linear := wire (r.selectorStart+2+2*k)
def absent (r : Record) : Linear := wire r.selectorStart
def active (r : Record) : Linear :=
  if r.kind = 7 then sum ((List.range 7).map (selector r)) else r.activeMode

def choice (r : Record) (i : Nat) : Linear := wire (r.choiceStart+2*i)
def choices (r : Record) : List Linear := (List.range (capacity r.kind)).map (choice r)
def raw (r : Record) : Linear := selector r 0 ++ selector r 5 ++ selector r 6
def lebActive (r : Record) : Linear := sub (active r) (raw r)
def signedActive (r : Record) : Linear := selector r 2 ++ selector r 3 ++ selector r 4

def sign (r : Record) : Linear :=
  if r.kind = 7 then wire r.signStart ++ wire (r.signStart+1) ++ wire (r.signStart+2)
  else if signed r.kind then atBit (RangeUse.bits r.valueRange) (width r.kind-1) else zero

def choiceGates (r : Record) : List Gate :=
  (List.range (capacity r.kind)).flatMap fun i =>
    zeroGates (sub r.length (nat (i+1))) (choice r i) (wire (r.choiceStart+2*i+1))

def selectorGates (r : Record) : List Gate :=
  zeroGates r.activeMode (absent r) (wire (r.selectorStart+1)) ++
  (List.range 7).flatMap (fun i => zeroGates (sub r.activeMode (nat (i+1)))
    (selector r i) (wire (r.selectorStart+3+2*i)))

def outputAvailable (r : Record) (i : Nat) : Linear :=
  if i < 8 then active r else if i < 32 then sub (active r) (selector r 0)
  else if i = 32 then selector r 3 ++ selector r 4 ++ selector r 6 else selector r 4 ++ selector r 6

def prologue (r : Record) : List Gate :=
  if r.kind = 7 then
    selectorGates r ++ [eqGate (absent r ++ active r) one] ++
    RangeUse.gates r.positionRange ++ RangeUse.gates r.valueRange ++ RangeUse.gates r.lengthRange ++
    choiceGates r ++ [eqGate (sum (choices r)) (active r),gate (absent r) r.length,
      gate (selector r 0) (sub r.length (nat 1)),gate (selector r 5) (sub r.length (nat 4)),
      gate (selector r 6) (sub r.length (nat 8)),
      gate (selector r 1 ++ selector r 2 ++ selector r 3) (sum ((choices r).drop 5)),
      mulGate (selector r 2) (atBit (RangeUse.bits r.valueRange) 31) (wire r.signStart),
      mulGate (selector r 3) (atBit (RangeUse.bits r.valueRange) 32) (wire (r.signStart+1)),
      mulGate (selector r 4) (atBit (RangeUse.bits r.valueRange) 63) (wire (r.signStart+2))] ++
    (List.range 64).map (fun i => gate (sub one (outputAvailable r i)) (atBit (RangeUse.bits r.valueRange) i))
  else
    [boolGate r.activeMode] ++ RangeUse.gates r.positionRange ++ RangeUse.gates r.lengthRange ++ choiceGates r ++
    [eqGate (sum (choices r)) r.activeMode,gate (sub one r.activeMode) r.length] ++ RangeUse.gates r.valueRange ++
    [gate (sub one r.activeMode) r.value]

def normalBits (r : Record) (row : Row) (i : Nat) (present : Linear) : List Gate :=
  let bytes := RangeUse.bits row.byteRange
  let bits := RangeUse.bits r.valueRange
  if leb r.kind then
    [eqGate (atBit bytes 7) row.next] ++ (List.range 7).flatMap (fun j =>
      let index := 7*i+j
      if index < width r.kind then
        [gate present (sub (atBit bytes j) (atBit bits index)),
          gate (sub one present) (sub (atBit bits index) (sign r))]
      else [gate present (sub (atBit bytes j) (sign r))]) ++
      (if signed r.kind then [gate (choice r i) (sub (atBit bytes 6) (sign r))] else [])
  else (List.range 8).map (fun j => eqGate (atBit bytes j) (atBit bits (8*i+j)))

def bitAvailable (r : Record) (index : Nat) : Linear :=
  if index < 32 then lebActive r else if index = 32 then selector r 3 ++ selector r 4
  else if index < 64 then selector r 4 else zero

structure PayloadStep where
  data : Linear
  extension : Linear
  target : Linear
  nextWire : Nat
  gates : List Gate

def payloadStep (r : Record) (row : Row) (i j cursor : Nat) : PayloadStep :=
  let index := 7*i+j
  let available := bitAvailable r index
  let data := if index < 64 then wire cursor else zero
  let extension := wire (cursor + if index < 64 then 1 else 0)
  let target := data ++ extension
  let dataGates := if index < 64 then [mulGate available (atBit (RangeUse.bits r.valueRange) index) data] else []
  ⟨data,extension,target,cursor+(if index < 64 then 2 else 1),
    dataGates ++ [mulGate (sub (lebActive r) available) (sign r) extension,
      gate (wire row.extrasStart) (sub (atBit (RangeUse.bits row.byteRange) j) target),
      gate (sub (lebActive r) (wire row.extrasStart)) (sub target (sign r))]⟩

structure PayloadPlan where
  steps : List (Nat × PayloadStep)
  nextWire : Nat

def payloadPlan (r : Record) (row : Row) (i cursor : Nat) : List Nat → PayloadPlan
  | [] => ⟨[],cursor⟩
  | j::js =>
    let step := payloadStep r row i j cursor
    let rest := payloadPlan r row i step.nextWire js
    ⟨(j,step)::rest.steps,rest.nextWire⟩

def variantBits (r : Record) (row : Row) (i : Nat) (present : Linear) : List Gate :=
  let plan := payloadPlan r row i (row.extrasStart+2) (List.range 7)
  [gate (lebActive r) (sub (atBit (RangeUse.bits row.byteRange) 7) row.next),
    mulGate (lebActive r) present (wire row.extrasStart),mulGate (raw r) present (wire (row.extrasStart+1))] ++
  plan.steps.flatMap (fun pair => pair.2.gates) ++
  [mulGate (signedActive r) (choice r i) (wire plan.nextWire),
    gate (wire plan.nextWire) (sub (atBit (RangeUse.bits row.byteRange) 6) (sign r))] ++
  (if i < 8 then (List.range 8).flatMap (fun j =>
    [gate (wire (row.extrasStart+1)) (sub (atBit (RangeUse.bits row.byteRange) j) (atBit (RangeUse.bits r.valueRange) (8*i+j))),
      gate (sub (raw r) (wire (row.extrasStart+1))) (atBit (RangeUse.bits r.valueRange) (8*i+j))]) else [])

def rowGates (r : Record) (row : Row) (i : Nat) (present : Linear) : List Gate :=
  RangeUse.gates row.byteRange ++ [mulGate present (r.position ++ nat i) row.address,
    mulGate present (sub (sub r.sourceLength r.position) (nat (i+1))) row.remaining] ++
  RangeUse.gates row.remainingRange ++ [eqGate row.next (sub present (choice r i))] ++
  (if r.kind = 7 then variantBits r row i present else normalBits r row i present)

def rowsGates (r : Record) (i : Nat) (present : Linear) : List Row → List Gate
  | [] => (if r.kind ≠ 7 ∧ !(leb r.kind) then [eqGate r.length (scale r.activeMode (Int.ofNat (capacity r.kind)))] else []) ++
    [eqGate present zero]
  | row::rest => rowGates r row i present ++ rowsGates r (i+1) row.next rest

def gates (r : Record) : List Gate := prologue r ++ rowsGates r 0 (active r) r.rows

def rowInputs (i : Nat) (present : Linear) : List Row → List (Nat × Linear × Row)
  | [] => []
  | row::rest => (i,present,row)::rowInputs (i+1) row.next rest

def queries (r : Record) : List BinarySourceMatrix.Entry :=
  (rowInputs 0 (active r) r.rows).map fun (_,present,row) => ⟨present,row.address,row.value⟩

def checkRowRanges (matrix : Shape) (row : Row) : Bool :=
  RangeUse.check matrix row.byteRange row.value 8 && RangeUse.check matrix row.remainingRange row.remaining 32

def check (matrix : Shape) (r : Record) : Bool :=
  decide (r.kind ≤ 7 ∧ r.rows.length = capacity r.kind ∧ 0 < r.firstWire ∧
    r.firstWire ≤ r.lastWire ∧ r.lastWire ≤ matrix.wires) &&
  RangeUse.check matrix r.positionRange r.position 32 && RangeUse.check matrix r.valueRange r.value (width r.kind) &&
  RangeUse.check matrix r.lengthRange r.length 4 && r.rows.all (checkRowRanges matrix) &&
  MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (gates r)

theorem checked_holds {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : Record) (accepted : check matrix r = true)
    (values : Nat → F) (satisfied : Satisfied matrix values) : AllHold values (gates r) := by
  have parts := Bool.and_eq_true_iff.mp accepted
  exact MemoryEvidence.span_sound matrix r.firstGate r.lastGate (gates r) parts.2 values satisfied

theorem checked_ranges {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : Record) (accepted : check matrix r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    RangeReuse.Certificate 32 (E values r.position) ((RangeUse.bits r.positionRange).map (E values)) ∧
    RangeReuse.Certificate (width r.kind) (E values r.value) ((RangeUse.bits r.valueRange).map (E values)) ∧
    RangeReuse.Certificate 4 (E values r.length) ((RangeUse.bits r.lengthRange).map (E values)) ∧
    ∀ row ∈ r.rows, RangeReuse.Certificate 8 (E values row.value) ((RangeUse.bits row.byteRange).map (E values)) ∧
      RangeReuse.Certificate 32 (E values row.remaining) ((RangeUse.bits row.remainingRange).map (E values)) := by
  have parts : (r.kind ≤ 7 ∧ r.rows.length = capacity r.kind ∧ 0 < r.firstWire ∧
      r.firstWire ≤ r.lastWire ∧ r.lastWire ≤ matrix.wires) ∧
      RangeUse.check matrix r.positionRange r.position 32 = true ∧
      RangeUse.check matrix r.valueRange r.value (width r.kind) = true ∧
      RangeUse.check matrix r.lengthRange r.length 4 = true ∧ r.rows.all (checkRowRanges matrix) = true ∧
      MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (gates r) = true := by
    simpa only [check,Bool.and_eq_true_iff,decide_eq_true_eq,and_assoc] using accepted
  refine ⟨RangeUse.checked_certificate matrix r.positionRange r.position 32 parts.2.1 values oneValue satisfied,
    RangeUse.checked_certificate matrix r.valueRange r.value (width r.kind) parts.2.2.1 values oneValue satisfied,
    RangeUse.checked_certificate matrix r.lengthRange r.length 4 parts.2.2.2.1 values oneValue satisfied,?_⟩
  intro row member
  have rowChecks := Bool.and_eq_true_iff.mp (List.all_eq_true.mp parts.2.2.2.2.1 row member)
  exact ⟨RangeUse.checked_certificate matrix row.byteRange row.value 8 rowChecks.1 values oneValue satisfied,
    RangeUse.checked_certificate matrix row.remainingRange row.remaining 32 rowChecks.2 values oneValue satisfied⟩

#print axioms checked_holds
#print axioms checked_ranges
end ZkBuild.BinaryTokenMatrix

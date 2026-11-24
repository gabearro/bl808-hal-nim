import ImportCoverage

set_option autoImplicit false

namespace ZkBuild.OwnedMatrix
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix

structure Parent where
  firstGate : Nat
  lastGate : Nat
  zeroStart : Nat
  fields : List Linear
  ranges : List RangeUse.Record
  deriving Inhabited
structure Child where
  firstGate : Nat
  lastGate : Nat
  heads : Nat
  priorZero : Nat
  nextZero : Nat
  fields : List Linear
  ranges : List RangeUse.Record
  countQuery : Entry
  spanQuery : Entry
  within : Linear
  order : Linear
  same : Linear
  continues : Linear
  withinRange : RangeUse.Record
  orderRange : RangeUse.Record
  deriving Inhabited
structure Record where
  closeStart : Nat
  closeEnd : Nat
  tables : List Nat
  parents : List Parent
  children : List Child
  deriving Inhabited

def pget (r : Parent) (i : Nat) := get r.fields i
def cget (r : Child) (i : Nat) := get r.fields i
def key (r : Child) : Linear := scale (cget r 1) (Int.ofNat (2^32))++cget r 2

def parentParts (r : Parent) (previous : Linear) : List (List Gate) :=
  [[boolGate (pget r 0),gate (pget r 0) (sub o previous)],
   (List.range 3).flatMap fun i => RangeUse.gates (r.ranges.getD i default)++[gate (sub o (pget r 0)) (pget r (i+1))],
   zeroGates (pget r 1) (wire r.zeroStart) (wire (r.zeroStart+1))++[gate (wire r.zeroStart) (sub (pget r 3) (pget r 2))]]
def parentGates (r : Parent) (previous : Linear) := (parentParts r previous).flatten

def priorGates (r : Child) (prior : Option Child) : List Gate :=
  match prior with
  | none => []
  | some p =>
    zeroGates (sub (cget r 1) (cget p 1)) (wire r.priorZero) (wire (r.priorZero+1))++
    [mulGate (cget r 0) (wire r.priorZero) r.same,
     mulGate (cget r 0) (sub (sub (key r) (key p)) o) r.order]++RangeUse.gates r.orderRange++
    [gate r.same (sub (sub (cget r 2) (cget p 2)) o),gate r.same (sub (cget r 3) (cget p 4))]
def nextGates (r : Child) (next : Option Child) : List Gate :=
  match next with
  | none => []
  | some n => zeroGates (sub (cget n 1) (cget r 1)) (wire r.nextZero) (wire (r.nextZero+1))++
      [mulGate (cget n 0) (wire r.nextZero) r.continues]
def childParts (splits : Splits) (r : Child) (prior next : Option Child) : List (List Gate) :=
  let previous := match prior with | none => o | some p => cget p 0
  let bounds := split splits r.heads
  [[boolGate (cget r 0),gate (cget r 0) (sub o previous)],
   (List.range 4).flatMap fun i => RangeUse.gates (r.ranges.getD i default)++[gate (sub o (cget r 0)) (cget r (i+1))],
   splitGates bounds++[mulGate (cget r 0) (sub (sub r.countQuery.value (cget r 2)) o) r.within]++RangeUse.gates r.withinRange,
   priorGates r prior,
   [gate (sub (cget r 0) r.same) (cget r 2),gate (sub (cget r 0) r.same) (sub (cget r 3) bounds.low)],
   nextGates r next,
   [gate (sub (cget r 0) r.continues) (sub (cget r 2++o) r.countQuery.value),
    gate (sub (cget r 0) r.continues) (sub (cget r 4) bounds.high)]]
def childGates (splits : Splits) (r : Child) (prior next : Option Child) := (childParts splits r prior next).flatten

def checkParent (matrix : Shape) (r : Parent) (previous : Linear) : Bool :=
  decide (r.fields.length = 4 ∧ r.ranges.length = 3) &&
  (List.range 3).all (fun i => RangeUse.check matrix (r.ranges.getD i default) (pget r (i+1)) 32) &&
  MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (parentGates r previous)
def checkParents (matrix : Shape) : List Parent → Linear → Bool
  | [],_ => true
  | p::rest,previous => checkParent matrix p previous && checkParents matrix rest (pget p 0)

def childShape (splits : Splits) (r : Child) (prior next : Option Child) : Prop :=
  r.fields.length = 5 ∧ r.ranges.length = 4 ∧ r.heads < splits.length ∧
  splitMatches (split splits r.heads) r.spanQuery.value 32 32 ∧
  r.countQuery.active = cget r 0 ∧ r.countQuery.address = cget r 1 ∧
  r.spanQuery.active = cget r 0 ∧ r.spanQuery.address = cget r 1 ∧
  (prior.isNone = true → r.same = z) ∧ (next.isNone = true → r.continues = z)
instance (splits : Splits) (r : Child) (prior next : Option Child) : Decidable (childShape splits r prior next) := by
  unfold childShape
  infer_instance

def checkChild (matrix : Shape) (splits : Splits) (r : Child) (prior next : Option Child) : Bool :=
  decide (childShape splits r prior next) &&
  (List.range 4).all (fun i => RangeUse.check matrix (r.ranges.getD i default) (cget r (i+1)) 32) &&
  RangeUse.check matrix r.withinRange r.within 32 &&
  (match prior with | none => true | some _ => RangeUse.check matrix r.orderRange r.order 64) &&
  MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (childGates splits r prior next)
def checkChildren (matrix : Shape) (splits : Splits) : List Child → Option Child → Bool
  | [],_ => true
  | c::rest,prior => checkChild matrix splits c prior rest.head? && checkChildren matrix splits rest (some c)

def parentEntry (r : Parent) (i : Nat) (span : Bool) : Entry :=
  ⟨pget r 0,scale (pget r 0) (Int.ofNat i),if span then pget r 2++scale (pget r 3) (Int.ofNat (2^32)) else pget r 1⟩
def entries (rows : List Parent) (span : Bool) : List Entry :=
  (List.range rows.length).map fun i => parentEntry (rows.getD i default) i span

def table (tables : List ReadOnlyMatrix.Record) (r : Record) (i : Nat) := tables.getD (r.tables.getD i 0) default
def links (tables : List ReadOnlyMatrix.Record) (r : Record) : Prop :=
  r.parents.length < 2^32 ∧ r.children.length < 2^32 ∧ r.tables.length = 2 ∧
  (∀ i ∈ r.tables, i < tables.length) ∧
  (table tables r 0).entries = entries r.parents false ∧ (table tables r 0).queries = r.children.map Child.countQuery ∧
  (table tables r 1).entries = entries r.parents true ∧ (table tables r 1).queries = r.children.map Child.spanQuery ∧
  (table tables r 0).memory.addressBits = 32 ∧ (table tables r 0).memory.valueBits = 32 ∧
  (table tables r 1).memory.addressBits = 32 ∧ (table tables r 1).memory.valueBits = 64
instance (tables : List ReadOnlyMatrix.Record) (r : Record) : Decidable (links tables r) := by
  unfold links
  infer_instance

def total (r : Record) : Linear := z++r.parents.flatMap (fun p => pget p 1)
def seen (r : Record) : Linear := z++r.children.flatMap (fun c => cget c 0)
def check (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (splits : Splits) (r : Record) : Bool :=
  decide (links tables r) && checkParents matrix r.parents o && checkChildren matrix splits r.children none &&
  MemoryEvidence.checkSpan matrix r.closeStart r.closeEnd [eqGate (total r) (seen r)]
end ZkBuild.OwnedMatrix

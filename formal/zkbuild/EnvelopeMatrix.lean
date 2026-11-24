import BinaryTokenSound
import LookupEmbedded
import SectionPolicy

namespace ZkBuild.EnvelopeMatrix
open Lean.Grind CircuitShape FullMatrix GadgetShape BinaryTokenMatrix
attribute [local instance] Ring.intCast Semiring.natCast

structure Section where
  active : Linear
  id : Linear
  start : Linear
  body : Linear
  size : Linear
  finish : Linear
  firstWord : Linear
  deriving Inhabited

def fields (r : Section) : List Linear := [r.id,r.start,r.body,r.size,r.finish,r.firstWord]

structure Row where
  entry : Section
  ranges : List RangeUse.Record
  idToken : Nat
  sizeToken : Nat
  wordToken : Nat
  sizePosition : Linear
  remaining : Linear
  standard : Linear
  rankGap : Linear
  nextRank : Linear
  wordGap : Linear
  cursor : Linear
  remainingRange : RangeUse.Record
  rankGapRange : RangeUse.Record
  wordGapRange : RangeUse.Record
  lookup : LookupEmbedded.Record
  standardStart : Nat
  aggregateStart : Nat
  deriving Inhabited

structure Totals where
  present : Nat → Linear
  firstWords : Nat → Linear
  payloads : Nat → Linear
  ends : Nat → Linear

def initialTotals : Totals := ⟨fun _ => constant 0,fun _ => constant 0,fun _ => constant 0,fun _ => constant 0⟩
def nextTotals (r : Row) : Totals :=
  ⟨fun id => wire (r.aggregateStart+10*id+3),fun id => wire (r.aggregateStart+10*id+5),
    fun id => wire (r.aggregateStart+10*id+7),fun id => wire (r.aggregateStart+10*id+9)⟩
def token (tokens : List BinaryTokenMatrix.Record) (i : Nat) := tokens.getD i default

def tokenMatches (t : BinaryTokenMatrix.Record) (kind : Nat) (active position value : Linear) : Prop :=
  t.kind = kind ∧ t.activeMode = active ∧ t.position = position ∧ t.value = value
instance (t : BinaryTokenMatrix.Record) (k : Nat) (a p v : Linear) : Decidable (tokenMatches t k a p v) := by unfold tokenMatches; infer_instance

def rangeRows (row : Row) : List Gate :=
  ((fields row.entry).zip row.ranges).flatMap fun (value,range) =>
    RangeUse.gates range ++ [gate (sub one row.entry.active) value]

def aggregateGates (r : Row) (previous : Totals) (wordLength : Linear) : List Gate :=
  (List.range 14).flatMap fun id =>
    let start := r.aggregateStart+10*id
    let matchWire := wire (start+2)
    zeroGates (sub r.entry.id (nat id)) (wire start) (wire (start+1)) ++
    [mulGate r.entry.active (wire start) matchWire,
      eqGate (wire (start+3)) (previous.present id ++ matchWire),
      mulGate matchWire r.entry.firstWord (wire (start+4)),
      eqGate (wire (start+5)) (previous.firstWords id ++ wire (start+4)),
      mulGate matchWire (r.entry.body ++ wordLength) (wire (start+6)),
      eqGate (wire (start+7)) (previous.payloads id ++ wire (start+6)),
      mulGate matchWire r.entry.finish (wire (start+8)),
      eqGate (wire (start+9)) (previous.ends id ++ wire (start+8))]

def rowParts (sourceLength : Linear) (tokens : List BinaryTokenMatrix.Record)
    (r : Row) (cursor rank previous : Linear) (totals : Totals) : List (List Gate) :=
  let entry := r.entry
  let size := token tokens r.sizeToken
  let word := token tokens r.wordToken
  [[boolGate entry.active,gate entry.active (sub one previous)], rangeRows r,
    [gate entry.active (sub entry.start cursor)], BinaryTokenMatrix.gates (token tokens r.idToken),
    [mulGate entry.active (entry.start ++ nat 1) r.sizePosition], BinaryTokenMatrix.gates size,
    [gate entry.active (sub (sub (sub entry.body entry.start) (nat 1)) size.length),
      gate entry.active (sub (sub entry.finish entry.body) entry.size),
      mulGate entry.active (sub sourceLength entry.finish) r.remaining], RangeUse.gates r.remainingRange,
    RangeUse.gates r.lookup.range, (LookupEmbedded.program r.lookup).gates,
    [gate entry.active (sub (r.lookup.outputs.getD 0 []) one)],
    zeroGates entry.id (wire r.standardStart) (wire (r.standardStart+1)),
    [mulGate entry.active (sub one (wire r.standardStart)) r.standard,
      mulGate r.standard (sub (sub (r.lookup.outputs.getD 1 []) rank) (nat 1)) r.rankGap],
    RangeUse.gates r.rankGapRange,[selectGate r.standard (r.lookup.outputs.getD 1 []) rank r.nextRank],
    BinaryTokenMatrix.gates word,[mulGate r.standard (sub (sub entry.finish entry.body) word.length) r.wordGap],
    RangeUse.gates r.wordGapRange,aggregateGates r totals word.length,[selectGate entry.active entry.finish cursor r.cursor]]

def rowGates (sourceLength : Linear) (tokens : List BinaryTokenMatrix.Record)
    (r : Row) (cursor rank previous : Linear) (totals : Totals) : List Gate :=
  (rowParts sourceLength tokens r cursor rank previous totals).flatten

theorem part_holds {F : Type} [CommRing F] (values : Nat → F)
    (sourceLength : Linear) (tokens : List BinaryTokenMatrix.Record) (r : Row) (cursor rank previous : Linear) (totals : Totals)
    (holds : AllHold values (rowGates sourceLength tokens r cursor rank previous totals))
    (i : Nat) (inside : i < 20) : AllHold values ((rowParts sourceLength tokens r cursor rank previous totals).getD i []) := by
  have bound : i < (rowParts sourceLength tokens r cursor rank previous totals).length := by simpa only [rowParts,List.length_cons,List.length_nil] using inside
  have mem : (rowParts sourceLength tokens r cursor rank previous totals).getD i [] ∈ rowParts sourceLength tokens r cursor rank previous totals := by
    rw [← List.getElem_eq_getD []]
    exact List.getElem_mem bound
  intro g gm
  exact holds g (List.mem_flatten.mpr ⟨_,mem,gm⟩)

def walk (sourceLength : Linear) (tokens : List BinaryTokenMatrix.Record) :
    List Row → Linear → Linear → Linear → Totals → List Gate
  | [],cursor,_,_,_ => [eqGate cursor sourceLength]
  | r::rest,cursor,rank,previous,totals => rowGates sourceLength tokens r cursor rank previous totals ++
    walk sourceLength tokens rest r.cursor r.nextRank r.entry.active (nextTotals r)

def finalTotals : List Row → Totals
  | [] => initialTotals
  | [r] => nextTotals r
  | _::rest => finalTotals rest

def outputs (rows : List Row) : List Linear :=
  let totals := finalTotals rows
  (List.range 14).flatMap fun id => [totals.present id,totals.firstWords id,totals.payloads id,totals.ends id]

structure Record where
  firstWire : Nat
  lastWire : Nat
  firstGate : Nat
  lastGate : Nat
  sourceLength : Linear
  headerTokens : List Nat
  rows : List Row
  outputs : List Linear
  deriving Inhabited

def header : List Nat := [0,97,115,109,1,0,0,0]
def gates (r : Record) (tokens : List BinaryTokenMatrix.Record) : List Gate :=
  r.headerTokens.flatMap (fun i => BinaryTokenMatrix.gates (token tokens i)) ++ walk r.sourceLength tokens r.rows (nat 8) (nat 0) one initialTotals

def checkRow (matrix : Shape) (tokens : List BinaryTokenMatrix.Record) (r : Row) : Bool :=
  decide (r.ranges.length = 6 ∧ r.idToken < tokens.length ∧ r.sizeToken < tokens.length ∧ r.wordToken < tokens.length ∧
    tokenMatches (token tokens r.idToken) 0 r.entry.active r.entry.start r.entry.id ∧
    tokenMatches (token tokens r.sizeToken) 1 r.entry.active r.sizePosition r.entry.size ∧
    tokenMatches (token tokens r.wordToken) 1 r.standard r.entry.body r.entry.firstWord ∧
    r.lookup.input = r.entry.id ∧ r.lookup.columns = 2) &&
  ((fields r.entry).zip r.ranges).all (fun (value,range) => RangeUse.check matrix range value 32) &&
  RangeUse.check matrix r.remainingRange r.remaining 32 && RangeUse.check matrix r.rankGapRange r.rankGap 4 &&
  RangeUse.check matrix r.wordGapRange r.wordGap 32 && LookupEmbedded.check matrix r.lookup &&
  LookupEmbedded.checkTable r.lookup 8 SectionPolicy.expected

def check (matrix : Shape) (r : Record) (tokens : List BinaryTokenMatrix.Record) : Bool :=
  decide (0 < r.firstWire ∧ r.firstWire ≤ r.lastWire ∧ r.lastWire ≤ matrix.wires ∧ r.headerTokens.length = 8 ∧
    r.outputs = outputs r.rows) &&
  ((List.range 8).all (fun i => decide (r.headerTokens.getD i 0 < tokens.length ∧
    tokenMatches (token tokens (r.headerTokens.getD i 0)) 0 one (nat i) (nat (header.getD i 0))))) &&
  r.rows.all (checkRow matrix tokens) && MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (gates r tokens)

theorem checked_holds {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : Record) (tokens : List BinaryTokenMatrix.Record) (accepted : check matrix r tokens = true)
    (values : Nat → F) (satisfied : Satisfied matrix values) : AllHold values (gates r tokens) := by
  exact MemoryEvidence.span_sound matrix r.firstGate r.lastGate (gates r tokens)
    (Bool.and_eq_true_iff.mp accepted).2 values satisfied

#print axioms checked_holds
end ZkBuild.EnvelopeMatrix

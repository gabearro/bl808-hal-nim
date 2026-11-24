import DeclarationFraming

namespace ZkBuild.IndexedMatrix
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix

structure LengthRow where
  firstGate : Nat
  lastGate : Nat
  headZero : Nat
  lengthZero : Nat
  entry : Entry
  nonempty : Linear
  firstMember : Entry
  deriving Inhabited

structure MemberRow where
  firstGate : Nat
  lastGate : Nat
  addressSplit : Nat
  cellSplit : Nat
  nodeSplit : Nat
  headZero : Nat
  cursorZero : Nat
  tagZero : Nat
  continuationZero : Nat
  entry : Entry
  nodeQuery : Entry
  lengthQuery : Entry
  continuing : Linear
  deriving Inhabited

structure CloseRow where
  firstGate : Nat
  lastGate : Nat
  deriving Inhabited

structure MetadataRow where
  firstGate : Nat
  lastGate : Nat
  heads : Nat
  entry : Entry
  params : Entry
  results : Entry
  deriving Inhabited

structure SingletonRow where
  firstGate : Nat
  lastGate : Nat
  entry : Entry
  nodeQuery : Entry
  deriving Inhabited

structure Record where
  nilStart : Nat
  nilEnd : Nat
  tables : List Nat
  extraLengths : List Entry
  extraMembers : List Entry
  extraSingletons : List Entry
  lengths : List LengthRow
  members : List MemberRow
  closing : List CloseRow
  metadata : List MetadataRow
  singletons : List SingletonRow
  deriving Inhabited

def lengthGates (r : LengthRow) : List Gate :=
  zeroGates r.entry.address (wire r.headZero) (wire (r.headZero+1)) ++
  zeroGates r.entry.value (wire r.lengthZero) (wire (r.lengthZero+1)) ++
  [gate r.entry.active (sub (wire r.headZero) (wire r.lengthZero)),
   mulGate r.entry.active (sub o (wire r.headZero)) r.nonempty,
   mulGate r.nonempty (scale r.entry.address (Int.ofNat (2^32))) r.firstMember.address]

def checkLength (matrix : Shape) (r : LengthRow) : Bool :=
  decide (r.firstMember.active = r.nonempty) && MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (lengthGates r)

def address (splits : Splits) (r : MemberRow) := split splits r.addressSplit
def cell (splits : Splits) (r : MemberRow) := split splits r.cellSplit
def node (splits : Splits) (r : MemberRow) := split splits r.nodeSplit
def start (r : MemberRow) := sub r.entry.active r.continuing

def memberParts (splits : Splits) (r : MemberRow) (index : Nat) (previousHead previousOrdinal previousNext : Linear) : List (List Gate) :=
  let a := address splits r
  let c := cell splits r
  let n := node splits r
  [splitGates a,splitGates c,
   zeroGates a.high (wire r.headZero) (wire (r.headZero+1))++[gate r.entry.active (wire r.headZero)],
   zeroGates c.high (wire r.cursorZero) (wire (r.cursorZero+1))++[gate r.entry.active (wire r.cursorZero)],
   zeroGates (sub c.low (DeclarationMatrix.n 7)) (wire r.tagZero) (wire (r.tagZero+1))++[eqGate (wire r.tagZero) z],
   [queryGate r.entry.active c.high r.nodeQuery],splitGates n,
   [gate r.entry.active (sub c.low n.low),queryGate r.entry.active a.high r.lengthQuery],
   (if index = 0 then [] else zeroGates (sub a.high previousHead) (wire r.continuationZero) (wire (r.continuationZero+1))++
     [mulGate r.entry.active (wire r.continuationZero) r.continuing]),
   [gate (start r) a.low,gate (start r) (sub c.high a.high)],
   (if index = 0 then [] else [gate r.continuing (sub (sub a.low previousOrdinal) o),gate r.continuing (sub c.high previousNext)])]

def memberGates (splits : Splits) (r : MemberRow) (index : Nat) (ph po pn : Linear) := (memberParts splits r index ph po pn).flatten

def checkMember (matrix : Shape) (splits : Splits) (r : MemberRow) (index : Nat) (ph po pn : Linear) : Bool :=
  decide (r.addressSplit < splits.length ∧ r.cellSplit < splits.length ∧ r.nodeSplit < splits.length ∧
    splitMatches (address splits r) r.entry.address 32 32 ∧ splitMatches (cell splits r) r.entry.value 3 32 ∧
    splitMatches (node splits r) r.nodeQuery.value 3 32 ∧ r.nodeQuery.active = r.entry.active ∧ r.lengthQuery.active = r.entry.active ∧
    (index = 0 → r.continuing = z ∧ r.continuationZero = 0)) &&
  MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (memberGates splits r index ph po pn)

def checkMembers (matrix : Shape) (splits : Splits) : List MemberRow → Nat → Linear → Linear → Linear → Bool
  | [],_,_,_,_ => true
  | r::rest,index,ph,po,pn => checkMember matrix splits r index ph po pn &&
    checkMembers matrix splits rest (index+1) (address splits r).high (address splits r).low (node splits r).high

def closeGates (splits : Splits) (r : MemberRow) (next : Linear) : List Gate :=
  let finish := sub r.entry.active next
  [gate finish (node splits r).high,gate finish (sub ((address splits r).low++o) r.lengthQuery.value)]

def checkClosing (matrix : Shape) (splits : Splits) : List MemberRow → List CloseRow → Bool
  | [],[] => true
  | r::rest,c::tail => MemoryEvidence.checkSpan matrix c.firstGate c.lastGate
      (closeGates splits r (match rest with | [] => z | next::_ => next.continuing)) && checkClosing matrix splits rest tail
  | _,_ => false

def metadataGates (splits : Splits) (r : MetadataRow) : List Gate :=
  splitGates (split splits r.heads)++[queryGate r.entry.active (split splits r.heads).low r.params,
    queryGate r.entry.active (split splits r.heads).high r.results]
def checkMetadata (matrix : Shape) (splits : Splits) (r : MetadataRow) : Bool :=
  decide (r.heads < splits.length ∧ splitMatches (split splits r.heads) r.entry.value 32 32 ∧
    r.params.active = r.entry.active ∧ r.results.active = r.entry.active) &&
  MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (metadataGates splits r)

def singletonLength (r : SingletonRow) : Entry := ⟨o,r.entry.value,o⟩
def singletonGates (r : SingletonRow) (index : Nat) : List Gate :=
  [eqGate r.entry.active o,eqGate r.entry.address (n index),queryGate o r.entry.value r.nodeQuery,eqGate r.nodeQuery.value (n index)]
def checkSingleton (matrix : Shape) (r : SingletonRow) (index : Nat) : Bool :=
  decide (r.nodeQuery.active = o) && MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (singletonGates r index)

def table (tables : List ReadOnlyMatrix.Record) (r : Record) (index : Nat) := tables.getD (r.tables.getD index 0) default
def nilGates (r : Record) : List Gate :=
  let nil := r.lengths.getD 0 default
  [eqGate nil.entry.active o,eqGate nil.entry.address z,eqGate nil.entry.value z]

def checkLinks (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record) (r : Record) : Bool :=
  decide (r.tables.length = 4 ∧ (∀ i ∈ r.tables, i < tables.length) ∧
    (table tables r 0).entries = r.lengths.map LengthRow.entry ∧
    (table tables r 0).queries = r.members.map MemberRow.lengthQuery++r.metadata.flatMap (fun m => [m.params,m.results])++r.singletons.map singletonLength++r.extraLengths ∧
    (table tables r 1).entries = r.members.map MemberRow.entry ∧
    (table tables r 1).queries = r.lengths.map LengthRow.firstMember++r.extraMembers ∧
    (table tables r 2).entries = r.singletons.map SingletonRow.entry ∧ (table tables r 2).queries = r.extraSingletons ∧
    (table tables r 3).queries = r.members.map MemberRow.nodeQuery++r.singletons.map SingletonRow.nodeQuery ∧
    (table tables r 0).entries = (DeclarationMatrix.table tables declaration 3).entries ∧
    (table tables r 1).entries = (DeclarationMatrix.table tables declaration 4).entries ∧
    r.metadata.map MetadataRow.entry = (DeclarationMatrix.table tables declaration 2).entries) &&
  (List.range 4).all (fun i => decide ((table tables r i).memory.addressBits = ([32,64,3,32] : List Nat).getD i 0 ∧
    (table tables r i).memory.valueBits = ([32,35,32,35] : List Nat).getD i 0))

def check (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record) (r : Record) : Bool :=
  decide (0 < r.lengths.length ∧ r.singletons.length = 7) &&
  MemoryEvidence.checkSpan matrix r.nilStart r.nilEnd (nilGates r) && r.lengths.all (checkLength matrix) &&
  checkMembers matrix splits r.members 0 z z z && checkClosing matrix splits r.members r.closing &&
  r.metadata.all (checkMetadata matrix splits) &&
  (List.range r.singletons.length).all (fun i => checkSingleton matrix (r.singletons.getD i default) i) &&
  checkLinks tables declaration r

end ZkBuild.IndexedMatrix

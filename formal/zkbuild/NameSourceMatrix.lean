import NameGraphSoundness
set_option autoImplicit false
namespace ZkBuild.NameSourceMatrix
open CircuitShape GadgetShape DeclarationMatrix

structure Header where
  firstGate : Nat
  lastGate : Nat
  zeroStart : Nat
  nilGate : Nat
  head : Linear
  finalHead : Linear
  deriving Inhabited
structure ByteRow where
  firstGate : Nat
  lastGate : Nat
  zeroStart : Nat
  tailGate : Nat
  nodeQuery : Entry
  rootQuery : Entry
  fields : List Linear
  range : RangeUse.Record
  deriving Inhabited
structure Ending where
  firstGate : Nat
  lastGate : Nat
  zeroStart : Nat
  tail : Linear
  selector : Linear
  countQuery : Entry
  range : RangeUse.Record
  deriving Inhabited
structure Record where
  tables : List Nat
  headers : List Header
  bytes : List ByteRow
  ends : List Ending
  deriving Inhabited

def field (b : ByteRow) (i : Nat) := get b.fields i
def packed (range : RangeUse.Record) (offset count : Nat) := z ++ NameGraphMatrix.slice range offset count

def headerGates (f : NameFrameMatrix.Header) (h : Header) : List Gate :=
  [gate (sub o (NameFrameMatrix.hget f 0)) h.head] ++
  zeroGates (NameFrameMatrix.hget f 1) (wire h.zeroStart) (wire (h.zeroStart+1)) ++ [gate (wire h.zeroStart) h.head]
def checkHeader (matrix : Shape) (f : NameFrameMatrix.Header) (h : Header) : Bool :=
  decide (h.nilGate = 0 ∧ h.finalHead = z) && MemoryEvidence.checkSpan matrix h.firstGate h.lastGate (headerGates f h)

def byteGates (flat : Bool) (f : NameFrameMatrix.ByteRow) (b : ByteRow) (i : Nat) (previousOwner previousTail : Linear) : List Gate :=
  RangeUse.gates b.range ++ [eqGate (field b 0) (packed b.range 0 8)] ++
  (if flat then [eqGate (field b 1) (packed b.range 8 32)] ++
    (if i = 0 then [] else zeroGates (sub (NameFrameMatrix.bget f 1) previousOwner) (wire b.zeroStart) (wire (b.zeroStart+1)) ++
      [mulGate (NameFrameMatrix.bget f 0) (wire b.zeroStart) (field b 2)]) ++
    [gate (sub (NameFrameMatrix.bget f 0) (field b 2)) (sub b.nodeQuery.address b.rootQuery.value),
     gate (field b 2) (sub b.nodeQuery.address previousTail)]
   else [])

def byteShape (tokens : DeclarationMatrix.Tokens) (flat : Bool) (f : NameFrameMatrix.ByteRow) (b : ByteRow) (i : Nat) : Prop :=
  b.fields.length = 3 ∧ b.nodeQuery.active = NameFrameMatrix.bget f 0 ∧
  (EnvelopeMatrix.token tokens f.token).value = field b 0 ∧
  (if flat then b.rootQuery.active = NameFrameMatrix.bget f 0 ∧ b.rootQuery.address = NameFrameMatrix.bget f 1 ∧ b.tailGate = 0 ∧
    (i = 0 → b.zeroStart = 0 ∧ field b 2 = z)
   else b.rootQuery = ⟨z,z,z⟩ ∧ b.zeroStart = 0 ∧ field b 2 = z)
instance (tokens : Tokens) (flat : Bool) (f : NameFrameMatrix.ByteRow) (b : ByteRow) (i : Nat) : Decidable (byteShape tokens flat f b i) := by
  unfold byteShape; infer_instance

def checkByte (matrix : Shape) (tokens : Tokens) (flat : Bool) (f : NameFrameMatrix.ByteRow) (b : ByteRow) (i : Nat)
    (previousOwner previousTail : Linear) : Bool :=
  decide (byteShape tokens flat f b i) && RangeUse.check matrix b.range b.nodeQuery.value 42 &&
    MemoryEvidence.checkSpan matrix b.firstGate b.lastGate (byteGates flat f b i previousOwner previousTail) &&
    (if flat then true else MemoryEvidence.checkSpan matrix b.tailGate (b.tailGate+1) [eqGate (field b 1) (packed b.range 8 32)])

def checkBytes (matrix : Shape) (tokens : Tokens) (flat : Bool) : List NameFrameMatrix.ByteRow → List ByteRow → Nat → Linear → Linear → Bool
  | [],[],_,_,_ => true
  | f::fs,b::bs,i,po,pt => checkByte matrix tokens flat f b i po pt && checkBytes matrix tokens flat fs bs (i+1) (NameFrameMatrix.bget f 1) (field b 1)
  | _,_,_,_,_ => false

def endingGates (f : NameFrameMatrix.ByteRow) (e : Ending) : List Gate :=
  RangeUse.gates e.range ++ [eqGate e.tail (packed e.range 8 32)] ++
  zeroGates (sub (NameFrameMatrix.bget f 2 ++ o) e.countQuery.value) (wire e.zeroStart) (wire (e.zeroStart+1)) ++
  [mulGate (NameFrameMatrix.bget f 0) (wire e.zeroStart) e.selector,gate e.selector e.tail]
def checkEnding (matrix : Shape) (f : NameFrameMatrix.ByteRow) (b : ByteRow) (e : Ending) : Bool :=
  decide (e.countQuery.active = NameFrameMatrix.bget f 0 ∧ e.countQuery.address = NameFrameMatrix.bget f 1) &&
  RangeUse.check matrix e.range b.nodeQuery.value 42 && MemoryEvidence.checkSpan matrix e.firstGate e.lastGate (endingGates f e)

def checkEnds (matrix : Shape) : List NameFrameMatrix.ByteRow → List ByteRow → List Ending → Bool
  | [],[],[] => true
  | f::fs,b::bs,e::es => checkEnding matrix f b e && checkEnds matrix fs bs es
  | _,_,_ => false

def legacyLink : List ByteRow → Linear → Linear → Bool
  | [],head,finish => decide (head = finish)
  | b::bs,head,finish => decide (b.nodeQuery.address = head) && legacyLink bs (field b 1) finish

def checkLegacy (matrix : Shape) (bytes : List ByteRow) : List NameFrameMatrix.Header → List Header → Bool
  | [],[] => true
  | f::fs,h::hs => decide (h.firstGate = 0 ∧ h.lastGate = 0 ∧ h.zeroStart = 0) &&
      legacyLink ((bytes.drop f.byteStart).take f.byteCount) h.head h.finalHead &&
      MemoryEvidence.checkSpan matrix h.nilGate (h.nilGate+1) [eqGate h.finalHead z] && checkLegacy matrix bytes fs hs
  | _,_ => false

def table (tables : List ReadOnlyMatrix.Record) (r : Record) (i : Nat) := tables.getD (r.tables.getD i 0) default
def rootEntry (f : NameFrameMatrix.Header) (h : Header) (i : Nat) : Entry :=
  ⟨NameFrameMatrix.hget f 0,scale (NameFrameMatrix.hget f 0) (Int.ofNat i),h.head⟩
def countEntry (f : NameFrameMatrix.Header) (i : Nat) : Entry :=
  ⟨NameFrameMatrix.hget f 0,scale (NameFrameMatrix.hget f 0) (Int.ofNat i),NameFrameMatrix.hget f 1⟩

def links (tables : List ReadOnlyMatrix.Record) (frame : NameFrameMatrix.Record) (graph : NameGraphMatrix.Record) (r : Record) : Prop :=
  r.headers.length = frame.headers.length ∧ r.bytes.length = frame.bytes.length ∧
  r.headers.map Header.head = graph.roots.map NameGraphMatrix.Root.head ∧
  r.tables.length = (if frame.flat then 3 else 1) ∧ (∀ i ∈ r.tables, i < tables.length) ∧
  (table tables r (if frame.flat then 1 else 0)).entries = (NameGraphMatrix.table tables graph 0).entries ∧
  (table tables r (if frame.flat then 1 else 0)).queries = r.bytes.map ByteRow.nodeQuery ∧
  r.bytes.length < 2^32 ∧
  (if frame.flat then
    (table tables r 0).entries = frame.headers.zipIdx.map (fun (f,i) => countEntry f i) ∧
    (table tables r 0).queries = r.ends.map Ending.countQuery ∧
    (table tables r 2).entries = (frame.headers.zip r.headers).zipIdx.map (fun ((f,h),i) => rootEntry f h i) ∧
    (table tables r 2).queries = r.bytes.map ByteRow.rootQuery
   else r.ends = [])
instance (tables : List ReadOnlyMatrix.Record) (frame : NameFrameMatrix.Record) (graph : NameGraphMatrix.Record) (r : Record) : Decidable (links tables frame graph r) := by
  unfold links; infer_instance

def check (matrix : Shape) (tokens : Tokens) (tables : List ReadOnlyMatrix.Record)
    (frame : NameFrameMatrix.Record) (graph : NameGraphMatrix.Record) (r : Record) : Bool :=
  decide (links tables frame graph r) && checkBytes matrix tokens frame.flat frame.bytes r.bytes 0 z z &&
  (if frame.flat then (frame.headers.zip r.headers).all (fun (f,h) => checkHeader matrix f h) && checkEnds matrix frame.bytes r.bytes r.ends
   else checkLegacy matrix r.bytes frame.headers r.headers)
end ZkBuild.NameSourceMatrix

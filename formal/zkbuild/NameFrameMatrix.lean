import OwnedSound
set_option autoImplicit false
namespace ZkBuild.NameFrameMatrix
open CircuitShape GadgetShape DeclarationMatrix

structure Header where
  firstGate : Nat
  lastGate : Nat
  token : Nat
  byteStart : Nat
  byteCount : Nat
  closeGate : Nat
  fields : List Linear
  ranges : List RangeUse.Record
  deriving Inhabited
structure ByteRow where
  firstGate : Nat
  lastGate : Nat
  token : Nat
  fields : List Linear
  deriving Inhabited
structure Record where
  flat : Bool
  owned : Nat
  headers : List Header
  bytes : List ByteRow
  deriving Inhabited

def hget (h : Header) (i : Nat) := get h.fields i
def bget (b : ByteRow) (i : Nat) := get b.fields i

def headerGates (tokens : Tokens) (h : Header) : List Gate :=
  h.ranges.flatMap RangeUse.gates ++ BinaryTokenMatrix.gates (EnvelopeMatrix.token tokens h.token) ++
    [eqGate (hget h 3) (hget h 2 ++ (EnvelopeMatrix.token tokens h.token).length)]
def byteGates (tokens : Tokens) (flat : Bool) (b : ByteRow) : List Gate :=
  BinaryTokenMatrix.gates (EnvelopeMatrix.token tokens b.token) ++
    [eqGate (bget b 4) (bget b 3 ++ if flat then (EnvelopeMatrix.token tokens b.token).length else o)]

def headerShape (tokens : Tokens) (flat : Bool) (h : Header) : Prop :=
  h.fields.length = 5 ∧ h.token < tokens.length ∧
  (EnvelopeMatrix.token tokens h.token).kind = 1 ∧
  (EnvelopeMatrix.token tokens h.token).activeMode = hget h 0 ∧
  (EnvelopeMatrix.token tokens h.token).position = hget h 2 ∧
  (EnvelopeMatrix.token tokens h.token).value = hget h 1 ∧
  (if flat then h.ranges = [] ∧ h.byteStart = 0 ∧ h.byteCount = 0 ∧ h.closeGate = 0
   else h.ranges.length = 2 ∧ hget h 0 = o ∧ hget h 1 = n h.byteCount)
instance (tokens : Tokens) (flat : Bool) (h : Header) : Decidable (headerShape tokens flat h) := by
  unfold headerShape; infer_instance

def checkHeader (matrix : Shape) (tokens : Tokens) (flat : Bool) (h : Header) : Bool :=
  decide (headerShape tokens flat h) &&
  (if flat then true else RangeUse.check matrix (h.ranges.getD 0 default) (hget h 2) 32 &&
    RangeUse.check matrix (h.ranges.getD 1 default) (hget h 4) 32) &&
  MemoryEvidence.checkSpan matrix h.firstGate h.lastGate (headerGates tokens h)
def byteShape (tokens : Tokens) (b : ByteRow) : Prop :=
  b.fields.length = 5 ∧ b.token < tokens.length ∧
  (EnvelopeMatrix.token tokens b.token).kind = 0 ∧
  (EnvelopeMatrix.token tokens b.token).activeMode = bget b 0 ∧
  (EnvelopeMatrix.token tokens b.token).position = bget b 3
instance (tokens : Tokens) (b : ByteRow) : Decidable (byteShape tokens b) := by
  unfold byteShape; infer_instance

def checkByte (matrix : Shape) (tokens : Tokens) (flat : Bool) (b : ByteRow) : Bool :=
  decide (byteShape tokens b) && MemoryEvidence.checkSpan matrix b.firstGate b.lastGate (byteGates tokens flat b)

def parentFields (h : Header) : List Linear := [hget h 0,hget h 1,hget h 3,hget h 4]
def entry (h : Header) (i : Nat) : Entry :=
  ⟨hget h 0,scale (hget h 0) (Int.ofNat i),hget h 2 ++ scale (hget h 4) (2^32)⟩
def entries (hs : List Header) : List Entry := hs.zipIdx |>.map (fun (h,i) => entry h i)

def legacyLink : List ByteRow → Nat → Nat → Linear → Bool
  | [],_,_,_ => true
  | b::bs,i,j,cursor => decide (bget b 0 = o ∧ bget b 1 = n i ∧ bget b 2 = n j ∧ bget b 3 = cursor) &&
      legacyLink bs i (j+1) (bget b 4)
def finalCursor : List ByteRow → Linear → Linear
  | [],cursor => cursor
  | b::bs,_ => finalCursor bs (bget b 4)
def legacyHeaders (matrix : Shape) (tokens : Tokens) (bytes : List ByteRow) : List Header → Nat → Nat → Bool
  | [],_,offset => decide (offset = bytes.length)
  | h::hs,i,offset => checkHeader matrix tokens false h &&
      decide (h.byteStart = offset ∧ offset+h.byteCount ≤ bytes.length) &&
      legacyLink ((bytes.drop offset).take h.byteCount) i 0 (hget h 3) &&
      MemoryEvidence.checkSpan matrix h.closeGate (h.closeGate+1)
        [eqGate (hget h 4) (finalCursor ((bytes.drop offset).take h.byteCount) (hget h 3))] &&
      legacyHeaders matrix tokens bytes hs (i+1) (offset+h.byteCount)

def stream (owned : List OwnedMatrix.Record) (r : Record) := owned.getD r.owned default

def check (matrix : Shape) (tokens : Tokens) (tables : List ReadOnlyMatrix.Record)
    (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record) (r : Record) : Bool :=
  decide (r.headers.length < 2^32 ∧ (ImportMatrix.table tables imports 0).entries = entries r.headers ∧
    (ImportMatrix.table tables imports 0).memory.addressBits = 32 ∧
    (ImportMatrix.table tables imports 0).memory.valueBits = 64) &&
  r.bytes.all (checkByte matrix tokens r.flat) &&
  (if r.flat then r.headers.all (checkHeader matrix tokens true) &&
    decide (r.owned < owned.length ∧ (stream owned r).parents.map OwnedMatrix.Parent.fields = r.headers.map parentFields ∧
      (stream owned r).children.map OwnedMatrix.Child.fields = r.bytes.map ByteRow.fields)
   else decide (r.owned = 0) && legacyHeaders matrix tokens r.bytes r.headers 0 0)
end ZkBuild.NameFrameMatrix

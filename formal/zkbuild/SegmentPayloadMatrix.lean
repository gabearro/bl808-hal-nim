import ScalarPayloadSoundness
set_option autoImplicit false
set_option synthInstance.maxSize 512
namespace ZkBuild.SegmentPayloadMatrix
open CircuitShape GadgetShape DeclarationMatrix ImportMatrix
structure Row where
  firstGate : Nat
  lastGate : Nat
  heads : Nat
  fields : List Linear
  zeros : List Nat
  ranges : List RangeUse.Record
  constants : List Nat
  queries : List Entry
  reads : List Read
  deriving Inhabited
structure Record where
  flat : Bool
  ownedCode : Nat
  modeCode : Nat
  elements : List Row
  items : List Row
  datas : List Row
  customs : List Row
  tail : Row
  closeStarts : List Nat
  closeEnds : List Nat
  deriving Inhabited

def f (r : Row) (i : Nat) := get r.fields i
def rangeAt (r : Row) (i : Nat) := r.ranges.getD i default
def bit (r : Row) (i : Nat) := (RangeUse.bits (rangeAt r 0)).getD i z
def zero (r : Row) (i : Nat) := wire (r.zeros.getD i 0)
def zeroG (r : Row) (i : Nat) (value : Linear) := zeroGates value (zero r i) (wire (r.zeros.getD i 0+1))
def readAt (r : Row) (i : Nat) := r.reads.getD i default
def queryAt (r : Row) (i : Nat) := r.queries.getD i default
def constAt (cs : List ConstantSourceMatrix.Record) (r : Row) (i : Nat) := cs.getD (r.constants.getD i 0) default
def constEnd (cs : List ConstantSourceMatrix.Record) (r : Row) (i : Nat) := (ConstantSourceMatrix.readAt (constAt cs r i) 5).cursor
def constLink (cs : List ConstantSourceMatrix.Record) (r : Row) (i : Nat) (active mode cursor : Linear) : Prop :=
  i < r.constants.length ∧ r.constants.getD i 0 < cs.length ∧
    ConstantSourceMatrix.same (ConstantSourceMatrix.field (constAt cs r i) 0) active ∧
    ConstantSourceMatrix.same (ConstantSourceMatrix.field (constAt cs r i) 1) mode ∧
    ConstantSourceMatrix.same (ConstantSourceMatrix.field (constAt cs r i) 2) cursor
instance (cs : List ConstantSourceMatrix.Record) (r : Row) (i : Nat) (a m p : Linear) : Decidable (constLink cs r i a m p) := by unfold constLink; infer_instance

-- Nim stores coefficients as canonical field residues. Compare interfaces in
-- the same field rather than requiring a particular integer spelling.
def readMatches (tokens : Tokens) (r : Read) (kind : Nat) (active cursor : Linear) : Prop :=
  r.token < tokens.length ∧ (EnvelopeMatrix.token tokens r.token).kind = kind ∧
    ConstantSourceMatrix.same (EnvelopeMatrix.token tokens r.token).activeMode active ∧
    ConstantSourceMatrix.same (EnvelopeMatrix.token tokens r.token).position cursor
instance (tokens : Tokens) (r : Read) (kind : Nat) (active cursor : Linear) : Decidable (readMatches tokens r kind active cursor) := by unfold readMatches; infer_instance

def rangeValue (r : RangeUse.Record) := get r.call.inputs 0
def checkRange (matrix : Shape) (r : RangeUse.Record) (value : Linear) (width : Nat) :=
  RangeUse.check matrix r (rangeValue r) width && decide (ConstantSourceMatrix.same (rangeValue r) value)

def legacyEnd (cs : List ConstantSourceMatrix.Record) (r : Row) : List Nat → Linear → Linear
  | [],start => start
  | i::rest,_ => legacyEnd cs r rest (constEnd cs r i)
def legacyLinks (cs : List ConstantSourceMatrix.Record) (r : Row) : List Nat → Linear → Prop
  | [],_ => True
  | i::rest,start => constLink cs r i o (bit r 2) start ∧ legacyLinks cs r rest (constEnd cs r i)
def decideLegacy (cs : List ConstantSourceMatrix.Record) (r : Row) : (is : List Nat) → (start : Linear) → Decidable (legacyLinks cs r is start)
  | [],_ => isTrue trivial
  | i::rest,start => by
      letI := decideLegacy cs r rest (constEnd cs r i)
      unfold legacyLinks
      infer_instance
instance (cs : List ConstantSourceMatrix.Record) (r : Row) (is : List Nat) (start : Linear) : Decidable (legacyLinks cs r is start) := decideLegacy cs r is start

def elementEnd (cs : List ConstantSourceMatrix.Record) (flat : Bool) (r : Row) :=
  if flat then f r 13 else legacyEnd cs r ((List.range r.constants.length).drop 1) (readAt r 3).cursor
def elementType (r : Row) := sub (sub (n 127) (f r 8)) (scale (zero r 0 ++ wire (r.zeros.getD 0 0+2)) 10)
def elementGates (tokens : Tokens) (splits : Splits) (cs : List ConstantSourceMatrix.Record) (flat : Bool) (r : Row) (start : Linear) :=
  RangeUse.gates (rangeAt r 0) ++ [gate (sub o (f r 0)) (f r 1)] ++
  ImportMatrix.readGates tokens (readAt r 0) (f r 0) (f r 1) start ++
  [mulGate (sub (f r 0) (bit r 0)) (bit r 1) (f r 2),mulGate (bit r 0) (bit r 1) (f r 5),
   eqGate (f r 3) (sub (f r 0) (bit r 0) ++ scale (f r 5) 2),gate (sub o (f r 2)) (f r 4)] ++
  ImportMatrix.readGates tokens (readAt r 1) (f r 2) (f r 4) (readAt r 0).cursor ++
  ConstantSourceMatrix.gates tokens splits (constAt cs r 0) ++
  [mulGate (bit r 0) (bit r 1) (f r 6),mulGate (sub (bit r 0 ++ bit r 1) (f r 6)) (bit r 2) (f r 7),
   gate (sub (f r 0) (f r 7)) (sub (f r 8) (n 5))] ++
  zeroG r 0 (sub (f r 8) (n 5)) ++
  zeroGates (sub (f r 8) (n 6)) (wire (r.zeros.getD 0 0+2)) (wire (r.zeros.getD 0 0+3)) ++
  [mulGate (bit r 2) (elementType r) (f r 9)] ++
  ImportMatrix.readGates tokens (readAt r 2) (sub (bit r 0 ++ bit r 1) (f r 6)) (f r 9) (constEnd cs r 0) ++
  ImportMatrix.readGates tokens (readAt r 3) (f r 0) (f r 10) (readAt r 2).cursor ++
  (if flat then [mulGate (f r 0) (readAt r 3).cursor (f r 11),selectGate (f r 0) (f r 12) (readAt r 3).cursor (f r 13)]
   else ((List.range r.constants.length).drop 1).flatMap (fun i => ConstantSourceMatrix.gates tokens splits (constAt cs r i)))

def elementShape (tokens : Tokens) (_splits : Splits) (cs : List ConstantSourceMatrix.Record) (flat : Bool) (r : Row) (start : Linear) : Prop :=
  r.fields.length = (if flat then 14 else 11) ∧ r.zeros.length = 1 ∧ r.ranges.length = 1 ∧ r.queries.length = 0 ∧ r.reads.length = 4 ∧
  (if flat then r.constants.length = 1 else 0 < r.constants.length) ∧
  readMatches tokens (readAt r 0) 1 (f r 0) start ∧
  readMatches tokens (readAt r 1) 1 (f r 2) (readAt r 0).cursor ∧
  constLink cs r 0 (sub (f r 0) (bit r 0)) o (readAt r 1).cursor ∧
  readMatches tokens (readAt r 2) 0 (sub (bit r 0 ++ bit r 1) (f r 6)) (constEnd cs r 0) ∧
  readMatches tokens (readAt r 3) 1 (f r 0) (readAt r 2).cursor ∧
  (flat = false → legacyLinks cs r ((List.range r.constants.length).drop 1) (readAt r 3).cursor)
instance (t : Tokens) (s : Splits) (cs : List ConstantSourceMatrix.Record) (flat : Bool) (r : Row) (p : Linear) : Decidable (elementShape t s cs flat r p) := by unfold elementShape; infer_instance

def checkElement (matrix : Shape) (tokens : Tokens) (splits : Splits) (cs : List ConstantSourceMatrix.Record) (flat : Bool) (r : Row) (start : Linear) :=
  decide (elementShape tokens splits cs flat r start) && checkRange matrix (rangeAt r 0) (f r 1) 3 &&
  MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (elementGates tokens splits cs flat r start)
def checkElements (matrix : Shape) (tokens : Tokens) (splits : Splits) (cs : List ConstantSourceMatrix.Record) (flat : Bool) : List Row → Linear → Bool
  | [],_ => true
  | r::rest,start => checkElement matrix tokens splits cs flat r start && checkElements matrix tokens splits cs flat rest (elementEnd cs flat r)
def elementsEnd (cs : List ConstantSourceMatrix.Record) (flat : Bool) : List Row → Linear → Linear
  | [],start => start
  | r::rest,_ => elementsEnd cs flat rest (elementEnd cs flat r)

def dataGates (tokens : Tokens) (splits : Splits) (cs : List ConstantSourceMatrix.Record) (r : Row) (start _finish : Linear) :=
  RangeUse.gates (rangeAt r 0) ++ zeroG r 0 (sub (f r 1) (n 3)) ++
  [eqGate (zero r 0) z,gate (sub o (f r 0)) (f r 1)] ++
  ImportMatrix.readGates tokens (readAt r 0) (f r 0) (f r 1) start ++
  zeroG r 1 (sub (f r 1) o) ++ [mulGate (f r 0) (zero r 1) (f r 2)] ++
  zeroG r 2 (sub (f r 1) (n 2)) ++ [mulGate (f r 0) (zero r 2) (f r 3),eqGate (f r 4) (f r 2),gate (sub o (f r 3)) (f r 5)] ++
  ImportMatrix.readGates tokens (readAt r 1) (f r 3) (f r 5) (readAt r 0).cursor ++
  ConstantSourceMatrix.gates tokens splits (constAt cs r 0) ++
  [gate (sub o (f r 0)) (f r 6)] ++ ImportMatrix.readGates tokens (readAt r 2) (f r 0) (f r 6) (constEnd cs r 0) ++
  [eqGate (f r 7) ((readAt r 2).cursor ++ f r 6)] ++ RangeUse.gates (rangeAt r 1)
def dataShape (tokens : Tokens) (cs : List ConstantSourceMatrix.Record) (r : Row) (start : Linear) : Prop :=
  r.fields.length = 8 ∧ r.zeros.length = 3 ∧ r.ranges.length = 2 ∧ r.constants.length = 1 ∧ r.queries.length = 0 ∧ r.reads.length = 3 ∧
  readMatches tokens (readAt r 0) 1 (f r 0) start ∧
  readMatches tokens (readAt r 1) 1 (f r 3) (readAt r 0).cursor ∧
  constLink cs r 0 (sub (f r 0) (f r 2)) o (readAt r 1).cursor ∧
  readMatches tokens (readAt r 2) 1 (f r 0) (constEnd cs r 0)
instance (t : Tokens) (cs : List ConstantSourceMatrix.Record) (r : Row) (p : Linear) : Decidable (dataShape t cs r p) := by unfold dataShape; infer_instance

def checkData (matrix : Shape) (tokens : Tokens) (splits : Splits) (cs : List ConstantSourceMatrix.Record) (r : Row) (start finish : Linear) :=
  decide (dataShape tokens cs r start) && checkRange matrix (rangeAt r 0) (f r 1) 2 &&
  checkRange matrix (rangeAt r 1) (sub finish (f r 7)) 32 &&
  MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (dataGates tokens splits cs r start finish)
def checkDatas (matrix : Shape) (tokens : Tokens) (splits : Splits) (cs : List ConstantSourceMatrix.Record) (finish : Linear) : List Row → Linear → Bool
  | [],_ => true
  | r::rest,start => checkData matrix tokens splits cs r start finish && checkDatas matrix tokens splits cs finish rest (f r 7)
def datasEnd : List Row → Linear → Linear
  | [],start => start
  | r::rest,_ => datasEnd rest (f r 7)

def itemShape (cs : List ConstantSourceMatrix.Record) (r : Row) : Prop :=
  r.fields.length = 6 ∧ r.zeros = [] ∧ r.ranges.length = 0 ∧ r.constants.length = 1 ∧ r.queries.length = 1 ∧ r.reads.length = 0 ∧
  constLink cs r 0 (f r 0) (f r 5) (f r 3) ∧ ConstantSourceMatrix.same (f r 4) (constEnd cs r 0) ∧
  queryAt r 0 = ⟨f r 0,f r 1,f r 5⟩
instance (cs : List ConstantSourceMatrix.Record) (r : Row) : Decidable (itemShape cs r) := by unfold itemShape; infer_instance

def checkItem (matrix : Shape) (tokens : Tokens) (splits : Splits) (cs : List ConstantSourceMatrix.Record) (r : Row) :=
  decide (itemShape cs r) && MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (ConstantSourceMatrix.gates tokens splits (constAt cs r 0))

def customGates (splits : Splits) (r : Row) (sectionRow : EnvelopeMatrix.Row) (base previous : Linear) :=
  zeroG r 0 sectionRow.entry.id ++ [mulGate sectionRow.entry.active (zero r 0) (f r 0),queryGate (f r 0) (base ++ previous) (queryAt r 0)] ++
  splitGates (split splits r.heads) ++ [gate (f r 0) (sub (split splits r.heads).low sectionRow.entry.body),
    mulGate (f r 0) (sub sectionRow.entry.finish (split splits r.heads).high) (f r 1)] ++ RangeUse.gates (rangeAt r 0) ++
  [eqGate (f r 2) (previous ++ f r 0)]
def customShape (splits : Splits) (r : Row) : Prop :=
  r.fields.length = 3 ∧ r.zeros.length = 1 ∧ r.ranges.length = 1 ∧ r.constants = [] ∧ r.queries.length = 1 ∧ r.reads.length = 0 ∧
  r.heads < splits.length ∧ splitMatches (split splits r.heads) (queryAt r 0).value 32 32 ∧ (queryAt r 0).active = f r 0
instance (s : Splits) (r : Row) : Decidable (customShape s r) := by unfold customShape; infer_instance

def checkCustom (matrix : Shape) (splits : Splits) (r : Row) (sectionRow : EnvelopeMatrix.Row) (base previous : Linear) :=
  decide (customShape splits r) && checkRange matrix (rangeAt r 0) (f r 1) 32 &&
  MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (customGates splits r sectionRow base previous)
def checkCustoms (matrix : Shape) (splits : Splits) (base : Linear) : List Row → List EnvelopeMatrix.Row → Linear → Bool
  | [],[],_ => true
  | r::rest,s::ss,previous => checkCustom matrix splits r s base previous && checkCustoms matrix splits base rest ss (f r 2)
  | _,_,_ => false

def sumActive (rows : List Row) := z ++ rows.flatMap (fun r => f r 0)
def customTotal (rows : List Row) := match rows.getLast? with | none => z | some r => f r 2
def atStart (body : ModuleAuditIO.SourceEnvelope) (id : Nat) := get body.envelope.outputs (4*id+2)
def atEnd (body : ModuleAuditIO.SourceEnvelope) (id : Nat) := get body.envelope.outputs (4*id+3)
def atCount (body : ModuleAuditIO.SourceEnvelope) (id : Nat) := get body.envelope.outputs (4*id+1)
def closeGates (body : ModuleAuditIO.SourceEnvelope) (cs : List ConstantSourceMatrix.Record) (r : Record) (kind : Nat) :=
  if kind = 0 then [eqGate (elementsEnd cs r.flat r.elements (atStart body 9)) (atEnd body 9),eqGate (sumActive r.elements) (atCount body 9)]
  else if kind = 1 then [eqGate (datasEnd r.datas (atStart body 11)) (atEnd body 11),eqGate (sumActive r.datas) (atCount body 11)]
  else [eqGate (atStart body 8) (atEnd body 8),eqGate (atStart body 12) (atEnd body 12)]
def nameCount (frame : NameFrameMatrix.Record) := z ++ frame.headers.flatMap (fun h => NameFrameMatrix.hget h 0)
def literalCount (r : Row) := (GadgetAudit.constantValue (f r 0)).getD 0
def tailGates (imports : ImportMatrix.Record) (frame : NameFrameMatrix.Record) (scalar : ScalarPayloadMatrix.Record) (r : Record) :=
  if r.flat then RangeUse.gates (rangeAt r.tail 0) ++
    [eqGate (nameCount frame) (imports.exportCount ++ scale (ImportMatrix.total imports.rows) 2 ++ customTotal r.customs)]
  else [eqGate (customTotal r.customs) (f r.tail 0),
    eqGate (n frame.headers.length) (n ((ScalarPayloadMatrix.getRows scalar 3).length+2*imports.rows.length+literalCount r.tail))]
def normalizeEntry (e : Entry) := [normalizeLinear e.active,normalizeLinear e.address,normalizeLinear e.value]
def modeEntry (r : Row) (i : Nat) : Entry := ⟨f r 0,scale (f r 0) (Int.ofNat i),bit r 2⟩
def modeEntries (rows : List Row) := (List.range rows.length).map (fun i => modeEntry (rows.getD i default) i)
def stream (owned : List OwnedMatrix.Record) (r : Record) := owned.getD (r.ownedCode-1) default
def modeTable (tables : List ReadOnlyMatrix.Record) (r : Record) := tables.getD (r.modeCode-1) default

def links (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (owned : List OwnedMatrix.Record)
    (imports : ImportMatrix.Record) (frame : NameFrameMatrix.Record) (r : Record) : Prop :=
  r.flat = frame.flat ∧ r.elements.length < 2^32 ∧ r.datas.length < 2^32 ∧ r.customs.length = body.envelope.rows.length ∧
  r.closeStarts.length = 3 ∧ r.closeEnds.length = 3 ∧ r.tail.fields.length = 1 ∧
  (r.customs.all (fun row => decide (queryAt row 0 ∈ (ImportMatrix.table tables imports 0).queries)) = true) ∧
  (if r.flat then
    0 < r.ownedCode ∧ r.ownedCode ≤ owned.length ∧ 0 < r.modeCode ∧ r.modeCode ≤ tables.length ∧
    (stream owned r).parents.map (fun p => p.fields.map normalizeLinear) =
      r.elements.map (fun row => [f row 0,f row 10,f row 11,f row 12].map normalizeLinear) ∧
    (stream owned r).children.map (fun c => c.fields.map normalizeLinear) = r.items.map (fun row => (row.fields.take 5).map normalizeLinear) ∧
    ((modeTable tables r).entries.map normalizeEntry) = (modeEntries r.elements).map normalizeEntry ∧
    ((modeTable tables r).queries.map normalizeEntry) = (r.items.map (fun row => queryAt row 0)).map normalizeEntry ∧
    (modeTable tables r).memory.addressBits = 32 ∧ (modeTable tables r).memory.valueBits = 1 ∧
    r.tail.ranges.length = 1
   else r.ownedCode = 0 ∧ r.modeCode = 0 ∧ r.items.length = 0 ∧ r.tail.ranges.length = 0 ∧ (GadgetAudit.constantValue (f r.tail 0)).isSome = true ∧ literalCount r.tail < 2^32)
instance (b : ModuleAuditIO.SourceEnvelope) (t : List ReadOnlyMatrix.Record) (o : List OwnedMatrix.Record) (i : ImportMatrix.Record) (fr : NameFrameMatrix.Record) (r : Record) : Decidable (links b t o i fr r) := by
  unfold links
  split <;> infer_instance

def check (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (owned : List OwnedMatrix.Record) (imports : ImportMatrix.Record) (frame : NameFrameMatrix.Record)
    (scalar : ScalarPayloadMatrix.Record) (cs : List ConstantSourceMatrix.Record) (r : Record) : Bool :=
  decide (links body tables owned imports frame r) &&
  checkElements matrix body.tokens splits cs r.flat r.elements (atStart body 9) &&
  r.items.all (checkItem matrix body.tokens splits cs) &&
  checkDatas matrix body.tokens splits cs (atEnd body 11) r.datas (atStart body 11) &&
  checkCustoms matrix splits (imports.exportCount ++ scale (ImportMatrix.total imports.rows) 2) r.customs body.envelope.rows z &&
  (List.range 3).all (fun i => MemoryEvidence.checkSpan matrix (r.closeStarts.getD i 0) (r.closeEnds.getD i 0) (closeGates body cs r i)) &&
  (if r.flat then checkRange matrix (rangeAt r.tail 0) (sub (f r.tail 0) (customTotal r.customs)) 32 else true) &&
  MemoryEvidence.checkSpan matrix r.tail.firstGate r.tail.lastGate (tailGates imports frame scalar r)
end ZkBuild.SegmentPayloadMatrix

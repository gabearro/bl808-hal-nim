import ModuleTables

namespace ZkBuild.DeclarationMatrix
open Lean.Grind CircuitShape FullMatrix GadgetShape EnvelopeMatrix
attribute [local instance] Ring.intCast Semiring.natCast

abbrev Entry := BinarySourceMatrix.Entry
abbrev Tokens := List BinaryTokenMatrix.Record
abbrev Splits := List PackedFields.Record

def z : Linear := constant 0
def o : Linear := constant 1
def n (value : Nat) : Linear := constant (Int.ofNat value)
def gate (a b : Linear) : Gate := ⟨a,b,z⟩
def get (xs : List Linear) (i : Nat) : Linear := xs.getD i z
def split (xs : Splits) (i : Nat) : PackedFields.Record := xs.getD i default
def splitGates (r : PackedFields.Record) := RangeUse.gates r.range ++ PackedFields.gates r
def queryGate (active key : Linear) (q : Entry) : Gate := mulGate active key q.address

def splitMatches (s : PackedFields.Record) (value : Linear) (low high : Nat) : Prop :=
  s.value = value ∧ s.lowWidth = low ∧ s.highWidth = high
instance (s : PackedFields.Record) (v : Linear) (a b : Nat) : Decidable (splitMatches s v a b) := by unfold splitMatches; infer_instance

structure TypeRow where
  firstGate : Nat
  lastGate : Nat
  fields : List Linear
  counts : List Linear
  ranges : List RangeUse.Record
  headerToken : Nat
  paramToken : Nat
  resultToken : Nat
  heads : Nat
  paramPosition : Linear
  resultPosition : Linear
  remaining : Linear
  remainingRange : RangeUse.Record
  metadata : Entry
  paramLength : Entry
  resultLength : Entry
  deriving Inhabited

def typeParts (tokens : Tokens) (splits : Splits) (r : TypeRow) (index : Nat) (prior : List Linear) (previous endPos : Linear) : List (List Gate) :=
  let a := get r.fields 0
  let start := get r.fields 1
  let ps := get r.fields 2
  let rs := get r.fields 3
  let finish := get r.fields 4
  let pc := get r.fields 5
  let rc := get r.fields 6
  let heads := split splits r.heads
  [[boolGate a,gate a (sub o previous)],
   ((r.fields.drop 1).zip r.ranges).flatMap (fun (v,range) => RangeUse.gates range ++ [gate (sub o a) v]),
   [gate a (sub start (get prior 3))],
   BinaryTokenMatrix.gates (token tokens r.headerToken),
   [mulGate a (start++o) r.paramPosition],BinaryTokenMatrix.gates (token tokens r.paramToken),
   [gate a (sub (sub (sub ps start) o) (token tokens r.paramToken).length),
    mulGate a (ps++pc) r.resultPosition],BinaryTokenMatrix.gates (token tokens r.resultToken),
   [gate a (sub (sub (sub rs ps) pc) (token tokens r.resultToken).length),
    gate a (sub (sub finish rs) rc),mulGate a (sub endPos finish) r.remaining],
   RangeUse.gates r.remainingRange,[queryGate a (n (2*index+1)) r.metadata],splitGates heads,
   [queryGate a heads.low r.paramLength,queryGate a heads.high r.resultLength,
    eqGate r.paramLength.value pc,eqGate r.resultLength.value rc,
    eqGate (get r.counts 0) (get prior 0++a),eqGate (get r.counts 1) (get prior 1++pc),
    eqGate (get r.counts 2) (get prior 2++rc),selectGate a finish (get prior 3) (get r.counts 3)]]

def typeGates (tokens : Tokens) (splits : Splits) (r : TypeRow) (index : Nat) (prior : List Linear) (previous endPos : Linear) :=
  (typeParts tokens splits r index prior previous endPos).flatten

def checkType (matrix : Shape) (tokens : Tokens) (splits : Splits) (r : TypeRow)
    (index : Nat) (prior : List Linear) (previous endPos : Linear) : Bool :=
  let a := get r.fields 0
  decide (r.fields.length = 7 ∧ r.ranges.length = 6 ∧ r.counts.length = 4 ∧
    r.headerToken < tokens.length ∧ r.paramToken < tokens.length ∧ r.resultToken < tokens.length ∧ r.heads < splits.length ∧
    tokenMatches (token tokens r.headerToken) 0 a (get r.fields 1) (scale a 96) ∧
    tokenMatches (token tokens r.paramToken) 1 a r.paramPosition (get r.fields 5) ∧
    tokenMatches (token tokens r.resultToken) 1 a r.resultPosition (get r.fields 6) ∧
    splitMatches (split splits r.heads) r.metadata.value 32 32 ∧
    r.metadata.active = a ∧ r.paramLength.active = a ∧ r.resultLength.active = a) &&
  ((r.fields.drop 1).zip r.ranges).all (fun (v,range) => RangeUse.check matrix range v 32) &&
  RangeUse.check matrix r.remainingRange r.remaining 32 &&
  MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (typeGates tokens splits r index prior previous endPos)

def typeSeed (start : Linear) : List Linear := [z,z,z,start]
def typeFinal : List TypeRow → List Linear → List Linear
  | [],prior => prior
  | r::rest,_ => typeFinal rest r.counts

def checkTypes (matrix : Shape) (tokens : Tokens) (splits : Splits) (endPos : Linear) :
    List TypeRow → Nat → List Linear → Linear → Bool
  | [],_,_,_ => true
  | r::rest,index,prior,previous => checkType matrix tokens splits r index prior previous endPos &&
      checkTypes matrix tokens splits endPos rest (index+1) r.counts (get r.fields 0)

structure VectorRow where
  firstGate : Nat
  lastGate : Nat
  tagZero : Nat
  extendedZero : Nat
  keySplit : Nat
  spanSplit : Nat
  heads : Nat
  node : Nat
  byteToken : Nat
  fields : List Linear
  location : Entry
  metadata : Entry
  memberQuery : Entry
  addressRange : RangeUse.Record
  valueRange : RangeUse.Record
  orderRange : RangeUse.Record
  withinRange : RangeUse.Record
  hasOrder : Bool
  orderDelta : Linear
  within : Linear
  code : Linear
  position : Linear
  memberKey : Linear
  count : Linear
  deriving Inhabited

def vectorParts (tokens : Tokens) (splits : Splits) (r : VectorRow) (reverse : Bool) (previous previousAddress count : Linear) : List (List Gate) :=
  let a := get r.fields 0
  let address := get r.fields 1
  let tag := get r.fields 2
  let key := split splits r.keySplit
  let span := split splits r.spanSplit
  let heads := split splits r.heads
  let node := split splits r.node
  let head := if reverse then heads.low else heads.high
  let ordinal := if reverse then sub (sub span.high key.low) o else key.low
  [[boolGate a,gate a (sub o previous)],RangeUse.gates r.addressRange,RangeUse.gates r.valueRange,
   zeroGates (sub tag (n 7)) (wire r.tagZero) (wire (r.tagZero+1))++[eqGate (wire r.tagZero) z],
   [gate (sub o a) address,gate (sub o a) tag],
   (if r.hasOrder then [mulGate a (sub (sub address previousAddress) o) r.orderDelta]++RangeUse.gates r.orderRange else []),
   splitGates key,[queryGate a key.high r.location],splitGates span,
   [mulGate a (sub (sub span.high key.low) o) r.within],RangeUse.gates r.withinRange,
   zeroGates (sub tag (n 5)) (wire r.extendedZero) (wire (r.extendedZero+1))++
     zeroGates (sub tag (n 6)) (wire (r.extendedZero+2)) (wire (r.extendedZero+3)),
   [mulGate a (sub (sub (n 127) tag) (scale (wire r.extendedZero++wire (r.extendedZero+2)) 10)) r.code,
    mulGate a (span.low++key.low) r.position],BinaryTokenMatrix.gates (token tokens r.byteToken),
   [queryGate a (scale key.high 2++o) r.metadata],splitGates heads,
   [mulGate a (scale head (Int.ofNat (2^32))++ordinal) r.memberKey,queryGate a r.memberKey r.memberQuery],
   splitGates node,[gate a (sub node.low tag),eqGate r.count (count++a)]]

def vectorGates (tokens : Tokens) (splits : Splits) (r : VectorRow) (reverse : Bool) (previous previousAddress count : Linear) :=
  (vectorParts tokens splits r reverse previous previousAddress count).flatten

def checkVector (matrix : Shape) (tokens : Tokens) (splits : Splits) (r : VectorRow) (reverse : Bool)
    (index : Nat) (previous previousAddress count : Linear) : Bool :=
  let a := get r.fields 0
  decide (r.fields.length = 3 ∧ r.byteToken < tokens.length ∧ r.keySplit < splits.length ∧
    r.spanSplit < splits.length ∧ r.heads < splits.length ∧ r.node < splits.length ∧
    r.hasOrder = (index != 0) ∧ tokenMatches (token tokens r.byteToken) 0 a r.position r.code ∧
    splitMatches (split splits r.keySplit) (get r.fields 1) 32 32 ∧
    splitMatches (split splits r.spanSplit) r.location.value 32 32 ∧
    splitMatches (split splits r.heads) r.metadata.value 32 32 ∧
    splitMatches (split splits r.node) r.memberQuery.value 3 32 ∧
    r.location.active = a ∧ r.metadata.active = a ∧ r.memberQuery.active = a) &&
  RangeUse.check matrix r.addressRange (get r.fields 1) 64 &&
  RangeUse.check matrix r.valueRange (get r.fields 2) 3 && RangeUse.check matrix r.withinRange r.within 32 &&
  (if r.hasOrder then RangeUse.check matrix r.orderRange r.orderDelta 64 else true) &&
  MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (vectorGates tokens splits r reverse previous previousAddress count)

def checkVectors (matrix : Shape) (tokens : Tokens) (splits : Splits) (reverse : Bool) :
    List VectorRow → Nat → Linear → Linear → Linear → Bool
  | [],_,_,_,_ => true
  | r::rest,index,previous,address,count => checkVector matrix tokens splits r reverse index previous address count &&
      checkVectors matrix tokens splits reverse rest (index+1) (get r.fields 0) (get r.fields 1) r.count

def vectorFinal : List VectorRow → Linear → Linear
  | [],count => count
  | r::rest,_ => vectorFinal rest r.count

structure FunctionRow where
  firstGate : Nat
  lastGate : Nat
  byteToken : Nat
  active : Linear
  cursor : Linear
  count : Linear
  query : Entry
  deriving Inhabited

def functionGates (tokens : Tokens) (r : FunctionRow) (index : Nat) (first cursor previous count : Linear) : List Gate :=
  [boolGate r.active,gate r.active (sub o previous)]++BinaryTokenMatrix.gates (token tokens r.byteToken)++
  [queryGate r.active (scale (first++n index) 2) r.query,
   eqGate r.cursor (cursor++(token tokens r.byteToken).length),eqGate r.count (count++r.active)]

def checkFunction (matrix : Shape) (tokens : Tokens) (r : FunctionRow) (index : Nat) (first cursor previous count : Linear) : Bool :=
  decide (r.byteToken < tokens.length ∧ r.query.active = r.active ∧ tokenMatches (token tokens r.byteToken) 1 r.active cursor r.query.value) &&
  MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (functionGates tokens r index first cursor previous count)

def checkFunctions (matrix : Shape) (tokens : Tokens) (first : Linear) : List FunctionRow → Nat → Linear → Linear → Linear → Bool
  | [],_,_,_,_ => true
  | r::rest,index,cursor,previous,count => checkFunction matrix tokens r index first cursor previous count &&
    checkFunctions matrix tokens first rest (index+1) r.cursor r.active r.count

def functionFinal : List FunctionRow → Linear → Linear → Linear × Linear
  | [],cursor,count => (cursor,count)
  | r::rest,_,_ => functionFinal rest r.cursor r.count

structure TagRow where
  firstGate : Nat
  lastGate : Nat
  attributeToken : Nat
  indexToken : Nat
  active : Linear
  typeIndex : Linear
  position : Linear
  cursor : Linear
  deriving Inhabited

def tagGates (tokens : Tokens) (r : TagRow) (cursor : Linear) : List Gate :=
  BinaryTokenMatrix.gates (token tokens r.attributeToken)++[mulGate r.active (cursor++o) r.position]++
  BinaryTokenMatrix.gates (token tokens r.indexToken)++[eqGate r.cursor (cursor++r.active++(token tokens r.indexToken).length)]

def checkTag (matrix : Shape) (tokens : Tokens) (r : TagRow) (cursor : Linear) : Bool :=
  decide (r.attributeToken < tokens.length ∧ r.indexToken < tokens.length ∧
    tokenMatches (token tokens r.attributeToken) 0 r.active cursor z ∧
    tokenMatches (token tokens r.indexToken) 1 r.active r.position r.typeIndex) &&
  MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (tagGates tokens r cursor)

def checkTags (matrix : Shape) (tokens : Tokens) : List TagRow → Linear → Bool
  | [],_ => true
  | r::rest,cursor => checkTag matrix tokens r cursor && checkTags matrix tokens rest r.cursor

def tagFinal : List TagRow → Linear → Linear
  | [],cursor => cursor
  | r::rest,_ => tagFinal rest r.cursor

structure Record where
  firstFunction : Linear
  typeStart : Linear
  typeEnd : Linear
  typeCount : Linear
  functionStart : Linear
  functionEnd : Linear
  functionCount : Linear
  tagStart : Linear
  tagEnd : Linear
  types : List TypeRow
  params : List VectorRow
  results : List VectorRow
  functions : List FunctionRow
  tags : List TagRow
  tables : List Nat
  typeCloseStart : Nat
  typeCloseEnd : Nat
  paramCloseStart : Nat
  paramCloseEnd : Nat
  resultCloseStart : Nat
  resultCloseEnd : Nat
  functionCloseStart : Nat
  functionCloseEnd : Nat
  tagCloseStart : Nat
  tagCloseEnd : Nat
  paramTotal : Linear
  resultTotal : Linear
  paramTotalRange : RangeUse.Record
  resultTotalRange : RangeUse.Record
  deriving Inhabited

def table (tables : List ReadOnlyMatrix.Record) (r : Record) (i : Nat) : ReadOnlyMatrix.Record := tables.getD (r.tables.getD i 0) default

def locations (rows : List TypeRow) (start count : Nat) : List Entry :=
  (List.range rows.length).map fun i =>
    let r := rows.getD i default
    ⟨get r.fields 0,scale (get r.fields 0) (Int.ofNat i),get r.fields start++scale (get r.fields count) (Int.ofNat (2^32))⟩

def checkLinks (tables : List ReadOnlyMatrix.Record) (r : Record) : Bool :=
  decide (r.tables.length = 6 ∧ (∀ i ∈ r.tables, i < tables.length) ∧
    (table tables r 0).entries = locations r.types 2 5 ∧ (table tables r 0).queries = r.params.map VectorRow.location ∧
    (table tables r 1).entries = locations r.types 3 6 ∧ (table tables r 1).queries = r.results.map VectorRow.location ∧
    (table tables r 2).queries = r.types.map TypeRow.metadata++r.params.map VectorRow.metadata++r.results.map VectorRow.metadata ∧
    (table tables r 3).queries = r.types.flatMap (fun t => [t.paramLength,t.resultLength]) ∧
    (table tables r 4).queries = r.params.map VectorRow.memberQuery++r.results.map VectorRow.memberQuery ∧
    (table tables r 5).queries = r.functions.map FunctionRow.query ∧
    ((table tables r 5).entries.map (fun e => (e.active,e.address))) = ((table tables r 2).entries.map (fun e => (e.active,e.address)))) &&
  (List.range 6).all (fun i => decide ((table tables r i).memory.addressBits = ([32,32,33,32,64,33] : List Nat).getD i 0 ∧
    (table tables r i).memory.valueBits = ([64,64,64,32,35,32] : List Nat).getD i 0))

def Metadata (envelope : EnvelopeMatrix.Record) (r : Record) : Prop :=
  let final := typeFinal r.types (typeSeed r.typeStart)
  r.types.length < 2^32 ∧ r.params.length < 2^32 ∧ r.results.length < 2^32 ∧ r.functions.length < 2^32 ∧
    r.typeStart = get envelope.outputs 6 ∧ r.typeEnd = get envelope.outputs 7 ∧ r.typeCount = get envelope.outputs 5 ∧
    r.functionStart = get envelope.outputs 14 ∧ r.functionEnd = get envelope.outputs 15 ∧ r.functionCount = get envelope.outputs 13 ∧
    r.tagStart = get envelope.outputs 54 ∧ r.tagEnd = get envelope.outputs 55 ∧
    r.paramTotal = get final 1 ∧ r.resultTotal = get final 2

instance (envelope : EnvelopeMatrix.Record) (r : Record) : Decidable (Metadata envelope r) := by
  unfold Metadata
  infer_instance

def check (matrix : Shape) (tokens : Tokens) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (envelope : EnvelopeMatrix.Record) (r : Record) : Bool :=
  let final := typeFinal r.types (typeSeed r.typeStart)
  let functions := functionFinal r.functions r.functionStart z
  decide (Metadata envelope r) &&
  checkTypes matrix tokens splits r.typeEnd r.types 0 (typeSeed r.typeStart) o &&
  RangeUse.check matrix r.paramTotalRange r.paramTotal 64 && RangeUse.check matrix r.resultTotalRange r.resultTotal 64 &&
  MemoryEvidence.checkSpan matrix r.typeCloseStart r.typeCloseEnd
    ([eqGate (get final 0) r.typeCount,eqGate (get final 3) r.typeEnd]++RangeUse.gates r.paramTotalRange++RangeUse.gates r.resultTotalRange) &&
  checkVectors matrix tokens splits true r.params 0 o z z && checkVectors matrix tokens splits false r.results 0 o z z &&
  MemoryEvidence.checkSpan matrix r.paramCloseStart r.paramCloseEnd [eqGate (vectorFinal r.params z) r.paramTotal] &&
  MemoryEvidence.checkSpan matrix r.resultCloseStart r.resultCloseEnd [eqGate (vectorFinal r.results z) r.resultTotal] &&
  checkLinks tables r && checkFunctions matrix tokens r.firstFunction r.functions 0 r.functionStart o z &&
  MemoryEvidence.checkSpan matrix r.functionCloseStart r.functionCloseEnd [eqGate functions.2 r.functionCount,eqGate functions.1 r.functionEnd] &&
  checkTags matrix tokens r.tags r.tagStart &&
  MemoryEvidence.checkSpan matrix r.tagCloseStart r.tagCloseEnd [eqGate (tagFinal r.tags r.tagStart) r.tagEnd]

end ZkBuild.DeclarationMatrix

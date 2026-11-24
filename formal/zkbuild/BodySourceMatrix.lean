import SourceProgram
import ModuleContextSound
set_option autoImplicit false
set_option synthInstance.maxSize 512
namespace ZkBuild.BodySourceMatrix
open CircuitShape GadgetShape DeclarationMatrix SourceProgram
abbrev Fields := List Linear
structure Body where
  fields : Fields
  locals : List Fields
  deriving Inhabited
structure Record where
  flat : Bool
  firstFunction : Linear
  bodies : List Body
  locals : List Fields
  spans : List Fields
  banks : List Nat
  program : Program
  deriving Inhabited
abbrev Entries := List ReadOnlyMatrix.Entry
abbrev Queries := List Entries
structure Result where
  queries : Queries
  positions : Entries
  counts : Entries
  spans : Entries
  deriving Inhabited

def f (xs : Fields) (i : Nat) := get xs i
def normalized := ModuleContextMatrix.normalized
def normalizedEntries := ModuleContextMatrix.normalizedEntries
def table (tables : List ReadOnlyMatrix.Record) (r : Record) (i : Nat) :=
  let atIndex := if r.flat then i else ([0,0,0,1,4,2,3] : List Nat).getD i 0
  tables.getD (r.banks.getD atIndex 0) default

def addQuery (acc : Queries) (i : Nat) (q : ReadOnlyMatrix.Entry) : Queries :=
  acc.take i ++ [(acc.getD i [] ++ [q])] ++ acc.drop (i+1)
def query (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (r : Record) (acc : Queries)
    (bank : Nat) (active key : Linear) : Eval (Linear × Queries) := do
  let entries := (table tables r bank).queries
  let i := (acc.getD bank []).length
  require (decide (i < entries.length)) s!"missing body query {bank}:{i}"
  let q := entries.getD i default
  let address ← if r.flat then mul matrix r.program active key else pure key
  require (decide (normalizedEntries [q] = normalizedEntries [⟨active,address,q.value⟩])) s!"body query {bank}:{i} rejected"
  pure (q.value,addQuery acc bank q)

def replayFlat (matrix : Shape) (tokens : Tokens) (splits : Splits)
    (tables : List ReadOnlyMatrix.Record) (body : ModuleAuditIO.SourceEnvelope) (r : Record) : Eval Result := do
  let p := r.program
  let mut queries : Queries := List.replicate 7 []
  let mut positions : Entries := []
  let mut counts : Entries := []
  let mut spans : Entries := []
  let mut cursor := get body.envelope.outputs 42
  let mut previous := o
  let mut bodyCount := z
  let mut localCount := z
  for i in List.range r.bodies.length do
    let row := (r.bodies.getD i default).fields
    let active := f row 0
    let size := f row 1
    let declared := f row 2
    let localStart := f row 3
    let instructions := f row 4
    let finish := f row 5
    boolean matrix p active
    raw matrix (gate active (sub o previous))
    for value in [size,declared,localStart,instructions,finish] do
      let _ ← range matrix p value 32
      raw matrix (gate (sub o active) value)
    let sizeLength ← read matrix tokens splits p 1 active cursor size
    let start ← mul matrix p active (cursor++sizeLength)
    raw matrix (gate active (sub (sub finish start) size))
    let remaining ← mul matrix p active (sub (get body.envelope.outputs 43) finish)
    let _ ← range matrix p remaining 32
    let countLength ← read matrix tokens splits p 1 active start declared
    eq matrix p localStart (start++countLength)
    let nonempty ← mul matrix p active (sub (sub finish instructions) o)
    let _ ← range matrix p nonempty 32
    let fn := r.firstFunction++n i
    let (signature,next) ← query matrix tables r queries 2 active (scale fn 2)
    queries := next
    let (head,_) ← split matrix tokens splits p signature
    let (parameters,next) ← query matrix tables r queries 3 active head
    queries := next
    let (total,next) ← query matrix tables r queries 4 active fn
    queries := next
    let (_,declarations) ← split matrix tokens splits p total
    raw matrix (gate active (sub (sub declarations parameters) declared))
    let empty ← zero matrix p declared
    let emptyEnabled ← mul matrix p active empty
    raw matrix (gate emptyEnabled (sub instructions localStart))
    let endPosition ← mul matrix p active (sub finish o)
    let _ ← read matrix tokens splits p 0 active endPosition (scale active 11)
    positions := positions++[⟨active,scale active (Int.ofNat i),localStart++scale instructions (Int.ofNat (2^32))⟩]
    counts := counts++[⟨active,scale active (Int.ofNat i),parameters++scale declared (Int.ofNat (2^32))⟩]
    let address ← mul matrix p active fn
    spans := spans++[⟨active,address,instructions++scale finish (Int.ofNat (2^32))⟩]
    bodyCount ← materialize matrix p (bodyCount++active)
    localCount ← materialize matrix p (localCount++declared)
    cursor ← select matrix p active finish cursor
    previous := active
  eq matrix p bodyCount (get body.envelope.outputs 41)
  eq matrix p cursor (get body.envelope.outputs 43)
  let mut previousOwner := z
  let mut previousOrdinal := z
  let mut previousKey := z
  let mut previousAfter := z
  let mut seen := z
  previous := o
  for i in List.range r.locals.length do
    let row := r.locals.getD i []
    let active := f row 0
    let owner := f row 1
    let ordinal := f row 2
    let position := f row 3
    let amount := f row 4
    let tag := f row 5
    boolean matrix p active
    raw matrix (gate active (sub o previous))
    for value in [owner,ordinal,position,amount,tag] do raw matrix (gate (sub o active) value)
    for value in [owner,ordinal,position] do
      let _ ← range matrix p value 32
    let _ ← range matrix p tag 3
    let invalid ← zero matrix p (sub tag (n 7))
    eq matrix p invalid z
    let key := scale owner (Int.ofNat (2^32))++ordinal
    if i != 0 then
      let delta ← mul matrix p active (sub (sub key previousKey) o)
      let _ ← range matrix p delta 64
    let (positionWord,next) ← query matrix tables r queries 0 active owner
    queries := next
    let span ← split matrix tokens splits p positionWord
    let (countWord,next) ← query matrix tables r queries 1 active owner
    queries := next
    let count ← split matrix tokens splits p countWord
    let distance ← mul matrix p active (sub (sub count.2 ordinal) o)
    let _ ← range matrix p distance 32
    let same ← if i == 0 then pure z else do
      let enabled ← mul matrix p active previous
      let equal ← zero matrix p (sub owner previousOwner)
      mul matrix p enabled equal
    let first := sub active same
    raw matrix (gate first ordinal)
    raw matrix (gate first (sub position span.1))
    raw matrix (gate same (sub (sub ordinal previousOrdinal) o))
    raw matrix (gate same (sub position previousAfter))
    let size ← read matrix tokens splits p 1 active position amount
    let functionRef ← zero matrix p (sub tag (n 5))
    let externalRef ← zero matrix p (sub tag (n 6))
    let typePosition ← mul matrix p active (position++size)
    let typeValue ← mul matrix p active (sub (sub (n 127) tag) (scale (functionRef++externalRef) 10))
    let typeLength ← read matrix tokens splits p 0 active typePosition typeValue
    let after ← materialize matrix p (position++size++typeLength)
    let continues ← if i+1 == r.locals.length then pure z else do
      let nextRow := r.locals.getD (i+1) []
      let enabled ← mul matrix p active (f nextRow 0)
      let equal ← zero matrix p (sub owner (f nextRow 1))
      mul matrix p enabled equal
    let last := sub active continues
    raw matrix (gate last (sub (ordinal++o) count.2))
    raw matrix (gate last (sub after span.2))
    let fn ← mul matrix p active (r.firstFunction++owner)
    let declOrdinal ← mul matrix p active (count.1++ordinal)
    let _ ← range matrix p fn 32
    let _ ← range matrix p declOrdinal 32
    let address := scale fn (Int.ofNat (2^32))++declOrdinal
    let (rangeWord,next) ← query matrix tables r queries 5 active address
    queries := next
    let (_,count) ← split matrix tokens splits p rangeWord
    eq matrix p count amount
    let (tagValue,next) ← query matrix tables r queries 6 active address
    queries := next
    eq matrix p tagValue tag
    seen ← materialize matrix p (seen++active)
    previous := active
    previousOwner := owner
    previousOrdinal := ordinal
    previousKey := key
    previousAfter := after
  let _ ← range matrix p localCount 64
  eq matrix p seen localCount
  pure ⟨queries,positions,counts,spans⟩

def replayLegacy (matrix : Shape) (tokens : Tokens) (splits : Splits)
    (tables : List ReadOnlyMatrix.Record) (body : ModuleAuditIO.SourceEnvelope) (r : Record) : Eval Result := do
  let p := r.program
  let mut queries : Queries := List.replicate 7 []
  let mut spans : Entries := []
  let mut cursor := get body.envelope.outputs 42
  for i in List.range r.bodies.length do
    let item := r.bodies.getD i default
    let row := item.fields
    let fn := r.firstFunction++n i
    let size := f row 1
    let declared := f row 2
    let instructions := f row 4
    let finish := f row 5
    for value in [size,declared,instructions,finish] do
      let _ ← range matrix p value 32
    let sizeLength ← read matrix tokens splits p 1 o cursor size
    let start ← materialize matrix p (cursor++sizeLength)
    eq matrix p finish (start++size)
    let _ ← range matrix p (sub (get body.envelope.outputs 43) finish) 32
    let countLength ← read matrix tokens splits p 1 o start declared
    eq matrix p declared (n item.locals.length)
    cursor ← materialize matrix p (start++countLength)
    require (decide (ModuleProgram.sameInputs [cursor] [f row 3])) "legacy locals cursor rejected"
    let (signature,next) ← query matrix tables r queries 2 o (scale fn 2)
    queries := next
    let (head,_) ← split matrix tokens splits p signature
    let (parameters,next) ← query matrix tables r queries 3 o head
    queries := next
    let (total,next) ← query matrix tables r queries 4 o fn
    queries := next
    let (_,declarations) ← split matrix tokens splits p total
    eq matrix p declarations (parameters++declared)
    for j in List.range item.locals.length do
      let declarationRow := item.locals.getD j []
      let count := f declarationRow 0
      let tag := f declarationRow 1
      let _ ← range matrix p tag 3
      let invalid ← zero matrix p (sub tag (n 7))
      eq matrix p invalid z
      let size ← read matrix tokens splits p 1 o cursor count
      cursor ← materialize matrix p (cursor++size)
      let functionRef ← zero matrix p (sub tag (n 5))
      let externalRef ← zero matrix p (sub tag (n 6))
      let _ ← read matrix tokens splits p 0 o cursor (sub (sub (n 127) tag) (scale (functionRef++externalRef) 10))
      cursor ← materialize matrix p (cursor++o)
      let ordinal ← materialize matrix p (parameters++n j)
      let _ ← range matrix p ordinal 32
      let address := scale fn (Int.ofNat (2^32))++ordinal
      let (rangeWord,next) ← query matrix tables r queries 5 o address
      queries := next
      let (_,rangeCount) ← split matrix tokens splits p rangeWord
      eq matrix p rangeCount count
      let (tagValue,next) ← query matrix tables r queries 6 o address
      queries := next
      eq matrix p tagValue tag
    eq matrix p instructions cursor
    let _ ← range matrix p (sub (sub finish instructions) o) 32
    let _ ← read matrix tokens splits p 0 o (sub finish o) (n 11)
    spans := spans++[⟨o,fn,instructions++scale finish (Int.ofNat (2^32))⟩]
    cursor := finish
  eq matrix p (n r.bodies.length) (get body.envelope.outputs 41)
  eq matrix p cursor (get body.envelope.outputs 43)
  pure ⟨queries,[],[],spans⟩

def replay (matrix : Shape) (tokens : Tokens) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (body : ModuleAuditIO.SourceEnvelope) (r : Record) :=
  (if r.flat then replayFlat matrix tokens splits tables body r else replayLegacy matrix tokens splits tables body r).run (init r.program)
end ZkBuild.BodySourceMatrix

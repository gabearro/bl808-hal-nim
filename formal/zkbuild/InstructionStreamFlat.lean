import InstructionStreamMatrix
set_option autoImplicit false
namespace ZkBuild.InstructionStreamFlat
open CircuitShape GadgetShape DeclarationMatrix SourceProgram InstructionStreamMatrix

def auxiliary (matrix : Shape) (tokens : Tokens) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (r : InstructionStreamMatrix.Record) (rows : List Fields) (catching : Bool) (expected : Linear) (a0 : Acc) : Eval Acc := do
  let p := r.program
  let mut a := a0
  let mut previousActive := o
  let mut previousKey := z
  let mut previousOwner := z
  let mut previousOrdinal := z
  let mut previousNext := z
  let mut previousAfter := z
  let mut countRows := z
  for i in List.range rows.length do
    let row := rows.getD i []
    let active := f row 0
    let owner := f row 1
    let ordinal := f row 2
    let node := f row 3
    let position := f row 4
    boolean matrix p active
    raw matrix (gate active (sub o previousActive))
    for value in [owner,ordinal,node,position] do
      let _ ← range matrix p value 32
      raw matrix (gate (sub o active) value)
    let key := scale owner (Int.ofNat (2^32))++ordinal
    if i != 0 then
      let distance ← mul matrix p active (sub (sub key previousKey) o)
      let _ ← range matrix p distance 64
    let (spanWord,next) ← query matrix tables r a 13 active owner
    a := next
    let span ← split matrix tokens splits p spanWord
    let (kindWord,next) ← query matrix tables r a 14 active owner
    a := next
    let kindBits ← range matrix p kindWord 35
    let kind ← packedBits matrix p (kindBits.take 2)
    let count ← packedBits matrix p (kindBits.drop 2 |>.take 33)
    raw matrix (gate active (sub kind (n (if catching then 2 else 1))))
    let distance ← mul matrix p active (sub (sub count ordinal) o)
    let _ ← range matrix p distance 33
    let (head,next) ← query matrix tables r a 15 active owner
    a := next
    let same ← if i == 0 then pure z else do
      let enabled ← mul matrix p active previousActive
      let equal ← zero matrix p (sub owner previousOwner)
      mul matrix p enabled equal
    let first := sub active same
    raw matrix (gate first ordinal)
    raw matrix (gate first (sub node head))
    raw matrix (gate first (sub position span.1))
    raw matrix (gate same (sub (sub ordinal previousOrdinal) o))
    raw matrix (gate same (sub node previousNext))
    raw matrix (gate same (sub position previousAfter))
    let mut after := position
    let nextNode ← if catching then do
      let (link,next) ← query matrix tables r a 9 active node
      a := next
      let (clause,next) ← query matrix tables r a 10 active node
      a := next
      let bits ← range matrix p link 34
      let clauseKind ← packedBits matrix p (bits.take 2)
      let nextNode ← packedBits matrix p (bits.drop 2 |>.take 32)
      let parts ← split matrix tokens splits p clause
      let tagged ← mul matrix p active (sub o (f bits 1))
      let kindLength ← read matrix tokens splits p 0 active after clauseKind
      after ← materialize matrix p (after++kindLength)
      let untagged ← mul matrix p active (f bits 1)
      raw matrix (gate untagged parts.1)
      let tagPosition ← mul matrix p tagged after
      let tagValue ← mul matrix p tagged parts.1
      let tagLength ← read matrix tokens splits p 1 tagged tagPosition tagValue
      after ← materialize matrix p (after++tagLength)
      let depthPosition ← mul matrix p active after
      let depthLength ← read matrix tokens splits p 1 active depthPosition parts.2
      after ← materialize matrix p (after++depthLength)
      pure nextNode
    else do
      let (nodeValue,next) ← query matrix tables r a 8 active node
      a := next
      let parts ← split matrix tokens splits p nodeValue
      let size ← read matrix tokens splits p 1 active after parts.1
      after ← materialize matrix p (after++size)
      pure parts.2
    let continues ← if i+1 == rows.length then pure z else do
      let nextRow := rows.getD (i+1) []
      let enabled ← mul matrix p active (f nextRow 0)
      let equal ← zero matrix p (sub owner (f nextRow 1))
      mul matrix p enabled equal
    let last := sub active continues
    raw matrix (gate last nextNode)
    raw matrix (gate last (sub after span.2))
    raw matrix (gate last (sub (ordinal++o) count))
    countRows ← materialize matrix p (countRows++active)
    previousActive := active
    previousKey := key
    previousOwner := owner
    previousOrdinal := ordinal
    previousNext := nextNode
    previousAfter := after
  let _ ← range matrix p expected 64
  eq matrix p countRows expected
  pure a

def replay (matrix : Shape) (tokens : Tokens) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (catalog : InstructionDecodeMatrix.Catalog) (decoders : List InstructionDecodeMatrix.Record) (r : InstructionStreamMatrix.Record) : Eval Acc := do
  let p := r.program
  let mut a : Acc := {}
  let _ ← range matrix p r.firstFunction 32
  let mut functionCount := z
  for i in List.range r.functions.length do
    let body := r.spans.getD i default
    let row := r.functions.getD i []
    for j in List.range 4 do
      eq matrix p (f row (3*j)) body.active
      raw matrix (gate (f row (3*j)) (sub (sub (f row (3*j+1)) r.firstFunction) (n i)))
      a := addEntry a (j+1) ⟨f row (3*j),f row (3*j+1),f row (3*j+2)⟩
    raw matrix (gate body.active (sub (sub body.address r.firstFunction) (n i)))
    functionCount ← materialize matrix p (functionCount++body.active)
  let mut fn := r.firstFunction
  let mut pc := z
  let mut previousFinish := z
  let mut depth := z
  let mut branchIndex := z
  let mut catchIndex := z
  let mut vectorIndex := z
  let mut previousActive := o
  let mut expectedLabels := z
  let mut expectedCatches := z
  for i in List.range r.rows.length do
    let row := r.rows.getD i default
    let active := f row.fields 0
    let function := f row.fields 1
    let rowPc := f row.fields 2
    let opcode := f row.fields 3
    let primary := f row.fields 4
    let secondary := f row.fields 5
    let pad := f row.fields 6
    let start := f row.fields 7
    let finish := f row.fields 8
    boolean matrix p active
    raw matrix (gate active (sub o previousActive))
    for value in row.fields.drop 1 do raw matrix (gate (sub o active) value)
    let _ ← range matrix p function 32
    let _ ← range matrix p rowPc 32
    raw matrix (gate active (sub function fn))
    raw matrix (gate active (sub rowPc pc))
    let (spanWord,next) ← query matrix tables r a 0 active function
    a := next
    let span ← split matrix tokens splits p spanWord
    let atStart ← zero matrix p rowPc
    let starting ← mul matrix p active atStart
    let afterPrevious ← select matrix p starting span.1 previousFinish
    raw matrix (gate active (sub start afterPrevious))
    let decoded ← decode matrix tokens splits catalog decoders r row branchIndex catchIndex vectorIndex
    let branch := f decoded 1
    let catching := f decoded 2
    let vector := f decoded 3
    let blockLike := f decoded 4
    let conditional := f decoded 5
    let list := branch++catching
    let listed ← mul matrix p list (f decoded 6)
    let count := listed++branch
    let (headB,next) ← query matrix tables r a 6 branch (scale function (Int.ofNat (2^32))++branchIndex)
    a := next
    let (headC,next) ← query matrix tables r a 7 catching (scale function (Int.ofNat (2^32))++catchIndex)
    a := next
    let head := headB++headC
    raw matrix (gate (sub active list) (sub finish (f decoded 0)))
    let emptyCount ← zero matrix p count
    let emptyList ← mul matrix p list emptyCount
    raw matrix (gate emptyList (sub finish (f decoded 0)))
    let margin ← mul matrix p active (sub finish (f decoded 0))
    let _ ← range matrix p margin 32
    let key := scale function (Int.ofNat (2^32))++rowPc
    a := addEntry a 11 ⟨active,key,opcode++scale pad 65536⟩
    a := addEntry a 12 ⟨active,key,primary++scale secondary (Int.ofNat (2^32))⟩
    a := addEntry a 13 ⟨active,scale active (Int.ofNat i),f decoded 0++scale finish (Int.ofNat (2^32))⟩
    a := addEntry a 14 ⟨active,scale active (Int.ofNat i),branch++scale catching 2++scale count 4⟩
    a := addEntry a 15 ⟨active,scale active (Int.ofNat i),head⟩
    let labelCount ← mul matrix p branch count
    expectedLabels ← materialize matrix p (expectedLabels++labelCount)
    let catchCount ← mul matrix p catching count
    expectedCatches ← materialize matrix p (expectedCatches++catchCount)
    branchIndex ← materialize matrix p (branchIndex++branch)
    catchIndex ← materialize matrix p (catchIndex++catching)
    vectorIndex ← materialize matrix p (vectorIndex++vector)
    let isEnd ← zero matrix p (sub opcode (n 11))
    let ending ← mul matrix p active isEnd
    let isElse ← zero matrix p (sub opcode (n 5))
    let otherwise ← mul matrix p active isElse
    let empty ← zero matrix p depth
    let innerEnd ← mul matrix p ending (sub o empty)
    let rootEnd ← mul matrix p ending empty
    raw matrix (gate otherwise empty)
    let readActive := innerEnd++otherwise
    let bits ← range matrix p row.frame 34
    let framePc ← packedBits matrix p (bits.take 32)
    let readAddress ← mul matrix p readActive (sub (scale function (Int.ofNat (2^32))++depth) o)
    a := addFrame a readActive z readAddress row.frame
    let (opener,next) ← query matrix tables r a 12 readActive (scale function (Int.ofNat (2^32))++framePc)
    a := next
    let offsets ← split matrix tokens splits p opener
    raw matrix (gate innerEnd (sub offsets.1 rowPc))
    raw matrix (gate otherwise (sub (f bits 32) o))
    raw matrix (gate otherwise (f bits 33))
    raw matrix (gate otherwise (sub offsets.2 rowPc))
    let conditionalEnd ← mul matrix p innerEnd (f bits 32)
    let unseenEnd ← mul matrix p conditionalEnd (sub o (f bits 33))
    raw matrix (gate unseenEnd (sub offsets.2 rowPc))
    let writeActive := blockLike++otherwise
    let firstValue ← mul matrix p blockLike (rowPc++scale conditional (Int.ofNat (2^32)))
    let secondValue ← mul matrix p otherwise (row.frame++n (2^33))
    let writeAddress ← mul matrix p writeActive (sub (scale function (Int.ofNat (2^32))++depth) otherwise)
    a := addFrame a writeActive writeActive writeAddress (firstValue++secondValue)
    depth ← materialize matrix p (sub (depth++blockLike) innerEnd)
    let _ ← range matrix p depth 32
    let (last,next) ← query matrix tables r a 1 rootEnd function
    a := next
    raw matrix (gate rootEnd (sub rowPc last))
    raw matrix (gate rootEnd (sub finish span.2))
    let (bCount,next) ← query matrix tables r a 2 rootEnd function
    a := next
    let (cCount,next) ← query matrix tables r a 3 rootEnd function
    a := next
    let (vCount,next) ← query matrix tables r a 4 rootEnd function
    a := next
    let (pool,next) ← query matrix tables r a 5 rootEnd function
    a := next
    raw matrix (gate rootEnd (sub branchIndex bCount))
    raw matrix (gate rootEnd (sub catchIndex cCount))
    raw matrix (gate rootEnd (sub vectorIndex vCount))
    raw matrix (gate rootEnd (sub vectorIndex pool))
    branchIndex ← mul matrix p (sub o rootEnd) branchIndex
    catchIndex ← mul matrix p (sub o rootEnd) catchIndex
    vectorIndex ← mul matrix p (sub o rootEnd) vectorIndex
    fn ← materialize matrix p (fn++rootEnd)
    pc ← mul matrix p (sub o rootEnd) (pc++active)
    previousFinish := finish
    previousActive := active
  eq matrix p fn (r.firstFunction++functionCount)
  eq matrix p pc z
  eq matrix p depth z
  a ← auxiliary matrix tokens splits tables r r.labels false expectedLabels a
  a ← auxiliary matrix tokens splits tables r r.catches true expectedCatches a
  a ← bankBounds matrix tokens splits tables r a
  events matrix tables r a
end ZkBuild.InstructionStreamFlat

import InstructionStreamMatrix
set_option autoImplicit false
set_option synthInstance.maxSize 512
namespace ZkBuild.InstructionStreamLegacy
open CircuitShape GadgetShape DeclarationMatrix SourceProgram InstructionStreamMatrix

def replay (matrix : Shape) (tokens : Tokens) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (catalog : InstructionDecodeMatrix.Catalog) (decoders : List InstructionDecodeMatrix.Record) (r : InstructionStreamMatrix.Record) : Eval Acc := do
  let p := r.program
  let _ ← range matrix p r.firstFunction 32
  let mut a : Acc := {}
  let mut offset := 0
  for body in List.range r.bodySizes.length do
    let count := r.bodySizes.getD body 0
    let fn := r.firstFunction++n body
    let _ ← range matrix p fn 32
    for pc in List.range count do
      let row := r.rows.getD (offset+pc) default
      let key := scale fn (Int.ofNat (2^32))++n pc
      a := addEntry a 11 ⟨o,key,f row.fields 3++scale (f row.fields 6) 65536⟩
      a := addEntry a 12 ⟨o,key,f row.fields 4++scale (f row.fields 5) (Int.ofNat (2^32))⟩
    a := addEntry a 1 ⟨o,fn,n (count-1)⟩
    offset := offset+count
  offset := 0
  for body in List.range r.bodySizes.length do
    let count := r.bodySizes.getD body 0
    let fn := r.firstFunction++n body
    let span := r.spans.getD body default
    eq matrix p span.active o
    eq matrix p span.address fn
    let bounds ← split matrix tokens splits p span.value
    let mut position := bounds.1
    let mut branchIndex := z
    let mut catchIndex := z
    let mut vectorIndex := z
    let mut depth := z
    for pc in List.range count do
      let row := r.rows.getD (offset+pc) default
      require (ModuleProgram.sameInputs (row.fields.take 3) [o,fn,n pc]) "legacy instruction address rejected"
      eq matrix p (f row.fields 7) position
      let decoded ← decode matrix tokens splits catalog decoders r row branchIndex catchIndex vectorIndex
      let mut after := f decoded 0
      let branch := f decoded 1
      let catching := f decoded 2
      let vector := f decoded 3
      let blockLike := f decoded 4
      let conditional := f decoded 5
      let total := f decoded 6
      let (head,next) ← query matrix tables r a 6 branch (scale fn (Int.ofNat (2^32))++branchIndex)
      a := next
      let mut cursor := head
      raw matrix (gate branch (sub (total++o) (n row.labels)))
      for _ in List.range row.labels do
        let (node,next) ← query matrix tables r a 8 branch cursor
        a := next
        let parts ← split matrix tokens splits p node
        let pos ← mul matrix p branch after
        let size ← read matrix tokens splits p 1 branch pos parts.1
        after ← materialize matrix p (after++size)
        cursor := parts.2
      eq matrix p cursor z
      let (head,next) ← query matrix tables r a 7 catching (scale fn (Int.ofNat (2^32))++catchIndex)
      a := next
      cursor := head
      raw matrix (gate catching (sub total (n row.catches)))
      for _ in List.range row.catches do
        let (link,next) ← query matrix tables r a 9 catching cursor
        a := next
        let (value,next) ← query matrix tables r a 10 catching cursor
        a := next
        let bits ← range matrix p link 34
        let kind ← packedBits matrix p (bits.take 2)
        let next ← packedBits matrix p (bits.drop 2)
        let parts ← split matrix tokens splits p value
        let tagged ← mul matrix p catching (sub o (f bits 1))
        let pos ← mul matrix p catching after
        let size ← read matrix tokens splits p 0 catching pos kind
        after ← materialize matrix p (after++size)
        let untagged ← mul matrix p catching (f bits 1)
        raw matrix (gate untagged parts.1)
        let pos ← mul matrix p tagged after
        let tag ← mul matrix p tagged parts.1
        let size ← read matrix tokens splits p 1 tagged pos tag
        after ← materialize matrix p (after++size)
        let pos ← mul matrix p catching after
        let size ← read matrix tokens splits p 1 catching pos parts.2
        after ← materialize matrix p (after++size)
        cursor := next
      eq matrix p cursor z
      eq matrix p (f row.fields 8) after
      position := f row.fields 8
      branchIndex ← materialize matrix p (branchIndex++branch)
      catchIndex ← materialize matrix p (catchIndex++catching)
      vectorIndex ← materialize matrix p (vectorIndex++vector)
      let ending ← zero matrix p (sub (f row.fields 3) (n 11))
      let otherwise ← zero matrix p (sub (f row.fields 3) (n 5))
      let empty ← zero matrix p depth
      let innerEnd ← mul matrix p ending (sub o empty)
      let rootEnd ← mul matrix p ending empty
      eq matrix p rootEnd (n (if pc+1 == count then 1 else 0))
      raw matrix (gate otherwise empty)
      let readActive := innerEnd++otherwise
      let frameBits ← range matrix p row.frame 34
      let framePc ← packedBits matrix p (frameBits.take 32)
      let frameIf := f frameBits 32
      let frameSeen := f frameBits 33
      let address ← mul matrix p readActive (sub (scale fn (Int.ofNat (2^32))++depth) o)
      a := addFrame a readActive z address row.frame
      let (original,next) ← query matrix tables r a 12 readActive (scale fn (Int.ofNat (2^32))++framePc)
      a := next
      let offsets ← split matrix tokens splits p original
      raw matrix (gate innerEnd (sub offsets.1 (n pc)))
      raw matrix (gate otherwise (sub frameIf o))
      raw matrix (gate otherwise frameSeen)
      raw matrix (gate otherwise (sub offsets.2 (n pc)))
      let unclosed ← mul matrix p innerEnd frameIf
      let unclosed ← mul matrix p unclosed (sub o frameSeen)
      raw matrix (gate unclosed (sub offsets.2 (n pc)))
      let writeActive := blockLike++otherwise
      let first ← mul matrix p blockLike (n pc++scale conditional (Int.ofNat (2^32)))
      let second ← mul matrix p otherwise (row.frame++n (2^33))
      let address ← mul matrix p writeActive (sub (scale fn (Int.ofNat (2^32))++depth) otherwise)
      a := addFrame a writeActive writeActive address (first++second)
      depth ← materialize matrix p (sub (depth++blockLike) innerEnd)
      let _ ← range matrix p depth 32
    eq matrix p depth z
    eq matrix p position bounds.2
    let (pool,next) ← query matrix tables r a 5 o fn
    a := next
    eq matrix p vectorIndex pool
    a := addEntry a 2 ⟨o,fn,branchIndex⟩
    a := addEntry a 3 ⟨o,fn,catchIndex⟩
    offset := offset+count
  a ← bankBounds matrix tokens splits tables r a
  events matrix tables r a
end ZkBuild.InstructionStreamLegacy

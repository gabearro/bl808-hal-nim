import StructuredMatrix
set_option autoImplicit false
namespace ZkBuild.StructuredFrames
open CircuitShape GadgetShape DeclarationMatrix SourceProgram ValidationEventMatrix DynamicTypingMatrix StructuredMatrix
def replay (matrix : Shape) (memory : MemoryEmbedded.Record) (s : DynamicTypingMatrix.Stage) : Eval (List Fields × List Fields) := do
  let p := s.program
  let mut beforeDepth := z
  let mut rootPending := z
  let mut heldPad := z
  let mut source := z
  let mut outputs := []
  let mut accesses := []
  for i in List.range s.rows.length do
    let row := eventAt s i
    let flags := flagsAt s i
    let primary := f (rowAt s.inputs i) 0
    let pad := f (rowAt s.inputs i) 1
    let labelDepth := f (rowAt s.inputs i) 2
    let mut op := []
    for code in ([2,3,4,5,11,31,12,13,15] : List Nat) do
      let selected ← zero matrix p (sub (f row 8) (n code))
      op := op++[selected]
    let opening := f op 0++f op 1++f op 2++f op 5
    let branching := f op 6++f op 7++f op 8
    let closing := f op 3++f op 4
    let control := opening++branching++closing
    let _ ← range matrix p pad 33
    let _ ← range matrix p primary 32
    raw matrix (gate (sub o (f flags 1)) pad)
    raw matrix (gate (sub o (f flags 1)) primary)
    raw matrix (gate rootPending (sub o (f flags 4)))
    let rootPush ← mul matrix p rootPending (f flags 4)
    raw matrix (gate (sub (f flags 4) rootPush) (sub (sub o opening) (f op 3)))
    raw matrix (gate (f flags 5) (sub o closing))
    let empty ← zero matrix p beforeDepth
    let nonempty := sub o empty
    let space := scale (f row 1) (Int.ofNat (2^32))
    let read ← mul matrix p (f flags 1) (branching++closing)
    let depth ← mul matrix p branching primary
    let read := read++f flags 9
    let depth ← select matrix p (f flags 9) labelDepth depth
    raw matrix (gate read (sub o nonempty))
    let slot ← select matrix p (f op 8) z (sub (sub beforeDepth o) depth)
    let slot ← mul matrix p read slot
    let _ ← range matrix p slot 32
    let observed := (memory.inputs.getD (2*i) default).fields.value
    let readAddress ← mul matrix p read space
    accesses := accesses++[[read,z,readAddress++slot,observed]]
    heldPad ← select matrix p (f flags 0++f flags 1) pad heldPad
    let emptyPad ← zero matrix p heldPad
    let mut singleton : Linear := []
    let mut singletonKey : Linear := []
    for tag in List.range 7 do
      let selected ← zero matrix p (sub heldPad (n (tag+1)))
      singleton := singleton++selected
      singletonKey := singletonKey++scale selected (Int.ofNat (4*tag+3))
    let typeIndex ← mul matrix p (sub (sub o emptyPad) singleton) (sub heldPad (n 256))
    let _ ← range matrix p typeIndex 32
    let blockKey := scale emptyPad 2++singletonKey++scale typeIndex 4
    let blockKind := f op 1++scale (f op 2) 2
    let proposed ← materialize matrix p (scale blockKey 4++blockKind)
    let rootToken := scale (f row 1) 16++n 4
    let left ← mul matrix p opening proposed
    let right ← mul matrix p (branching++closing) observed
    let initial ← select matrix p (f flags 0) rootToken (left++right)
    source ← select matrix p (f flags 0++f flags 1) initial source
    source ← select matrix p (f flags 9) observed source
    let descriptor ← frameSplit matrix p source
    let elseBegin ← mul matrix p (f flags 1) (f op 3)
    raw matrix (gate elseBegin (sub (f descriptor 1) (n 2)))
    let nested ← select matrix p (f op 3) (scale (f descriptor 2) 4++n 3) proposed
    let written ← select matrix p rootPush rootToken nested
    let address ← mul matrix p (f flags 4) (space++beforeDepth)
    let value ← mul matrix p (f flags 4) written
    accesses := accesses++[[f flags 4,f flags 4,address,value]]
    outputs := outputs++[descriptor++op++[opening,branching,closing,control,rootPush]]
    beforeDepth := f row 7
    rootPending := f flags 0
  eq matrix p rootPending z
  pure (outputs,accesses)
end ZkBuild.StructuredFrames

import StructuredMatrix
set_option autoImplicit false
namespace ZkBuild.StructuredExceptions
open CircuitShape GadgetShape DeclarationMatrix SourceProgram ValidationEventMatrix DynamicTypingMatrix StructuredMatrix
def reversals (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (s : DynamicTypingMatrix.Stage) : Eval (List (List Fields)) := do
  let p := s.program
  let rs := bank tables s 0
  let ls := bank tables s 1
  let ms := bank tables s 2
  let mut reverseQueries := []
  let mut ownLengths := []
  let mut oppositeLengths := []
  let mut memberLengths := []
  let mut members := []
  for i in List.range rs.entries.length do
    let entry := rs.entries.getD i default
    let length ← readQuery matrix p entry.active entry.value (DynamicTypingMatrix.entry (ls.queries.getD (rs.entries.length+i) default))
    oppositeLengths := oppositeLengths++[length]
    ownLengths := ownLengths++[[entry.active,entry.address,f length 2]]
  for i in List.range ms.entries.length do
    let entry := ms.entries.getD i default
    let (ordinal,head) ← split matrix [] splits p entry.address
    let reversed ← readQuery matrix p entry.active head (DynamicTypingMatrix.entry (rs.queries.getD i default))
    reverseQueries := reverseQueries++[reversed]
    let length ← readQuery matrix p entry.active head (DynamicTypingMatrix.entry (ls.queries.getD (2*rs.entries.length+i) default))
    memberLengths := memberLengths++[length]
    let opposite ← memberQuery matrix p entry.active (f reversed 2) (sub (sub (f length 2) o) ordinal) (DynamicTypingMatrix.entry (ms.queries.getD i default))
    members := members++[opposite]
    let (a,_) ← split matrix [] splits p entry.value 3 32
    let (b,_) ← split matrix [] splits p (f opposite 2) 3 32
    raw matrix (gate entry.active (sub a b))
  pure [reverseQueries,ownLengths++oppositeLengths++memberLengths,members]

def throws (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (s : DynamicTypingMatrix.Stage) : Eval (List (List Fields)) := do
  let p := s.program
  let os := bank tables s 0
  let ts := bank tables s 1
  let ns := bank tables s 2
  let mut origins := []
  let mut tags := []
  let mut nodes := []
  for i in List.range ts.entries.length do
    let entry := ts.entries.getD i default
    let typeIndex := f (rowAt s.auxiliary i) 0
    raw matrix (gate entry.active (sub entry.address (n i)))
    let _ ← range matrix p typeIndex 32
    raw matrix (gate (sub o entry.active) typeIndex)
    let (_,results) ← split matrix [] splits p entry.value
    raw matrix (gate entry.active results)
    let address ← mul matrix p entry.active (scale typeIndex 2++o)
    origins := origins++[[entry.active,address,entry.value]]
  let mut params := z
  let mut cleared := z
  for i in List.range s.rows.length do
    let row := eventAt s i
    let flags := flagsAt s i
    let primary := f (rowAt s.inputs i) 0
    let tagged ← zero matrix p (sub (f row 8) (n 8))
    let opaqueOp ← zero matrix p (sub (f row 8) (n 10))
    let throwing := tagged++opaqueOp
    let _ ← range matrix p (f row 8) 16
    let _ ← range matrix p primary 32
    raw matrix (gate (sub o (f flags 1)) primary)
    let query ← mul matrix p tagged (f flags 1)
    let data := (ts.queries.getD i default).value
    let address ← mul matrix p query primary
    tags := tags++[[query,address,data]]
    let (head,_) ← split matrix [] splits p data
    let reset := f flags 0++f flags 1
    let reference ← mul matrix p opaqueOp (f flags 1)
    params ← select matrix p reset (head++reference) params
    cleared ← select matrix p reset z cleared
    let pop ← mul matrix p throwing (f flags 3)
    let taggedPop ← mul matrix p tagged (f flags 3)
    let opaquePop ← mul matrix p opaqueOp (f flags 3)
    let clear ← mul matrix p throwing (f flags 6)
    let finish ← mul matrix p throwing (f flags 7)
    raw matrix (gate throwing (f flags 2++f flags 4++f flags 5))
    raw matrix (gate pop cleared)
    let payload := (ns.queries.getD i default).value
    let address ← mul matrix p taggedPop params
    nodes := nodes++[[taggedPop,address,payload]]
    let (tag,next) ← split matrix [] splits p payload 3 32
    let actual := f row 4
    let unknown ← zero matrix p (sub actual (n 7))
    let invalid ← zero matrix p (sub tag (n 7))
    raw matrix (gate taggedPop invalid)
    let matched ← zero matrix p (sub actual tag)
    raw matrix (gate taggedPop (sub (sub o unknown) matched))
    let matched ← zero matrix p (sub actual (n 6))
    raw matrix (gate opaquePop (sub (sub o unknown) matched))
    raw matrix (gate opaquePop (sub params o))
    let next ← select matrix p taggedPop next params
    params ← materialize matrix p (sub next opaquePop)
    raw matrix (gate clear (params++cleared))
    cleared ← materialize matrix p (cleared++clear)
    raw matrix (gate finish params)
    raw matrix (gate finish (sub cleared o))
  let _ := os
  pure [origins,tags,nodes]
end ZkBuild.StructuredExceptions

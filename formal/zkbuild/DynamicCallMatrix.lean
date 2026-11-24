import DynamicTypingMatrix
set_option autoImplicit false
namespace ZkBuild.DynamicCallMatrix
open CircuitShape GadgetShape DeclarationMatrix SourceProgram ValidationEventMatrix DynamicTypingMatrix

def replay (matrix : Shape) (splits : Splits) (s : DynamicTypingMatrix.Stage) : Eval (List Fields × List Fields × List Fields) := do
  let p := s.program
  let mut params := z
  let mut results := z
  let mut pending := z
  let mut pushed := z
  let mut cleared := z
  let mut rootResults := z
  let mut metadata := []
  let mut nodes := []
  let mut tables := []
  for i in List.range s.rows.length do
    let row := eventAt s i
    let flags := flagsAt s i
    let primary := f (rowAt s.inputs i) 0
    let secondary := f (rowAt s.inputs i) 1
    let direct ← zero matrix p (sub (f row 8) (n 16))
    let indirect ← zero matrix p (sub (f row 8) (n 17))
    let returnDirect ← zero matrix p (sub (f row 8) (n 18))
    let returnIndirect ← zero matrix p (sub (f row 8) (n 19))
    let call := direct++indirect++returnDirect++returnIndirect
    let tail := returnDirect++returnIndirect
    let indexed := indirect++returnIndirect
    let begin ← mul matrix p call (f flags 1)
    let indirectBegin ← mul matrix p indexed (f flags 1)
    let reset := f flags 0++f flags 1
    let _ ← range matrix p primary 32
    let _ ← range matrix p secondary 32
    raw matrix (gate (sub o (f flags 1)) primary)
    raw matrix (gate (sub o (f flags 1)) secondary)
    let metaActive := f flags 0++begin
    let left ← mul matrix p (f flags 0) (scale (f row 1) 2)
    let right ← mul matrix p begin (scale primary 2++indexed)
    let packed := f (rowAt s.auxiliary i) 0
    metadata := metadata++[query metaActive (left++right) packed]
    let (headParams,headResults) ← split matrix [] splits p packed 32 32
    rootResults ← select matrix p (f flags 0) headResults rootResults
    let returning ← mul matrix p tail (f flags 1)
    raw matrix (gate returning (sub headResults rootResults))
    params ← select matrix p reset headParams params
    results ← select matrix p reset headResults results
    pending ← select matrix p reset indexed pending
    pushed ← select matrix p reset z pushed
    cleared ← select matrix p reset z cleared
    let tableValue := f (rowAt s.auxiliary i) 1
    let address ← mul matrix p indirectBegin (scale secondary 2++o)
    tables := tables++[query indirectBegin address tableValue]
    raw matrix (gate indirectBegin (sub tableValue (n 5)))
    let pop ← mul matrix p call (f flags 3)
    let indexPop ← mul matrix p pop pending
    let argumentPop := sub pop indexPop
    let push ← mul matrix p call (f flags 2)
    let clear ← mul matrix p call (f flags 6)
    let actual := f row 4
    let unknown ← zero matrix p (sub actual (n 7))
    let actualZero ← zero matrix p actual
    raw matrix (gate indexPop (sub (sub o unknown) actualZero))
    raw matrix (gate pop (pushed++cleared))
    raw matrix (gate push (tail++pending++cleared))
    raw matrix (gate push params)
    let nodeValue := f (rowAt s.auxiliary i) 2
    let left ← mul matrix p argumentPop params
    let right ← mul matrix p push results
    nodes := nodes++[query (argumentPop++push) (left++right) nodeValue]
    let (nodeTag,nodeNext) ← split matrix [] splits p nodeValue 3 32
    let matched ← zero matrix p (sub actual nodeTag)
    raw matrix (gate argumentPop (sub (sub o unknown) matched))
    raw matrix (gate push (sub actual nodeTag))
    params ← select matrix p argumentPop nodeNext params
    results ← select matrix p push nodeNext results
    pending ← materialize matrix p (sub pending indexPop)
    pushed ← select matrix p push o pushed
    raw matrix (gate call (f flags 4++f flags 5))
    raw matrix (gate clear (sub o tail))
    raw matrix (gate clear (params++pending++cleared))
    cleared ← materialize matrix p (cleared++clear)
    let finish ← mul matrix p call (f flags 7)
    raw matrix (gate finish params)
    raw matrix (gate finish pending)
    raw matrix (gate finish (sub cleared tail))
    let ordinary ← mul matrix p (direct++indirect) (f flags 7)
    raw matrix (gate ordinary results)
  pure (metadata,nodes,tables)
end ZkBuild.DynamicCallMatrix

import StructuredMatrix
set_option autoImplicit false
namespace ZkBuild.StructuredBranches
open CircuitShape GadgetShape DeclarationMatrix SourceProgram ValidationEventMatrix DynamicTypingMatrix StructuredMatrix
def replay (matrix : Shape) (splits : Splits) (s : DynamicTypingMatrix.Stage) : Eval (List Fields × List Fields) := do
  let p := s.program
  let mut head := z
  let mut length := z
  let mut arity := z
  let mut pops := z
  let mut pushes := z
  let mut pending := z
  let mut seen := z
  let mut last := z
  let mut cleared := z
  let mut popStart := z
  let mut outputs := []
  let mut scratch := []
  for i in List.range s.rows.length do
    let row := eventAt s i
    let flags := flagsAt s i
    let frame := selectorsAt s i
    let values := rowAt s.outputs i
    let table ← zero matrix p (sub (f row 8) (n 14))
    let reset := f flags 0++f flags 1
    let mark := f flags 9
    head ← select matrix p reset z head
    length ← select matrix p reset z length
    arity ← select matrix p reset z arity
    pops ← select matrix p reset z pops
    pushes ← select matrix p reset z pushes
    let begin ← mul matrix p (f flags 1) table
    pending ← select matrix p reset begin pending
    seen ← select matrix p reset z seen
    last ← select matrix p reset z last
    cleared ← select matrix p reset z cleared
    popStart ← select matrix p reset z popStart
    raw matrix (gate mark (sub o table))
    raw matrix (gate mark (pending++last++cleared))
    let repeated ← mul matrix p mark seen
    raw matrix (gate repeated (sub pops length))
    let restore ← mul matrix p (sub o last) length
    raw matrix (gate repeated (sub pushes restore))
    let active ← mul matrix p mark (f frame 4++f frame 5)
    let metaQuery ← readQuery matrix p active (scale (f frame 3) 2++f frame 4) (qAt values 0)
    let (params,results) ← split matrix [] splits p (f metaQuery 2)
    let active ← mul matrix p mark (f frame 7)
    let single ← readQuery matrix p active (f frame 3) (qAt values 9)
    let empty ← mul matrix p mark (f frame 6)
    raw matrix (gate empty (f frame 3))
    let loopFrame ← zero matrix p (sub (f frame 1) o)
    let parameters ← mul matrix p (f frame 4) params
    let selected ← select matrix p loopFrame parameters (results++f single 2)
    let size ← readQuery matrix p mark selected (qAt values 3)
    raw matrix (gate repeated (sub (f size 2) arity))
    let first ← mul matrix p mark (sub o seen)
    arity ← select matrix p first (f size 2) arity
    head ← select matrix p mark selected head
    length ← select matrix p mark (f size 2) length
    pops ← select matrix p mark z pops
    pushes ← select matrix p mark z pushes
    popStart ← select matrix p mark (n (i+1)) popStart
    seen ← select matrix p mark o seen
    last ← select matrix p mark (f (rowAt s.inputs i) 0) last
    let pop ← mul matrix p table (f flags 3)
    let condition ← mul matrix p pop pending
    let argument := sub pop condition
    let push ← mul matrix p table (f flags 2)
    let clear ← mul matrix p table (f flags 6)
    let actual := f row 4
    let unknown ← zero matrix p (sub actual (n 7))
    let actualZero ← zero matrix p actual
    raw matrix (gate condition (sub (sub o unknown) actualZero))
    raw matrix (gate (argument++push++clear) (sub o seen))
    raw matrix (gate argument (pending++pushes++cleared))
    raw matrix (gate argument (sub (sub (n i) popStart) pops))
    let ordinal ← select matrix p loopFrame pops (sub (sub length o) pops)
    let member ← memberQuery matrix p argument head ordinal (qAt values 6)
    let (tag,_) ← split matrix [] splits p (f member 2) 3 32
    let matched ← zero matrix p (sub actual tag)
    raw matrix (gate argument (sub (sub o unknown) matched))
    raw matrix (gate push (pending++last++cleared))
    raw matrix (gate push (sub pops length))
    let restoreOrdinal ← mul matrix p push (sub (sub length o) pushes)
    let _ ← range matrix p restoreOrdinal 32
    let address ← mul matrix p push (popStart++restoreOrdinal)
    let value ← mul matrix p (argument++push) actual
    scratch := scratch++[[argument++push,argument,scale argument (Int.ofNat i)++address,value]]
    raw matrix (gate clear (sub o last))
    raw matrix (gate clear (pending++pushes++cleared))
    raw matrix (gate clear (sub pops length))
    pops ← materialize matrix p (pops++argument)
    pushes ← materialize matrix p (pushes++push)
    pending ← materialize matrix p (sub pending condition)
    cleared ← materialize matrix p (cleared++clear)
    let finish ← mul matrix p table (f flags 7)
    raw matrix (gate finish (sub o seen))
    raw matrix (gate finish (sub o last))
    raw matrix (gate finish (pending++pushes))
    raw matrix (gate finish (sub pops length))
    raw matrix (gate finish (sub cleared o))
    outputs := outputs++[metaQuery++size++member++single]
  pure (outputs,scratch)
end ZkBuild.StructuredBranches

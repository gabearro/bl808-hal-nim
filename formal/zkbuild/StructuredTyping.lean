import StructuredMatrix
set_option autoImplicit false
namespace ZkBuild.StructuredTyping
open CircuitShape GadgetShape DeclarationMatrix SourceProgram ValidationEventMatrix DynamicTypingMatrix StructuredMatrix
def replay (matrix : Shape) (splits : Splits) (s : DynamicTypingMatrix.Stage) : Eval (List Fields) := do
  let p := s.program
  let mut pHead := z
  let mut rHead := z
  let mut pLen := z
  let mut rLen := z
  let mut pops := z
  let mut pushes := z
  let mut pending := z
  let mut pushed := z
  let mut popped := z
  let mut cleared := z
  let mut outputs := []
  for i in List.range s.rows.length do
    let row := eventAt s i
    let flags := flagsAt s i
    let frame := selectorsAt s i
    let values := rowAt s.outputs i
    let reset := f flags 0++f flags 1
    let enabled ← mul matrix p (f flags 1) (f frame 20)
    let lookup := f flags 0++enabled
    let metaActive ← mul matrix p lookup (f frame 4++f frame 5)
    let metaQuery ← readQuery matrix p metaActive (scale (f frame 3) 2++f frame 4) (qAt values 0)
    let (hp,hr) ← split matrix [] splits p (f metaQuery 2)
    let singleActive ← mul matrix p lookup (f frame 7)
    let single ← readQuery matrix p singleActive (f frame 3) (qAt values 9)
    let empty ← mul matrix p lookup (f frame 6)
    raw matrix (gate empty (f frame 3))
    let head ← mul matrix p (f frame 4) hp
    pHead ← select matrix p reset head pHead
    rHead ← select matrix p reset (hr++f single 2) rHead
    let paramLength ← readQuery matrix p lookup pHead (qAt values 3)
    let resultLength ← readQuery matrix p lookup rHead (qAt values 12)
    pLen ← select matrix p reset (f paramLength 2) pLen
    rLen ← select matrix p reset (f resultLength 2) rLen
    pops ← select matrix p reset z pops
    pushes ← select matrix p reset z pushes
    pushed ← select matrix p reset z pushed
    popped ← select matrix p reset z popped
    cleared ← select matrix p reset z cleared
    pending ← select matrix p reset (f frame 10++f frame 15) pending
    let loopFrame ← zero matrix p (sub (f frame 1) o)
    let ifFrame ← zero matrix p (sub (f frame 1) (n 2))
    let branchParam ← mul matrix p (f frame 18) loopFrame
    let parameterInput := f frame 17++branchParam
    let inputHead ← select matrix p parameterInput pHead rHead
    let inputLength ← select matrix p parameterInput pLen rLen
    let branchOutput ← mul matrix p (f frame 15) loopFrame
    let parameterOutput := f frame 17++f frame 11++branchOutput
    let endOutput ← mul matrix p (f frame 12) (sub o (f frame 5))
    let conditionalOutput ← mul matrix p (f frame 15) (sub o loopFrame)
    let resultOutput := endOutput++conditionalOutput
    let left ← mul matrix p parameterOutput pLen
    let right ← mul matrix p resultOutput rLen
    let outputLength := left++right
    let outputHead ← select matrix p parameterOutput pHead rHead
    let pop ← mul matrix p (f frame 20) (f flags 3)
    let indexPop ← mul matrix p pop pending
    let argumentPop := sub pop indexPop
    let push ← mul matrix p (f frame 20) (f flags 2)
    let actual := f row 4
    let unknown ← zero matrix p (sub actual (n 7))
    let actualZero ← zero matrix p actual
    raw matrix (gate indexPop (sub (sub o unknown) actualZero))
    raw matrix (gate pop (pushes++pushed++popped++cleared))
    let inputOrdinal ← select matrix p parameterInput pops (sub (sub rLen o) pops)
    let outputOrdinal ← select matrix p parameterOutput (sub (sub pLen o) pushes) pushes
    let left ← mul matrix p argumentPop inputHead
    let right ← mul matrix p push outputHead
    let head := left++right
    let left ← mul matrix p argumentPop inputOrdinal
    let right ← mul matrix p push outputOrdinal
    let member ← memberQuery matrix p (argumentPop++push) head (left++right) (qAt values 6)
    let (memberTag,_) ← split matrix [] splits p (f member 2) 3 32
    let matched ← zero matrix p (sub actual memberTag)
    raw matrix (gate argumentPop (sub (sub o unknown) matched))
    raw matrix (gate push (sub actual memberTag))
    raw matrix (gate push (sub pops inputLength))
    raw matrix (gate push (pending++cleared))
    raw matrix (gate push (sub (sub pushed (f frame 17)) (f frame 11)))
    raw matrix (gate push (sub popped (f frame 19)))
    let implicitElse ← mul matrix p (f frame 12) ifFrame
    let compareBegin ← mul matrix p (f flags 1) implicitElse
    raw matrix (gate compareBegin (sub pLen rLen))
    let active ← mul matrix p argumentPop implicitElse
    let compare ← memberQuery matrix p active pHead pops (qAt values 15)
    let (compareTag,_) ← split matrix [] splits p (f compare 2) 3 32
    raw matrix (gate (f compare 0) (sub compareTag memberTag))
    let controlPush ← mul matrix p (f frame 20) (f flags 4)
    let controlPop ← mul matrix p (f frame 20) (f flags 5)
    raw matrix (gate (controlPush++controlPop) (sub pops inputLength))
    raw matrix (gate (controlPush++controlPop) (pending++pushes++cleared))
    raw matrix (gate controlPush pushed)
    raw matrix (gate controlPush (sub popped (f frame 11)))
    raw matrix (gate controlPop (pushed++popped))
    let clear ← mul matrix p (f frame 20) (f flags 6)
    raw matrix (gate clear (sub (sub o (f frame 14)) (f frame 16)))
    raw matrix (gate clear (sub pops inputLength))
    raw matrix (gate clear (pending++pushes++pushed++popped++cleared))
    pops ← materialize matrix p (pops++argumentPop)
    pushes ← materialize matrix p (pushes++push)
    pending ← materialize matrix p (sub pending indexPop)
    pushed ← materialize matrix p (pushed++f flags 4)
    popped ← materialize matrix p (popped++f flags 5)
    cleared ← materialize matrix p (cleared++clear)
    let finish ← mul matrix p (f frame 20) (f flags 7)
    raw matrix (gate finish (sub pops inputLength))
    raw matrix (gate finish pending)
    raw matrix (gate finish (sub pushes outputLength))
    raw matrix (gate finish (sub (sub pushed (f frame 17)) (f frame 11)))
    raw matrix (gate finish (sub popped (f frame 19)))
    raw matrix (gate finish (sub (sub cleared (f frame 14)) (f frame 16)))
    outputs := outputs++[metaQuery++paramLength++member++single++resultLength++compare]
  pure outputs
end ZkBuild.StructuredTyping

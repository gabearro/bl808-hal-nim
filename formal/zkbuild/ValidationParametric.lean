import ValidationEventMatrix
set_option autoImplicit false
namespace ZkBuild.ValidationParametric
open CircuitShape GadgetShape DeclarationMatrix SourceProgram ValidationEventMatrix

def replay (matrix : Shape) (s : Stage) : Eval Unit := do
  let p := s.program
  let mut pops := z
  let mut pushes := z
  let mut first := z
  let mut second := z
  let mut declared := z
  for i in List.range s.rows.length do
    let row := rowAt s.rows i
    let flags := rowAt s.flags i
    let primary := f (rowAt s.inputs i) 0
    let untyped ← zero matrix p (sub (f row 8) (n 27))
    let typed ← zero matrix p (sub (f row 8) (n 28))
    let reference ← zero matrix p (sub (f row 8) (n 208))
    let selectOp := untyped++typed
    let present := selectOp++reference
    let reset := f flags 0++f flags 1
    let _ ← range matrix p primary 32
    raw matrix (gate (sub o (f flags 1)) primary)
    let mut validType := e
    let mut tag := e
    let mut references := e
    let codes := [127,126,125,124,123,112,111]
    for index in List.range 7 do
      let selected ← zero matrix p (sub primary (n (codes.getD index 0)))
      validType := validType++selected
      tag := tag++scale selected (Int.ofNat index)
      if index ≥ 5 then references := references++selected
    let selected ← mul matrix p (f flags 1) typed
    raw matrix (gate selected (sub o validType))
    let selected ← mul matrix p (f flags 1) reference
    raw matrix (gate selected (sub o references))
    let selected ← mul matrix p (f flags 1) untyped
    raw matrix (gate selected primary)
    declared ← select matrix p reset tag declared
    pops ← select matrix p reset z pops
    pushes ← select matrix p reset z pushes
    first ← select matrix p reset z first
    second ← select matrix p reset z second
    let pop ← mul matrix p present (f flags 3)
    let push ← mul matrix p present (f flags 2)
    let index0 ← zero matrix p pops
    let index1 ← zero matrix p (sub pops o)
    let index2 ← zero matrix p (sub pops (n 2))
    raw matrix (gate pop (sub o selectOp))
    raw matrix (gate pop (sub (sub (sub o index0) index1) index2))
    raw matrix (gate pop pushes)
    let condition ← mul matrix p pop index0
    let valuePop := sub pop condition
    let actual := f row 4
    let unknown ← zero matrix p (sub actual (n 7))
    let actualZero ← zero matrix p actual
    raw matrix (gate condition (sub (sub o unknown) actualZero))
    let declaredPop ← mul matrix p typed valuePop
    let knownDeclared ← mul matrix p declaredPop (sub o unknown)
    raw matrix (gate knownDeclared (sub actual declared))
    let inferredPop ← mul matrix p untyped valuePop
    let ref0 ← zero matrix p (sub actual (n 5))
    let ref1 ← zero matrix p (sub actual (n 6))
    raw matrix (gate inferredPop (ref0++ref1))
    let firstPop ← mul matrix p pop index1
    let secondPop ← mul matrix p pop index2
    first ← select matrix p firstPop actual first
    second ← select matrix p secondPop actual second
    let firstUnknown ← zero matrix p (sub first (n 7))
    let bothKnown ← mul matrix p (sub o firstUnknown) (sub o unknown)
    let selected ← mul matrix p untyped secondPop
    let selected ← mul matrix p selected bothKnown
    raw matrix (gate selected (sub first actual))
    let inferred ← select matrix p firstUnknown second first
    let left ← mul matrix p untyped inferred
    let right ← mul matrix p (typed++reference) declared
    let expected := left++right
    raw matrix (gate push (sub actual expected))
    raw matrix (gate push (sub pops (scale selectOp 3)))
    raw matrix (gate push pushes)
    raw matrix (gate present (f flags 4++f flags 5++f flags 6++f flags 9))
    pops ← materialize matrix p (pops++pop)
    pushes ← materialize matrix p (pushes++push)
    let finish ← mul matrix p present (f flags 7)
    raw matrix (gate finish (sub pops (scale selectOp 3)))
    raw matrix (gate finish (sub pushes o))
end ZkBuild.ValidationParametric

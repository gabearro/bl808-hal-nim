import StructuredMatrix
set_option autoImplicit false
namespace ZkBuild.StructuredCatches
open CircuitShape GadgetShape DeclarationMatrix SourceProgram ValidationEventMatrix DynamicTypingMatrix StructuredMatrix
def replay (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (s : DynamicTypingMatrix.Stage) : Eval (List (List Fields)) := do
  let p := s.program
  let mut metadata := []
  let mut singles := []
  let mut tags := []
  let mut reversals := []
  let mut nodes := []
  for i in List.range s.inputs.length do
    let input := rowAt s.inputs i
    let frame := selectorsAt s i
    let mark := f input 0
    let metaActive ← mul matrix p mark (f frame 4++f frame 5)
    let metaQuery ← readQuery matrix p metaActive (scale (f frame 3) 2++f frame 4) (DynamicTypingMatrix.entry ((bank tables s 0).queries.getD i default))
    metadata := metadata++[metaQuery]
    let (params,results) ← split matrix [] splits p (f metaQuery 2)
    let singleActive ← mul matrix p mark (f frame 7)
    let single ← readQuery matrix p singleActive (f frame 3) (DynamicTypingMatrix.entry ((bank tables s 1).queries.getD i default))
    singles := singles++[single]
    let empty ← mul matrix p mark (f frame 6)
    raw matrix (gate empty (f frame 3))
    let loopFrame ← zero matrix p (sub (f frame 1) o)
    let parameters ← mul matrix p (f frame 4) params
    let head ← select matrix p loopFrame parameters (results++f single 2)
    let reverseActive ← mul matrix p mark (sub o loopFrame)
    let reversed ← readQuery matrix p reverseActive head (DynamicTypingMatrix.entry ((bank tables s 3).queries.getD i default))
    reversals := reversals++[reversed]
    let loopHead ← mul matrix p loopFrame head
    let normalized := loopHead++f reversed 2
    let tag ← readQuery matrix p (f input 3) (f input 2) (DynamicTypingMatrix.entry ((bank tables s 2).queries.getD i default))
    tags := tags++[tag]
    let (payload,returns) ← split matrix [] splits p (f tag 2)
    raw matrix (gate (f input 3) returns)
    raw matrix (gate (sub mark (f input 4)) (sub normalized payload))
    let node ← readQuery matrix p (f input 4) normalized (DynamicTypingMatrix.entry ((bank tables s 4).queries.getD i default))
    nodes := nodes++[node]
    let (nodeTag,nodeNext) ← split matrix [] splits p (f node 2) 3 32
    raw matrix (gate (f input 4) (sub nodeTag (n 6)))
    raw matrix (gate (f input 4) (sub nodeNext payload))
  pure [metadata,singles,tags,reversals,nodes]
end ZkBuild.StructuredCatches

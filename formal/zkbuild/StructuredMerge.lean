import StructuredMatrix
set_option autoImplicit false
namespace ZkBuild.StructuredMerge
open CircuitShape GadgetShape DeclarationMatrix SourceProgram ValidationEventMatrix DynamicTypingMatrix StructuredMatrix
def merge (matrix : Shape) (a b : Fields) : Eval Fields := do
  raw matrix (gate (f a 0) (f b 0))
  raw matrix (gate (sub o (f a 0)) (f a 2))
  raw matrix (gate (sub o (f b 0)) (f b 2))
  pure [f a 0++f b 0,f a 1++f b 1,f a 2++f b 2]
def replay (matrix : Shape) (s : DynamicTypingMatrix.Stage) : Eval (List Fields) := do
  let mut outputs := []
  for i in List.range s.rows.length do
    let a := rowAt s.selectors i
    let b := rowAt s.inputs i
    let metaQuery ← merge matrix (qAt a 0) (qAt b 0)
    let length ← merge matrix (qAt a 3) (qAt b 3)
    let member ← merge matrix (qAt a 6) (qAt b 6)
    let single ← merge matrix (qAt a 9) (qAt b 9)
    outputs := outputs++[metaQuery++length++member++single++qAt a 12++qAt a 15]
  pure outputs
end ZkBuild.StructuredMerge

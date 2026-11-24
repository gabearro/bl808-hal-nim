import CallMode
import CallEvents
set_option autoImplicit false
namespace ZkBuild.CallSignatureBody
open CallEvents StaticEvents

/-- Parameters are in operand-pop order. The executable signature function
    accepts their source order, hence the reversal at this boundary. -/
def Typed (code : Nat) (params results current : List Nat) (tokens : List Token) : Prop :=
  ∃ inputs outputs actuals,
    callSignature code params.reverse results current 5 = some (inputs,outputs) ∧
    Aligned inputs actuals ∧
    tokens = actuals.map Token.pop ++ outputs.map Token.push ++ (if CallMode.tail code then [.clear] else [])

theorem signature (code : Nat) (active : CallMode.active code = true)
    (params results current : List Nat) (root : CallMode.tail code = true → current = results) :
    callSignature code params.reverse results current 5 =
      some ((if CallMode.indirect code then [0] else []) ++ params, if CallMode.tail code then [] else results) := by
  have cases := of_decide_eq_true active
  rcases cases with rfl | rfl | rfl | rfl <;>
    simp_all [callSignature,CallMode.tail,CallMode.indirect]

theorem body (code : Nat) (active : CallMode.active code = true)
    (params results current : List Nat) (root : CallMode.tail code = true → current = results)
    (indexTokens rest : List Token)
    (index : if CallMode.indirect code then ∃ actual, InputOk 0 actual ∧ indexTokens = [.pop actual] else indexTokens = [])
    (run : Body params results (CallMode.tail code) rest) :
    Typed code params results current (indexTokens ++ rest) := by
  have sig := signature code active params results current root
  have tailShape : ∃ actuals, Aligned params actuals ∧ rest = actuals.map Token.pop ++
      (if CallMode.tail code then [] else results.map Token.push) ++ (if CallMode.tail code then [.clear] else []) := by
    cases mode : CallMode.tail code
    · rw [mode] at run
      obtain ⟨actuals,aligned,shape⟩ := normal_shape params results rest run
      exact ⟨actuals,aligned,by simpa using shape⟩
    · rw [mode] at run
      obtain ⟨actuals,aligned,shape⟩ := tail_shape params results rest run
      exact ⟨actuals,aligned,by simpa using shape⟩
  obtain ⟨actuals,aligned,shape⟩ := tailShape
  cases mode : CallMode.indirect code
  · simp only [mode,Bool.false_eq_true,ite_false] at index sig
    refine ⟨params,if CallMode.tail code then [] else results,actuals,by simpa using sig,aligned,?_⟩
    subst indexTokens
    cases tailMode : CallMode.tail code <;> simpa [tailMode] using shape
  · simp only [mode,ite_true] at index sig
    obtain ⟨actual,typed,same⟩ := index
    refine ⟨0::params,if CallMode.tail code then [] else results,actual::actuals,by simpa using sig,.cons typed aligned,?_⟩
    subst indexTokens
    cases tailMode : CallMode.tail code <;> simp_all

#print axioms signature
#print axioms body
end ZkBuild.CallSignatureBody

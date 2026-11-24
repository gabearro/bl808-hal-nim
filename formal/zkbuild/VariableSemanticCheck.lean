import VariableCountTrace
import VariableSelectorCheck
import EnvironmentRowSound
set_option autoImplicit false
namespace ZkBuild.VariableSemanticCheck
open CircuitShape GadgetShape DeclarationMatrix ValidationEventMatrix

def rowLinks (events : ValidationEventMatrix.Record) (env : EnvironmentRowCheck.Record)
    (varRow : VariableRowCheck.Record) (i : Nat) : Bool :=
  decide (ModuleProgram.sameInputs varRow.row ((rowAt events.rows i).take 10) ∧
    ModuleProgram.sameInputs env.row varRow.row ∧ ModuleProgram.sameInputs env.flags varRow.flags ∧
    ModuleProgram.sameInputs env.selectors varRow.selectors ∧
    ModuleProgram.sameInputs [f env.after 11] [varRow.declared])

def linked (tables : List ReadOnlyMatrix.Record) (events : ValidationEventMatrix.Record)
    (typing : DynamicTypingMatrix.Record) : Bool :=
  let selectors := DynamicTypingCheck.stage typing 0
  let environment := DynamicTypingCheck.stage typing 1
  let variables := DynamicTypingCheck.stage typing 2
  decide (selectors.rows.length = variables.rows.length ∧ environment.rows.length = variables.rows.length ∧
    events.rows.length = variables.rows.length) &&
  (List.range variables.rows.length).all (fun i =>
    VariableSelectorCheck.check selectors (VariableRowCheck.record variables i) i &&
    rowLinks events (EnvironmentRowCheck.record tables environment i) (VariableRowCheck.record variables i) i)

def check (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (statics : StaticCatalog)
    (events : ValidationEventMatrix.Record) (typing : DynamicTypingMatrix.Record) : Bool :=
  VariableCertificate.check matrix statics events typing &&
  DynamicSelectors.check matrix (DynamicTypingCheck.stage typing 0) &&
  EnvironmentRowCheck.checkStage matrix tables (DynamicTypingCheck.stage typing 1) && linked tables events typing
end ZkBuild.VariableSemanticCheck

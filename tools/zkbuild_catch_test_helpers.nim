## Legacy test adapters for the production module composition.
import cps/wasm/types
import cps/zk/[r1cs, wasm_instruction_events, wasm_catch_environment, wasm_module_validation]
import zkbuild_control_type_test_helpers
export zkbuild_control_type_test_helpers

proc catchRows*(module: WasmModule, capacity = 0): seq[InstructionEventRow] =
  moduleValidationRows(module, capacity)

proc fullCatch*(module: WasmModule, rows: seq[InstructionEventRow], catches: CatchEnvironment,
    binding = true, moduleChecks = false): Circuit =
  buildModuleValidationCircuit(module, rows, catches, binding, moduleChecks)

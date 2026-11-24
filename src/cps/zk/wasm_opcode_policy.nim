## A fixed decision DAG rejects every opcode outside the implemented relation.
import ../wasm/opcode_policy
import r1cs, opcode_lookup, wasm_instruction_events

proc table(): OpcodeLookup[1] =
  var values = newSeq[array[1, int]](65536)
  for code in 0..65535: values[code][0] = int(admittedOpcode(uint16(code)))
  buildOpcodeLookup(values)

let admitted = table()

proc constrainAdmittedOpcodes*(c: var Circuit, rows: openArray[InstructionEventWires]) =
  when defined(zkbuildValidationEventAudit):
    let auditMarker = c.beginSourceProgram()
  for row in rows:
    let value = c.constrainLookup(admitted, row.opcode)
    c.assertEqual(value[0], constant(1))

  when defined(zkbuildValidationEventAudit):
    c.validationStageRecords.add ValidationStageAudit(kind: 0,rows: captureInstructionRows(rows),
      program: c.endSourceProgram(auditMarker))

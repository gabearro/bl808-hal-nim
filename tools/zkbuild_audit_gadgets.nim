## Build identical circuits with/without auditing and export the actual spans.
import std/os
import zkbuild_payload_fixture
import cps/zk/[r1cs,range_check,gadget_audit,wasm_module_validation,wasm_module_prover]

proc fixture(): seq[byte] =
  @[0'u8,97,115,109,1,0,0,0,0,2,0,255,1,5,1,96,0,1,127,
    2,8,1,1,104,1,103,3,127,0,3,2,1,0,7,7,1,3,114,117,110,0,0,
    10,6,1,4,0,65,42,11]

proc core(): Circuit =
  result = initCircuit(reuseRangeWitnesses = true)
  let x = result.publicInput(scalar(5))
  let y = result.publicInput(scalar(9))
  let s = result.publicInput(scalar(1))
  result.assertEqual(x,x)
  let product = result.multiply(x,y)
  discard result.materialize(product)
  discard result.bit(false)
  result.constrainBoolean(s)
  discard result.select(s,x,y)
  discard result.selectWire(s,x,y)
  discard result.zeroIndicator(x)
  discard result.zeroIndicator(constant(0))
  discard result.constrainUnsigned(x,8)
  discard result.constrainUnsigned(x,8)
  discard result.constrainUnsigned(y,8)
  discard result.constrainUnsigned(x,16)
  discard result.constrainUnsigned(x+y,8)
  discard result.constrainUnsigned(x+y,8)
  discard result.constrainUnsigned(constant(255),8)
  discard result.constrainUnsigned(constant(0),0)
  result.constrain(x,constant(0),constant(0)) # unclassified, retained visibly.

proc main() =
  if paramCount() != 3:
    quit("usage: zkbuild_audit_gadgets core|invalid|module|full METADATA AUDIT_OR_DASH",1)
  let mode = paramStr(1)
  var circuit = if mode in ["core","invalid"]: core()
    elif mode == "module": buildModuleValidationCircuit(fixture(),eventCapacity = 16,sourceCapacity = 64,
      sectionCapacity = 6,digestClaim = true,instructionCapacity = 3,
      declarationProfile = DeclarationProfile(enabled: true,types: 1,functions: 1,results: 1),
      payloadProfile = PayloadProfile(enabled: true,imports: 1,globals: 1,exports: 1,
        customSections: 1,nameBytes: 8))
    elif mode == "full": buildModuleValidationCircuit(fullPayloadFixture(),eventCapacity = 16,
      sourceCapacity = 1024,sectionCapacity = 20,digestClaim = true,instructionCapacity = 8,
      branchCapacity = 2,catchCapacity = 2,
      declarationProfile = DeclarationProfile(enabled: true,types: 2,functions: 2,
        parameters: 2,results: 2,tags: 1,localGroups: 2,localRanges: 4),
      payloadProfile = PayloadProfile(enabled: true,imports: 6,globals: 13,tables: 3,
        memories: 1,exports: 6,elements: 8,elementItems: 16,datas: 3,
        customSections: 3,nameBytes: 80))
    else: raise newException(ValueError,"unknown audit circuit")
  if mode == "invalid": discard circuit.constrainUnsigned(constant(256),8)
  doAssert circuit.satisfied() == (mode != "invalid")
  let hashes = circuit.fingerprints()
  writeFile(paramStr(2),$circuit.values.len & " " & $circuit.publicCount & " " & $circuit.constraints.len &
    "\n" & hashes.matrix & "\n" & hashes.witness & "\n")
  if paramStr(3) != "-": writeGadgetAudit(paramStr(3),circuit)
  echo "audit fixture ",mode," constraints=",circuit.constraints.len

main()

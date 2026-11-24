## The default target selection must not authorize unverified vendor opcodes.
import cps/wasm/jit/codegen_rv64

let d0 = bl808Target(bl808D0)
let m0 = bl808Target(bl808M0)
let lp = bl808Target(bl808LP)
doAssert d0.xlen == rv64 and
  d0.features == {rvExtM, rvExtA, rvExtF, rvExtD, rvExtC}
doAssert m0.xlen == rv32 and
  m0.features == {rvExtM, rvExtA, rvExtF, rvExtC}
doAssert lp.xlen == rv32 and
  lp.features == {rvExtE, rvExtM, rvExtC, rvExtZicsr, rvExtZifencei}
doAssert rvXTheadCondMov in rv64BL808D0ExperimentalTarget.features
doAssert rvXTheadInt in rv32BL808M0ExperimentalTarget.features
echo "BL808 JIT default ISA profiles:ok"

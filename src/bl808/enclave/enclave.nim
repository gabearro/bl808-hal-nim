## Enclave runtime entry point: bring up the secure world, measure the image,
## lock the partition, then run the untrusted U-mode application. Services are
## reached from U-mode via ecall and from D0/LP via the XRAM mailbox.
##
## Boot order (called from M0 main, after systemInit + heapInit):
##   enclaveInit(partition, root) -> vault -> measure -> wire ecall -> apply
##   -> (gate secondary cores) -> enclaveRunUmode(app)

import ../umode, ../ipc, ../pds
import partition, vault, measure, abi, services
import cruntime

# Main M-mode stack top from the linker; the ecall handler swaps onto it.
{.emit: """/*TYPESECTION*/
extern char _sp[];
static unsigned long __main_sp(void){return (unsigned long)_sp;}
""".}
proc mainSp(): uint {.importc: "__main_sp", nodecl.}

var sharedBuf: ptr UncheckedArray[uint8]
var sharedCap: int
var initialized = false

proc enclaveEcall(frame: ptr EcallFrame) {.nimcall.} =
  ## Bridge a U-mode ecall to the service dispatcher. The request is already in
  ## the shared buffer; a0 = SvcId, a1 = request length.
  let svc = toSvcId(frame.a0)
  let reqLen = frame.a1.int
  let (status, respLen) = enclaveDispatch(svc, reqLen, sharedBuf, sharedCap)
  frame.a0 = status.uint32
  frame.a1 = respLen.uint32

proc enclaveOnFault(cause, mepc, mtval: uint32) {.nimcall.} =
  ## A trap taken from the U-mode application means it violated the PMP policy
  ## (or executed an illegal op) — treat it as hostile and wipe all key material
  ## before the handler halts, so a detected attack leaves no secrets in RAM.
  vaultZeroizeAll()

proc enclaveInit*(part: SecurePartition, root: RootKeySource): bool =
  ## Initialise the vault, capture the boot measurement, wire the ecall bridge,
  ## then program and (if part.lock) freeze the partition. Returns false if any
  ## step fails — the caller must NOT release secondary cores in that case.
  ##
  ## First, defang the BootROM warm-boot fast path: a stale or attacker-planted
  ## "EHBN"/"WHBN" magic at HbnRsv0 would make the next reset jump to a retained
  ## pointer, skipping this whole init (verify/measure/lock). Clear it on every
  ## COLD boot. A measured HBN resume (enclave/hibernate.nim) is a separate,
  ## MAC-gated entry path that re-arms the magic deliberately — it does not come
  ## through here.
  hbnClearWarmBootMagic()
  if not vaultInit(root):
    return false
  discard measureImage()
  sharedBuf = cast[ptr UncheckedArray[uint8]](sharedBufStart())
  sharedCap = sharedBufLen().int
  enclaveSetEcallDispatch(enclaveEcall)
  enclaveSetFaultHook(enclaveOnFault)
  applyPartition(part)
  initialized = true
  true

proc enclaveReady*(): bool = initialized

proc enclaveRunUmode*(appEntry: uint) {.noreturn.} =
  ## Install the enclave exception entry, then drop into the untrusted
  ## application. The handler runs on the main M-mode stack (the caller never
  ## resumes once we enter U-mode).
  enclaveInstallTrapVector(mainSp())
  enclaveEnterUmode(appEntry, umodeStackTop())

# --- D0/LP client transport over the XRAM mailbox ---------------------------
proc enclaveIpcPoll*() =
  ## Drain one enclave request from a peer core, dispatch it, and reply. Tag is
  ## SvcIpcTagBase + SvcId; payload is the request, reply payload the response.
  ## Small requests only (bounded by the IPC buffer); large data uses ecall.
  for peer in [ipcD0, ipcLP]:
    var tag: uint16
    var payload: array[256, uint8]
    let n = ipcRecvMessage(peer, tag, payload)
    if n <= 0: continue
    if tag < SvcIpcTagBase: continue
    let svc = toSvcId((tag - SvcIpcTagBase).uint32)
    let reqLen = min(n, sharedCap)
    for i in 0 ..< reqLen: sharedBuf[i] = payload[i]
    let (status, respLen) = enclaveDispatch(svc, reqLen, sharedBuf, sharedCap)
    var reply: array[256, uint8]
    let m = min(respLen, reply.len)
    for i in 0 ..< m: reply[i] = sharedBuf[i]
    discard ipcSendMessage(peer, status.uint16, toOpenArray(reply, 0, m - 1))

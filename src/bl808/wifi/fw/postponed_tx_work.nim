## Coalesce postponed STA TX requests into the existing Wi-Fi service hook.

const PostponedTxReconcileUs = 20_000'u32

type PostponedTxWork = enum
  postponedTxNone, postponedTxRequested, postponedTxReconcile

var
  postponedTxWakePending: bool
  postponedTxChecked: bool
  postponedTxLastCheck: uint32

proc requestPostponedTx() =
  let saved = irqSave()
  let notify = not postponedTxWakePending
  postponedTxWakePending = true
  irqRestore(saved)
  if notify: bl808_wifi_backend_signal_work()

proc postponedTxChannelReady() =
  # Enqueue publishes its own wake. The periodic check covers stale counts.
  if txFrameEnv().postponedCount != 0:
    requestPostponedTx()

proc takePostponedTxWork(now: uint32): PostponedTxWork =
  let saved = irqSave()
  defer: irqRestore(saved)
  # M0 mtime is in microseconds. Unsigned elapsed time handles low-word wrap.
  if not postponedTxChecked or now - postponedTxLastCheck >= PostponedTxReconcileUs:
    postponedTxChecked = true
    postponedTxLastCheck = now
    result = postponedTxReconcile
  elif postponedTxWakePending:
    result = postponedTxRequested
  postponedTxWakePending = false

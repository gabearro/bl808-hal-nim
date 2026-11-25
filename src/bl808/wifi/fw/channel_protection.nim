# Protection frames: before leaving an operating channel, chan_goto_idle_cb
# sends a PM=1 null per associated STA and a self-CTS per AP. Their
# confirmations count down chan_env[121] (STA) and [122] (AP), and the last
# one starts the departure, as in chan.o. Each departure attempt is a new
# generation (chanSw.serial) and its frames carry it as their callback
# argument, so a confirmation from an earlier attempt counts for nothing.
# Any status counts, a reset's flush included: the frame is finished either
# way.

proc chanProtectionToken(): uint32 =
  0x80000000'u32 or (chanSw.serial and 0x7FFFFFFF'u32)

proc chanProtectionBegin() =
  ## A new departure attempt: earlier protection frames stop counting.
  inc chanSw.serial
  chanSw.phase = swQueued
  chanSw.building = false
  chanEnvView().scanDelayCount = 0
  chanEnvView().connlessDelayCount = 0

proc chanProtectionDone(param: pointer; pending: var uint8) =
  ## One protection frame of the current attempt has finished. Frames that
  ## finish while chan_goto_idle_cb is still sending only count.
  if chanSw.phase != swProtecting or pending == 0 or
      cast[uint](param) != chanProtectionToken().uint:
    return
  dec pending
  let env = chanEnvView()
  if not chanSw.building and env.scanDelayCount == 0 and env.connlessDelayCount == 0:
    chanSwitchDepart()

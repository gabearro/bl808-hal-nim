# SM's scan and join exchange with SCANU (states 1 and 2).
#
# sm_scan_bss / sm_join_bss send SCANU_START_REQ or SCANU_JOIN_REQ with
# smSend. SCANU answers SM's request in place (scanuAnswer), so the answer
# is the message SM holds and always arrives; scanu_start_cfm_handler and
# scanu_join_cfm_handler take it with smScanAccept.

proc smScanRefused(request: pointer): bool =
  ## SCANU's entry check for a request from SM. One SM no longer waits on,
  ## or one the user aborted before SCANU started it, is answered at once
  ## with a failure and never reaches the radio. Others go on.
  let header = keMsgHdrFromPayload(request)
  if header.srcId != TASK_SM or
      (smAwaits(request) and smEnvView().cancelRequested == 0):
    return false
  when defined(bl808WifiScanOwnershipBench): inc nimFwDbgScanOwnershipCancelled
  scanuAnswer(request, header.id + 1, TASK_SM, SCAN_STATUS_FAIL)
  true

proc smScanAccept(reply: pointer; id: uint16): bool =
  ## `reply` (SCANU_START_CFM or SCANU_JOIN_CFM, `id`) answers SM's live scan
  ## or join and reports success. A failure ends the attempt here; the
  ## user's abort wins, as in the pinned SM handlers.
  if not smTakeAnswer(reply): return false
  when defined(bl808WifiDiagColdScan):
    nimFwDbgColdScanFlow[4] = 2 or (statusCfmView(reply).status.uint32 shl 8)
  if statusCfmView(reply).status == 0: return true
  let sm = smEnvView()
  let aborted = sm.cancelRequested != 0
  sm.cancelRequested = 0
  let status =
    if id == SCANU_START_CFM:
      if aborted: WLAN_FW_CONNECT_ABORT_WHEN_SCANNING else: WLAN_FW_SCAN_NO_BSSID_AND_CHANNEL
    elif aborted: WLAN_FW_CONNECT_ABORT_WHEN_JOINING_NETWORK
    else: WLAN_FW_JOIN_NETWORK_FAILURE
  sm_connect_ind(status.uint16, 0xFFFF)
  false

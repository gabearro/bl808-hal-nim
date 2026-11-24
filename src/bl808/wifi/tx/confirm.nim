when defined(bl808WifiDiagDhcpTxAttempts) or defined(bl808WifiDiagTcpPath):
  proc bl808_wifi_copy_completed_tx_policy(wrapper, statusAddress: pointer;
      words: ptr array[8, uint32]; power: ptr array[4, uint32];
      airTag: ptr uint32 = nil): bool {.importc, cdecl.}

when defined(bl808WifiDiagTcpPath):
  proc logTcpCompletion(packet: TcpPathPacket; txHeaderPtr, hostId: pointer;
                        txStatusWord: uint32) =
    if packet.ports == 0: return
    let repush = txHdrRepush(txHeaderPtr)
    var policy: TcpPathPolicy
    var captured = false
    if (txStatusWord and (DescDoneTxBit or DescDoneSwTxBit)) == DescDoneTxBit:
      let saved = hostIpc.ipcHostIrqSave()
      let wrapper = hostIpc.ipcHostTxCompletionWrapper(hostId)
      if wrapper != nil:
        captured = bl808_wifi_copy_completed_tx_policy(wrapper,
          addr txHdrView(txHeaderPtr).status, addr policy.control, addr policy.power)
      hostIpc.ipcHostIrqRestore(saved)
    logTcpPath(packet, tcpTxConfirm, txStatusWord, repush,
               if captured: addr policy else: nil)

include confirm_parts/dhcp_log
include confirm_parts/repush
include confirm_parts/eapol_log
when defined(bl808WifiDiagHostTxStatus):
  include confirm_parts/data_trace
include confirm_parts/complete

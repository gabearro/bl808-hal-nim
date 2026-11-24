proc txlConfigureTcpFallback(desc: ptr HostTxDescView;
    rate: ptr HostTxRateTemplateView; ackControl: uint32) =
  # Only compare normal-ACK STATION copies with an inactive rate trial and
  # an existing 1 Mbps entry outside the two reachable retry slots.
  const valid = 0x80000000'u32
  const legacy1M = valid or 0x0400'u32
  const rateMask = valid or TxFeedbackRateMask
  let second = rate.retryRateControl0
  if ackControl != 0x2200 or (rate.policyWord and 0xFFFF) != 0x0704 or
      (rate.rateWord and valid) == 0 or (second and valid) == 0 or
      (rate.rateWord and rateMask) == legacy1M or (second and rateMask) == legacy1M or
      (rate.retryRateControl2 and rateMask) != legacy1M or
      desc.vifIdx >= MAX_VIFS.uint8 or
      vifChannelForIdx(desc.vifIdx).vifType != VIF_TYPE_STA or
      desc.staInfoIdx >= rcTrialSerial.len.uint8:
    return
  let sta = staInfoForIdx(desc.staInfoIdx)
  let stats = sta.rcStats
  if stats == nil or sta.txPolicy != desc.policy or
      (sta.txPolicyUpdateFlags[0] and StaTxPolicyUpdateRateControl) != 0 or
      (rcRateCapabilities(stats).legacyRateMap and 1) == 0 or
      rcRateCapabilities(stats).fixedRate != 0xFFFF'u16 or rcTrialControl(stats).status != 0:
    return

  let packet = txlObserveTcpHostPacket(desc)
  if (packet.lengthId and 0xFFFF) == 0:
    return
  logTcpPath(packet, tcpTxFallbackChoice, second)
  if tcpPathFallbackTreatment(packet):
    rate.retryRateControl0 = rate.retryRateControl2
    rate.retryTxPowerControl0 = rate.retryTxPowerControl2

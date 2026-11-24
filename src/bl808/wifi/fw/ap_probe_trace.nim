type
  ApProbeKind = enum
    apProbeUnknown, apProbeWildcard, apProbeNamed, apProbeOther

  ApProbeOutcome = enum
    apProbeBadLength, apProbeNoVif, apProbeWrongAddress, apProbeBadIes,
    apProbeWrongChannel, apProbeRetired, apProbeWrongSsid, apProbeRespond

  ApProbeCounts = object
    rxUpper, apmEntered: uint32
    outcomes: array[ApProbeOutcome, uint32]
    built, submitted, done, acked, unacked, aborted, lastStatus: uint32

  ApProbeTxTag = object
    generation: uint32
    kind: ApProbeKind

  ApProbeDsssOutcome = enum
    apProbeDsssMatched, apProbeDsssBadLength, apProbeDsssNoOperatingChannel,
    apProbeDsssInvalidOperatingChannel, apProbeDsssMismatch

  ApProbeDsssSample = object
    sequence: uint32
    reason, length, requested, configured: uint8
    rxTunedMhz, configuredMhz: uint16

  ApProbeDsssHistory = object
    count: uint32
    samples: array[32, ApProbeDsssSample]

var
  apProbeTrace {.wifiCtrl, exportc: "nimfw_ap_probe_trace".}: array[ApProbeKind, ApProbeCounts]
  apProbeDsssTrace {.wifiCtrl, exportc: "nimfw_ap_probe_dsss_trace".}: ApProbeDsssHistory
  apProbeTxTags {.wifiCtrl.}: array[32, ApProbeTxTag]

static:
  doAssert sizeof(ApProbeCounts) == 17 * sizeof(uint32)
  doAssert sizeof(ApProbeDsssSample) == 3 * sizeof(uint32)
  doAssert offsetof(ApProbeDsssSample, reason) == 4
  doAssert offsetof(ApProbeDsssSample, rxTunedMhz) == 8
  doAssert offsetof(ApProbeDsssHistory, samples) == 4

proc apProbeNoteDsss(kind: ApProbeKind; reason: ApProbeDsssOutcome;
                     length, requested, configured: uint8;
                     rxTunedMhz, configuredMhz: uint16) =
  if kind != apProbeNamed:
    return
  let index = apProbeDsssTrace.count mod apProbeDsssTrace.samples.len.uint32
  let sequence = apProbeDsssTrace.count + 1
  apProbeDsssTrace.samples[index] = ApProbeDsssSample(sequence: sequence,
    reason: reason.uint8, length: length, requested: requested, configured: configured,
    rxTunedMhz: rxTunedMhz, configuredMhz: configuredMhz)
  apProbeDsssTrace.count = sequence

proc apProbeClassify(ies: ptr UncheckedArray[uint8]; length: uint32;
                     wanted: openArray[uint8]): ApProbeKind =
  if ies == nil or wanted.len notin 1 .. 32:
    return apProbeUnknown
  var offset = 0'u32
  result = apProbeUnknown
  while length - offset >= 2:
    let count = ies[offset + 1].uint32
    let data = offset + 2
    if count > length - data:
      break
    case ies[offset]
    of IE_ID_SSID:
      if count == 0:
        result = apProbeWildcard
      elif count <= 32 and result != apProbeWildcard:
        result = apProbeOther
      if count == wanted.len.uint32 and
          equalMem(addr ies[data], unsafeAddr wanted[0], wanted.len):
        return apProbeNamed
    of IE_ID_SSID_LIST:
      var entry = data
      let limit = data + count
      while limit - entry >= 2:
        let size = ies[entry + 1].uint32
        if ies[entry] != IE_ID_SSID or size > 32 or size > limit - entry - 2:
          break
        if size == wanted.len.uint32 and
            equalMem(addr ies[entry + 2], unsafeAddr wanted[0], wanted.len):
          return apProbeNamed
        if size == 0:
          result = apProbeWildcard
        elif result == apProbeUnknown:
          result = apProbeOther
        entry += size + 2
    else: discard
    offset = data + count

proc apProbeClassifyForAp(ies: pointer; length: uint32): ApProbeKind =
  let apm = apmEnvView()
  if apm.embeddedEnabled == 0 or apm.vifIdx >= MAX_VIFS.uint8:
    return apProbeUnknown
  let vif = vifChannelForIdx(apm.vifIdx)
  if vif.vifType != VIF_TYPE_AP or vif.state == 0:
    return apProbeUnknown
  let ssid = vifApProbeSsid(vif)
  if ssid.ssidLen notin 1'u8 .. 32'u8:
    return apProbeUnknown
  apProbeClassify(cast[ptr UncheckedArray[uint8]](ies), length,
                  (addr ssid.ssidData).toOpenArray(0, ssid.ssidLen.int - 1))

proc apProbeMarkBuilt(generation: uint32; kind: ApProbeKind) =
  inc apProbeTrace[kind].built
  if generation != 0:
    apProbeTxTags[generation mod apProbeTxTags.len.uint32] = ApProbeTxTag(
      generation: generation, kind: kind)

proc apProbeTakeTxKind(generation: uint32): ApProbeKind =
  if generation != 0:
    let tag = addr apProbeTxTags[generation mod apProbeTxTags.len.uint32]
    if tag.generation == generation:
      result = tag.kind
      tag.generation = 0

proc apProbeNoteCompletion(generation, status, thdFlags: uint32) =
  let kind = apProbeTakeTxKind(generation)
  let counts = addr apProbeTrace[kind]
  counts.lastStatus = status
  if (status and 0x80000000'u32) == 0:
    inc counts.aborted
  else:
    inc counts.done
    if (status and 0x00800000'u32) != 0 and (thdFlags and 0x10000'u32) == 0:
      inc counts.acked
    else:
      inc counts.unacked

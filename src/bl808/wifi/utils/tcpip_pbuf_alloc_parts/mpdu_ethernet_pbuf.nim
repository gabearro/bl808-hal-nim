include mpdu_ethernet_pbuf_parts/validated_view
include mpdu_ethernet_pbuf_parts/ethernet_header
include mpdu_ethernet_pbuf_parts/pbuf_fill

proc allocMpduEthernetPbuf(msduOffset: uint32; pkt: pointer): ptr Pbuf =
  inc nimFwDbgTcpipInputMpduConv
  var view {.noinit.}: MpduEthernetView
  if not loadMpduEthernetView(msduOffset, pkt, view):
    return nil

  var ethHdr {.noinit.}: array[14, uint8]
  buildMpduEthernetHeader(view, ethHdr)
  result = allocAndFillMpduEthernetPbuf(pkt, view, ethHdr)

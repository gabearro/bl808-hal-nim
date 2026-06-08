proc buildMpduEthernetHeader(view: MpduEthernetView;
                             ethHdr: var array[14, uint8]) =
  let snap = view.snap
  let toDs = (view.frameControl and 0x0100'u16) != 0
  let fromDs = (view.frameControl and 0x0200'u16) != 0
  let da =
    if toDs and fromDs: ptrAt(view.frame, 16)
    elif toDs: ptrAt(view.frame, 16)
    else: ptrAt(view.frame, 4)
  let sa =
    if toDs and fromDs: ptrAt(view.frame, 24)
    elif fromDs: ptrAt(view.frame, 16)
    else: ptrAt(view.frame, 10)
  discard c_memcpy(addr ethHdr[0], da, 6.csize_t)
  discard c_memcpy(addr ethHdr[6], sa, 6.csize_t)
  ethHdr[12] = loadU8(snap, 6)
  ethHdr[13] = loadU8(snap, 7)

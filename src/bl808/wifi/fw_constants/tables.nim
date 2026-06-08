## Firmware table entry sizes recovered from the vendor blob layout.

const
  STA_ENTRY_SIZE*   = 368    # struct sta_info_tag size from disasm (0x170)
  CHAN_CTXT_SIZE*   = 28     # channel context entry size (from blob stride)
  VIF_ENTRY_SIZE*   = 1512   # struct vif_info_tag size from WiFi blob (0x5E8)

# Build settings of the radio firmware that are not Nim defines. Nim reads
# this file when it compiles freenetradio.nim (the host tests are other
# projects and do not see it).

# The TCP receive window, for the stream and the web server alike: upstream's
# 10 KB (radio.rs, NET_LEN). The repo's Wi-Fi lwIP profile defaults to two
# segments (2920 bytes), which holds a stream to about window / round-trip
# time. `tcpconn.nim` sizes its buffers from the same number.
switch("passC", "-DTCP_WND=10240")

# FreeNetRadio's measured RX DMA ring depth.
if not defined(WifiRxRingSlots):
  switch("define", "WifiRxRingSlots=8")

# Keep host submission slots separate from the live MAC DMA chain.
if not defined(bl808WifiCombinedTxSlots):
  switch("define", "bl808WifiSplitTxSlots")

# WPA2 key derivation (4096 rounds of HMAC-SHA-1 when joining) on the chip's
# SHA engine, like the rest of this firmware's hashing.
switch("define", "bl808WifiMbedTlsSha1Hardware")

# The DAC queue: 12288 frames (279 ms at 44.1 kHz) instead of upstream's 4096.
# On this chip the Wi-Fi stack is polled from the same scheduler as the audio
# task, and stretches of 50 to 100 ms in which the decoder does not get its
# turn are normal; with 93 ms queued those were audible drop-outs. The cost
# is that volume and equaliser changes are heard a quarter of a second later.
switch("define", "radioRingFrames=12288")

# The stream buffer: 64 KB instead of upstream's 10 KB. Playback still starts
# at upstream's level; the rest fills from the server's start-up burst and
# carries the radio through a few seconds without reception, which Wi-Fi has
# and upstream's wired Ethernet did not.
switch("define", "radioPipeBytes=65536")

# The stack. The linker profile guards 8 KB at the top of on-chip RAM, which
# a TLS handshake comes close to. This firmware leaves about 27 KB between
# the end of .bss and the top, so the stack gets 20 KB of it; 12 KB when AES
# is in software, whose tables take 8.5 KB of that RAM. Without TLS the
# profile's 8 KB is plenty. The profile refuses to link if .bss ever grows
# into the stack.
if not defined(radioNoTls):
  switch("passL", "-Wl,--defsym=__bl808_app_stack_bytes=" &
    (if defined(bl808MbedTlsSoftware) or defined(bl808MbedTlsAesSoftware): "12288"
     else: "20480"))

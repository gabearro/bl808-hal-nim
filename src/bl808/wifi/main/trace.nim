## Direct-UART trace helpers - `cfg_trace(char*)` and `cfg_trace_rc(char*,int)`
## are kept available as extern C symbols so any wifi_* module can drop in
## prints without going through the wifi-blob log routing, which is
## char-write-blind and gets clobbered by PHY printf chatter. Poll FIFO-free
## status before each byte so traces survive concurrent emits.
{.emit: """
static void cfg_putc(char c) {
  volatile unsigned int *fifo = (volatile unsigned int *)0x2000a088;
  volatile unsigned int *cfg  = (volatile unsigned int *)0x2000a084;
  unsigned int t = 200000u;
  while (((*cfg) & 0x3fu) == 0u && t--) {}
  *fifo = (unsigned int)(unsigned char)c;
}
void cfg_trace(char *s) {
  while (*s) cfg_putc(*s++);
}
void cfg_trace_rc(char *s, int v) {
  while (*s) cfg_putc(*s++);
  unsigned int u = (unsigned int)v;
  for (int sh = 28; sh >= 0; sh -= 4) {
    unsigned int n = (u >> sh) & 0xf;
    cfg_putc((char)(n < 10 ? ('0' + n) : ('a' + n - 10)));
  }
  cfg_putc('\r'); cfg_putc('\n');
}
""".}

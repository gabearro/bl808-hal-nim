"""The Wi-Fi TCP lwIP profile as a TCP client would build it.

Host checks of src/bl808/kernel/lwip_wifi_http/lwipopts.h: the defaults are
the values the HTTP server has always had, `-D` overrides reach lwIP, and the
opt-in resolver works end to end (DHCP records the lease's DNS servers, a
lookup goes to them and its answer comes back) against the pinned SDK lwIP.

One cross-build links an M0 Wi-Fi image that calls every client binding in
src/bl808/kernel/lwipcore.nim. Nothing is flashed or run on a board.
"""

import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]
KERNEL = ROOT / "src/bl808/kernel"
HTTP = KERNEL / "lwip_wifi_http"
OPTS = HTTP / "lwipopts.h"
SDK = ROOT / "build/bl_iot_sdk_b773b3f/components/network/lwip/src"


def host_cc() -> list[str]:
    cc = shlex.split(os.environ.get("CC", "cc"))
    if not cc or shutil.which(cc[0]) is None:
        pytest.skip("requires a host C compiler")
    return cc


def profile_values(tmp_path: Path, *flags: str) -> dict[str, int]:
    """The profile's client options as the C compiler sees them."""
    names = ("TCP_MSS", "TCP_WND", "TCP_SND_BUF", "TCP_SND_QUEUELEN", "LWIP_DNS")
    source = tmp_path / "values.c"
    source.write_text(
        "#include <stdio.h>\nint main(void) {\n"
        + "".join(f'  printf("{name} %ld\\n", (long)({name}));\n' for name in names)
        + "#ifdef DNS_RAND_TXID\n  puts(\"DNS_RAND_TXID 1\");\n#else\n  puts(\"DNS_RAND_TXID 0\");\n#endif\n"
        "  return 0;\n}\n"
        # Only named, never called: the firmware's Wi-Fi runtime provides it.
        "unsigned int bl808_lwip_dhcp_xid_seed(void) { return 0; }\n",
        encoding="ascii",
    )
    binary = tmp_path / "values"
    result = subprocess.run([*host_cc(), *flags, "-include", str(OPTS), "-o", str(binary), str(source)],
                            capture_output=True, text=True, timeout=60, check=False)
    assert result.returncode == 0, result.stdout + result.stderr
    output = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10, check=True).stdout
    return {name: int(value) for name, value in (line.split() for line in output.splitlines())}


def test_default_profile_is_the_http_server_configuration(tmp_path: Path) -> None:
    assert profile_values(tmp_path) == {
        "TCP_MSS": 1460, "TCP_WND": 2920, "TCP_SND_BUF": 2920, "TCP_SND_QUEUELEN": 8,
        "LWIP_DNS": 0, "DNS_RAND_TXID": 0,
    }


def test_client_options_can_be_set_from_the_command_line(tmp_path: Path) -> None:
    values = profile_values(tmp_path, "-DTCP_WND=16384", "-DTCP_SND_BUF=(4*TCP_MSS)", "-DLWIP_DNS=1")
    assert values["TCP_WND"] == 16384
    assert values["TCP_SND_BUF"] == 5840
    assert values["TCP_SND_QUEUELEN"] == 16          # still derived from the send buffer
    assert values["LWIP_DNS"] == 1 and values["DNS_RAND_TXID"] == 1
    assert profile_values(tmp_path, "-DTCP_SND_QUEUELEN=32")["TCP_SND_QUEUELEN"] == 32


def test_lwipcore_drives_the_resolver_from_one_define() -> None:
    core = (KERNEL / "lwipcore.nim").read_text(encoding="utf-8")
    assert '{.passC: "-DLWIP_DNS=1".}' in core
    assert 'ErrAbrt*: ErrT = -13' in core            # ERR_ABRT in lwip/err.h
    # lwIP's error codes, as the pinned SDK and the vendored tree number them.
    for tree in (SDK, ROOT / "vendor/lwip/src"):
        header = tree / "include/lwip/err.h"
        if not header.is_file():
            continue
        codes = dict(re.findall(r"(ERR_\w+)\s*=\s*(-?\d+)", header.read_text(encoding="utf-8")))
        for nim_name, c_name in (("ErrOk", "ERR_OK"), ("ErrMem", "ERR_MEM"), ("ErrBuf", "ERR_BUF"),
                                 ("ErrTimeout", "ERR_TIMEOUT"), ("ErrRte", "ERR_RTE"),
                                 ("ErrInProgress", "ERR_INPROGRESS"), ("ErrConn", "ERR_CONN"),
                                 ("ErrAbrt", "ERR_ABRT"), ("ErrRst", "ERR_RST"), ("ErrClsd", "ERR_CLSD")):
            assert re.search(rf"{nim_name}\*: ErrT = {codes[c_name]}\n", core), (nim_name, header)


DRIVER = r"""
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lwip/init.h"
#include "lwip/dhcp.h"
#include "lwip/dns.h"
#include "lwip/inet_chksum.h"
#include "lwip/ip4.h"
#include "lwip/netif.h"
#include "lwip/pbuf.h"
#include "lwip/prot/dhcp.h"
#include "lwip/prot/ip4.h"
#include "lwip/prot/udp.h"
#include "lwip/tcp.h"

#define CHECK(condition) do { if (!(condition)) { \
  fprintf(stderr, "line %d: %s\n", __LINE__, #condition); exit(1); } } while (0)

uint32_t sys_now(void) { return 1000; }
void test_lwip_assert(const char *message) { fprintf(stderr, "lwIP assert: %s\n", message); exit(1); }

/* The firmware's TRNG-backed source; here a counter the test can predict. */
static uint32_t seed = 0x5EED0000U;
uint32_t bl808_lwip_dhcp_xid_seed(void) { return ++seed; }
uint16_t bl808_lwip_dhcp_retry_ms(uint32_t xid, uint32_t now_ms, uint8_t tries, uint8_t state)
{
    (void)xid; (void)now_ms; (void)tries; (void)state;
    return 1000;
}

/* The interface hands lwIP's IP packets to the test and takes its replies. */
static uint8_t sent[1600];
static unsigned sent_len;

static err_t capture(struct netif *netif, struct pbuf *p, const ip4_addr_t *dest)
{
    (void)netif; (void)dest;
    CHECK(p->tot_len <= sizeof(sent));
    sent_len = pbuf_copy_partial(p, sent, p->tot_len, 0);
    return ERR_OK;
}

static err_t interface_init(struct netif *netif)
{
    static const uint8_t mac[6] = {0x02, 0x80, 0x08, 0x00, 0x00, 0x01};
    memcpy(netif->hwaddr, mac, 6);
    netif->hwaddr_len = 6;
    netif->mtu = 1500;
    netif->flags = NETIF_FLAG_BROADCAST;
    netif->output = capture;
    return ERR_OK;
}

#define IP(a, b, c, d) PP_HTONL(LWIP_MAKEU32(a, b, c, d))
#define SERVER   IP(192, 168, 7, 1)
#define CLIENT   IP(192, 168, 7, 50)
#define DNS_ONE  IP(192, 168, 7, 53)
#define DNS_TWO  IP(9, 9, 9, 9)

static void deliver(struct netif *netif, uint32_t src, uint32_t dst, uint16_t sport, uint16_t dport,
                    const uint8_t *payload, unsigned len)
{
    struct pbuf *p = pbuf_alloc(PBUF_RAW, (u16_t)(IP_HLEN + UDP_HLEN + len), PBUF_RAM);
    CHECK(p != NULL && p->len == p->tot_len);
    struct ip_hdr *ip = (struct ip_hdr *)p->payload;
    struct udp_hdr *udp = (struct udp_hdr *)((uint8_t *)p->payload + IP_HLEN);
    memset(ip, 0, IP_HLEN + UDP_HLEN);
    IPH_VHL_SET(ip, 4, IP_HLEN / 4);
    IPH_LEN_SET(ip, lwip_htons((u16_t)p->tot_len));
    IPH_TTL_SET(ip, 64);
    IPH_PROTO_SET(ip, IP_PROTO_UDP);
    ip->src.addr = src;
    ip->dest.addr = dst;
    IPH_CHKSUM_SET(ip, inet_chksum(ip, IP_HLEN));
    udp->src = lwip_htons(sport);
    udp->dest = lwip_htons(dport);
    udp->len = lwip_htons((u16_t)(UDP_HLEN + len));     /* checksum 0: none */
    memcpy((uint8_t *)udp + UDP_HLEN, payload, len);
    CHECK(ip4_input(p, netif) == ERR_OK);
}

static const uint8_t *sent_udp(uint16_t *sport, uint16_t *dport, unsigned *len)
{
    CHECK(sent_len >= IP_HLEN + UDP_HLEN);
    const struct udp_hdr *udp = (const struct udp_hdr *)(sent + IP_HLEN);
    *sport = lwip_ntohs(udp->src);
    *dport = lwip_ntohs(udp->dest);
    *len = sent_len - IP_HLEN - UDP_HLEN;
    return sent + IP_HLEN + UDP_HLEN;
}

static int requests_option(const uint8_t *dhcp, unsigned len, uint8_t wanted)
{
    for (unsigned i = DHCP_OPTIONS_OFS; i + 1 < len && dhcp[i] != DHCP_OPTION_END; i += 2U + dhcp[i + 1]) {
        if (dhcp[i] != DHCP_OPTION_PARAMETER_REQUEST_LIST) continue;
        for (unsigned j = 0; j < dhcp[i + 1]; j++) if (dhcp[i + 2 + j] == wanted) return 1;
    }
    return 0;
}

static void dhcp_reply(struct netif *netif, const uint8_t *request, uint8_t type)
{
    uint8_t reply[DHCP_OPTIONS_OFS + 64];
    memset(reply, 0, sizeof(reply));
    struct dhcp_msg *msg = (struct dhcp_msg *)reply;
    const struct dhcp_msg *asked = (const struct dhcp_msg *)request;
    msg->op = DHCP_BOOTREPLY;
    msg->htype = 1;
    msg->hlen = 6;
    msg->xid = asked->xid;
    msg->yiaddr.addr = CLIENT;
    memcpy(msg->chaddr, netif->hwaddr, 6);
    msg->cookie = PP_HTONL(DHCP_MAGIC_COOKIE);
    const uint32_t mask = IP(255, 255, 255, 0), server = SERVER, dns[2] = {DNS_ONE, DNS_TWO};
    const uint32_t lease = PP_HTONL(3600);
    uint8_t *o = reply + DHCP_OPTIONS_OFS;
    *o++ = DHCP_OPTION_MESSAGE_TYPE; *o++ = 1; *o++ = type;
    *o++ = DHCP_OPTION_SERVER_ID; *o++ = 4; memcpy(o, &server, 4); o += 4;
    *o++ = DHCP_OPTION_LEASE_TIME; *o++ = 4; memcpy(o, &lease, 4); o += 4;
    *o++ = DHCP_OPTION_SUBNET_MASK; *o++ = 4; memcpy(o, &mask, 4); o += 4;
    *o++ = DHCP_OPTION_ROUTER; *o++ = 4; memcpy(o, &server, 4); o += 4;
    *o++ = DHCP_OPTION_DNS_SERVER; *o++ = 8; memcpy(o, dns, 8); o += 8;
    *o++ = DHCP_OPTION_END;
    deliver(netif, SERVER, IPADDR_BROADCAST, 67, 68, reply, sizeof(reply));
}

static unsigned found_calls;
static uint32_t found_address;

static void found(const char *name, const ip_addr_t *address, void *arg)
{
    CHECK(strcmp(name, "radio.example") == 0 && arg == &found_calls);
    found_calls++;
    found_address = address != NULL ? ip_2_ip4(address)->addr : 0;
}

int main(void)
{
    static struct netif netif;
    uint16_t sport, dport;
    unsigned len;

    lwip_init();
    CHECK(netif_add(&netif, NULL, NULL, NULL, NULL, interface_init, ip4_input) != NULL);
    netif_set_default(&netif);
    netif_set_up(&netif);
    netif_set_link_up(&netif);
    CHECK(ip_addr_isany(dns_getserver(0)));

    /* DHCP asks for the resolvers and keeps the ones the lease names. */
    CHECK(dhcp_start(&netif) == ERR_OK);
    const uint8_t *message = sent_udp(&sport, &dport, &len);
    CHECK(sport == 68 && dport == 67 && requests_option(message, len, DHCP_OPTION_DNS_SERVER));
    dhcp_reply(&netif, message, DHCP_OFFER);
    message = sent_udp(&sport, &dport, &len);
    CHECK(dport == 67 && requests_option(message, len, DHCP_OPTION_DNS_SERVER));
    dhcp_reply(&netif, message, DHCP_ACK);
    CHECK(dhcp_supplied_address(&netif));
    CHECK(netif_ip4_addr(&netif)->addr == CLIENT && netif_ip4_gw(&netif)->addr == SERVER);
    CHECK(netif_ip4_netmask(&netif)->addr == IP(255, 255, 255, 0));
    CHECK(ip_2_ip4(dns_getserver(0))->addr == DNS_ONE);
    CHECK(ip_2_ip4(dns_getserver(1))->addr == DNS_TWO);

    /* A lookup goes to the first of them, with an id and a source port from
     * the firmware's random source, and its answer reaches the callback. */
    ip_addr_t answer;
    sent_len = 0;
    const uint32_t before = seed;
    CHECK(dns_gethostbyname("10.1.2.3", &answer, found, &found_calls) == ERR_OK);
    CHECK(ip_2_ip4(&answer)->addr == IP(10, 1, 2, 3) && sent_len == 0);
    CHECK(dns_gethostbyname("radio.example", &answer, found, &found_calls) == ERR_INPROGRESS);
    const struct ip_hdr *ip = (const struct ip_hdr *)sent;
    CHECK(sent_len > 0 && ip->dest.addr == DNS_ONE && ip->src.addr == CLIENT);
    message = sent_udp(&sport, &dport, &len);
    CHECK(dport == 53 && len == 12 + 15 + 4);
    CHECK(memcmp(message + 12, "\005radio\007example\000\000\001\000\001", 19) == 0);
    CHECK(seed > before);
    const uint16_t id = (uint16_t)((message[0] << 8) | message[1]);
    int drawn = 0;
    for (uint32_t value = before + 1; value <= seed; value++) drawn |= (uint16_t)value == id;
    CHECK(drawn && sport >= 1024);

    uint8_t reply[12 + 19 + 16];
    memcpy(reply, message, 12 + 19);
    reply[2] = 0x81; reply[3] = 0x80;                 /* response, no error */
    reply[7] = 1;                                     /* one answer */
    static const uint8_t record[16] = {0xC0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 203, 0, 113, 7};
    memcpy(reply + 12 + 19, record, 16);
    deliver(&netif, DNS_ONE, CLIENT, 53, sport, reply, sizeof(reply));
    CHECK(found_calls == 1 && found_address == IP(203, 0, 113, 7));
    CHECK(dns_gethostbyname("radio.example", &answer, found, &found_calls) == ERR_OK);   /* cached */
    CHECK(ip_2_ip4(&answer)->addr == IP(203, 0, 113, 7) && found_calls == 1);

    /* The window a connection opens with is the one the build asked for. */
    struct tcp_pcb *pcb = tcp_new();
    CHECK(pcb != NULL && pcb->rcv_wnd == TCP_WND && tcp_sndbuf(pcb) == TCP_SND_BUF);
    printf("TCP_WND %d TCP_SND_BUF %d\n", (int)pcb->rcv_wnd, (int)tcp_sndbuf(pcb));
    tcp_abort(pcb);
    return 0;
}
"""

SDK_SOURCES = (
    "core/init.c", "core/def.c", "core/mem.c", "core/memp.c", "core/pbuf.c", "core/netif.c",
    "core/ip.c", "core/raw.c", "core/udp.c", "core/inet_chksum.c", "core/sys.c", "core/dns.c",
    "core/ipv4/ip4.c", "core/ipv4/ip4_addr.c", "core/ipv4/icmp.c", "core/ipv4/etharp.c",
    "netif/ethernet.c",
)


def build_client(work: Path, *flags: str) -> subprocess.CompletedProcess:
    """The profile's lwIP, built for the host the way lwipcore.nim builds it."""
    if not (SDK / "core/dns.c").is_file():
        pytest.skip("requires the pinned bl_iot_sdk_b773b3f checkout under build/")
    (work / "arch").mkdir(parents=True, exist_ok=True)
    # Replace only the platform headers, not lwIP code or the firmware options.
    (work / "arch/cc.h").write_text(
        "#pragma once\n#include <sys/types.h>\n#include <limits.h>\n#include <stdint.h>\n#include <stdio.h>\n"
        "uint32_t sys_now(void);\n"
        "void test_lwip_assert(const char *message);\n"
        "#define LWIP_DONT_PROVIDE_BYTEORDER_FUNCTIONS\n"
        "#define LWIP_PLATFORM_DIAG(message) do { } while (0)\n"
        "#define LWIP_PLATFORM_ASSERT(message) test_lwip_assert(message)\n"
        "#define PACK_STRUCT_STRUCT __attribute__((packed))\n",
        encoding="ascii",
    )
    (work / "FreeRTOS.h").write_text("#pragma once\n", encoding="ascii")
    (work / "timers.h").write_text("#pragma once\ntypedef void *TimerHandle_t;\n", encoding="ascii")
    driver = work / "client_driver.c"
    driver.write_text(DRIVER, encoding="ascii")
    return subprocess.run(
        [*host_cc(), "-std=gnu11", *flags, "-I", str(work), "-I", str(HTTP), "-I", str(SDK / "include"),
         "-include", str(OPTS), "-o", str(work / "client_driver"), str(driver),
         str(KERNEL / "lwip_wifi_smoke/timeouts.c"), str(KERNEL / "lwip_wifi_smoke/dhcp_seeded.c"),
         *(str(HTTP / f"{name}_enabled.c") for name in ("tcp", "tcp_in", "tcp_out")),
         *(str(SDK / source) for source in SDK_SOURCES)],
        capture_output=True, text=True, timeout=120, check=False,
    )


@pytest.mark.parametrize("flags, window, send_buffer", [
    (("-DLWIP_DNS=1",), 2920, 2920),
    (("-DLWIP_DNS=1", "-DTCP_WND=16384", "-DTCP_SND_BUF=(4*TCP_MSS)"), 16384, 5840),
])
def test_resolver_and_window_with_the_pinned_lwip(tmp_path: Path, flags: tuple[str, ...],
                                                  window: int, send_buffer: int) -> None:
    result = build_client(tmp_path, *flags)
    assert result.returncode == 0, result.stdout + result.stderr
    run = subprocess.run([str(tmp_path / "client_driver")], capture_output=True, text=True,
                         timeout=10, check=False)
    assert run.returncode == 0, run.stdout + run.stderr
    # The SDK's netif.c prints the address it was given first.
    assert run.stdout.splitlines()[-1] == f"TCP_WND {window} TCP_SND_BUF {send_buffer}"


def test_lwip_rejects_an_inconsistent_override(tmp_path: Path) -> None:
    result = build_client(tmp_path, "-DLWIP_DNS=1", "-DTCP_SND_QUEUELEN=2")
    assert result.returncode != 0
    assert "TCP_SND_QUEUELEN must be at least" in result.stderr


# m0_wifi_http_server as tools/hardware_validation.json builds it, with
# placeholder credentials.
WIFI_HTTP_SERVER = [
    "-d:bl808m0", "-d:bl808kernel", "-d:WifiSsid=placeholder-ssid", "-d:WifiPassword=placeholder-password",
    "-d:bl808WifiHttpServer=1", "-d:bl808WifiNimFw=1", "-d:bl808WifiUseBl808Rf=1",
    "-d:bl808WifiNativeWlanCalibration=1", "-d:bl808WifiRealLwip=1", "-d:bl808WifiRealLwipTcp=1",
    "-d:bl808WifiRxPbufInput=1", "-d:HwValidationLogExternalBuffer=1",
    "-d:HwValidationLogSection=.psrambss.jtaglog",
]

# The HTTP server example plus a client that reaches every binding a TCP
# client needs, so section GC keeps what such an image would link.
CLIENT_PROBE = r'''
import bl808/kernel/lwipcore

var
  probeSink {.volatile.}: uint32
  probeAddress: IpAddr

proc probeConnected(arg: pointer, pcb: ptr TcpPcb, err: ErrT): ErrT {.cdecl.} =
  probeSink = tcpSndbuf(pcb).uint32 + TcpWnd.uint32 + TcpSndBuf.uint32
  ErrOk

proc probeFound(name: cstring, ipaddr: ptr IpAddr, arg: pointer) {.cdecl.} =
  if ipaddr != nil: probeAddress = ipaddr[]

proc lwipClientProbe(netif: ptr Netif) {.exportc: "bl808_lwip_client_probe".} =
  probeSink = netifIp4Addr(netif).address xor netifIp4Netmask(netif).address xor
              netifIp4Gw(netif).address
  var server = ip4Addr(1, 1, 1, 1)
  dnsSetServer(1, addr server)
  probeSink = dnsGetServer(0).address
  if dnsGetHostByName("radio.example", addr probeAddress, probeFound, nil) == ErrInProgress:
    return
  let pcb = tcpNew()
  if pcb != nil and tcpConnect(pcb, addr probeAddress, 80, probeConnected) != ErrOk:
    tcpAbort(pcb)

{.passL: "-Wl,--undefined=bl808_lwip_client_probe".}

include "EXAMPLE"
'''


def test_m0_client_image_links(tmp_path: Path) -> None:
    nim = shutil.which("nim")
    nm = shutil.which("riscv64-unknown-elf-nm")
    if not nim or not nm or not shutil.which("riscv64-unknown-elf-gcc"):
        pytest.skip("needs Nim and the RISC-V toolchain")
    if not (SDK / "core/dns.c").is_file():
        pytest.skip("requires the pinned bl_iot_sdk_b773b3f checkout under build/")
    # The repository's config.nims applies to projects below it; this one is not.
    (tmp_path / "config.nims").write_text(f'include "{ROOT / "config.nims"}"\n', encoding="utf-8")
    source = tmp_path / "lwip_client_link.nim"
    source.write_text(CLIENT_PROBE.replace("EXAMPLE", str(ROOT / "examples/m0_wifi_http_server.nim")),
                      encoding="utf-8")

    def link(label: str, *flags: str) -> str:
        elf = tmp_path / f"{label}.elf"
        result = subprocess.run(
            [nim, "c", "--hints:off", "--warnings:off", f"--path:{ROOT / 'src'}", *WIFI_HTTP_SERVER, *flags,
             f"--nimcache:{tmp_path / label}", f"--out:{elf}", str(source)],
            cwd=ROOT, capture_output=True, text=True, timeout=900, check=False)
        if result.returncode != 0:
            return (result.stdout + result.stderr)[-4000:]
        symbols = subprocess.run([nm, str(elf)], capture_output=True, text=True, check=True).stdout
        return "linked\n" + symbols

    client = link("client", "-d:bl808WifiRealLwipDns", "--passC:-DTCP_WND=16384",
                  "--passC:-DTCP_SND_BUF=5840")
    assert client.startswith("linked"), client
    for symbol in ("dns_gethostbyname", "dns_setserver", "dns_tmr", "tcp_connect",
                   "bl808_lwip_client_probe"):
        assert re.search(rf" T {symbol}$", client, re.MULTILINE), symbol

    # Without the define the resolver is not in the image, and asking for it
    # is a Nim error at the call, not a link failure.
    without = link("no_dns")
    assert not without.startswith("linked")
    assert "undeclared identifier: 'dnsSetServer'" in without

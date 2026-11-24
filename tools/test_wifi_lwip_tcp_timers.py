"""Exercise the Wi-Fi HTTP build's pinned lwIP TCP timers and DHCP lifecycle."""

import os
from pathlib import Path
import shlex
import shutil
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]
KERNEL = ROOT / "src/bl808/kernel"
HTTP = KERNEL / "lwip_wifi_http"
SDK = ROOT / "build/bl_iot_sdk_b773b3f/components/network/lwip/src"

DRIVER = r"""
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lwip/init.h"
#include "lwip/dhcp.h"
#include "lwip/prot/dhcp.h"
#include "lwip/inet_chksum.h"
#include "lwip/ip4.h"
#include "lwip/memp.h"
#include "lwip/priv/tcp_priv.h"
#include "lwip/prot/ip4.h"
#include "lwip/prot/udp.h"
#include "lwip/sys.h"

uint32_t bl808_lwip_dhcp_xid_seed(void)
{
    return 0x20260811U;
}

uint16_t bl808_lwip_dhcp_retry_ms(uint32_t xid, uint32_t now_ms,
                                uint8_t tries, uint8_t state);

#define CHECK(expr) do {                                                     \
    if (!(expr)) {                                                           \
        fprintf(stderr, "line %d: %s (sys_now=%" U32_F ", tcp_ticks=%" U32_F ")\n", \
                __LINE__, #expr, now_ms, tcp_ticks);                         \
        exit(1);                                                             \
    }                                                                        \
} while (0)

static u32_t now_ms;
static bool fail_timeout_alloc;
static unsigned timeout_alloc_attempts;

u32_t sys_now(void) { return now_ms; }

void test_lwip_assert(const char *message)
{
    /* The BL808 platform assertion returns. Keep other host assertions fatal. */
    if (fail_timeout_alloc && strcmp(message, "sys_timeout: pool MEMP_SYS_TIMEOUT is empty") == 0) {
        return;
    }
    fprintf(stderr, "lwIP assertion: %s\n", message);
    abort();
}

void *test_memp_malloc(memp_t type)
{
    if (type == MEMP_SYS_TIMEOUT) {
        ++timeout_alloc_attempts;
        if (fail_timeout_alloc) {
            return NULL;
        }
    }
    return memp_malloc(type);
}

static void advance(u32_t ms)
{
    now_ms += ms;
    sys_check_timeouts();
}

static void check_periodic(void)
{
    struct tcp_pcb *pcb = tcp_new();
    CHECK(pcb != NULL);
    pcb->state = ESTABLISHED;
    TCP_REG_ACTIVE(pcb);

    u32_t ticks = tcp_ticks;
    advance(TCP_TMR_INTERVAL);
    CHECK(tcp_ticks - ticks == 1);
    advance(TCP_TMR_INTERVAL);
    CHECK(tcp_ticks - ticks == 2);
    tcp_abandon(pcb, 0);
}

static void check_subtick(void)
{
    const u32_t interval = TCP_SLOW_INTERVAL;
    tcpip_tmr_compensate_tick();  /* sys_now() == 0 is a valid starting point. */
    u32_t ticks = tcp_ticks;
    now_ms += interval / 2;
    tcpip_tmr_compensate_tick();
    CHECK(tcp_ticks == ticks);
    now_ms += interval - interval / 2 - 1;
    tcpip_tmr_compensate_tick();
    CHECK(tcp_ticks == ticks);
    ++now_ms;
    tcpip_tmr_compensate_tick();
    CHECK(tcp_ticks - ticks == 1);
    now_ms += 2 * interval + 1;
    tcpip_tmr_compensate_tick();
    CHECK(tcp_ticks - ticks == 3);
    now_ms += interval - 1;
    tcpip_tmr_compensate_tick();
    CHECK(tcp_ticks - ticks == 4);
}

static void check_rollover(void)
{
    const u32_t interval = TCP_SLOW_INTERVAL;
    const u32_t to_zero = interval / 2;
    now_ms = UINT32_MAX - to_zero + 1;
    tcpip_tmr_compensate_tick();
    u32_t ticks = tcp_ticks;
    now_ms += to_zero;
    CHECK(sys_now() == 0);
    tcpip_tmr_compensate_tick();
    CHECK(tcp_ticks == ticks);
    now_ms += interval - to_zero;
    tcpip_tmr_compensate_tick();
    CHECK(tcp_ticks - ticks == 1);
    now_ms += interval;
    tcpip_tmr_compensate_tick();
    CHECK(tcp_ticks - ticks == 2);
}

static const char request[] = "GET / HTTP/1.1\r\nHost: test\r\n\r\n";
static const char header[] = "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\n\r\n";
static const char body[] = "ok";
#define RESPONSE_LEN (sizeof(header) + sizeof(body) - 2)
#define PEER_PORT 50000
#define HTTP_PORT 80

static struct netif netif;
static ip4_addr_t server_ip, peer_ip;
static struct tcp_pcb *client_pcb;
static unsigned requests, data_attempts, data_delivered;
static bool drop_first_data;

struct packet {
    u32_t seq, ack;
    u16_t flags, len;
    char payload[RESPONSE_LEN];
};

static struct packet first_data, last_packet;

static err_t capture_output(struct netif *iface, struct pbuf *p,
                            const ip4_addr_t *dst)
{
    struct ip_hdr ip;
    struct tcp_hdr tcp;
    LWIP_UNUSED_ARG(iface);
    CHECK(ip4_addr_cmp(dst, &peer_ip));
    CHECK(pbuf_copy_partial(p, &ip, sizeof(ip), 0) == sizeof(ip));
    CHECK(IPH_PROTO(&ip) == IP_PROTO_TCP);
    const u16_t ip_len = IPH_HL_BYTES(&ip);
    CHECK(pbuf_copy_partial(p, &tcp, sizeof(tcp), ip_len) == sizeof(tcp));
    const u16_t offset = ip_len + TCPH_HDRLEN_BYTES(&tcp);
    CHECK(p->tot_len >= offset);
    last_packet.seq = lwip_ntohl(tcp.seqno);
    last_packet.ack = lwip_ntohl(tcp.ackno);
    last_packet.flags = TCPH_FLAGS(&tcp);
    last_packet.len = p->tot_len - offset;
    CHECK(last_packet.len <= sizeof(last_packet.payload));
    CHECK(pbuf_copy_partial(p, last_packet.payload, last_packet.len, offset) == last_packet.len);
    if (last_packet.len != 0) {
        if (++data_attempts == 1) {
            first_data = last_packet;
            if (drop_first_data) {
                /* Successful handoff, but no delivery or extra pbuf reference. */
                return ERR_OK;
            }
        }
        ++data_delivered;
    }
    return ERR_OK;
}

static err_t setup_netif(struct netif *iface)
{
    iface->output = capture_output;
    iface->mtu = 1500;
    return ERR_OK;
}

static void inject_tcp(u32_t seq, u32_t ack, u8_t flags, const char *data, u16_t len)
{
    const u16_t tcp_len = TCP_HLEN + len;
    struct pbuf *p = pbuf_alloc(PBUF_RAW, IP_HLEN + tcp_len, PBUF_RAM);
    CHECK(p != NULL && p->len == p->tot_len);
    struct ip_hdr *ip = p->payload;
    memset(ip, 0, IP_HLEN + tcp_len);
    CHECK(pbuf_remove_header(p, IP_HLEN) == 0);

    struct tcp_hdr *tcp = p->payload;
    tcp->src = lwip_htons(PEER_PORT);
    tcp->dest = lwip_htons(HTTP_PORT);
    tcp->seqno = lwip_htonl(seq);
    tcp->ackno = lwip_htonl(ack);
    tcp->wnd = lwip_htons(65535);
    TCPH_HDRLEN_FLAGS_SET(tcp, TCP_HLEN / 4, flags);
    if (len != 0) {
        memcpy((char *)tcp + TCP_HLEN, data, len);
    }
    tcp->chksum = ip_chksum_pseudo(p, IP_PROTO_TCP, tcp_len, &peer_ip, &server_ip);

    CHECK(pbuf_add_header_force(p, IP_HLEN) == 0);
    IPH_VHL_SET(ip, 4, IP_HLEN / 4);
    IPH_LEN_SET(ip, lwip_htons(p->tot_len));
    IPH_TTL_SET(ip, 64);
    IPH_PROTO_SET(ip, IP_PROTO_TCP);
    ip4_addr_copy(ip->src, peer_ip);
    ip4_addr_copy(ip->dest, server_ip);
    IPH_CHKSUM_SET(ip, inet_chksum(ip, IP_HLEN));
    CHECK(ip4_input(p, &netif) == ERR_OK);
}

static err_t receive_request(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err)
{
    char actual[sizeof(request) - 1];
    LWIP_UNUSED_ARG(arg);
    CHECK(err == ERR_OK && p != NULL);
    CHECK(p->tot_len == sizeof(actual));
    CHECK(pbuf_copy_partial(p, actual, sizeof(actual), 0) == sizeof(actual));
    CHECK(memcmp(actual, request, sizeof(actual)) == 0);
    ++requests;
    tcp_recved(pcb, p->tot_len);
    pbuf_free(p);
    CHECK(tcp_write(pcb, header, sizeof(header) - 1, TCP_WRITE_FLAG_COPY) == ERR_OK);
    CHECK(tcp_write(pcb, body, sizeof(body) - 1, TCP_WRITE_FLAG_COPY) == ERR_OK);
    CHECK(tcp_output(pcb) == ERR_OK);
    CHECK(data_attempts == 0);  /* Real output is deferred until tcp_input unwinds. */
    tcp_recv(pcb, NULL);
    CHECK(tcp_close(pcb) == ERR_OK);
    return ERR_OK;
}

static err_t accept_client(void *arg, struct tcp_pcb *pcb, err_t err)
{
    LWIP_UNUSED_ARG(arg);
    CHECK(err == ERR_OK && pcb != NULL);
    client_pcb = pcb;
    tcp_recv(pcb, receive_request);
    return ERR_OK;
}

static void check_http(bool lose_response)
{
    ip4_addr_t mask, gateway;
    IP4_ADDR(&server_ip, 192, 0, 2, 1);
    IP4_ADDR(&peer_ip, 192, 0, 2, 2);
    IP4_ADDR(&mask, 255, 255, 255, 0);
    ip4_addr_set_zero(&gateway);
    CHECK(netif_add(&netif, &server_ip, &mask, &gateway, NULL, setup_netif, ip4_input) == &netif);
    netif_set_up(&netif);
    netif_set_link_up(&netif);

    struct tcp_pcb *listener = tcp_new();
    CHECK(listener != NULL);
    CHECK(tcp_bind(listener, &server_ip, HTTP_PORT) == ERR_OK);
    listener = tcp_listen(listener);
    CHECK(listener != NULL);
    tcp_accept(listener, accept_client);

    const u32_t peer_seq = 12345;
    inject_tcp(peer_seq, 0, TCP_SYN, NULL, 0);
    CHECK(last_packet.flags == (TCP_SYN | TCP_ACK) && last_packet.ack == peer_seq + 1);
    const u32_t server_seq = last_packet.seq + 1;
    inject_tcp(peer_seq + 1, server_seq, TCP_ACK, NULL, 0);
    CHECK(client_pcb != NULL && client_pcb->state == ESTABLISHED);

    drop_first_data = lose_response;
    const u32_t peer_end = peer_seq + sizeof(request);
    const u32_t server_end = server_seq + RESPONSE_LEN + 1;
    inject_tcp(peer_seq + 1, server_seq, TCP_ACK | TCP_PSH, request, sizeof(request) - 1);
    CHECK(requests == 1 && data_attempts == 1);
    CHECK(first_data.seq == server_seq && first_data.ack == peer_end);
    CHECK((first_data.flags & (TCP_ACK | TCP_FIN)) == (TCP_ACK | TCP_FIN));
    CHECK(first_data.len == RESPONSE_LEN);
    CHECK(memcmp(first_data.payload, header, sizeof(header) - 1) == 0);
    CHECK(memcmp(first_data.payload + sizeof(header) - 1, body, sizeof(body) - 1) == 0);
    CHECK(client_pcb->state == FIN_WAIT_1 && client_pcb->unacked != NULL);

    if (lose_response) {
        CHECK(data_delivered == 0);
        inject_tcp(peer_seq + 1, server_seq, TCP_ACK | TCP_PSH, request, sizeof(request) - 1);
        CHECK(requests == 1 && data_attempts == 1);
        CHECK(last_packet.flags == TCP_ACK && last_packet.len == 0);
        CHECK(last_packet.seq == server_end && last_packet.ack == peer_end);

        const unsigned limit = 2 * client_pcb->rto + 2;
        for (unsigned i = 0; i < limit && data_delivered == 0; ++i) {
            advance(TCP_TMR_INTERVAL);
        }
        CHECK(data_attempts == 2 && data_delivered == 1);
        CHECK(last_packet.seq == first_data.seq && last_packet.ack == first_data.ack);
        CHECK(last_packet.flags == first_data.flags && last_packet.len == first_data.len);
        CHECK(memcmp(last_packet.payload, first_data.payload, first_data.len) == 0);
    } else {
        CHECK(data_delivered == 1);
    }

    inject_tcp(peer_end, server_end, TCP_ACK | TCP_FIN, NULL, 0);
    CHECK(last_packet.flags == TCP_ACK && last_packet.ack == peer_end + 1);
    CHECK(tcp_active_pcbs == NULL && tcp_tw_pcbs == client_pcb);
    CHECK(tcp_tw_pcbs->state == TIME_WAIT);
    if (!lose_response) {
        /* Use the no-loss path to test cleanup even when retransmission is broken. */
        advance(TCP_TMR_INTERVAL);
        CHECK(tcp_tw_pcbs == client_pcb);
        for (unsigned ms = TCP_TMR_INTERVAL; ms < 2 * TCP_MSL + TCP_TMR_INTERVAL;
             ms += TCP_TMR_INTERVAL) {
            advance(TCP_TMR_INTERVAL);
        }
        CHECK(tcp_tw_pcbs == NULL);
    }
    CHECK(tcp_close(listener) == ERR_OK);
}

static bool dhcp_authorized;
static unsigned dhcp_early, dhcp_delivered;
static u8_t dhcp_last_type;
static void (*dhcp_output_hook)(void);

static err_t dhcp_output(struct netif *iface, struct pbuf *p, const ip4_addr_t *dst)
{
    struct ip_hdr ip;
    u8_t option[3];
    LWIP_UNUSED_ARG(iface);
    LWIP_UNUSED_ARG(dst);
    CHECK(pbuf_copy_partial(p, &ip, sizeof(ip), 0) == sizeof(ip));
    CHECK(IPH_PROTO(&ip) == IP_PROTO_UDP);
    const u16_t offset = IPH_HL_BYTES(&ip) + UDP_HLEN + offsetof(struct dhcp_msg, options);
    CHECK(pbuf_copy_partial(p, option, sizeof(option), offset) == sizeof(option));
    CHECK(option[0] == DHCP_OPTION_MESSAGE_TYPE && option[1] == 1);
    dhcp_last_type = option[2];
    if (!dhcp_authorized) {
        ++dhcp_early;
        return ERR_IF;
    }
    ++dhcp_delivered;
    if (dhcp_output_hook != NULL) {
        dhcp_output_hook();
    }
    return ERR_OK;
}

static err_t setup_dhcp_netif(struct netif *iface)
{
    iface->mtu = 1500;
    iface->flags = NETIF_FLAG_BROADCAST;
    iface->hwaddr_len = 6;
    iface->hwaddr[0] = 2;
    iface->output = dhcp_output;
    return ERR_OK;
}

static void deliver_dhcp_reply(u8_t type, u32_t xid, const ip4_addr_t *lease,
                               const ip4_addr_t *router)
{
    const u16_t len = IP_HLEN + UDP_HLEN + sizeof(struct dhcp_msg);
    struct pbuf *p = pbuf_alloc(PBUF_RAW, len, PBUF_RAM);
    CHECK(p != NULL && p->len == len);
    memset(p->payload, 0, len);
    struct ip_hdr *ip = p->payload;
    struct udp_hdr *udp = (void *)((u8_t *)p->payload + IP_HLEN);
    struct dhcp_msg *dhcp = (void *)((u8_t *)p->payload + IP_HLEN + UDP_HLEN);
    IPH_VHL_SET(ip, 4, IP_HLEN / 4);
    IPH_LEN_SET(ip, lwip_htons(len));
    IPH_TTL_SET(ip, 64);
    IPH_PROTO_SET(ip, IP_PROTO_UDP);
    ip4_addr_copy(ip->src, *router);
    ip->dest.addr = PP_HTONL(0xFFFFFFFFUL);
    IPH_CHKSUM_SET(ip, inet_chksum(ip, IP_HLEN));
    udp->src = lwip_htons(67);
    udp->dest = lwip_htons(68);
    udp->len = lwip_htons(len - IP_HLEN);
    dhcp->op = DHCP_BOOTREPLY;
    dhcp->htype = 1;
    dhcp->hlen = netif.hwaddr_len;
    dhcp->xid = lwip_htonl(xid);
    dhcp->cookie = lwip_htonl(DHCP_MAGIC_COOKIE);
    ip4_addr_copy(dhcp->yiaddr, *lease);
    memcpy(dhcp->chaddr, netif.hwaddr, netif.hwaddr_len);
    const u8_t options[] = {
        DHCP_OPTION_MESSAGE_TYPE, 1, type,
        DHCP_OPTION_SERVER_ID, 4, 192, 0, 2, 126,
        DHCP_OPTION_SUBNET_MASK, 4, 255, 255, 255, 128,
        DHCP_OPTION_ROUTER, 4, 192, 0, 2, 126,
        DHCP_OPTION_LEASE_TIME, 4, 0, 0, 14, 16,
        DHCP_OPTION_END
    };
    memcpy(dhcp->options, options, sizeof(options));
    CHECK(ip4_input(p, &netif) == ERR_OK);
}

static struct lwip_cyclic_timer *find_cyclic(lwip_cyclic_timer_handler handler)
{
    for (int i = 0; i < lwip_num_cyclic_timers; ++i) {
        if (lwip_cyclic_timers[i].handler == handler) {
            return &lwip_cyclic_timers[i];
        }
    }
    CHECK(0);
    return NULL;
}

static void check_cyclic(lwip_cyclic_timer_handler handler, bool armed, u32_t due)
{
    struct lwip_cyclic_timer *cyclic = find_cyclic(handler);
    unsigned matches = 0, nodes = 0;
    for (struct sys_timeo *t = *sys_timeouts_get_next_timeout(); t != NULL; t = t->next) {
        CHECK(++nodes <= (unsigned)lwip_num_cyclic_timers + 1);
        if (t->h == lwip_cyclic_timer && t->arg == cyclic) {
            CHECK(t->time == due);
            ++matches;
        }
    }
    CHECK(matches == (unsigned)armed);
    CHECK(cyclic->status == (armed ? LWIP_TIMER_STATUS_RUNNING : LWIP_TIMER_STATUS_IDLE));
}

static void check_tcp_timer_oom(void)
{
    lwip_cyclic_timer_handler tcp = lwip_cyclic_timers[0].handler;
    check_cyclic(tcp, false, 0);
    fail_timeout_alloc = true;
    tcp_timer_needed();
    CHECK(timeout_alloc_attempts == 1);
    check_cyclic(tcp, false, 0);

    fail_timeout_alloc = false;
    tcp_timer_needed();
    check_cyclic(tcp, true, now_ms + TCP_TMR_INTERVAL);
    fail_timeout_alloc = true;
    advance(TCP_TMR_INTERVAL);
    CHECK(timeout_alloc_attempts == 3);
    check_cyclic(tcp, false, 0);

    fail_timeout_alloc = false;
    tcp_timer_needed();
    check_cyclic(tcp, true, now_ms + TCP_TMR_INTERVAL);
}

static void check_dhcp_timer_self_stop(void)
{
    advance(DHCP_FINE_TIMER_MSECS);
    check_cyclic(dhcp_fine_tmr, false, 0);
    advance(DHCP_COARSE_TIMER_MSECS - DHCP_FINE_TIMER_MSECS);
    check_cyclic(dhcp_coarse_tmr, false, 0);
}

static unsigned one_shot_calls;

static void record_one_shot(void *arg)
{
    CHECK(find_cyclic(dhcp_fine_tmr)->status == LWIP_TIMER_STATUS_IDLE);
    CHECK(++one_shot_calls == *(const unsigned *)arg);
}

static void check_mixed_timers(void)
{
    unsigned first = 1, second = 2, cancelled = 3;
    sys_timeout(DHCP_FINE_TIMER_MSECS / 2, record_one_shot, &cancelled);
    sys_timeout(DHCP_FINE_TIMER_MSECS, record_one_shot, &first);
    sys_timeout(DHCP_FINE_TIMER_MSECS, record_one_shot, &second);
    sys_untimeout(record_one_shot, &cancelled);
    CHECK(sys_timeouts_sleeptime() == DHCP_FINE_TIMER_MSECS);
    advance(DHCP_FINE_TIMER_MSECS - 1);
    CHECK(one_shot_calls == 0);
    advance(1);
    CHECK(one_shot_calls == 2);
    check_cyclic(dhcp_fine_tmr, false, 0);
}

static void check_dhcp_timer_reenable(void)
{
    advance(17);
    sys_timeouts_set_timer_enable(false, dhcp_fine_tmr);
    sys_timeouts_set_timer_enable(false, dhcp_coarse_tmr);
    sys_timeouts_set_timer_enable(false, dhcp_fine_tmr);
    check_cyclic(dhcp_fine_tmr, false, 0);
    check_cyclic(dhcp_coarse_tmr, false, 0);
    sys_timeouts_set_timer_enable(true, dhcp_fine_tmr);
    sys_timeouts_set_timer_enable(true, dhcp_coarse_tmr);
    const u32_t fine_due = now_ms + DHCP_FINE_TIMER_MSECS;
    const u32_t coarse_due = now_ms + DHCP_COARSE_TIMER_MSECS;
    advance(DHCP_FINE_TIMER_MSECS - 17);  /* The cancelled fine deadline. */
    sys_timeouts_set_timer_enable(true, dhcp_fine_tmr);  /* Already armed. */
    check_cyclic(dhcp_fine_tmr, true, fine_due);
    check_cyclic(dhcp_coarse_tmr, true, coarse_due);
    advance(17);  /* New fine deadline crosses sys_now() rollover. */
    check_cyclic(dhcp_fine_tmr, false, 0);
    advance(DHCP_COARSE_TIMER_MSECS - DHCP_FINE_TIMER_MSECS - 17);
    check_cyclic(dhcp_coarse_tmr, true, coarse_due);
    advance(17);
    check_cyclic(dhcp_coarse_tmr, false, 0);
}

static void restart_fine_on_output(void)
{
    CHECK(dhcp_last_type == DHCP_DISCOVER);
    dhcp_output_hook = NULL;
    now_ms += 7;
    sys_timeouts_set_timer_enable(false, dhcp_fine_tmr);
    check_cyclic(dhcp_fine_tmr, false, 0);
    sys_timeouts_set_timer_enable(true, dhcp_fine_tmr);
    check_cyclic(dhcp_fine_tmr, true, now_ms + DHCP_FINE_TIMER_MSECS);
}

static void check_dhcp_timer_under_load(bool restart_in_callback)
{
    ip4_addr_t zero, lease, router;
    ip4_addr_set_zero(&zero);
    IP4_ADDR(&lease, 192, 0, 2, 7);
    IP4_ADDR(&router, 192, 0, 2, 126);
    if (!restart_in_callback) {
        check_dhcp_timer_self_stop();  /* Exercise fresh arms as well as init and rearm. */
    }
    CHECK(netif_add(&netif, &zero, &zero, &zero, NULL, setup_dhcp_netif, ip4_input) == &netif);
    netif_set_up(&netif);
    netif_set_link_up(&netif);
    dhcp_authorized = true;
    CHECK(dhcp_start(&netif) == ERR_OK && dhcp_delivered == 1);
    struct dhcp *client = netif_dhcp_data(&netif);
    CHECK(client != NULL && client->request_timeout >= 1);
    check_cyclic(dhcp_fine_tmr, true, now_ms + DHCP_FINE_TIMER_MSECS);
    const u16_t ticks = client->request_timeout;
    advance(DHCP_FINE_TIMER_MSECS - 1);
    CHECK(client->request_timeout == ticks && dhcp_delivered == 1);
    if (restart_in_callback) {
        dhcp_output_hook = restart_fine_on_output;
    }
    advance(1);
    for (u16_t remaining = ticks - 1; remaining != 0; --remaining) {
        CHECK(client->request_timeout == remaining && dhcp_delivered == 1);
        advance(DHCP_FINE_TIMER_MSECS);
    }
    CHECK(dhcp_delivered == 2 && dhcp_output_hook == NULL);
    check_cyclic(dhcp_fine_tmr, true, now_ms + DHCP_FINE_TIMER_MSECS);

    deliver_dhcp_reply(DHCP_OFFER, client->xid, &lease, &router);
    deliver_dhcp_reply(DHCP_ACK, client->xid, &lease, &router);
    CHECK(dhcp_supplied_address(&netif));
    if (!restart_in_callback) {
        check_cyclic(dhcp_coarse_tmr, true, now_ms + DHCP_COARSE_TIMER_MSECS);
    }
    CHECK(client->t0_timeout != 0);
    client->lease_used = client->t0_timeout - 1;
    advance(DHCP_COARSE_TIMER_MSECS);
    CHECK(!dhcp_supplied_address(&netif) && dhcp_last_type == DHCP_DISCOVER);
    check_cyclic(dhcp_coarse_tmr, false, 0);
    if (fail_timeout_alloc) {
        CHECK(timeout_alloc_attempts == 0);
    }
    dhcp_stop(&netif);
    dhcp_cleanup(&netif);
    netif_remove(&netif);
}

static void check_dhcp_lease_authority(void)
{
    ip4_addr_t zero, lease, mask, router;
    ip4_addr_set_zero(&zero);
    IP4_ADDR(&lease, 192, 0, 2, 7);
    IP4_ADDR(&mask, 255, 255, 255, 128);
    IP4_ADDR(&router, 192, 0, 2, 126);
    CHECK(netif_add(&netif, &zero, &zero, &zero, NULL, setup_dhcp_netif, ip4_input) == &netif);
    netif_set_up(&netif);
    netif_set_link_up(&netif);
    dhcp_authorized = true;
    CHECK(dhcp_start(&netif) == ERR_OK && dhcp_last_type == DHCP_DISCOVER);
    struct dhcp *client = netif_dhcp_data(&netif);
    CHECK(client != NULL && client->state == DHCP_STATE_SELECTING);

    deliver_dhcp_reply(DHCP_OFFER, client->xid, &lease, &router);
    CHECK(client->state == DHCP_STATE_REQUESTING && dhcp_last_type == DHCP_REQUEST);
    CHECK(!dhcp_supplied_address(&netif) && ip4_addr_isany(netif_ip4_addr(&netif)));
    deliver_dhcp_reply(DHCP_ACK, client->xid + 1, &lease, &router);
    CHECK(!dhcp_supplied_address(&netif) && ip4_addr_isany(netif_ip4_addr(&netif)));
    deliver_dhcp_reply(DHCP_ACK, client->xid, &lease, &router);
    CHECK(dhcp_supplied_address(&netif) && ip4_addr_cmp(netif_ip4_addr(&netif), &lease));
    CHECK(ip4_addr_cmp(netif_ip4_netmask(&netif), &mask));
    CHECK(ip4_addr_cmp(netif_ip4_gw(&netif), &router));
    struct tcp_pcb *listener = tcp_new();
    CHECK(listener != NULL && tcp_bind(listener, IP_ADDR_ANY, HTTP_PORT) == ERR_OK);
    listener = tcp_listen(listener);
    CHECK(listener != NULL);

    CHECK(dhcp_renew(&netif) == ERR_OK && client->state == DHCP_STATE_RENEWING);
    CHECK(dhcp_supplied_address(&netif) && ip4_addr_cmp(netif_ip4_addr(&netif), &lease));
    CHECK(client->t0_timeout != 0);
    client->lease_used = client->t0_timeout - 1;
    client->t1_renew_time = client->t2_rebind_time = 1;
    deliver_dhcp_reply(DHCP_NAK, client->xid, &zero, &router);
    CHECK(netif_is_link_up(&netif) && client->state == DHCP_STATE_SELECTING);
    CHECK(!dhcp_supplied_address(&netif) && ip4_addr_isany(netif_ip4_addr(&netif)));
    CHECK(dhcp_last_type == DHCP_DISCOVER);
    const u32_t replacement_xid = client->xid;
    const unsigned sends = dhcp_delivered;
    dhcp_coarse_tmr();
    CHECK(client->state == DHCP_STATE_SELECTING && client->xid == replacement_xid);
    CHECK(dhcp_delivered == sends && client->lease_used == 0 && client->t0_timeout == 0);
    CHECK(client->t1_timeout == 0 && client->t1_renew_time == 0 &&
          client->t2_timeout == 0 && client->t2_rebind_time == 0);

    IP4_ADDR(&lease, 192, 0, 2, 8);
    deliver_dhcp_reply(DHCP_OFFER, client->xid, &lease, &router);
    deliver_dhcp_reply(DHCP_ACK, client->xid, &lease, &router);
    CHECK(dhcp_supplied_address(&netif) && ip4_addr_cmp(netif_ip4_addr(&netif), &lease));
    CHECK(client->t0_timeout != 0);
    client->lease_used = client->t0_timeout - 1;
    dhcp_coarse_tmr();
    CHECK(netif_is_link_up(&netif) && client->state == DHCP_STATE_SELECTING);
    CHECK(!dhcp_supplied_address(&netif) && ip4_addr_isany(netif_ip4_addr(&netif)));
    CHECK(dhcp_last_type == DHCP_DISCOVER);
    CHECK(listener->state == LISTEN && ip_addr_isany(&listener->local_ip));
    CHECK(tcp_close(listener) == ERR_OK);
    dhcp_stop(&netif);
    dhcp_cleanup(&netif);
    netif_remove(&netif);
}

static void check_reconnect_dhcp(bool stop_old_client)
{
    ip4_addr_t lease, zero;
    IP4_ADDR(&lease, 192, 0, 2, 7);
    ip4_addr_set_zero(&zero);
    CHECK(netif_add(&netif, &zero, &zero, &zero, NULL, setup_dhcp_netif, ip4_input) == &netif);
    netif_set_up(&netif);
    netif_set_link_up(&netif);
    dhcp_authorized = true;
    CHECK(dhcp_start(&netif) == ERR_OK);
    struct dhcp *client = netif_dhcp_data(&netif);
    CHECK(client != NULL);
    client->state = DHCP_STATE_BOUND;
    ip4_addr_copy(client->offered_ip_addr, lease);
    netif_set_ipaddr(&netif, &lease);

    if (stop_old_client) dhcp_stop(&netif);
    netif_set_link_down(&netif);
    netif_set_addr(&netif, &zero, &zero, &zero);
    dhcp_early = dhcp_delivered = 0;
    dhcp_authorized = false;
    netif_set_link_up(&netif);
    CHECK(ip4_addr_isany(netif_ip4_addr(&netif)) && !dhcp_supplied_address(&netif));
    if (stop_old_client) {
        CHECK(dhcp_early == 0 && client->state == DHCP_STATE_OFF);
        dhcp_authorized = true;
        CHECK(dhcp_start(&netif) == ERR_OK);
        CHECK(dhcp_delivered == 1 && dhcp_last_type == DHCP_DISCOVER);
    } else {
        CHECK(dhcp_early == 1 && dhcp_last_type == DHCP_REQUEST &&
              client->state == DHCP_STATE_REBOOTING);
        const u16_t ticks = client->request_timeout;
        CHECK(ticks == bl808_lwip_dhcp_retry_ms(client->xid, now_ms, 1, DHCP_STATE_REBOOTING) /
              DHCP_FINE_TIMER_MSECS && ticks >= 6 && ticks <= 10);
        dhcp_authorized = true;
        for (u16_t remaining = ticks; remaining > 1; --remaining) {
            dhcp_fine_tmr();
            CHECK(dhcp_delivered == 0);
        }
        dhcp_fine_tmr();
        CHECK(dhcp_delivered == 1 && dhcp_last_type == DHCP_REQUEST);
    }
    CHECK(!dhcp_supplied_address(&netif)); /* Neither path can publish before an ACK. */
    dhcp_stop(&netif);
    dhcp_cleanup(&netif);
    netif_remove(&netif);
}

static void check_dhcp_backoff(void)
{
    ip4_addr_t zero, lease, router;
    ip4_addr_set_zero(&zero);
    IP4_ADDR(&lease, 192, 0, 2, 7);
    IP4_ADDR(&router, 192, 0, 2, 126);
    CHECK(netif_add(&netif, &zero, &zero, &zero, NULL, setup_dhcp_netif, ip4_input) == &netif);
    netif_set_up(&netif);
    netif_set_link_up(&netif);
    dhcp_authorized = true;
    CHECK(dhcp_start(&netif) == ERR_OK);
    struct dhcp *client = netif_dhcp_data(&netif);
    CHECK(client != NULL);
    const u32_t xid = client->xid;
    for (u8_t attempt = 1; attempt <= 7; ++attempt) {
        CHECK(client->state == DHCP_STATE_SELECTING && client->xid == xid);
        CHECK(client->tries == attempt && dhcp_delivered == attempt);
        const u16_t center = (u16_t)(4000U << (attempt < 5 ? attempt - 1 : 4));
        const u16_t ticks = client->request_timeout;
        const unsigned ms = ticks * DHCP_FINE_TIMER_MSECS;
        CHECK(ms >= center - 1000U && ms <= center + 1000U && ms <= 64000U);
        CHECK(ms == bl808_lwip_dhcp_retry_ms(xid, now_ms, attempt, DHCP_STATE_SELECTING));
        if (attempt == 7) break;
        for (u16_t remaining = ticks; remaining > 1; --remaining) {
            advance(DHCP_FINE_TIMER_MSECS);
            CHECK(dhcp_delivered == attempt);
        }
        advance(DHCP_FINE_TIMER_MSECS);
    }
    deliver_dhcp_reply(DHCP_OFFER, xid, &lease, &router);
    CHECK(client->state == DHCP_STATE_REQUESTING && client->tries == 1 && client->xid == xid);
    CHECK(client->request_timeout * DHCP_FINE_TIMER_MSECS ==
          bl808_lwip_dhcp_retry_ms(xid, now_ms, 1, DHCP_STATE_REQUESTING));
    unsigned choices = 0;
    for (u32_t sample = 0; sample < 100; ++sample) {
        const unsigned ms = bl808_lwip_dhcp_retry_ms(xid + sample, now_ms, 1, DHCP_STATE_SELECTING);
        CHECK(ms >= 3000U && ms <= 5000U && ms % 500U == 0);
        choices |= 1U << ((ms - 3000U) / 500U);
    }
    CHECK(choices == 0x1f);
    dhcp_stop(&netif);
    dhcp_cleanup(&netif);
    netif_remove(&netif);
}

int main(int argc, char **argv)
{
    CHECK(argc == 2);
    if (strcmp(argv[1], "dhcp-timer-reenable") == 0) {
        now_ms = UINT32_MAX - DHCP_FINE_TIMER_MSECS - 4;
    }
    fail_timeout_alloc = strcmp(argv[1], "dhcp-timer-oom") == 0;
    lwip_init();
    if (strcmp(argv[1], "periodic") == 0) {
        check_periodic();
    } else if (strcmp(argv[1], "subtick") == 0) {
        check_subtick();
    } else if (strcmp(argv[1], "rollover") == 0) {
        check_rollover();
    } else if (strcmp(argv[1], "tcp-timer-oom") == 0) {
        check_tcp_timer_oom();
    } else if (strcmp(argv[1], "retransmit") == 0) {
        check_http(true);
    } else if (strcmp(argv[1], "time-wait") == 0) {
        check_http(false);
    } else if (strcmp(argv[1], "dhcp-retained") == 0) {
        check_reconnect_dhcp(false);
    } else if (strcmp(argv[1], "dhcp-after-wpa") == 0) {
        check_reconnect_dhcp(true);
    } else if (strcmp(argv[1], "dhcp-lease-authority") == 0) {
        check_dhcp_lease_authority();
    } else if (strcmp(argv[1], "dhcp-backoff") == 0) {
        check_dhcp_backoff();
    } else if (strcmp(argv[1], "dhcp-timer-self-stop") == 0) {
        check_dhcp_timer_self_stop();
    } else if (strcmp(argv[1], "mixed-timers") == 0) {
        check_mixed_timers();
    } else if (strcmp(argv[1], "dhcp-timer-reenable") == 0) {
        check_dhcp_timer_reenable();
    } else if (strcmp(argv[1], "dhcp-timer-restart-callback") == 0 || fail_timeout_alloc) {
        check_dhcp_timer_under_load(!fail_timeout_alloc);
    } else {
        CHECK(0);
    }
    return 0;
}
"""


@pytest.fixture(scope="module")
def tcp_timer_program(tmp_path_factory: pytest.TempPathFactory) -> Path:
    if not (SDK / "core/tcp.c").is_file():
        pytest.skip("requires the pinned bl_iot_sdk_b773b3f checkout under build/")
    cc = shlex.split(os.environ.get("CC", "cc"))
    if not cc or shutil.which(cc[0]) is None:
        pytest.skip("requires a host C compiler")
    nim = shutil.which("nim")
    if nim is None:
        pytest.fail("requires Nim to build the production DHCP backoff hook")

    work = tmp_path_factory.mktemp("wifi_lwip_tcp_timers")
    (work / "arch").mkdir()
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
    driver = work / "tcp_timer_driver.c"
    driver.write_text(DRIVER, encoding="ascii")
    timeouts = work / "timeouts_under_test.c"
    timeouts.write_text(
        '#include "lwip/memp.h"\n'
        'void *test_memp_malloc(memp_t type);\n'
        '#define memp_malloc test_memp_malloc\n'
        f'#include "{KERNEL / "lwip_wifi_smoke/timeouts.c"}"\n',
        encoding="ascii",
    )
    binary = work / "tcp_timer_driver"
    policy = work / "libdhcp_policy.a"
    result = subprocess.run(
        [nim, "c", "--app:staticlib", "--skipProjCfg:on", "--skipParentCfg:on", "--skipUserCfg:on",
         f"--nimcache:{work / 'nimcache'}", f"-o:{policy}", "-d:release",
         str(ROOT / "src/bl808/wifi/support/runtime_facade_parts/dhcp_retry.nim")],
        capture_output=True, text=True, timeout=60, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr

    sdk_sources = (
        "core/init.c", "core/def.c", "core/mem.c", "core/memp.c", "core/pbuf.c",
        "core/netif.c", "core/ip.c", "core/raw.c", "core/udp.c", "core/inet_chksum.c",
        "core/sys.c", "core/ipv4/ip4.c", "core/ipv4/ip4_addr.c",
        "core/ipv4/icmp.c", "core/ipv4/etharp.c", "netif/ethernet.c",
    )
    result = subprocess.run(
        [*cc, "-std=gnu11", "-DLWIP_TESTMODE=1", "-I", str(work), "-I", str(HTTP), "-I", str(SDK / "include"),
         "-include", str(HTTP / "lwipopts.h"), "-o", str(binary), str(driver),
         str(timeouts),
         *(str(HTTP / f"{name}_enabled.c") for name in ("tcp", "tcp_in", "tcp_out")),
         *(str(SDK / source) for source in sdk_sources),
         str(KERNEL / "lwip_wifi_smoke/dhcp_seeded.c"), str(policy)],
        capture_output=True, text=True, timeout=60, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    return binary


@pytest.mark.parametrize("case", ("periodic", "subtick", "rollover", "retransmit", "time-wait", "tcp-timer-oom"))
def test_wifi_lwip_tcp_timers(tcp_timer_program: Path, case: str) -> None:
    result = subprocess.run([str(tcp_timer_program), case], capture_output=True,
                            text=True, timeout=10, check=False)
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.parametrize("case", (
    "dhcp-retained", "dhcp-after-wpa", "dhcp-lease-authority", "dhcp-backoff",
    "dhcp-timer-self-stop", "dhcp-timer-reenable", "dhcp-timer-restart-callback", "dhcp-timer-oom",
    "mixed-timers",
))
def test_wifi_lwip_dhcp_lifecycle(tcp_timer_program: Path, case: str) -> None:
    result = subprocess.run([str(tcp_timer_program), case], capture_output=True,
                            text=True, timeout=10, check=False)
    assert result.returncode == 0, result.stdout + result.stderr

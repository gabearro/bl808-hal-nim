/*
 * Cooperative NO_SYS lwIP timer core for BL808 WiFi smoke images.
 *
 * The SDK timeouts.c carries a Bouffalo TCP low-power helper that is compiled
 * even when LWIP_TCP=0. This file keeps the normal lwIP timeout algorithm while
 * matching the SDK's mutable cyclic-timer struct layout.
 */

#include "lwip/opt.h"
#include "lwip/timeouts.h"
#include "lwip/def.h"
#include "lwip/memp.h"
#include "lwip/sys.h"
#include "lwip/ip4_frag.h"
#include "lwip/etharp.h"
#include "lwip/dhcp.h"
#include "lwip/autoip.h"
#include "lwip/igmp.h"
#include "lwip/dns.h"
#include "lwip/nd6.h"
#include "lwip/ip6_frag.h"
#include "lwip/mld6.h"
#include "lwip/dhcp6.h"
#include "lwip/pbuf.h"
#if LWIP_TCP
#include "lwip/priv/tcp_priv.h"
#endif

#if LWIP_DEBUG_TIMERNAMES
#define HANDLER(x) x, #x
#else
#define HANDLER(x) x
#endif

#define LWIP_MAX_TIMEOUT 0x7fffffff
#define TIME_LESS_THAN(t, compare_to) ((((u32_t)((t) - (compare_to))) > LWIP_MAX_TIMEOUT) ? 1 : 0)

struct lwip_cyclic_timer lwip_cyclic_timers[] = {
#if LWIP_TCP
  {LWIP_TIMER_STATUS_RUNNING, TCP_TMR_INTERVAL, HANDLER(tcp_tmr)},
#endif
#if LWIP_IPV4
#if IP_REASSEMBLY
  {LWIP_TIMER_STATUS_RUNNING, IP_TMR_INTERVAL, HANDLER(ip_reass_tmr)},
#endif
#if LWIP_ARP
  {LWIP_TIMER_STATUS_RUNNING, ARP_TMR_INTERVAL, HANDLER(etharp_tmr)},
#endif
#if LWIP_DHCP
  {LWIP_TIMER_STATUS_RUNNING, DHCP_COARSE_TIMER_MSECS, HANDLER(dhcp_coarse_tmr)},
  {LWIP_TIMER_STATUS_RUNNING, DHCP_FINE_TIMER_MSECS, HANDLER(dhcp_fine_tmr)},
#endif
#if LWIP_AUTOIP
  {LWIP_TIMER_STATUS_RUNNING, AUTOIP_TMR_INTERVAL, HANDLER(autoip_tmr)},
#endif
#if LWIP_IGMP
  {LWIP_TIMER_STATUS_RUNNING, IGMP_TMR_INTERVAL, HANDLER(igmp_tmr)},
#endif
#endif
#if LWIP_DNS
  {LWIP_TIMER_STATUS_RUNNING, DNS_TMR_INTERVAL, HANDLER(dns_tmr)},
#endif
#if LWIP_IPV6
  {LWIP_TIMER_STATUS_RUNNING, ND6_TMR_INTERVAL, HANDLER(nd6_tmr)},
#if LWIP_IPV6_REASS
  {LWIP_TIMER_STATUS_RUNNING, IP6_REASS_TMR_INTERVAL, HANDLER(ip6_reass_tmr)},
#endif
#if LWIP_IPV6_MLD
  {LWIP_TIMER_STATUS_RUNNING, MLD6_TMR_INTERVAL, HANDLER(mld6_tmr)},
#endif
#if LWIP_IPV6_DHCP6
  {LWIP_TIMER_STATUS_RUNNING, DHCP6_TIMER_MSECS, HANDLER(dhcp6_tmr)},
#endif
#endif
};

const int lwip_num_cyclic_timers = LWIP_ARRAYSIZE(lwip_cyclic_timers);

#if LWIP_TIMERS && !LWIP_TIMERS_CUSTOM

static struct sys_timeo *next_timeout;
static u32_t current_timeout_due_time;

#if LWIP_TESTMODE
struct sys_timeo **sys_timeouts_get_next_timeout(void)
{
  return &next_timeout;
}
#endif

#if LWIP_DEBUG_TIMERNAMES
static void sys_timeout_abs(u32_t abs_time, sys_timeout_handler handler,
                            void *arg, const char *handler_name)
#else
static void sys_timeout_abs(u32_t abs_time, sys_timeout_handler handler,
                            void *arg)
#endif
{
  struct sys_timeo *timeout = (struct sys_timeo *)memp_malloc(MEMP_SYS_TIMEOUT);
  struct sys_timeo *t;

  LWIP_ASSERT("sys_timeout: pool MEMP_SYS_TIMEOUT is empty", timeout != NULL);
  if (timeout == NULL) {
    return;
  }

  timeout->next = NULL;
  timeout->time = abs_time;
  timeout->h = handler;
  timeout->arg = arg;
#if LWIP_DEBUG_TIMERNAMES
  timeout->handler_name = handler_name;
#endif

  if (next_timeout == NULL || TIME_LESS_THAN(abs_time, next_timeout->time)) {
    timeout->next = next_timeout;
    next_timeout = timeout;
    return;
  }

  for (t = next_timeout; t->next != NULL; t = t->next) {
    if (TIME_LESS_THAN(abs_time, t->next->time)) {
      break;
    }
  }
  timeout->next = t->next;
  t->next = timeout;
}

void lwip_cyclic_timer(void *arg)
{
  u32_t now;
  u32_t next_timeout_time;
  struct lwip_cyclic_timer *cyclic = (struct lwip_cyclic_timer *)arg;

  if (cyclic->status == LWIP_TIMER_STATUS_STOPPING) {
    cyclic->status = LWIP_TIMER_STATUS_IDLE;
    return;
  }
  if (cyclic->status != LWIP_TIMER_STATUS_RUNNING) {
    return;
  }

  cyclic->handler();

  now = sys_now();
  next_timeout_time = (u32_t)(current_timeout_due_time + cyclic->interval_ms);
  if (TIME_LESS_THAN(next_timeout_time, now)) {
    next_timeout_time = (u32_t)(now + cyclic->interval_ms);
  }
#if LWIP_DEBUG_TIMERNAMES
  sys_timeout_abs(next_timeout_time, lwip_cyclic_timer, arg, cyclic->handler_name);
#else
  sys_timeout_abs(next_timeout_time, lwip_cyclic_timer, arg);
#endif
}

void sys_timeouts_init(void)
{
  size_t i;
  for (i = (LWIP_TCP ? 1 : 0); i < LWIP_ARRAYSIZE(lwip_cyclic_timers); i++) {
    if (lwip_cyclic_timers[i].status == LWIP_TIMER_STATUS_RUNNING) {
      sys_timeout(lwip_cyclic_timers[i].interval_ms, lwip_cyclic_timer,
                  LWIP_CONST_CAST(void *, &lwip_cyclic_timers[i]));
    }
  }
}

#if LWIP_TCP
static bool tcp_timer_pending;

void tcpip_tmr_compensate_tick(void)
{
}

void tcp_timer_needed(void)
{
  if (!tcp_timer_pending) {
    tcp_timer_pending = true;
    sys_timeout(TCP_TMR_INTERVAL, lwip_cyclic_timer,
                LWIP_CONST_CAST(void *, &lwip_cyclic_timers[0]));
  }
}

void tcp_keepalive_timer_start(struct tcp_pcb *pcb)
{
  LWIP_UNUSED_ARG(pcb);
}

void tcp_keepalive_timer_stop(struct tcp_pcb *pcb)
{
  LWIP_UNUSED_ARG(pcb);
}
#endif

#if LWIP_DEBUG_TIMERNAMES
void sys_timeout_debug(u32_t msecs, sys_timeout_handler handler, void *arg,
                       const char *handler_name)
#else
void sys_timeout(u32_t msecs, sys_timeout_handler handler, void *arg)
#endif
{
  LWIP_ASSERT("Timeout time too long", msecs <= (LWIP_UINT32_MAX / 4));
#if LWIP_DEBUG_TIMERNAMES
  sys_timeout_abs((u32_t)(sys_now() + msecs), handler, arg, handler_name);
#else
  sys_timeout_abs((u32_t)(sys_now() + msecs), handler, arg);
#endif
}

void sys_untimeout(sys_timeout_handler handler, void *arg)
{
  struct sys_timeo *prev_t = NULL;
  struct sys_timeo *t = next_timeout;

  while (t != NULL) {
    if (t->h == handler && t->arg == arg) {
      if (prev_t == NULL) {
        next_timeout = t->next;
      } else {
        prev_t->next = t->next;
      }
      memp_free(MEMP_SYS_TIMEOUT, t);
      return;
    }
    prev_t = t;
    t = t->next;
  }
}

void sys_check_timeouts(void)
{
  u32_t now = sys_now();

  while (next_timeout != NULL && !TIME_LESS_THAN(now, next_timeout->time)) {
    struct sys_timeo *tmptimeout = next_timeout;
    sys_timeout_handler handler = tmptimeout->h;
    void *arg = tmptimeout->arg;

    PBUF_CHECK_FREE_OOSEQ();
    next_timeout = tmptimeout->next;
    current_timeout_due_time = tmptimeout->time;
    memp_free(MEMP_SYS_TIMEOUT, tmptimeout);
    if (handler != NULL) {
      handler(arg);
    }
  }
}

void sys_restart_timeouts(void)
{
  u32_t now;
  u32_t base;
  struct sys_timeo *t;

  if (next_timeout == NULL) {
    return;
  }
  now = sys_now();
  base = next_timeout->time;
  for (t = next_timeout; t != NULL; t = t->next) {
    t->time = (t->time - base) + now;
  }
}

u32_t sys_timeouts_sleeptime(void)
{
  u32_t now;

  if (next_timeout == NULL) {
    return SYS_TIMEOUTS_SLEEPTIME_INFINITE;
  }
  now = sys_now();
  if (TIME_LESS_THAN(next_timeout->time, now)) {
    return 0;
  }
  return (u32_t)(next_timeout->time - now);
}

void sys_timeouts_set_timer_enable(bool enable, lwip_cyclic_timer_handler handler)
{
  size_t i;
  for (i = (LWIP_TCP ? 1 : 0); i < LWIP_ARRAYSIZE(lwip_cyclic_timers); i++) {
    if (lwip_cyclic_timers[i].handler == handler) {
      if (enable) {
        if (lwip_cyclic_timers[i].status == LWIP_TIMER_STATUS_IDLE) {
          sys_timeout(lwip_cyclic_timers[i].interval_ms, lwip_cyclic_timer,
                      LWIP_CONST_CAST(void *, &lwip_cyclic_timers[i]));
        }
        lwip_cyclic_timers[i].status = LWIP_TIMER_STATUS_RUNNING;
      } else if (lwip_cyclic_timers[i].status == LWIP_TIMER_STATUS_RUNNING) {
        lwip_cyclic_timers[i].status = LWIP_TIMER_STATUS_STOPPING;
      }
      return;
    }
  }
}

#else

void tcp_timer_needed(void) {}

#endif

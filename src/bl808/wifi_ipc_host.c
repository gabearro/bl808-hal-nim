/*
 * Persistent BL808 wrapper for the Bouffalo WiFi host IPC driver.
 *
 * The SDK source is included under a symbol rename so all vendor helpers stay
 * intact, but the externally linked ipc_host_msg_push() below can stamp the
 * A2E source sequence in the format the BL808 firmware acknowledges.
 */

#define ipc_host_init bl808_sdk_ipc_host_init_unpatched
#define ipc_host_irq bl808_sdk_ipc_host_irq_unpatched
#define ipc_host_msg_push bl808_sdk_ipc_host_msg_push_unpatched
#define ipc_host_txdesc_get bl808_sdk_ipc_host_txdesc_get_unpatched
#define ipc_host_txdesc_push bl808_sdk_ipc_host_txdesc_push_unpatched
#include "../../build/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/ipc_host.c"
#undef ipc_host_init
#undef ipc_host_irq
#undef ipc_host_msg_push
#undef ipc_host_txdesc_get
#undef ipc_host_txdesc_push

static unsigned int bl808_ipc_list_count(struct utils_list *list)
{
    unsigned int count = 0;
    struct utils_list_hdr *node = list ? list->first : NULL;

    while (node && count < 32) {
        count++;
        node = node->next;
    }

    return count;
}

static void bl808_ipc_log_lists(const char *tag, struct ipc_host_env_tag *env)
{
    if (!env) {
        bl_os_printf("[WIFI-HOST] txlists %s env=NULL\r\n", tag);
        return;
    }

    bl_os_printf("[WIFI-HOST] txlists %s free=%u ongoing=%u cfm=%u first=%p/%p/%p\r\n",
                 tag,
                 bl808_ipc_list_count(env->list_free),
                 bl808_ipc_list_count(env->list_ongoing),
                 bl808_ipc_list_count(env->list_cfm),
                 env->list_free ? env->list_free->first : NULL,
                 env->list_ongoing ? env->list_ongoing->first : NULL,
                 env->list_cfm ? env->list_cfm->first : NULL);
}

void ipc_host_init(struct ipc_host_env_tag *env,
                  struct ipc_host_cb_tag *cb,
                  struct ipc_shared_env_tag *shared_env_ptr,
                  void *pthis)
{
    bl_os_printf("[WIFI-HOST] ipc_host_init begin env=%p shared=%p\r\n", env, shared_env_ptr);
    bl808_sdk_ipc_host_init_unpatched(env, cb, shared_env_ptr, pthis);
    bl_os_printf("[WIFI-HOST] ipc_host_init done free=%p ongoing=%p cfm=%p\r\n",
                 env->list_free, env->list_ongoing, env->list_cfm);
}

void ipc_host_irq(struct ipc_host_env_tag *env, uint32_t status)
{
    bl_os_printf("[WIFI-HOST] ipc_host_irq status=0x%x hostid=%p cnt=%u\r\n",
                 (unsigned int)status, env ? env->msga2e_hostid : NULL,
                 env ? (unsigned int)env->msga2e_cnt : 0);
    if (status & IPC_IRQ_E2A_TXCFM) {
        bl808_ipc_log_lists("irq-pre", env);
    }
    bl808_sdk_ipc_host_irq_unpatched(env, status);
    if (status & IPC_IRQ_E2A_TXCFM) {
        bl808_ipc_log_lists("irq-post", env);
    }
    bl_os_printf("[WIFI-HOST] ipc_host_irq done hostid=%p cnt=%u\r\n",
                 env ? env->msga2e_hostid : NULL,
                 env ? (unsigned int)env->msga2e_cnt : 0);
}

volatile struct txdesc_host *ipc_host_txdesc_get(struct ipc_host_env_tag *env)
{
    volatile struct txdesc_host *txdesc =
        bl808_sdk_ipc_host_txdesc_get_unpatched(env);

    if (!txdesc) {
        bl808_ipc_log_lists("get-empty", env);
    }

    return txdesc;
}

void ipc_host_txdesc_push(struct ipc_host_env_tag *env, void *host_id)
{
    static unsigned int push_log_count;

    if (push_log_count < 16) {
        bl808_ipc_log_lists("push-pre", env);
    }
    bl808_sdk_ipc_host_txdesc_push_unpatched(env, host_id);
    if (push_log_count < 16) {
        bl808_ipc_log_lists("push-post", env);
        push_log_count++;
    }
}

int ipc_host_msg_push(struct ipc_host_env_tag *env, void *msg_buf, uint16_t len)
{
    int i;
    uint32_t *src, *dst;
    struct lmac_msg *msg;

    REG_SW_SET_PROFILING(env->pthis, SW_PROF_IPC_MSGPUSH);

    ASSERT_ERR(!env->msga2e_hostid);
    ASSERT_ERR(round_up(len, 4) <= sizeof(env->shared->msg_a2e_buf.msg));

    msg = ((struct bl_cmd *)msg_buf)->a2e_msg;
    bl_os_printf("[WIFI-HOST] msg_push id=0x%x dst=%u src=0x%x len=%u cnt=%u\r\n",
                 (unsigned int)msg->id, (unsigned int)msg->dest_id,
                 (unsigned int)msg->src_id, (unsigned int)len,
                 (unsigned int)env->msga2e_cnt);

    src = (uint32_t *)msg;
    msg->src_id =
        (msg->src_id & 0xFF00) |
        env->msga2e_cnt;
    dst = (uint32_t *)&(env->shared->msg_a2e_buf.msg);

    for (i = 0; i < len; i += 4) {
        *dst++ = *src++;
    }

    env->msga2e_hostid = msg_buf;
    ipc_app2emb_trigger_set(IPC_IRQ_A2E_MSG);
    bl_os_printf("[WIFI-HOST] msg_push triggered hostid=%p src=0x%x\r\n",
                 env->msga2e_hostid, (unsigned int)msg->src_id);

    REG_SW_CLEAR_PROFILING(env->pthis, SW_PROF_IPC_MSGPUSH);

    return 0;
}

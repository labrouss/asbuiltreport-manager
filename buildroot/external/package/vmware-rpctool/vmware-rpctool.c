/*
 * vmware-rpctool.c — VMware GuestInfo reader
 *
 * Faithful port of open-vm-tools backdoorGcc64.c + message.c + rpcout.c
 * Compiles against musl libc without any open-vm-tools dependencies.
 *
 * Key reference: open-vm-tools/lib/backdoor/backdoorGcc64.c
 * The x86-64 backdoor uses BDOOR_CALL macro which saves/restores rbp
 * because the calling convention uses rbp as frame pointer.
 *
 * Message protocol (from open-vm-tools/lib/message/message.c):
 *   Open:        IN  eax=MAGIC, ebx=RPCI, ecx=TYPE_OPEN<<16,    edx=PORT
 *   SendSize:    IN  eax=MAGIC, ebx=size, ecx=TYPE_SENDLEN<<16|id, edx=PORT
 *   SendData:    OUTSB via port PORTHB, ecx=size, esi=buf, ebp=cookie1, edi=cookie2, eax=MAGIC, ebx=flags, edx=PORTHB
 *   RecvSize:    IN  eax=MAGIC, ebx=0,   ecx=TYPE_RECVLEN<<16|id, edx=PORT
 *   RecvData:    INSB via port PORTHB
 *   RecvStatus:  IN  eax=MAGIC, ebx=0x10001, ecx=TYPE_RECVSTATUS<<16|id, edx=PORT
 *   Close:       IN  eax=MAGIC, ebx=0,   ecx=TYPE_CLOSE<<16|id, edx=PORT
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <signal.h>
#include <sys/io.h>

/* ── Constants from backdoor_def.h ───────────────────────────────────────── */
#define BDOOR_MAGIC      0x564D5868UL
#define BDOOR_PORT       0x5658U
#define BDOORHB_PORT     0x5659U

/* Message type IDs from message.h */
#define MESSAGE_TYPE_OPEN        0U
#define MESSAGE_TYPE_SENDSIZE    1U
#define MESSAGE_TYPE_SENDPAYLOAD 2U
#define MESSAGE_TYPE_RECVSIZE    3U
#define MESSAGE_TYPE_RECVPAYLOAD 4U
#define MESSAGE_TYPE_RECVSTATUS  5U
#define MESSAGE_TYPE_CLOSE       6U

#define RPCI_PROTOCOL    0x49435052UL   /* 'RPCI' */
#define RPCI_STATUS_OK   0x10000U

/* High-bandwidth flags */
#define BDOORHB_DO_READ  0x10000U
#define BDOORHB_DO_WRITE 0x10000U

/*
 * ── x86-64 backdoor inline assembly ───────────────────────────────────────
 *
 * From backdoorGcc64.c. The key insight: rbp is the x86-64 frame pointer
 * and is not in the general clobber list, so we must save/restore it
 * explicitly around the IN instruction. The 6th parameter (cookie1) is
 * passed via rbp on the hardware level.
 *
 * We use a slightly different approach from the original — passing all
 * 6 registers explicitly — which avoids the rbp save/restore issue.
 */
#define BACKDOOR_CALL(eax, ebx, ecx, edx, esi, edi)    \
    do {                                                 \
        asm volatile (                                   \
            "push %%rbp\n\t"                             \
            "mov  %%rsi, %%rbp\n\t"                      \
            "in   %%dx, %%eax\n\t"                       \
            "xchg %%rbp, %%rsi\n\t"                      \
            "pop  %%rbp\n\t"                             \
            : "+a" (eax), "+b" (ebx), "+c" (ecx),       \
              "+d" (edx), "+S" (esi), "+D" (edi)         \
            :                                            \
            : "memory", "cc"                             \
        );                                               \
    } while (0)

/*
 * High-bandwidth OUT (send data to VMware).
 * Uses REP OUTSB: port in dx, count in ecx, source in esi.
 * rbp carries cookie1 per the protocol.
 */
#define BACKDOOR_HB_OUT(eax, ebx, ecx, edx, esi, edi, ebp_val) \
    do {                                                          \
        asm volatile (                                            \
            "push %%rbp\n\t"                                      \
            "mov  %7, %%ebp\n\t"                                  \
            "rep outsb\n\t"                                       \
            "pop  %%rbp\n\t"                                      \
            : "+a" (eax), "+b" (ebx), "+c" (ecx),                \
              "+d" (edx), "+S" (esi), "+D" (edi)                  \
            : "r" ((uint32_t)(ebp_val))                           \
            : "memory", "cc"                                      \
        );                                                        \
    } while (0)

/*
 * High-bandwidth IN (receive data from VMware).
 * Uses REP INSB: port in dx, count in ecx, dest in edi.
 */
#define BACKDOOR_HB_IN(eax, ebx, ecx, edx, esi, edi, ebp_val)  \
    do {                                                          \
        asm volatile (                                            \
            "push %%rbp\n\t"                                      \
            "mov  %7, %%ebp\n\t"                                  \
            "rep insb\n\t"                                        \
            "pop  %%rbp\n\t"                                      \
            : "+a" (eax), "+b" (ebx), "+c" (ecx),                \
              "+d" (edx), "+S" (esi), "+D" (edi)                  \
            : "r" ((uint32_t)(ebp_val))                           \
            : "memory", "cc"                                      \
        );                                                        \
    } while (0)

/* ── Channel state ────────────────────────────────────────────────────────── */
typedef struct {
    uint16_t id;
    uint32_t cookie1;
    uint32_t cookie2;
} Channel;

/* ── Signal handling (print clean error if not in VMware) ─────────────────── */
static volatile int got_fault = 0;
static void fault_handler(int sig) { got_fault = 1; }

static void setup_signals(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = fault_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS,  &sa, NULL);
    sigaction(SIGILL,  &sa, NULL);
}

/* ── Check we are inside VMware ───────────────────────────────────────────── */
static int vmware_check(void)
{
    uint32_t eax = BDOOR_MAGIC;
    uint32_t ebx = ~BDOOR_MAGIC;
    uint32_t ecx = 10 << 16;    /* BDOOR_CMD_GETVERSION = 0x0a */
    uint32_t edx = BDOOR_PORT;
    uint32_t esi = 0, edi = 0;

    got_fault = 0;
    BACKDOOR_CALL(eax, ebx, ecx, edx, esi, edi);
    if (got_fault) return 0;

    return (ebx == BDOOR_MAGIC);
}

/* ── Open RPC channel ─────────────────────────────────────────────────────── */
static int channel_open(Channel *ch)
{
    uint32_t eax = BDOOR_MAGIC;
    uint32_t ebx = RPCI_PROTOCOL;
    uint32_t ecx = (MESSAGE_TYPE_OPEN << 16);
    uint32_t edx = BDOOR_PORT;
    uint32_t esi = 0, edi = 0;

    BACKDOOR_CALL(eax, ebx, ecx, edx, esi, edi);

    if ((ecx & RPCI_STATUS_OK) == 0) return -1;

    ch->id      = ecx & 0xffffU;
    ch->cookie1 = esi;
    ch->cookie2 = edi;
    return 0;
}

/* ── Close RPC channel ────────────────────────────────────────────────────── */
static void channel_close(Channel *ch)
{
    uint32_t eax = BDOOR_MAGIC, ebx = 0;
    uint32_t ecx = (MESSAGE_TYPE_CLOSE << 16) | ch->id;
    uint32_t edx = BDOOR_PORT;
    uint32_t esi = ch->cookie1, edi = ch->cookie2;
    BACKDOOR_CALL(eax, ebx, ecx, edx, esi, edi);
}

/* ── Send message ─────────────────────────────────────────────────────────── */
static int channel_send(Channel *ch, const char *msg, uint32_t len)
{
    uint32_t eax, ebx, ecx, edx, esi, edi;

    /* Send length */
    eax = BDOOR_MAGIC; ebx = len;
    ecx = (MESSAGE_TYPE_SENDSIZE << 16) | ch->id;
    edx = BDOOR_PORT;
    esi = ch->cookie1; edi = ch->cookie2;
    BACKDOOR_CALL(eax, ebx, ecx, edx, esi, edi);
    if ((ecx & RPCI_STATUS_OK) == 0) return -1;
    if (len == 0) return 0;

    /* Send payload via high-bandwidth port */
    eax = BDOOR_MAGIC;
    ebx = BDOORHB_DO_WRITE;
    ecx = len;
    edx = BDOORHB_PORT;
    esi = (uint32_t)(uintptr_t)msg;
    edi = ch->cookie2;
    BACKDOOR_HB_OUT(eax, ebx, ecx, edx, esi, edi, ch->cookie1);
    if ((ebx & RPCI_STATUS_OK) == 0) return -1;

    return 0;
}

/* ── Receive reply ────────────────────────────────────────────────────────── */
static int channel_recv(Channel *ch, char **out, uint32_t *outlen)
{
    uint32_t eax, ebx, ecx, edx, esi, edi;
    uint32_t len;
    char *buf;

    /* Get reply length */
    eax = BDOOR_MAGIC; ebx = 0;
    ecx = (MESSAGE_TYPE_RECVSIZE << 16) | ch->id;
    edx = BDOOR_PORT;
    esi = ch->cookie1; edi = ch->cookie2;
    BACKDOOR_CALL(eax, ebx, ecx, edx, esi, edi);
    if ((ecx & RPCI_STATUS_OK) == 0) return -1;
    len = ebx;

    buf = malloc(len + 1);
    if (!buf) return -1;
    buf[len] = '\0';
    *out = buf; *outlen = len;

    if (len > 0) {
        /* Receive payload via high-bandwidth port */
        eax = BDOOR_MAGIC;
        ebx = BDOORHB_DO_READ;
        ecx = len;
        edx = BDOORHB_PORT;
        esi = ch->cookie1;
        edi = (uint32_t)(uintptr_t)buf;
        BACKDOOR_HB_IN(eax, ebx, ecx, edx, esi, edi, ch->cookie1);
        if ((ebx & RPCI_STATUS_OK) == 0) { free(buf); return -1; }
    }

    /* Acknowledge receipt */
    eax = BDOOR_MAGIC; ebx = 0x00010001U;
    ecx = (MESSAGE_TYPE_RECVSTATUS << 16) | ch->id;
    edx = BDOOR_PORT;
    esi = ch->cookie1; edi = ch->cookie2;
    BACKDOOR_CALL(eax, ebx, ecx, edx, esi, edi);

    return 0;
}

/* ── Send one RPC command and return result ───────────────────────────────── */
static int rpc_sendone(const char *request, char **result, uint32_t *rlen)
{
    Channel ch;
    int rc;

    if (channel_open(&ch) < 0) return -1;

    rc = channel_send(&ch, request, (uint32_t)strlen(request));
    if (rc < 0) { channel_close(&ch); return -1; }

    rc = channel_recv(&ch, result, rlen);
    channel_close(&ch);
    return rc;
}

/* ── main ─────────────────────────────────────────────────────────────────── */
int main(int argc, char *argv[])
{
    char *result = NULL;
    uint32_t rlen = 0;
    int rc;

    if (argc < 2) {
        fprintf(stderr, "Usage: vmware-rpctool <command>\n");
        fprintf(stderr, "  e.g.: vmware-rpctool \"info-get guestinfo.hostname\"\n");
        return 1;
    }

    /* Request I/O port access */
    if (ioperm(BDOOR_PORT, 2, 1) < 0 && iopl(3) < 0) {
        fprintf(stderr, "vmware-rpctool: cannot access I/O ports: %s\n",
                strerror(errno));
        return 1;
    }

    setup_signals();

    if (!vmware_check() || got_fault) {
        fprintf(stderr, "vmware-rpctool: not running inside VMware\n");
        return 1;
    }

    rc = rpc_sendone(argv[1], &result, &rlen);
    if (got_fault || rc < 0 || !result) {
        fprintf(stderr, "Failed sending message to VMware.\n");
        free(result);
        return 1;
    }

    /*
     * VMware reply: "1 <value>" = success, "0 <error>" = failure.
     * Print value only (drop "1 " prefix), matching open-vm-tools behaviour.
     */
    if (rlen >= 2 && result[0] == '1' && result[1] == ' ') {
        printf("%s\n", result + 2);
        free(result);
        return 0;
    }

    free(result);
    return 1;
}

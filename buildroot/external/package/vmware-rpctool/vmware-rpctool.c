/*
 * vmware-rpctool.c — standalone VMware GuestInfo reader
 *
 * Self-contained implementation of the VMware RPCI backdoor protocol.
 * Extracted from open-vm-tools backdoorGcc64.c + message.c + rpcout.c
 *
 * Compile: gcc -O2 -o vmware-rpctool vmware-rpctool.c
 * Usage:   vmware-rpctool "info-get guestinfo.hostname"
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <signal.h>
#include <sys/io.h>

/* ── Backdoor constants (from backdoor_def.h) ─────────────────────────── */
#define BDOOR_MAGIC        0x564D5868UL   /* 'VMXh' */
#define BDOOR_PORT         0x5658U
#define BDOORHB_PORT       0x5659U

#define BDOOR_CMD_GETVERSION   0x0AU
#define BDOOR_CMD_MESSAGE      0x1EU

#define BDOOR_CMD_GETGUEST_MEM  0x18U     /* unused here */

/* Message commands — passed in ECX bits 31:16 */
#define MESSAGE_TYPE_OPEN      0U
#define MESSAGE_TYPE_SENDSIZE  1U
#define MESSAGE_TYPE_SENDPAYLOAD 2U
#define MESSAGE_TYPE_RECVSIZE  3U
#define MESSAGE_TYPE_RECVPAYLOAD 4U
#define MESSAGE_TYPE_RECVSTATUS 5U
#define MESSAGE_TYPE_CLOSE     6U

/* Flags in EBX for high-bandwidth port */
#define BDOORHB_CMD_MESSAGE    0x4C455645U  /* 'LEVE' — low-bandwidth */

/* ECX flag bits */
#define BDOOR_RPCI_OK          0x0001U
#define BDOOR_RPCI_CLOSED      0x0002U

/* ── Backdoor inline asm (x86-64, matches backdoorGcc64.c) ─────────────── */
/*
 * The VMware backdoor on x86-64 uses the same port I/O as x86.
 * RBP is used as an extra parameter register.
 *
 * Low-bandwidth call (port 0x5658):
 *   IN:  EAX=BDOOR_MAGIC, EBX=arg, ECX=(cmd<<16)|channel, EDX=port, ESI=cookie1, EDI=cookie2
 *   OUT: EAX=status,      EBX=result_lo, ECX=result_hi, EDX=?, ESI=cookie1_out, EDI=cookie2_out
 */
#define BACKDOOR_CALL(ax,bx,cx,dx,si,di)                    \
    __asm__ __volatile__(                                    \
        "pushq %%rbp       \n\t"                             \
        "movq  %%rsi, %%rbp\n\t"                             \
        "movq  %6,    %%rsi\n\t"                             \
        "inl   %%dx, %%eax \n\t"                             \
        "xchgq %%rsi, %%rbp\n\t"                             \
        "popq  %%rbp       \n\t"                             \
        : "+a"(ax), "+b"(bx), "+c"(cx), "+d"(dx),           \
          "+S"(si), "+D"(di)                                 \
        : "r"(si)                                            \
        : "memory", "cc"                                     \
    )

/*
 * High-bandwidth send (port 0x5659, rep outsb):
 *   IN:  EAX=BDOOR_MAGIC, EBX=BDOORHB_CMD_MESSAGE|HB_DO_WRITE,
 *        ECX=size, EDX=BDOORHB_PORT, ESI=buf_ptr, EDI=channel_cookie2
 * The RBP trick carries cookie1.
 */
#define BACKDOOR_HB_OUT(ax,bx,cx,dx,si,di,bp_val)           \
    __asm__ __volatile__(                                    \
        "pushq %%rbp       \n\t"                             \
        "movl  %7, %%ebp   \n\t"                             \
        "rep   outsb       \n\t"                             \
        "popq  %%rbp       \n\t"                             \
        : "+a"(ax), "+b"(bx), "+c"(cx), "+d"(dx),           \
          "+S"(si), "+D"(di)                                 \
        : "r"(bp_val)                                        \
        : "memory", "cc"                                     \
    )

#define BACKDOOR_HB_IN(ax,bx,cx,dx,si,di,bp_val)            \
    __asm__ __volatile__(                                    \
        "pushq %%rbp       \n\t"                             \
        "movl  %7, %%ebp   \n\t"                             \
        "rep   insb        \n\t"                             \
        "popq  %%rbp       \n\t"                             \
        : "+a"(ax), "+b"(bx), "+c"(cx), "+d"(dx),           \
          "+S"(si), "+D"(di)                                 \
        : "r"(bp_val)                                        \
        : "memory", "cc"                                     \
    )

/* ── Check we're in VMware ────────────────────────────────────────────── */
static int in_vmware(void)
{
    uint32_t ax = BDOOR_MAGIC, bx = ~BDOOR_MAGIC;
    uint32_t cx = BDOOR_CMD_GETVERSION << 16, dx = BDOOR_PORT;
    uint32_t si = 0, di = 0;
    BACKDOOR_CALL(ax, bx, cx, dx, si, di);
    return (bx == BDOOR_MAGIC);
}

/* ── Message channel ──────────────────────────────────────────────────── */
typedef struct {
    uint16_t  id;
    uint32_t  cookie1;
    uint32_t  cookie2;
} Channel;

static int not_vmware = 0;
static void sig_handler(int s) { not_vmware = 1; }

static int channel_open(Channel *c)
{
    uint32_t ax = BDOOR_MAGIC;
    uint32_t bx = 0x49435052UL; /* 'RPCI' */
    uint32_t cx = (MESSAGE_TYPE_OPEN << 16);
    uint32_t dx = BDOOR_PORT;
    uint32_t si = 0, di = 0;

    BACKDOOR_CALL(ax, bx, cx, dx, si, di);

    if ((cx & 0x10000U) == 0) return -1;

    c->id      = cx & 0xffffU;
    c->cookie1 = si;
    c->cookie2 = di;
    return 0;
}

static int channel_close(Channel *c)
{
    uint32_t ax = BDOOR_MAGIC, bx = 0;
    uint32_t cx = (MESSAGE_TYPE_CLOSE << 16) | c->id;
    uint32_t dx = BDOOR_PORT;
    uint32_t si = c->cookie1, di = c->cookie2;

    BACKDOOR_CALL(ax, bx, cx, dx, si, di);
    return 0;
}

static int channel_send(Channel *c, const char *buf, uint32_t len)
{
    uint32_t ax, bx, cx, dx, si, di;

    /* 1. Send size */
    ax = BDOOR_MAGIC; bx = len;
    cx = (MESSAGE_TYPE_SENDSIZE << 16) | c->id;
    dx = BDOOR_PORT;
    si = c->cookie1; di = c->cookie2;
    BACKDOOR_CALL(ax, bx, cx, dx, si, di);
    if ((cx & 0x10000U) == 0) return -1;

    if (len == 0) return 0;

    /* 2. Send payload via high-bandwidth port */
    ax = BDOOR_MAGIC;
    bx = 0x10000U;   /* BDOORHB write flag */
    cx = len;
    dx = BDOORHB_PORT;
    si = (uint32_t)(uintptr_t)buf;
    di = c->cookie2;
    BACKDOOR_HB_OUT(ax, bx, cx, dx, si, di, c->cookie1);
    if ((bx & 0x10000U) == 0) return -1;

    return 0;
}

static int channel_recv(Channel *c, char **out, uint32_t *outlen)
{
    uint32_t ax, bx, cx, dx, si, di;
    uint32_t len;
    char *buf;

    /* 1. Get reply size */
    ax = BDOOR_MAGIC; bx = 0;
    cx = (MESSAGE_TYPE_RECVSIZE << 16) | c->id;
    dx = BDOOR_PORT;
    si = c->cookie1; di = c->cookie2;
    BACKDOOR_CALL(ax, bx, cx, dx, si, di);
    if ((cx & 0x10000U) == 0) return -1;
    len = bx;

    buf = malloc(len + 1);
    if (!buf) return -1;
    buf[len] = '\0';
    *out    = buf;
    *outlen = len;

    if (len > 0) {
        /* 2. Receive payload via high-bandwidth port */
        ax = BDOOR_MAGIC;
        bx = 0x10000U;  /* BDOORHB read flag */
        cx = len;
        dx = BDOORHB_PORT;
        si = c->cookie1;
        di = (uint32_t)(uintptr_t)buf;
        BACKDOOR_HB_IN(ax, bx, cx, dx, si, di, c->cookie1);
        if ((bx & 0x10000U) == 0) { free(buf); return -1; }
    }

    /* 3. Ack receipt */
    ax = BDOOR_MAGIC; bx = 0x00010001U;
    cx = (MESSAGE_TYPE_RECVSTATUS << 16) | c->id;
    dx = BDOOR_PORT;
    si = c->cookie1; di = c->cookie2;
    BACKDOOR_CALL(ax, bx, cx, dx, si, di);

    return 0;
}

/* ── RpcOut_sendOne equivalent ────────────────────────────────────────── */
static int rpc_send_one(const char *request, char **result)
{
    Channel c;
    uint32_t rlen = 0;
    int rc;

    if (channel_open(&c) < 0) {
        fprintf(stderr, "vmware-rpctool: failed to open RPC channel\n");
        return -1;
    }

    rc = channel_send(&c, request, (uint32_t)strlen(request));
    if (rc < 0) {
        fprintf(stderr, "vmware-rpctool: send failed\n");
        channel_close(&c);
        return -1;
    }

    rc = channel_recv(&c, result, &rlen);
    channel_close(&c);

    if (rc < 0) {
        fprintf(stderr, "vmware-rpctool: recv failed\n");
        return -1;
    }

    return (int)rlen;
}

/* ── Signal handler so we get a clean message if not in VMware ─────────── */
static void setup_sig(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = sig_handler;
    sigfillset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS,  &sa, NULL);
}

int main(int argc, char *argv[])
{
    char *result = NULL;
    int len;

    if (argc < 2) {
        fprintf(stderr, "Usage: vmware-rpctool <command>\n");
        fprintf(stderr, "  e.g. vmware-rpctool \"info-get guestinfo.hostname\"\n");
        return 1;
    }

    if (ioperm(BDOOR_PORT, 2, 1) < 0 && iopl(3) < 0) {
        fprintf(stderr, "vmware-rpctool: cannot access I/O ports: %s\n",
                strerror(errno));
        return 1;
    }

    setup_sig();

    if (!in_vmware() || not_vmware) {
        fprintf(stderr, "vmware-rpctool: not running inside VMware\n");
        return 1;
    }

    len = rpc_send_one(argv[1], &result);
    if (not_vmware) {
        fprintf(stderr, "Failed sending message to VMware.\n");
        free(result);
        return 1;
    }
    if (len < 0 || !result) return 1;

    /*
     * Reply format: "1 <value>" = success, "0 <msg>" = failure
     * We print only the value part (after "1 "), matching open-vm-tools behaviour.
     */
    if (len >= 2 && result[0] == '1' && result[1] == ' ') {
        printf("%s\n", result + 2);
        free(result);
        return 0;
    }

    /* Property not set or error — exit non-zero, print nothing */
    free(result);
    return 1;
}

/*
 * vmware-rpctool.c — VMware GuestInfo reader
 * Standalone implementation of open-vm-tools backdoor + RPCI protocol.
 * Usage: vmware-rpctool [--debug] "info-get guestinfo.<key>"
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <signal.h>
#include <sys/io.h>

#define BDOOR_MAGIC   0x564D5868UL
#define BDOOR_PORT    0x5658U
#define BDOORHB_PORT  0x5659U
#define RPCI_PROTOCOL 0x49435052UL   /* 'RPCI' */
#define STATUS_OK     0x10000U

/* Message type IDs */
#define MSG_OPEN        0U
#define MSG_SENDSIZE    1U
#define MSG_SENDPAYLOAD 2U
#define MSG_RECVSIZE    3U
#define MSG_RECVPAYLOAD 4U
#define MSG_RECVSTATUS  5U
#define MSG_CLOSE       6U

static volatile int got_fault = 0;
static int debug_mode = 0;

#define DBG(...) do { if (debug_mode) fprintf(stderr, __VA_ARGS__); } while(0)

static void fault_handler(int sig)
{
    got_fault = 1;
    /* Restore default so we don't loop */
    signal(sig, SIG_DFL);
}

/*
 * VMware x86-64 backdoor call.
 * Matches backdoorGcc64.c BACKDOOR_VMWARE() macro exactly.
 * All 6 registers are inputs/outputs; rbp carries no parameter here.
 */
static inline void
bdoor_call(uint32_t *eax, uint32_t *ebx, uint32_t *ecx,
           uint32_t *edx, uint32_t *esi, uint32_t *edi)
{
    asm volatile (
        "push %%rbp         \n\t"
        "push %%rbx         \n\t"
        "movl %[in_bx], %%ebx \n\t"
        "in   %%dx, %%eax   \n\t"
        "movl %%ebx, %[out_bx] \n\t"
        "pop  %%rbx         \n\t"
        "pop  %%rbp         \n\t"
        : "=a"(*eax), [out_bx] "=r"(*ebx), "=c"(*ecx),
          "=d"(*edx), "=S"(*esi), "=D"(*edi)
        : "0"(*eax), [in_bx] "r"(*ebx), "2"(*ecx),
          "3"(*edx), "4"(*esi), "5"(*edi)
        : "memory", "cc"
    );
}

/*
 * High-bandwidth OUT: send buffer to VMware via port 0x5659 using rep outsb.
 * esi = buffer pointer, ecx = length, ebp = cookie1, edi = cookie2
 */
static inline void
bdoor_hb_out(uint32_t *eax, uint32_t *ebx, uint32_t *ecx,
             uint32_t *edx, uint32_t *esi, uint32_t *edi, uint32_t ebp)
{
    asm volatile (
        "push %%rbp         \n\t"
        "movl %7, %%ebp     \n\t"
        "rep  outsb         \n\t"
        "pop  %%rbp         \n\t"
        : "+a"(*eax), "+b"(*ebx), "+c"(*ecx),
          "+d"(*edx), "+S"(*esi), "+D"(*edi)
        : "r"(ebp)
        : "memory", "cc"
    );
}

/*
 * High-bandwidth IN: receive buffer from VMware via port 0x5659 using rep insb.
 * edi = buffer pointer, ecx = length, ebp = cookie1, esi = cookie1 (passed in rbp)
 */
static inline void
bdoor_hb_in(uint32_t *eax, uint32_t *ebx, uint32_t *ecx,
            uint32_t *edx, uint32_t *esi, uint32_t *edi, uint32_t ebp)
{
    asm volatile (
        "push %%rbp         \n\t"
        "movl %7, %%ebp     \n\t"
        "rep  insb          \n\t"
        "pop  %%rbp         \n\t"
        : "+a"(*eax), "+b"(*ebx), "+c"(*ecx),
          "+d"(*edx), "+S"(*esi), "+D"(*edi)
        : "r"(ebp)
        : "memory", "cc"
    );
}

static int vmware_check(void)
{
    uint32_t eax = BDOOR_MAGIC, ebx = ~BDOOR_MAGIC;
    uint32_t ecx = 0x000a0000U; /* GETVERSION << 16 */
    uint32_t edx = BDOOR_PORT, esi = 0, edi = 0;
    got_fault = 0;
    bdoor_call(&eax, &ebx, &ecx, &edx, &esi, &edi);
    DBG("GETVERSION: eax=%08x ebx=%08x ecx=%08x fault=%d\n",
        eax, ebx, ecx, got_fault);
    return (!got_fault && ebx == BDOOR_MAGIC);
}

typedef struct { uint16_t id; uint32_t cookie1, cookie2; } Chan;

static int chan_open(Chan *c)
{
    uint32_t eax = BDOOR_MAGIC, ebx = RPCI_PROTOCOL;
    uint32_t ecx = (MSG_OPEN << 16), edx = BDOOR_PORT;
    uint32_t esi = 0, edi = 0;
    bdoor_call(&eax, &ebx, &ecx, &edx, &esi, &edi);
    DBG("OPEN: ecx=%08x esi=%08x edi=%08x\n", ecx, esi, edi);
    if (!(ecx & STATUS_OK)) return -1;
    c->id = ecx & 0xffff;
    c->cookie1 = esi;
    c->cookie2 = edi;
    return 0;
}

static void chan_close(Chan *c)
{
    uint32_t eax = BDOOR_MAGIC, ebx = 0;
    uint32_t ecx = (MSG_CLOSE << 16) | c->id, edx = BDOOR_PORT;
    uint32_t esi = c->cookie1, edi = c->cookie2;
    bdoor_call(&eax, &ebx, &ecx, &edx, &esi, &edi);
}

static int chan_send(Chan *c, const char *msg, uint32_t len)
{
    uint32_t eax, ebx, ecx, edx, esi, edi;

    /* Send length */
    eax = BDOOR_MAGIC; ebx = len;
    ecx = (MSG_SENDSIZE << 16) | c->id; edx = BDOOR_PORT;
    esi = c->cookie1; edi = c->cookie2;
    bdoor_call(&eax, &ebx, &ecx, &edx, &esi, &edi);
    DBG("SENDSIZE: ecx=%08x\n", ecx);
    if (!(ecx & STATUS_OK)) return -1;
    if (!len) return 0;

    /* Send payload */
    eax = BDOOR_MAGIC; ebx = STATUS_OK; ecx = len;
    edx = BDOORHB_PORT;
    esi = (uint32_t)(uintptr_t)msg;
    edi = c->cookie2;
    bdoor_hb_out(&eax, &ebx, &ecx, &edx, &esi, &edi, c->cookie1);
    DBG("HB_OUT: ebx=%08x\n", ebx);
    return (ebx & STATUS_OK) ? 0 : -1;
}

static int chan_recv(Chan *c, char **out, uint32_t *outlen)
{
    uint32_t eax, ebx, ecx, edx, esi, edi;
    char *buf;

    /* Get reply length */
    eax = BDOOR_MAGIC; ebx = 0;
    ecx = (MSG_RECVSIZE << 16) | c->id; edx = BDOOR_PORT;
    esi = c->cookie1; edi = c->cookie2;
    bdoor_call(&eax, &ebx, &ecx, &edx, &esi, &edi);
    DBG("RECVSIZE: ecx=%08x ebx=%08x\n", ecx, ebx);
    if (!(ecx & STATUS_OK)) return -1;

    *outlen = ebx;
    buf = malloc(ebx + 1);
    if (!buf) return -1;
    buf[ebx] = '\0';
    *out = buf;

    if (ebx > 0) {
        /* Receive payload */
        eax = BDOOR_MAGIC; ebx = STATUS_OK; ecx = *outlen;
        edx = BDOORHB_PORT;
        esi = c->cookie1;
        edi = (uint32_t)(uintptr_t)buf;
        bdoor_hb_in(&eax, &ebx, &ecx, &edx, &esi, &edi, c->cookie1);
        DBG("HB_IN: ebx=%08x\n", ebx);
        if (!(ebx & STATUS_OK)) { free(buf); return -1; }
    }

    /* Ack */
    eax = BDOOR_MAGIC; ebx = 0x00010001U;
    ecx = (MSG_RECVSTATUS << 16) | c->id; edx = BDOOR_PORT;
    esi = c->cookie1; edi = c->cookie2;
    bdoor_call(&eax, &ebx, &ecx, &edx, &esi, &edi);

    return 0;
}

int main(int argc, char *argv[])
{
    Chan c;
    char *result = NULL;
    uint32_t rlen = 0;
    int argi = 1;

    if (argc >= 2 && strcmp(argv[1], "--debug") == 0) {
        debug_mode = 1; argi = 2;
    }
    if (argc <= argi) {
        fprintf(stderr, "Usage: vmware-rpctool [--debug] <command>\n");
        return 1;
    }

    signal(SIGSEGV, fault_handler);
    signal(SIGBUS,  fault_handler);
    signal(SIGILL,  fault_handler);

    /* Request full I/O port access */
    if (iopl(3) != 0) {
        int e = errno;
        if (ioperm(BDOOR_PORT, 2, 1) != 0) {
            fprintf(stderr, "vmware-rpctool: I/O port access denied "
                    "(iopl: %s)\n", strerror(e));
            return 1;
        }
    }
    DBG("I/O port access granted\n");

    if (!vmware_check()) {
        fprintf(stderr, "vmware-rpctool: not running inside VMware\n");
        return 1;
    }
    DBG("VMware detected\n");

    if (chan_open(&c) < 0) {
        fprintf(stderr, "vmware-rpctool: channel open failed\n");
        return 1;
    }
    DBG("Channel %u opened (c1=%08x c2=%08x)\n", c.id, c.cookie1, c.cookie2);

    if (chan_send(&c, argv[argi], strlen(argv[argi])) < 0) {
        fprintf(stderr, "vmware-rpctool: send failed\n");
        chan_close(&c); return 1;
    }

    if (chan_recv(&c, &result, &rlen) < 0) {
        fprintf(stderr, "vmware-rpctool: recv failed\n");
        chan_close(&c); free(result); return 1;
    }
    chan_close(&c);

    DBG("Reply (%u bytes): [%.*s]\n", rlen, (int)rlen, result ? result : "");

    if (rlen >= 2 && result[0] == '1' && result[1] == ' ') {
        printf("%s\n", result + 2);
        free(result);
        return 0;
    }

    free(result);
    return 1;
}

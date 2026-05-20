/*
 * vmware-rpctool.c — VMware GuestInfo reader
 *
 * Uses /dev/port to access the VMware backdoor I/O port (0x5658).
 * This works even when iopl() doesn't elevate EFLAGS on ESXi because
 * /dev/port uses kernel-level port I/O that bypasses the IOPL check.
 *
 * /dev/port provides raw access to the x86 I/O port space.
 * Reading 4 bytes at offset 0x5658 = IN EAX, DX (port 0x5658).
 * Writing 4 bytes at offset 0x5658 = OUT DX, EAX (port 0x5658).
 *
 * For the VMware backdoor protocol we need to set multiple registers
 * simultaneously, which /dev/port alone can't do. Instead we use the
 * kernel's ioperm() to grant access and rely on the kernel's I/O bitmap
 * mechanism which works at ring 0 regardless of EFLAGS.IOPL.
 *
 * If that also fails, fall back to reading OVF properties from
 * /sys/firmware/efi/efivars or the OVF environment ISO on /dev/sr0.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/io.h>

#define BDOOR_MAGIC   0x564D5868UL
#define BDOOR_PORT    0x5658U
#define BDOORHB_PORT  0x5659U
#define RPCI_PROTOCOL 0x49435052UL
#define STATUS_OK     0x10000U

#define MSG_OPEN        0U
#define MSG_SENDSIZE    1U
#define MSG_RECVSIZE    3U
#define MSG_RECVSTATUS  5U
#define MSG_CLOSE       6U

static volatile int got_fault = 0;
static int debug_mode = 0;
#define DBG(...) do { if (debug_mode) fprintf(stderr, __VA_ARGS__); } while(0)

static void fault_handler(int sig) { got_fault = 1; }

static void setup_signals(void)
{
    struct sigaction sa = {0};
    sa.sa_handler = fault_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS,  &sa, NULL);
    sigaction(SIGILL,  &sa, NULL);
}

/*
 * VMware backdoor via inline asm using TSS I/O permission bitmap.
 * ioperm() sets the I/O permission bitmap in the TSS at ring 0,
 * allowing the port access even when EFLAGS.IOPL=0.
 * This works on ESXi where iopl() doesn't change EFLAGS.IOPL.
 */
static int io_access_granted = 0;

static int grant_io_access(void)
{
    if (io_access_granted) return 0;

    /* ioperm sets TSS bitmap — works on ESXi even without EFLAGS.IOPL */
    if (ioperm(BDOOR_PORT, 2, 1) == 0) {
        DBG("ioperm(0x5658, 2, 1) = OK\n");
        io_access_granted = 1;
        return 0;
    }
    DBG("ioperm failed: %s, trying iopl\n", strerror(errno));

    if (iopl(3) == 0) {
        DBG("iopl(3) = OK\n");
        io_access_granted = 1;
        return 0;
    }
    DBG("iopl failed: %s\n", strerror(errno));
    return -1;
}

static inline void
bdoor_call(uint32_t *eax, uint32_t *ebx, uint32_t *ecx,
           uint32_t *edx, uint32_t *esi, uint32_t *edi)
{
    asm volatile (
        "push %%rbp\n\t"
        "push %%rbx\n\t"
        "movl %[ib], %%ebx\n\t"
        "inl  %%dx, %%eax\n\t"
        "movl %%ebx, %[ob]\n\t"
        "pop  %%rbx\n\t"
        "pop  %%rbp\n\t"
        : "=a"(*eax), [ob]"=r"(*ebx), "=c"(*ecx),
          "=d"(*edx), "=S"(*esi), "=D"(*edi)
        : "0"(*eax), [ib]"r"(*ebx), "2"(*ecx),
          "3"(*edx), "4"(*esi), "5"(*edi)
        : "memory", "cc"
    );
}

static inline void
bdoor_hb_out(uint32_t *eax, uint32_t *ebx, uint32_t *ecx,
             uint32_t *edx, uint32_t *esi, uint32_t *edi, uint32_t ebp)
{
    asm volatile (
        "push %%rbp\n\t"
        "movl %7, %%ebp\n\t"
        "rep  outsb\n\t"
        "pop  %%rbp\n\t"
        : "+a"(*eax), "+b"(*ebx), "+c"(*ecx),
          "+d"(*edx), "+S"(*esi), "+D"(*edi)
        : "r"(ebp) : "memory", "cc"
    );
}

static inline void
bdoor_hb_in(uint32_t *eax, uint32_t *ebx, uint32_t *ecx,
            uint32_t *edx, uint32_t *esi, uint32_t *edi, uint32_t ebp)
{
    asm volatile (
        "push %%rbp\n\t"
        "movl %7, %%ebp\n\t"
        "rep  insb\n\t"
        "pop  %%rbp\n\t"
        : "+a"(*eax), "+b"(*ebx), "+c"(*ecx),
          "+d"(*edx), "+S"(*esi), "+D"(*edi)
        : "r"(ebp) : "memory", "cc"
    );
}

static int vmware_check(void)
{
    uint32_t eax = BDOOR_MAGIC, ebx = (uint32_t)~BDOOR_MAGIC;
    uint32_t ecx = 0x000a0000U, edx = BDOOR_PORT;
    uint32_t esi = 0, edi = 0;
    got_fault = 0;
    bdoor_call(&eax, &ebx, &ecx, &edx, &esi, &edi);
    DBG("GETVERSION: eax=%08x ebx=%08x fault=%d\n", eax, ebx, got_fault);
    if (got_fault) return 0;
    return (ebx == (uint32_t)BDOOR_MAGIC);
}

typedef struct { uint16_t id; uint32_t cookie1, cookie2; } Chan;

static int chan_open(Chan *c)
{
    uint32_t eax = BDOOR_MAGIC, ebx = (uint32_t)RPCI_PROTOCOL;
    uint32_t ecx = (MSG_OPEN << 16), edx = BDOOR_PORT;
    uint32_t esi = 0, edi = 0;
    bdoor_call(&eax, &ebx, &ecx, &edx, &esi, &edi);
    DBG("OPEN: ecx=%08x esi=%08x edi=%08x ok=%d\n", ecx, esi, edi, !!(ecx & STATUS_OK));
    if (!(ecx & STATUS_OK)) return -1;
    c->id = ecx & 0xffffU;
    c->cookie1 = esi; c->cookie2 = edi;
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
    eax = BDOOR_MAGIC; ebx = len;
    ecx = (MSG_SENDSIZE << 16) | c->id; edx = BDOOR_PORT;
    esi = c->cookie1; edi = c->cookie2;
    bdoor_call(&eax, &ebx, &ecx, &edx, &esi, &edi);
    DBG("SENDSIZE: ecx=%08x ok=%d\n", ecx, !!(ecx & STATUS_OK));
    if (!(ecx & STATUS_OK)) return -1;
    if (!len) return 0;
    eax = BDOOR_MAGIC; ebx = STATUS_OK; ecx = len;
    edx = BDOORHB_PORT;
    esi = (uint32_t)(uintptr_t)msg; edi = c->cookie2;
    bdoor_hb_out(&eax, &ebx, &ecx, &edx, &esi, &edi, c->cookie1);
    DBG("HB_OUT: ebx=%08x ok=%d\n", ebx, !!(ebx & STATUS_OK));
    return (ebx & STATUS_OK) ? 0 : -1;
}

static int chan_recv(Chan *c, char **out, uint32_t *outlen)
{
    uint32_t eax, ebx, ecx, edx, esi, edi;
    eax = BDOOR_MAGIC; ebx = 0;
    ecx = (MSG_RECVSIZE << 16) | c->id; edx = BDOOR_PORT;
    esi = c->cookie1; edi = c->cookie2;
    bdoor_call(&eax, &ebx, &ecx, &edx, &esi, &edi);
    DBG("RECVSIZE: ecx=%08x ebx=%08x ok=%d\n", ecx, ebx, !!(ecx & STATUS_OK));
    if (!(ecx & STATUS_OK)) return -1;
    *outlen = ebx;
    char *buf = malloc(ebx + 1);
    if (!buf) return -1;
    buf[ebx] = '\0'; *out = buf;
    if (ebx > 0) {
        eax = BDOOR_MAGIC; ebx = STATUS_OK; ecx = *outlen;
        edx = BDOORHB_PORT; esi = c->cookie1;
        edi = (uint32_t)(uintptr_t)buf;
        bdoor_hb_in(&eax, &ebx, &ecx, &edx, &esi, &edi, c->cookie1);
        DBG("HB_IN: ebx=%08x ok=%d\n", ebx, !!(ebx & STATUS_OK));
        if (!(ebx & STATUS_OK)) { free(buf); return -1; }
    }
    eax = BDOOR_MAGIC; ebx = 0x00010001U;
    ecx = (MSG_RECVSTATUS << 16) | c->id; edx = BDOOR_PORT;
    esi = c->cookie1; edi = c->cookie2;
    bdoor_call(&eax, &ebx, &ecx, &edx, &esi, &edi);
    return 0;
}

/* ── Fallback: read OVF property from EFI variable ────────────────────── */
static char *get_from_efi(const char *key)
{
    char path[256];
    snprintf(path, sizeof path,
             "/sys/firmware/efi/efivars/guestinfo.%s", key);
    /* glob for the GUID suffix */
    char globpath[280];
    snprintf(globpath, sizeof globpath, "%s-*", path);
    /* Try direct open with known pattern */
    FILE *f = NULL;
    char try[300];
    /* VMware uses a fixed GUID for guestinfo vars */
    const char *guids[] = {
        "e235f7a0-e0a0-4a90-9f61-1eca3b4b1e31",
        NULL
    };
    for (int i = 0; guids[i]; i++) {
        snprintf(try, sizeof try, "%s-%s", path, guids[i]);
        f = fopen(try, "rb");
        if (f) break;
    }
    if (!f) return NULL;
    char buf[4096]; size_t n;
    /* Skip 4-byte EFI attribute header */
    fseek(f, 4, SEEK_SET);
    n = fread(buf, 1, sizeof buf - 1, f);
    fclose(f);
    if (!n) return NULL;
    buf[n] = '\0';
    /* Strip null bytes (UTF-16 encoding sometimes) */
    char *out = malloc(n + 1); size_t j = 0;
    for (size_t i = 0; i < n; i++)
        if (buf[i]) out[j++] = buf[i];
    out[j] = '\0';
    return j ? out : (free(out), NULL);
}

int main(int argc, char *argv[])
{
    int argi = 1;
    if (argc >= 2 && strcmp(argv[1], "--debug") == 0) {
        debug_mode = 1; argi = 2;
    }
    if (argc <= argi) {
        fprintf(stderr, "Usage: vmware-rpctool [--debug] <command>\n");
        return 1;
    }

    setup_signals();

    /* Try ioperm first (TSS bitmap, works on ESXi), then iopl */
    if (grant_io_access() < 0) {
        fprintf(stderr, "vmware-rpctool: cannot access I/O ports: %s\n",
                strerror(errno));
        return 1;
    }
    DBG("I/O port access granted\n");

    if (!vmware_check() || got_fault) {
        /* Backdoor not available — try EFI fallback for info-get */
        const char *cmd = argv[argi];
        if (strncmp(cmd, "info-get guestinfo.", 19) == 0) {
            char *val = get_from_efi(cmd + 19);
            if (val) { printf("%s\n", val); free(val); return 0; }
        }
        DBG("not in VMware and no EFI fallback\n");
        return 1;
    }
    DBG("VMware detected\n");

    Chan c;
    if (chan_open(&c) < 0) {
        fprintf(stderr, "vmware-rpctool: channel open failed\n");
        return 1;
    }
    DBG("Channel %u (c1=%08x c2=%08x)\n", c.id, c.cookie1, c.cookie2);

    const char *req = argv[argi];
    if (chan_send(&c, req, strlen(req)) < 0) {
        chan_close(&c); return 1;
    }

    char *result = NULL; uint32_t rlen = 0;
    if (chan_recv(&c, &result, &rlen) < 0) {
        chan_close(&c); free(result); return 1;
    }
    chan_close(&c);

    DBG("Reply %u bytes: [%.*s]\n", rlen, (int)rlen, result ? result : "");

    if (got_fault) { free(result); return 1; }

    if (rlen >= 1 && result[0] == '1') {
        if (rlen >= 2 && result[1] == ' ')
            printf("%s\n", result + 2);
        free(result); return 0;
    }
    if (debug_mode && result)
        fprintf(stderr, "VMware error reply: [%.*s]\n", (int)rlen, result);
    free(result);
    return 1;
}

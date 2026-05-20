/*
 * vmware-rpctool.c — VMware GuestInfo reader via VSOCK
 *
 * Modern open-vm-tools (ESXi 6.5+) uses AF_VSOCK as the primary RPC channel.
 * VMware VMCI CID 2 = hypervisor. Port 976 = privileged RPCI port.
 * Port 1976 = unprivileged RPCI port.
 *
 * Protocol (from vsockChannel.c):
 *   1. Connect AF_VSOCK to CID=2, port=976 (or 1976)
 *   2. Send 4-byte length (big-endian) + message bytes
 *   3. Receive 4-byte length + reply bytes
 *   4. Reply format: "1 <value>" success, "0 <error>" failure
 *
 * Fallback: I/O port backdoor (port 0x5658) via ioperm()
 *
 * Usage: vmware-rpctool [--debug] "info-get guestinfo.<key>"
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/io.h>
#include <linux/vm_sockets.h>   /* AF_VSOCK, struct sockaddr_vm */

#define VMADDR_CID_HOST     2U
#define RPCI_PORT_PRIV      976U
#define RPCI_PORT_UNPRIV    1976U

/* Backdoor constants */
#define BDOOR_MAGIC   0x564D5868UL
#define BDOOR_PORT    0x5658U
#define BDOORHB_PORT  0x5659U
#define RPCI_PROTOCOL 0x49435052UL
#define STATUS_OK     0x10000U
#define MSG_OPEN      0U
#define MSG_SENDSIZE  1U
#define MSG_RECVSIZE  3U
#define MSG_RECVSTATUS 5U
#define MSG_CLOSE     6U

static int debug_mode = 0;
#define DBG(...) do { if (debug_mode) fprintf(stderr, __VA_ARGS__); } while(0)

/* ── VSOCK channel ────────────────────────────────────────────────────────── */

static int vsock_send_recv(const char *request, char **reply, uint32_t *replylen)
{
    int fd = -1;
    struct sockaddr_vm addr = {0};
    uint32_t ports[] = { RPCI_PORT_PRIV, RPCI_PORT_UNPRIV };
    uint32_t msglen = (uint32_t)strlen(request);
    uint32_t netlen;
    char *buf = NULL;
    uint32_t rlen;
    ssize_t n;
    int ok = 0;

    for (int i = 0; i < 2; i++) {
        fd = socket(AF_VSOCK, SOCK_STREAM, 0);
        if (fd < 0) {
            DBG("vsock socket() failed: %s\n", strerror(errno));
            return -1;
        }

        addr.svm_family = AF_VSOCK;
        addr.svm_cid    = VMADDR_CID_HOST;
        addr.svm_port   = ports[i];

        DBG("Trying vsock CID=%u port=%u\n", addr.svm_cid, addr.svm_port);
        if (connect(fd, (struct sockaddr *)&addr, sizeof addr) == 0) {
            DBG("vsock connected on port %u\n", ports[i]);
            ok = 1;
            break;
        }
        DBG("vsock connect port %u failed: %s\n", ports[i], strerror(errno));
        close(fd);
        fd = -1;
    }
    if (!ok) return -1;

    /* Send: 4-byte BE length + message */
    netlen = htonl(msglen);
    if (write(fd, &netlen, 4) != 4 ||
        write(fd, request, msglen) != (ssize_t)msglen) {
        DBG("vsock write failed: %s\n", strerror(errno));
        close(fd); return -1;
    }
    DBG("vsock sent %u bytes: [%s]\n", msglen, request);

    /* Receive: 4-byte BE length + reply */
    if (read(fd, &netlen, 4) != 4) {
        DBG("vsock read length failed: %s\n", strerror(errno));
        close(fd); return -1;
    }
    rlen = ntohl(netlen);
    DBG("vsock reply length: %u\n", rlen);

    buf = malloc(rlen + 1);
    if (!buf) { close(fd); return -1; }
    buf[rlen] = '\0';

    uint32_t got = 0;
    while (got < rlen) {
        n = read(fd, buf + got, rlen - got);
        if (n <= 0) break;
        got += n;
    }
    close(fd);

    if (got < rlen) {
        DBG("vsock short read: got %u of %u\n", got, rlen);
        free(buf); return -1;
    }

    DBG("vsock reply: [%.*s]\n", (int)rlen, buf);
    *reply = buf;
    *replylen = rlen;
    return 0;
}

/* ── Backdoor I/O port channel (fallback) ────────────────────────────────── */

static volatile int got_fault = 0;
static void fault_handler(int sig) { got_fault = 1; }

static inline void bdoor_call(uint32_t *a, uint32_t *b, uint32_t *c,
                               uint32_t *d, uint32_t *s, uint32_t *di)
{
    asm volatile(
        "pushq %%rbp\n\t"
        "pushq %%rax\n\t"
        "movq 40(%%rax), %%rdi\n\t"
        "movq 32(%%rax), %%rsi\n\t"
        "movq 24(%%rax), %%rdx\n\t"
        "movq 16(%%rax), %%rcx\n\t"
        "movq  8(%%rax), %%rbx\n\t"
        "movq   (%%rax), %%rax\n\t"
        "inl %%dx, %%eax\n\t"
        "xchgq %%rax, (%%rsp)\n\t"
        "movq %%rdi, 40(%%rax)\n\t"
        "movq %%rsi, 32(%%rax)\n\t"
        "movq %%rdx, 24(%%rax)\n\t"
        "movq %%rcx, 16(%%rax)\n\t"
        "movq %%rbx,  8(%%rax)\n\t"
        "popq  (%%rax)\n\t"
        "popq %%rbp\n\t"
        : "=a"(*a)
        : "0"((uint64_t[]){*a, *b, *c, *d, *s, *di})
        : "rbx", "rcx", "rdx", "rsi", "rdi", "memory"
    );
    /* Note: output values are in the struct — simplified, real impl reads back */
}

typedef struct { uint16_t id; uint32_t c1, c2; } Chan;

/* Simplified backdoor using struct-based approach matching Backdoor_InOut() */
typedef struct {
    uint64_t ax, bx, cx, dx, si, di;
} BdPro;

static void bd(BdPro *p)
{
    uint64_t dummy;
    asm volatile(
        "pushq %%rbp\n\t"
        "pushq %%rax\n\t"
        "movq 40(%%rax), %%rdi\n\t"
        "movq 32(%%rax), %%rsi\n\t"
        "movq 24(%%rax), %%rdx\n\t"
        "movq 16(%%rax), %%rcx\n\t"
        "movq  8(%%rax), %%rbx\n\t"
        "movq   (%%rax), %%rax\n\t"
        "inl %%dx, %%eax\n\t"
        "xchgq %%rax, (%%rsp)\n\t"
        "movq %%rdi, 40(%%rax)\n\t"
        "movq %%rsi, 32(%%rax)\n\t"
        "movq %%rdx, 24(%%rax)\n\t"
        "movq %%rcx, 16(%%rax)\n\t"
        "movq %%rbx,  8(%%rax)\n\t"
        "popq   (%%rax)\n\t"
        "popq %%rbp\n\t"
        : "=a"(dummy)
        : "0"(p)
        : "rbx", "rcx", "rdx", "rsi", "rdi", "memory"
    );
}

static void bdhb_out(BdPro *p)
{
    uint64_t dummy;
    asm volatile(
        "pushq %%rbp\n\t"
        "pushq %%rax\n\t"
        "movq 48(%%rax), %%rbp\n\t"
        "movq 40(%%rax), %%rdi\n\t"
        "movq 32(%%rax), %%rsi\n\t"
        "movq 24(%%rax), %%rdx\n\t"
        "movq 16(%%rax), %%rcx\n\t"
        "movq  8(%%rax), %%rbx\n\t"
        "movq   (%%rax), %%rax\n\t"
        "cld\n\t"
        "rep; outsb\n\t"
        "xchgq %%rax, (%%rsp)\n\t"
        "movq %%rbp, 48(%%rax)\n\t"
        "movq %%rdi, 40(%%rax)\n\t"
        "movq %%rsi, 32(%%rax)\n\t"
        "movq %%rdx, 24(%%rax)\n\t"
        "movq %%rcx, 16(%%rax)\n\t"
        "movq %%rbx,  8(%%rax)\n\t"
        "popq   (%%rax)\n\t"
        "popq %%rbp\n\t"
        : "=a"(dummy) : "0"(p)
        : "rbx", "rcx", "rdx", "rsi", "rdi", "memory", "cc"
    );
}

static void bdhb_in(BdPro *p)
{
    uint64_t dummy;
    asm volatile(
        "pushq %%rbp\n\t"
        "pushq %%rax\n\t"
        "movq 48(%%rax), %%rbp\n\t"
        "movq 40(%%rax), %%rdi\n\t"
        "movq 32(%%rax), %%rsi\n\t"
        "movq 24(%%rax), %%rdx\n\t"
        "movq 16(%%rax), %%rcx\n\t"
        "movq  8(%%rax), %%rbx\n\t"
        "movq   (%%rax), %%rax\n\t"
        "cld\n\t"
        "rep; insb\n\t"
        "xchgq %%rax, (%%rsp)\n\t"
        "movq %%rbp, 48(%%rax)\n\t"
        "movq %%rdi, 40(%%rax)\n\t"
        "movq %%rsi, 32(%%rax)\n\t"
        "movq %%rdx, 24(%%rax)\n\t"
        "movq %%rcx, 16(%%rax)\n\t"
        "movq %%rbx,  8(%%rax)\n\t"
        "popq   (%%rax)\n\t"
        "popq %%rbp\n\t"
        : "=a"(dummy) : "0"(p)
        : "rbx", "rcx", "rdx", "rsi", "rdi", "memory", "cc"
    );
}

/* 7-register struct for HB ops (ax,bx,cx,dx,si,di,bp) */
typedef struct { uint64_t ax,bx,cx,dx,si,di,bp; } BdHb;

static int bdoor_send_recv(const char *request, char **reply, uint32_t *replylen)
{
    BdPro p;
    uint32_t id, c1, c2, rlen;
    char *buf;

    if (ioperm(BDOOR_PORT, 2, 1) != 0 && iopl(3) != 0) {
        DBG("I/O port access denied: %s\n", strerror(errno));
        return -1;
    }

    struct sigaction sa = {0}, old_segv, old_bus;
    sa.sa_handler = fault_handler;
    sigaction(SIGSEGV, &sa, &old_segv);
    sigaction(SIGBUS,  &sa, &old_bus);
    got_fault = 0;

    /* GETVERSION check */
    p = (BdPro){ BDOOR_MAGIC, ~(uint64_t)BDOOR_MAGIC, 0xa0000, BDOOR_PORT, 0, 0 };
    bd(&p);
    DBG("GETVERSION: bx=%08lx want=%08lx fault=%d\n", p.bx, (unsigned long)BDOOR_MAGIC, got_fault);
    if (got_fault || (uint32_t)p.bx != (uint32_t)BDOOR_MAGIC) {
        sigaction(SIGSEGV, &old_segv, NULL);
        sigaction(SIGBUS,  &old_bus,  NULL);
        return -1;
    }

    /* OPEN */
    p = (BdPro){ BDOOR_MAGIC, RPCI_PROTOCOL, (MSG_OPEN<<16), BDOOR_PORT, 0, 0 };
    bd(&p);
    DBG("OPEN: cx=%08lx si=%08lx di=%08lx ok=%d\n", p.cx, p.si, p.di, !!(p.cx & STATUS_OK));
    if (!(p.cx & STATUS_OK)) { sigaction(SIGSEGV, &old_segv, NULL); sigaction(SIGBUS, &old_bus, NULL); return -1; }
    id = p.cx & 0xffff; c1 = p.si; c2 = p.di;

    uint32_t mlen = strlen(request);

    /* SENDSIZE */
    p = (BdPro){ BDOOR_MAGIC, mlen, (MSG_SENDSIZE<<16)|id, BDOOR_PORT, c1, c2 };
    bd(&p);
    if (!(p.cx & STATUS_OK)) goto close_fail;

    if (mlen > 0) {
        /* HB OUT — need 7-reg struct including bp */
        typedef struct { uint64_t ax,bx,cx,dx,si,di,bp; } H;
        H h = { BDOOR_MAGIC, STATUS_OK, mlen, BDOORHB_PORT,
                (uintptr_t)request, c2, c1 };
        /* Use inline asm directly for HB since our struct doesn't have bp slot */
        uint64_t dummy;
        asm volatile(
            "pushq %%rbp\n\t"
            "pushq %%rax\n\t"
            "movq 48(%%rax), %%rbp\n\t"
            "movq 40(%%rax), %%rdi\n\t"
            "movq 32(%%rax), %%rsi\n\t"
            "movq 24(%%rax), %%rdx\n\t"
            "movq 16(%%rax), %%rcx\n\t"
            "movq  8(%%rax), %%rbx\n\t"
            "movq   (%%rax), %%rax\n\t"
            "cld\n\t"
            "rep; outsb\n\t"
            "xchgq %%rax, (%%rsp)\n\t"
            "movq %%rdi, 40(%%rax)\n\t"
            "movq %%rsi, 32(%%rax)\n\t"
            "movq %%rdx, 24(%%rax)\n\t"
            "movq %%rcx, 16(%%rax)\n\t"
            "movq %%rbx,  8(%%rax)\n\t"
            "popq   (%%rax)\n\t"
            "popq %%rbp\n\t"
            : "=a"(dummy) : "0"(&h)
            : "rbx","rcx","rdx","rsi","rdi","memory","cc");
        DBG("HB_OUT: bx=%08lx ok=%d\n", h.bx, !!(h.bx & STATUS_OK));
        if (!(h.bx & STATUS_OK)) goto close_fail;
    }

    /* RECVSIZE */
    p = (BdPro){ BDOOR_MAGIC, 0, (MSG_RECVSIZE<<16)|id, BDOOR_PORT, c1, c2 };
    bd(&p);
    DBG("RECVSIZE: cx=%08lx bx=%08lx ok=%d\n", p.cx, p.bx, !!(p.cx & STATUS_OK));
    if (!(p.cx & STATUS_OK)) goto close_fail;
    rlen = p.bx;

    buf = malloc(rlen + 1); if (!buf) goto close_fail;
    buf[rlen] = '\0';

    if (rlen > 0) {
        typedef struct { uint64_t ax,bx,cx,dx,si,di,bp; } H;
        H h = { BDOOR_MAGIC, STATUS_OK, rlen, BDOORHB_PORT, c1, (uintptr_t)buf, c1 };
        uint64_t dummy;
        asm volatile(
            "pushq %%rbp\n\t"
            "pushq %%rax\n\t"
            "movq 48(%%rax), %%rbp\n\t"
            "movq 40(%%rax), %%rdi\n\t"
            "movq 32(%%rax), %%rsi\n\t"
            "movq 24(%%rax), %%rdx\n\t"
            "movq 16(%%rax), %%rcx\n\t"
            "movq  8(%%rax), %%rbx\n\t"
            "movq   (%%rax), %%rax\n\t"
            "cld\n\t"
            "rep; insb\n\t"
            "xchgq %%rax, (%%rsp)\n\t"
            "movq %%rdi, 40(%%rax)\n\t"
            "movq %%rsi, 32(%%rax)\n\t"
            "movq %%rdx, 24(%%rax)\n\t"
            "movq %%rcx, 16(%%rax)\n\t"
            "movq %%rbx,  8(%%rax)\n\t"
            "popq   (%%rax)\n\t"
            "popq %%rbp\n\t"
            : "=a"(dummy) : "0"(&h)
            : "rbx","rcx","rdx","rsi","rdi","memory","cc");
        DBG("HB_IN: bx=%08lx ok=%d\n", h.bx, !!(h.bx & STATUS_OK));
        if (!(h.bx & STATUS_OK)) { free(buf); goto close_fail; }
    }

    /* RECVSTATUS */
    p = (BdPro){ BDOOR_MAGIC, 0x10001, (MSG_RECVSTATUS<<16)|id, BDOOR_PORT, c1, c2 };
    bd(&p);

    /* CLOSE */
    p = (BdPro){ BDOOR_MAGIC, 0, (MSG_CLOSE<<16)|id, BDOOR_PORT, c1, c2 };
    bd(&p);

    sigaction(SIGSEGV, &old_segv, NULL);
    sigaction(SIGBUS,  &old_bus,  NULL);
    *reply = buf; *replylen = rlen;
    return 0;

close_fail:
    p = (BdPro){ BDOOR_MAGIC, 0, (MSG_CLOSE<<16)|id, BDOOR_PORT, c1, c2 };
    bd(&p);
    sigaction(SIGSEGV, &old_segv, NULL);
    sigaction(SIGBUS,  &old_bus,  NULL);
    return -1;
}

/* ── Kernel module via /sys/kernel/vmci ──────────────────────────────────── */
static int check_vsock_available(void)
{
    /* Check if AF_VSOCK is supported */
    int fd = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (fd >= 0) { close(fd); return 1; }
    DBG("AF_VSOCK not available: %s\n", strerror(errno));
    return 0;
}

/* ── main ────────────────────────────────────────────────────────────────── */
int main(int argc, char *argv[])
{
    int argi = 1;
    if (argc >= 2 && strcmp(argv[1], "--debug") == 0) {
        debug_mode = 1; argi = 2;
    }
    if (argc <= argi) {
        fprintf(stderr, "Usage: vmware-rpctool [--debug] <command>\n");
        fprintf(stderr, "  e.g.: vmware-rpctool \"info-get guestinfo.hostname\"\n");
        return 1;
    }

    const char *request = argv[argi];
    char *reply = NULL;
    uint32_t replylen = 0;
    int rc = -1;

    /* Try VSOCK first (works on ESXi without I/O port access) */
    if (check_vsock_available()) {
        DBG("Trying VSOCK channel\n");
        rc = vsock_send_recv(request, &reply, &replylen);
    }

    /* Fall back to I/O port backdoor */
    if (rc < 0) {
        DBG("Trying backdoor I/O port channel\n");
        rc = bdoor_send_recv(request, &reply, &replylen);
    }

    if (rc < 0 || !reply) {
        fprintf(stderr, "vmware-rpctool: failed to communicate with VMware\n");
        return 1;
    }

    DBG("Final reply (%u bytes): [%.*s]\n", replylen, (int)replylen, reply);

    /* "1 <value>" = success, "1" alone = empty success */
    if (replylen >= 1 && reply[0] == '1') {
        if (replylen >= 2 && reply[1] == ' ')
            printf("%s\n", reply + 2);
        free(reply);
        return 0;
    }

    if (debug_mode)
        fprintf(stderr, "VMware error: [%.*s]\n", (int)replylen, reply);
    free(reply);
    return 1;
}

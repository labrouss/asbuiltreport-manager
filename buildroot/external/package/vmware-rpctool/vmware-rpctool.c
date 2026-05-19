/*
 * vmware-rpctool.c — minimal VMware GuestInfo reader
 *
 * Uses the VMware backdoor I/O port (0x5658 / 0x5659) to read guestinfo
 * properties. This replaces open-vm-tools for musl-based appliances.
 *
 * Usage: vmware-rpctool "info-get guestinfo.<key>"
 *
 * Protocol reference: VMware backdoor port protocol (VX/VY ports)
 * Magic: 0x564D5868 ('VMXh'), port 0x5658 (VX) for 32-bit commands
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/io.h>

#define VMWARE_MAGIC        0x564D5868UL  /* 'VMXh' */
#define VMWARE_PORT         0x5658        /* 'VX'   */
#define VMWARE_PORT_RPC     0x5659        /* 'VY' - high-bandwidth */

#define VMCMD_GET_VERSION   0x0a
#define VMCMD_RPC_OPEN      0x1c
#define VMCMD_RPC_SET_LEN   0x1d
#define VMCMD_RPC_GET_DATA  0x1e
#define VMCMD_RPC_END       0x1f

/* VMware backdoor call via port 0x5658 */
static void vmware_cmd(uint32_t *eax, uint32_t *ebx, uint32_t *ecx,
                       uint32_t *edx)
{
    __asm__ volatile (
        "in %%dx, %%eax"
        : "+a"(*eax), "+b"(*ebx), "+c"(*ecx), "+d"(*edx)
    );
}

/* Check if running inside VMware */
static int vmware_check(void)
{
    uint32_t eax = VMWARE_MAGIC, ebx = ~VMWARE_MAGIC,
             ecx = VMCMD_GET_VERSION, edx = VMWARE_PORT;
    vmware_cmd(&eax, &ebx, &ecx, &edx);
    return (ebx == VMWARE_MAGIC);
}

/*
 * Send an RPC command and receive the response.
 * Uses the RPCI (Remote Procedure Call Interface) protocol.
 */
static int vmware_rpc(const char *request, char *reply, size_t reply_sz)
{
    uint32_t eax, ebx, ecx, edx;
    size_t req_len = strlen(request);
    uint32_t channel, cookie1, cookie2;
    uint32_t reply_len;
    size_t i;

    /* Open RPC channel */
    eax = VMWARE_MAGIC;
    ebx = 0x49435052; /* 'RPCI' */
    ecx = VMCMD_RPC_OPEN << 16;
    edx = VMWARE_PORT;
    vmware_cmd(&eax, &ebx, &ecx, &edx);
    channel = ecx & 0xffff;
    cookie1 = ecx >> 16;  /* not actually used this way, simplified */

    /* Send request length */
    eax = VMWARE_MAGIC;
    ebx = req_len;
    ecx = (VMCMD_RPC_SET_LEN << 16) | channel;
    edx = VMWARE_PORT;
    vmware_cmd(&eax, &ebx, &ecx, &edx);
    if ((ecx & 0x10000) == 0) return -1;

    /* Send request data word by word via high-bandwidth port */
    for (i = 0; i < req_len; i += 4) {
        uint32_t word = 0;
        memcpy(&word, request + i, req_len - i >= 4 ? 4 : req_len - i);
        eax = VMWARE_MAGIC;
        ebx = word;
        ecx = (VMCMD_RPC_GET_DATA << 16) | channel;
        edx = VMWARE_PORT;
        vmware_cmd(&eax, &ebx, &ecx, &edx);
    }

    /* Get reply length */
    eax = VMWARE_MAGIC;
    ebx = 0;
    ecx = (VMCMD_RPC_GET_DATA << 16) | channel;
    edx = VMWARE_PORT;
    vmware_cmd(&eax, &ebx, &ecx, &edx);
    reply_len = ebx;
    if (reply_len == 0 || reply_len >= reply_sz) {
        /* Close channel and fail */
        goto close;
    }

    /* Read reply data */
    for (i = 0; i < reply_len; i += 4) {
        uint32_t word;
        eax = VMWARE_MAGIC;
        ebx = 0x10000;
        ecx = (VMCMD_RPC_GET_DATA << 16) | channel;
        edx = VMWARE_PORT;
        vmware_cmd(&eax, &ebx, &ecx, &edx);
        word = ebx;
        size_t copy = reply_len - i;
        if (copy > 4) copy = 4;
        memcpy(reply + i, &word, copy);
    }
    reply[reply_len] = '\0';

close:
    /* Close RPC channel */
    eax = VMWARE_MAGIC;
    ebx = 0;
    ecx = (VMCMD_RPC_END << 16) | channel;
    edx = VMWARE_PORT;
    vmware_cmd(&eax, &ebx, &ecx, &edx);

    return (int)reply_len;
}

int main(int argc, char *argv[])
{
    char reply[65536];
    int len;

    if (argc < 2) {
        fprintf(stderr, "Usage: vmware-rpctool <command>\n");
        return 1;
    }

    /* Request I/O port access */
    if (ioperm(VMWARE_PORT, 2, 1) != 0) {
        /* Try iopl as fallback */
        if (iopl(3) != 0) {
            fprintf(stderr, "vmware-rpctool: cannot access I/O ports\n");
            return 1;
        }
    }

    if (!vmware_check()) {
        fprintf(stderr, "vmware-rpctool: not running in VMware\n");
        return 1;
    }

    len = vmware_rpc(argv[1], reply, sizeof(reply) - 1);
    if (len < 0) {
        return 1;
    }

    /* VMware replies start with "1 " (success) or "0 " (failure) */
    if (len >= 2 && reply[0] == '1' && reply[1] == ' ') {
        /* Print the value (skip "1 " prefix) */
        printf("%s", reply + 2);
        return 0;
    }

    return 1;
}

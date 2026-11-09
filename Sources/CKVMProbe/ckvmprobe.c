// What a vmapple guest needs from arm64 KVM, checked with a throwaway guest:
// a 16 KiB stage 1 on a host of any page size, VMApple's hypercall range
// forwarded to user space, PSCI 1.1, and pointer authentication.
//
// The guest payload and page tables follow probes/kvm/probe.c from
// Hackintosh-on-DGXSpark/hmacos-arm, Copyright (c) 2026 Icegrave0391, used under
// the MIT License, whose text is in LICENSE.
#define _GNU_SOURCE
#include "ckvmprobe.h"

#include <stdio.h>
#include <string.h>

#if defined(__linux__) && defined(__aarch64__)

#include <errno.h>
#include <fcntl.h>
#include <linux/kvm.h>
#include <sched.h>
#include <stddef.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

// Linux 6.4's SMCCC filter, for building against older kernel headers.
#ifndef KVM_ARM_VM_SMCCC_CTRL
#define KVM_ARM_VM_SMCCC_CTRL 0
#define KVM_ARM_VM_SMCCC_FILTER 0
#define KVM_SMCCC_FILTER_FWD_TO_USER 2
struct kvm_smccc_filter {
    __u32 base;
    __u32 nr_functions;
    __u8 action;
    __u8 pad[15];
};
#endif

#define RAM_BYTES (2UL * 1024 * 1024)
#define GUEST_BASE UINT64_C(0x40000000)
#define MMIO_BASE UINT64_C(0x10000000)
#define PAC_POINTER UINT64_C(0x40000100)
#define EXPECTED UINT64_C(0x4b564d5000061df0)
#define VMAPPLE_HVC_BASE 0xc1000000U

#define CORE_REG(name)                                                                             \
    (KVM_REG_ARM64 | KVM_REG_SIZE_U64 | KVM_REG_ARM_CORE | KVM_REG_ARM_CORE_REG(regs.name))

extern const unsigned char ckvm_guest_start[], ckvm_guest_end[];
__asm__(".pushsection .rodata.ckvm_guest,\"a\",%progbits\n"
        ".balign 4\n"
        ".global ckvm_guest_start, ckvm_guest_end\n"
        "ckvm_guest_start:\n"
        "movz x0, #0xc100, lsl #16\n"
        "mov x1, #0x123\n"
        "hvc #0\n"
        "mov x11, x0\n"
        "mrs x12, cntfrq_el0\n"
        "mov x0, #0x1234\n"
        "mov x1, #0x56\n"
        "mul x2, x0, x1\n"
        "add x2, x2, #0x78\n"
        "movz x3, #0x4d50, lsl #32\n"
        "movk x3, #0x4b56, lsl #48\n"
        "eor x2, x2, x3\n"
        "mov x4, #0x10000000\n"
        "mov x5, #0x40000000\n"
        "add x5, x5, #0x100\n"
        "mov x6, #0x5678\n"
        ".inst 0xdac100c5\n" // pacia x5, x6
        "mov x7, x5\n"
        ".inst 0xdac110c5\n" // autia x5, x6
        "str x2, [x4]\n"
        "1: b 1b\n"
        "ckvm_guest_end:\n"
        ".popsection\n");

// MARK: - Helpers

#define FAIL(...)                                                                                  \
    do {                                                                                           \
        snprintf(report->error, sizeof(report->error), __VA_ARGS__);                               \
        return -1;                                                                                 \
    } while (0)

#define CHECKED_IOCTL(result, fd, request, argument)                                               \
    do {                                                                                           \
        unsigned int retries = 0;                                                                  \
        do {                                                                                       \
            (result) = ioctl((fd), (request), (argument));                                         \
        } while ((result) < 0 && errno == EINTR && ++retries < 8);                                 \
        if ((result) < 0)                                                                          \
            FAIL("%s: %s", #request, strerror(errno));                                             \
    } while (0)

static int get_reg(int vcpu, uint64_t id, uint64_t *value) {
    struct kvm_one_reg reg = {.id = id, .addr = (uintptr_t)value};
    return ioctl(vcpu, KVM_GET_ONE_REG, &reg);
}

static int set_reg(int vcpu, uint64_t id, uint64_t value) {
    struct kvm_one_reg reg = {.id = id, .addr = (uintptr_t)&value};
    return ioctl(vcpu, KVM_SET_ONE_REG, &reg);
}

#define GET_REG(vcpu, id, out)                                                                     \
    do {                                                                                           \
        if (get_reg((vcpu), (id), (out)) < 0)                                                      \
            FAIL("KVM_GET_ONE_REG %s: %s", #id, strerror(errno));                                  \
    } while (0)

#define SET_REG(vcpu, id, value)                                                                   \
    do {                                                                                           \
        if (set_reg((vcpu), (id), (value)) < 0)                                                    \
            FAIL("KVM_SET_ONE_REG %s: %s", #id, strerror(errno));                                  \
    } while (0)

// MARK: - Probe

int ckvm_probe(int cpu, ckvm_report *report) {
    memset(report, 0, sizeof(*report));
    int result;

    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    if (sched_setaffinity(0, sizeof(set), &set) != 0)
        FAIL("sched_setaffinity(%d): %s", cpu, strerror(errno));
    alarm(8);

    int kvm = open("/dev/kvm", O_RDWR | O_CLOEXEC);
    if (kvm < 0)
        FAIL("/dev/kvm: %s", strerror(errno));
    CHECKED_IOCTL(report->api_version, kvm, KVM_GET_API_VERSION, 0);
    CHECKED_IOCTL(report->ipa_bits, kvm, KVM_CHECK_EXTENSION, KVM_CAP_ARM_VM_IPA_SIZE);
    CHECKED_IOCTL(report->ptrauth_address, kvm, KVM_CHECK_EXTENSION, KVM_CAP_ARM_PTRAUTH_ADDRESS);
    CHECKED_IOCTL(report->ptrauth_generic, kvm, KVM_CHECK_EXTENSION, KVM_CAP_ARM_PTRAUTH_GENERIC);
    if (report->ptrauth_address <= 0 || report->ptrauth_generic <= 0)
        FAIL("KVM does not offer pointer authentication");

    int vm;
    CHECKED_IOCTL(vm, kvm, KVM_CREATE_VM, 0);

    struct kvm_smccc_filter filter = {
        .base = VMAPPLE_HVC_BASE,
        .nr_functions = 0x100,
        .action = KVM_SMCCC_FILTER_FWD_TO_USER,
    };
    struct kvm_device_attr attribute = {
        .group = KVM_ARM_VM_SMCCC_CTRL,
        .attr = KVM_ARM_VM_SMCCC_FILTER,
        .addr = (uintptr_t)&filter,
    };
    CHECKED_IOCTL(result, vm, KVM_SET_DEVICE_ATTR, &attribute);

    int vcpu;
    CHECKED_IOCTL(vcpu, vm, KVM_CREATE_VCPU, 0);
    struct kvm_vcpu_init init = {0};
    CHECKED_IOCTL(result, vm, KVM_ARM_PREFERRED_TARGET, &init);
    memset(init.features, 0, sizeof(init.features));
    init.features[0] = (1U << KVM_ARM_VCPU_PSCI_0_2) | (1U << KVM_ARM_VCPU_PTRAUTH_ADDRESS) |
                       (1U << KVM_ARM_VCPU_PTRAUTH_GENERIC);
    CHECKED_IOCTL(result, vcpu, KVM_ARM_VCPU_INIT, &init);

    GET_REG(vcpu, ARM64_SYS_REG(3, 0, 0, 6, 1), &report->isar1);
    GET_REG(vcpu, ARM64_SYS_REG(3, 0, 0, 6, 2), &report->isar2);
    GET_REG(vcpu, ARM64_SYS_REG(3, 0, 0, 7, 0), &report->mmfr0);
    report->tgran16 = (unsigned int)((report->mmfr0 >> 20) & 15);
    report->pa_range = (unsigned int)(report->mmfr0 & 15);
    if (report->tgran16 != 1 && report->tgran16 != 2)
        FAIL("no 16 KiB stage 1 granule: TGran16=%u", report->tgran16);

    SET_REG(vcpu, KVM_REG_ARM_PSCI_VERSION, 0x00010001);
    uint64_t psci = 0;
    GET_REG(vcpu, KVM_REG_ARM_PSCI_VERSION, &psci);
    report->psci_1_1 = psci == 0x00010001;

    void *ram = mmap(NULL, RAM_BYTES, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (ram == MAP_FAILED)
        FAIL("mmap guest RAM: %s", strerror(errno));
    size_t guest_bytes = (uintptr_t)ckvm_guest_end - (uintptr_t)ckvm_guest_start;
    memcpy(ram, ckvm_guest_start, guest_bytes);
    __builtin___clear_cache((char *)ram, (char *)ram + guest_bytes);
    struct kvm_userspace_memory_region memory = {
        .slot = 0,
        .guest_phys_addr = GUEST_BASE,
        .memory_size = RAM_BYTES,
        .userspace_addr = (uintptr_t)ram,
    };
    CHECKED_IOCTL(result, vm, KVM_SET_USER_MEMORY_REGION, &memory);

    int run_bytes;
    CHECKED_IOCTL(run_bytes, kvm, KVM_GET_VCPU_MMAP_SIZE, 0);
    struct kvm_run *run =
        mmap(NULL, (size_t)run_bytes, PROT_READ | PROT_WRITE, MAP_SHARED, vcpu, 0);
    if (run == MAP_FAILED)
        FAIL("mmap kvm_run: %s", strerror(errno));

    // 48-bit VA: 16 KiB L0/L1/L2 tables with identity-mapped 32 MiB blocks.
    uint64_t *l0 = (uint64_t *)((char *)ram + 0x4000);
    uint64_t *l1 = (uint64_t *)((char *)ram + 0x8000);
    uint64_t *l2 = (uint64_t *)((char *)ram + 0xc000);
    l0[0] = (GUEST_BASE + 0x8000) | 3;
    l1[0] = (GUEST_BASE + 0xc000) | 3;
    l2[GUEST_BASE >> 25] = GUEST_BASE | 1 | (1 << 10) | (3 << 8);
    l2[MMIO_BASE >> 25] =
        MMIO_BASE | 1 | (1 << 10) | (1 << 2) | (UINT64_C(1) << 53) | (UINT64_C(1) << 54);
    uint64_t tcr = 16 | (1 << 8) | (1 << 10) | (3 << 12) | (2 << 14) | (16 << 16) | (1 << 23) |
                   (UINT64_C(1) << 30) | (UINT64_C(2) << 32);

    uint64_t sctlr = 0;
    GET_REG(vcpu, ARM64_SYS_REG(3, 0, 1, 0, 0), &sctlr);
    sctlr &= ~(UINT64_C(1) << 25);
    sctlr |= (UINT64_C(1) << 31) | 1; // EnIA, MMU on.
    SET_REG(vcpu, CORE_REG(pc), GUEST_BASE);
    SET_REG(vcpu, CORE_REG(pstate), 0x3c5); // EL1h, DAIF masked.
    SET_REG(vcpu, ARM64_SYS_REG(3, 0, 10, 2, 0), 0xff); // MAIR: normal, device.
    SET_REG(vcpu, ARM64_SYS_REG(3, 0, 2, 0, 0), GUEST_BASE + 0x4000); // TTBR0_EL1.
    SET_REG(vcpu, ARM64_SYS_REG(3, 0, 2, 0, 2), tcr);
    SET_REG(vcpu, ARM64_SYS_REG(3, 0, 2, 1, 0), UINT64_C(0x0123456789abcdef)); // APIAKeyLo_EL1.
    SET_REG(vcpu, ARM64_SYS_REG(3, 0, 2, 1, 1), UINT64_C(0xfedcba9876543210)); // APIAKeyHi_EL1.
    SET_REG(vcpu, ARM64_SYS_REG(3, 0, 1, 0, 0), sctlr);

    // The first exit must be the hypercall, made with the 16 KiB MMU on.
    CHECKED_IOCTL(result, vcpu, KVM_RUN, 0);
    if (run->exit_reason != KVM_EXIT_HYPERCALL || run->hypercall.nr != VMAPPLE_HVC_BASE)
        FAIL("expected the VMApple hypercall, got exit %u", run->exit_reason);
    uint64_t argument = 0;
    GET_REG(vcpu, CORE_REG(regs[1]), &argument);
    if (argument != 0x123)
        FAIL("hypercall argument changed: 0x%llx", (unsigned long long)argument);
    SET_REG(vcpu, CORE_REG(regs[0]), 0x42);
    CHECKED_IOCTL(result, vcpu, KVM_RUN, 0);
    uint64_t answer = 0;
    GET_REG(vcpu, CORE_REG(regs[11]), &answer);
    report->hvc_forwarded = answer == 0x42;
    GET_REG(vcpu, CORE_REG(regs[12]), &report->cntfrq);

    uint64_t apctl = 0;
    struct kvm_one_reg apple_reg = {.id = ARM64_SYS_REG(3, 6, 15, 15, 0),
                                    .addr = (uintptr_t)&apctl};
    report->apple_key_registers = ioctl(vcpu, KVM_GET_ONE_REG, &apple_reg) == 0;

    // The second exit is the store past the arithmetic and the PAC round trip.
    if (run->exit_reason != KVM_EXIT_MMIO || run->mmio.phys_addr != MMIO_BASE ||
        !run->mmio.is_write || run->mmio.len != sizeof(uint64_t))
        FAIL("expected an 8 byte MMIO store, got exit %u", run->exit_reason);
    uint64_t stored;
    memcpy(&stored, run->mmio.data, sizeof(stored));
    if (stored != EXPECTED)
        FAIL("guest computed 0x%llx", (unsigned long long)stored);
    report->mmu_16k_ran = 1;

    uint64_t signed_pointer = 0, authenticated = 0;
    GET_REG(vcpu, CORE_REG(regs[7]), &signed_pointer);
    GET_REG(vcpu, CORE_REG(regs[5]), &authenticated);
    report->pac_round_trip = signed_pointer != PAC_POINTER && authenticated == PAC_POINTER;

    alarm(0);
    munmap(run, (size_t)run_bytes);
    munmap(ram, RAM_BYTES);
    close(vcpu);
    close(vm);
    close(kvm);
    return 0;
}

#else

int ckvm_probe(int cpu, ckvm_report *report) {
    (void)cpu;
    memset(report, 0, sizeof(*report));
    snprintf(report->error, sizeof(report->error), "needs arm64 Linux");
    return -1;
}

#endif

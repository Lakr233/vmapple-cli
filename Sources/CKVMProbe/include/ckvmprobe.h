#ifndef CKVMPROBE_H
#define CKVMPROBE_H

#include <stdint.h>

typedef struct {
    int api_version;
    int ipa_bits;
    int ptrauth_address;
    int ptrauth_generic;
    uint64_t isar1;
    uint64_t isar2;
    uint64_t mmfr0;
    unsigned int tgran16;
    unsigned int pa_range;
    int psci_1_1;
    int mmu_16k_ran;
    int hvc_forwarded;
    int pac_round_trip;
    int apple_key_registers;
    uint64_t cntfrq;
    char error[160];
} ckvm_report;

/// Runs a throwaway 2 MiB guest pinned to `cpu`. Returns 0 when every check
/// ran, and -1 with `report->error` set otherwise. Exits the process if the
/// guest hangs for 8 seconds.
int ckvm_probe(int cpu, ckvm_report *report);

#endif

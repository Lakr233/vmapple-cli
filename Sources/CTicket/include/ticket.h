#pragma once

#include <stddef.h>
#include <stdint.h>

/// Asks Apple's signing server for a ticket, through libtatsu. A hand-written
/// request gets STATUS=94 even for a real Mac.
///
/// With `policy_digest` the request is the local policy's, which needs
/// `next_stage_hash`, the SHA-384 of the AP ticket. Both are 48 bytes.
/// On success `*ticket` is malloc'd and the result is 0.
int vmapple_ticket_request(
    const void *manifest,
    size_t manifest_size,
    uint64_t ecid,
    const uint8_t ap_nonce[32],
    const uint8_t sep_nonce[20],
    const uint8_t *policy_digest,
    const uint8_t *next_stage_hash,
    uint8_t **ticket,
    size_t *ticket_size
);

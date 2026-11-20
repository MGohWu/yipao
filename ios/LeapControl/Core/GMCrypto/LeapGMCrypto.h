#ifndef LEAP_GM_CRYPTO_H
#define LEAP_GM_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    LeapGMCryptoSuccess = 1,
    LeapGMCryptoInvalidInput = -1,
    LeapGMCryptoInvalidCertificate = -2,
    LeapGMCryptoKeyGenerationFailed = -3,
    LeapGMCryptoKeyAgreementFailed = -4,
    LeapGMCryptoOutputTooSmall = -5,
    LeapGMCryptoCipherFailed = -6
};

/// Implements the BabaSSL 8.3.1 SM2 KAP used by the official vehicle app.
/// The local key is used as both static and ephemeral, as is the certificate key.
int32_t LeapGMSM2KAPFromCertificate(
    const uint8_t *certificate_der,
    size_t certificate_der_length,
    const uint8_t *private_key,
    size_t private_key_length,
    uint8_t public_key[65],
    uint8_t shared_key[32]
);

/// Raw-public-key entry point retained for deterministic protocol tests.
int32_t LeapGMSM2KAPFromPublicKey(
    const uint8_t *peer_public_key,
    size_t peer_public_key_length,
    const uint8_t *private_key,
    size_t private_key_length,
    uint8_t public_key[65],
    uint8_t shared_key[32]
);

int32_t LeapGMSM3(
    const uint8_t *input,
    size_t input_length,
    uint8_t digest[32]
);

int32_t LeapGMSM4CBCPKCS7Encrypt(
    const uint8_t *input,
    size_t input_length,
    const uint8_t key[16],
    const uint8_t iv[16],
    uint8_t *output,
    size_t output_capacity,
    size_t *output_length
);

int32_t LeapGMSM4CBCPKCS7Decrypt(
    const uint8_t *input,
    size_t input_length,
    const uint8_t key[16],
    const uint8_t iv[16],
    uint8_t *output,
    size_t output_capacity,
    size_t *output_length
);

#ifdef __cplusplus
}
#endif

#endif

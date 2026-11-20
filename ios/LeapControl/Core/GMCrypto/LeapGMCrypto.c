#include "LeapGMCrypto.h"

#include <gmssl/sm2.h>
#include <gmssl/sm3.h>
#include <gmssl/sm4.h>
#include <gmssl/x509.h>
#include <string.h>

static void leap_gm_clear(void *value, size_t length) {
    volatile uint8_t *bytes = (volatile uint8_t *)value;
    while (length-- > 0) {
        *bytes++ = 0;
    }
}

static void leap_gm_sm2_x_bar(const uint8_t x[32], uint8_t result[32]) {
    // w = 127 for the 256-bit SM2 group: 2^w + (x mod 2^w).
    memset(result, 0, 16);
    memcpy(result + 16, x + 16, 16);
    result[16] |= 0x80;
}

static int32_t leap_gm_sm2_kap(
    const SM2_POINT *peer_public,
    const uint8_t *private_key,
    size_t private_key_length,
    uint8_t public_key[65],
    uint8_t shared_key[32]
) {
    SM2_KEY self_key;
    SM2_KEY checked_peer_key;
    SM2_POINT peer_combined;
    SM2_POINT agreement_point;
    SM2_Fn self_x_bar;
    SM2_Fn peer_x_bar;
    SM2_Fn private_scalar;
    SM2_Fn product;
    SM2_Fn self_factor;
    SM2_Fn one;
    SM2_Fn peer_factor;
    uint8_t x_bar_bytes[32];
    uint8_t scalar_bytes[32];
    uint8_t material[32 * 4];
    SM3_KDF_CTX kdf;
    int32_t status = LeapGMCryptoKeyAgreementFailed;

    memset(&self_key, 0, sizeof(self_key));
    memset(&checked_peer_key, 0, sizeof(checked_peer_key));
    memset(&peer_combined, 0, sizeof(peer_combined));
    memset(&agreement_point, 0, sizeof(agreement_point));
    memset(material, 0, sizeof(material));

    if (peer_public == NULL || public_key == NULL || shared_key == NULL) {
        return LeapGMCryptoInvalidInput;
    }
    if (private_key == NULL && private_key_length == 0) {
        if (sm2_key_generate(&self_key) != 1) {
            return LeapGMCryptoKeyGenerationFailed;
        }
    } else if (private_key != NULL && private_key_length == 32) {
        if (sm2_key_set_private_key(&self_key, private_key) != 1) {
            return LeapGMCryptoKeyGenerationFailed;
        }
    } else {
        return LeapGMCryptoInvalidInput;
    }
    if (sm2_key_set_public_key(&checked_peer_key, peer_public) != 1) {
        status = LeapGMCryptoInvalidCertificate;
        goto cleanup;
    }

    leap_gm_sm2_x_bar(self_key.public_key.x, x_bar_bytes);
    sm2_bn_from_bytes(self_x_bar, x_bar_bytes);
    sm2_bn_from_bytes(private_scalar, self_key.private_key);
    sm2_fn_mul(product, self_x_bar, private_scalar);
    sm2_fn_add(self_factor, product, private_scalar);

    leap_gm_sm2_x_bar(peer_public->x, x_bar_bytes);
    sm2_bn_from_bytes(peer_x_bar, x_bar_bytes);
    sm2_fn_set_one(one);
    sm2_fn_add(peer_factor, peer_x_bar, one);

    sm2_bn_to_bytes(peer_factor, scalar_bytes);
    if (sm2_point_mul(&peer_combined, scalar_bytes, peer_public) != 1) {
        goto cleanup;
    }
    sm2_bn_to_bytes(self_factor, scalar_bytes);
    if (sm2_point_mul(&agreement_point, scalar_bytes, &peer_combined) != 1
        || sm2_point_is_at_infinity(&agreement_point)) {
        goto cleanup;
    }

    memcpy(material, agreement_point.x, 32);
    memcpy(material + 32, agreement_point.y, 32);
    if (sm2_compute_z(
            material + 64,
            &self_key.public_key,
            SM2_DEFAULT_ID,
            SM2_DEFAULT_ID_LENGTH
        ) != 1
        || sm2_compute_z(
            material + 96,
            peer_public,
            SM2_DEFAULT_ID,
            SM2_DEFAULT_ID_LENGTH
        ) != 1) {
        goto cleanup;
    }

    sm3_kdf_init(&kdf, 32);
    sm3_kdf_update(&kdf, material, sizeof(material));
    sm3_kdf_finish(&kdf, shared_key);
    public_key[0] = 0x04;
    memcpy(public_key + 1, self_key.public_key.x, 32);
    memcpy(public_key + 33, self_key.public_key.y, 32);
    status = LeapGMCryptoSuccess;

cleanup:
    leap_gm_clear(&self_key, sizeof(self_key));
    leap_gm_clear(&checked_peer_key, sizeof(checked_peer_key));
    leap_gm_clear(&peer_combined, sizeof(peer_combined));
    leap_gm_clear(&agreement_point, sizeof(agreement_point));
    leap_gm_clear(self_x_bar, sizeof(self_x_bar));
    leap_gm_clear(peer_x_bar, sizeof(peer_x_bar));
    leap_gm_clear(private_scalar, sizeof(private_scalar));
    leap_gm_clear(product, sizeof(product));
    leap_gm_clear(self_factor, sizeof(self_factor));
    leap_gm_clear(one, sizeof(one));
    leap_gm_clear(peer_factor, sizeof(peer_factor));
    leap_gm_clear(x_bar_bytes, sizeof(x_bar_bytes));
    leap_gm_clear(scalar_bytes, sizeof(scalar_bytes));
    leap_gm_clear(material, sizeof(material));
    leap_gm_clear(&kdf, sizeof(kdf));
    return status;
}

int32_t LeapGMSM2KAPFromCertificate(
    const uint8_t *certificate_der,
    size_t certificate_der_length,
    const uint8_t *private_key,
    size_t private_key_length,
    uint8_t public_key[65],
    uint8_t shared_key[32]
) {
    SM2_KEY peer_key;
    int32_t status;

    if (certificate_der == NULL || certificate_der_length == 0) {
        return LeapGMCryptoInvalidInput;
    }
    memset(&peer_key, 0, sizeof(peer_key));
    if (x509_cert_get_subject_public_key(
            certificate_der,
            certificate_der_length,
            &peer_key
        ) != 1) {
        return LeapGMCryptoInvalidCertificate;
    }
    status = leap_gm_sm2_kap(
        &peer_key.public_key,
        private_key,
        private_key_length,
        public_key,
        shared_key
    );
    leap_gm_clear(&peer_key, sizeof(peer_key));
    return status;
}

int32_t LeapGMSM2KAPFromPublicKey(
    const uint8_t *peer_public_key,
    size_t peer_public_key_length,
    const uint8_t *private_key,
    size_t private_key_length,
    uint8_t public_key[65],
    uint8_t shared_key[32]
) {
    SM2_POINT peer_point;

    if (peer_public_key == NULL || peer_public_key_length != 65) {
        return LeapGMCryptoInvalidInput;
    }
    memset(&peer_point, 0, sizeof(peer_point));
    if (sm2_point_from_octets(
            &peer_point,
            peer_public_key,
            peer_public_key_length
        ) != 1) {
        return LeapGMCryptoInvalidCertificate;
    }
    return leap_gm_sm2_kap(
        &peer_point,
        private_key,
        private_key_length,
        public_key,
        shared_key
    );
}

int32_t LeapGMSM3(
    const uint8_t *input,
    size_t input_length,
    uint8_t digest[32]
) {
    if (input == NULL || input_length == 0 || digest == NULL) {
        return LeapGMCryptoInvalidInput;
    }
    sm3_digest(input, input_length, digest);
    return LeapGMCryptoSuccess;
}

int32_t LeapGMSM4CBCPKCS7Encrypt(
    const uint8_t *input,
    size_t input_length,
    const uint8_t key[16],
    const uint8_t iv[16],
    uint8_t *output,
    size_t output_capacity,
    size_t *output_length
) {
    SM4_KEY sm4_key;
    size_t required = input_length - (input_length % 16) + 16;
    int result;

    if (input == NULL || input_length == 0 || key == NULL || iv == NULL
        || output == NULL || output_length == NULL) {
        return LeapGMCryptoInvalidInput;
    }
    if (output_capacity < required) {
        return LeapGMCryptoOutputTooSmall;
    }
    sm4_set_encrypt_key(&sm4_key, key);
    result = sm4_cbc_padding_encrypt(
        &sm4_key,
        iv,
        input,
        input_length,
        output,
        output_length
    );
    leap_gm_clear(&sm4_key, sizeof(sm4_key));
    return result == 1 ? LeapGMCryptoSuccess : LeapGMCryptoCipherFailed;
}

int32_t LeapGMSM4CBCPKCS7Decrypt(
    const uint8_t *input,
    size_t input_length,
    const uint8_t key[16],
    const uint8_t iv[16],
    uint8_t *output,
    size_t output_capacity,
    size_t *output_length
) {
    SM4_KEY sm4_key;
    int result;

    if (input == NULL || input_length == 0 || key == NULL || iv == NULL
        || output == NULL || output_length == NULL) {
        return LeapGMCryptoInvalidInput;
    }
    if (output_capacity < input_length) {
        return LeapGMCryptoOutputTooSmall;
    }
    sm4_set_decrypt_key(&sm4_key, key);
    result = sm4_cbc_padding_decrypt(
        &sm4_key,
        iv,
        input,
        input_length,
        output,
        output_length
    );
    leap_gm_clear(&sm4_key, sizeof(sm4_key));
    return result == 1 ? LeapGMCryptoSuccess : LeapGMCryptoCipherFailed;
}

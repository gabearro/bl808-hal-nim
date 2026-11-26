/* RSA public-key exponentiation on the BL808 PKA, behind the stock Mbed TLS
 * bignum module. This file is compiled instead of library/bignum.c when
 * BL808_MBEDTLS_HW_RSA is set: it includes that file with
 * mbedtls_mpi_exp_mod_unsafe renamed (it stays available as the software
 * path) and provides the public one, which tries the PKA first.
 *
 * mbedtls_mpi_exp_mod_unsafe is what Mbed TLS calls when base, exponent and
 * modulus are all public: the RSA public operation (rsa.c), i.e. signature
 * checks. mbedtls_mpi_exp_mod, used with private exponents, is not touched.
 *
 * All policy (sizes, probe, ownership, counters) and the PKA program are in
 * rsa_alt.nim / rsa_engine.nim; this file only converts between Mbed TLS
 * numbers and big-endian strings of the PKA register's length. */
#define mbedtls_mpi_exp_mod_unsafe bl808_software_mpi_exp_mod_unsafe
#include "../../../vendor/mbedtls/library/bignum.c"
#undef mbedtls_mpi_exp_mod_unsafe

#if defined(MBEDTLS_BIGNUM_C)

#define BL808_RSA_MAX_BYTES 256

/* 0: x holds a^e mod n. Anything else: use the software path. */
extern int bl808_mbedtls_rsa_exp_mod(const unsigned char *n, const unsigned char *a,
                                     uint32_t e, unsigned char *x, size_t length);

/* Software a^e mod n on raw numbers, for the provider's first-use comparison
 * with the PKA. */
int bl808_software_rsa_exp_mod(const unsigned char *n, const unsigned char *a,
                               uint32_t e, unsigned char *x, size_t length)
{
    int ret = MBEDTLS_ERR_ERROR_CORRUPTION_DETECTED;
    mbedtls_mpi N, A, E, X;

    mbedtls_mpi_init(&N);
    mbedtls_mpi_init(&A);
    mbedtls_mpi_init(&E);
    mbedtls_mpi_init(&X);
    MBEDTLS_MPI_CHK(mbedtls_mpi_read_binary(&N, n, length));
    MBEDTLS_MPI_CHK(mbedtls_mpi_read_binary(&A, a, length));
    MBEDTLS_MPI_CHK(mbedtls_mpi_lset(&E, (mbedtls_mpi_sint) e));
    MBEDTLS_MPI_CHK(bl808_software_mpi_exp_mod_unsafe(&X, &A, &E, &N, NULL));
    MBEDTLS_MPI_CHK(mbedtls_mpi_write_binary(&X, x, length));

cleanup:
    mbedtls_mpi_free(&X);
    mbedtls_mpi_free(&E);
    mbedtls_mpi_free(&A);
    mbedtls_mpi_free(&N);
    return ret;
}

/* The smallest PKA register the program uses that holds a modulus of this
 * many bytes; 0 if there is none (below 264 or above 2048 bits). */
static size_t bl808_rsa_register_bytes(size_t bytes)
{
    static const unsigned short sizes[] = { 64, 96, 128, 192, 256 };
    for (size_t i = 0; bytes > 32 && i < sizeof(sizes) / sizeof(sizes[0]); i++) {
        if (bytes <= sizes[i]) {
            return sizes[i];
        }
    }
    return 0;
}

/* 0: X holds A^E mod N from the provider. 1: not attempted or not trusted,
 * the caller runs the software path (which also reports invalid input). */
static int bl808_rsa_try_hardware(mbedtls_mpi *X, const mbedtls_mpi *A,
                                  const mbedtls_mpi *E, const mbedtls_mpi *N)
{
    int ret = MBEDTLS_ERR_ERROR_CORRUPTION_DETECTED;
    int done = 0;
    size_t length;
    uint32_t e = 0;
    unsigned char *buffer;

    if (mbedtls_mpi_cmp_int(N, 0) <= 0 || (N->p[0] & 1) == 0 ||
        mbedtls_mpi_cmp_int(A, 0) < 0 || mbedtls_mpi_cmp_mpi(A, N) >= 0 ||
        mbedtls_mpi_cmp_int(E, 0) <= 0 || mbedtls_mpi_bitlen(E) > 32) {
        return 1;
    }
    length = bl808_rsa_register_bytes(mbedtls_mpi_size(N));
    if (length == 0) {
        return 1;
    }
    for (size_t bit = 0; bit < 32; bit++) {
        e |= (uint32_t) mbedtls_mpi_get_bit(E, bit) << bit;
    }
    buffer = mbedtls_calloc(3, BL808_RSA_MAX_BYTES);
    if (buffer == NULL) {
        return 1;
    }

    /* From here on any failure only means software computes the result. */
    MBEDTLS_MPI_CHK(mbedtls_mpi_write_binary(N, buffer, length));
    MBEDTLS_MPI_CHK(mbedtls_mpi_write_binary(A, buffer + BL808_RSA_MAX_BYTES, length));
    if (bl808_mbedtls_rsa_exp_mod(buffer, buffer + BL808_RSA_MAX_BYTES, e,
                                  buffer + 2 * BL808_RSA_MAX_BYTES, length) != 0) {
        goto cleanup;
    }
    MBEDTLS_MPI_CHK(mbedtls_mpi_read_binary(X, buffer + 2 * BL808_RSA_MAX_BYTES, length));
    done = 1;

cleanup:
    mbedtls_free(buffer);
    return done ? 0 : 1;
}

int mbedtls_mpi_exp_mod_unsafe(mbedtls_mpi *X, const mbedtls_mpi *A,
                               const mbedtls_mpi *E, const mbedtls_mpi *N,
                               mbedtls_mpi *prec_RR)
{
    if (bl808_rsa_try_hardware(X, A, E, N) == 0) {
        return 0;
    }
    return bl808_software_mpi_exp_mod_unsafe(X, A, E, N, prec_RR);
}

#endif /* MBEDTLS_BIGNUM_C */

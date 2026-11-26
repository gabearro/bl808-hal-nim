/* P-256 scalar multiplication on the BL808 PKA, behind the stock Mbed TLS ECP
 * module. This file is compiled instead of library/ecp.c when
 * BL808_MBEDTLS_HW_P256 is set: it includes that file with its public
 * multiplication entry points renamed (they stay available as the software
 * path) and provides the public ones, which try the PKA first for secp256r1.
 *
 * Covered: every multiplication requested from outside ecp.c. That is the
 * ECDH public key (psa_crypto_ecp.c) and shared secret (ecdh.c) of a TLS key
 * exchange, and the m*G + n*Q of ECDSA verification (ecdsa.c, through
 * mbedtls_ecp_muladd): the products the PKA takes, added in software.
 * Not covered: multiplications ecp.c makes for itself (key-pair checks).
 *
 * All policy (probe, ownership, counters) is in p256_alt.nim; this file only
 * converts between Mbed TLS numbers and 32-byte big-endian strings. */
#define mbedtls_ecp_mul bl808_software_ecp_mul
#define mbedtls_ecp_mul_restartable bl808_software_ecp_mul_restartable
#define mbedtls_ecp_muladd bl808_software_ecp_muladd
#define mbedtls_ecp_muladd_restartable bl808_software_ecp_muladd_restartable
#include "../../../vendor/mbedtls/library/ecp.c"
#undef mbedtls_ecp_mul
#undef mbedtls_ecp_mul_restartable
#undef mbedtls_ecp_muladd
#undef mbedtls_ecp_muladd_restartable

#if defined(MBEDTLS_ECP_C) && defined(MBEDTLS_ECP_DP_SECP256R1_ENABLED)

#define BL808_P256_BYTES 32

/* 0: the PKA produced rx/ry. Anything else: use the software path. */
extern int bl808_mbedtls_p256_mul(const unsigned char *scalar,
                                  const unsigned char *px, const unsigned char *py,
                                  unsigned char *rx, unsigned char *ry);
/* The product just returned is not a point on the curve. */
extern void bl808_mbedtls_p256_reject(void);

/* The probe's reference does not handle secrets, so its blinding source may
 * be a counter. */
static int bl808_p256_probe_rng(void *state, unsigned char *output, size_t len)
{
    unsigned char *counter = (unsigned char *) state;
    while (len-- > 0) {
        *output++ = (unsigned char) (0x5a ^ (*counter)++);
    }
    return 0;
}

/* Software k * (px, py) on raw coordinates, for the provider's first-use
 * comparison with the PKA. */
int bl808_software_p256_mul(const unsigned char *scalar,
                            const unsigned char *px, const unsigned char *py,
                            unsigned char *rx, unsigned char *ry)
{
    int ret = MBEDTLS_ERR_ERROR_CORRUPTION_DETECTED;
    unsigned char counter = 0;
    mbedtls_ecp_group grp;
    mbedtls_ecp_point P, R;
    mbedtls_mpi m;

    mbedtls_ecp_group_init(&grp);
    mbedtls_ecp_point_init(&P);
    mbedtls_ecp_point_init(&R);
    mbedtls_mpi_init(&m);
    MBEDTLS_MPI_CHK(mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256R1));
    MBEDTLS_MPI_CHK(mbedtls_mpi_read_binary(&m, scalar, BL808_P256_BYTES));
    MBEDTLS_MPI_CHK(mbedtls_mpi_read_binary(&P.X, px, BL808_P256_BYTES));
    MBEDTLS_MPI_CHK(mbedtls_mpi_read_binary(&P.Y, py, BL808_P256_BYTES));
    MBEDTLS_MPI_CHK(mbedtls_mpi_lset(&P.Z, 1));
    MBEDTLS_MPI_CHK(bl808_software_ecp_mul_restartable(&grp, &R, &m, &P,
                                                       bl808_p256_probe_rng,
                                                       &counter, NULL));
    MBEDTLS_MPI_CHK(mbedtls_mpi_write_binary(&R.X, rx, BL808_P256_BYTES));
    MBEDTLS_MPI_CHK(mbedtls_mpi_write_binary(&R.Y, ry, BL808_P256_BYTES));

cleanup:
    mbedtls_mpi_free(&m);
    mbedtls_ecp_point_free(&R);
    mbedtls_ecp_point_free(&P);
    mbedtls_ecp_group_free(&grp);
    return ret;
}

/* 0: R holds m * P from the PKA. 1: not attempted or not trusted, the caller
 * runs the software path. Negative: invalid input, as software reports it. */
static int bl808_p256_try_hardware(mbedtls_ecp_group *grp, mbedtls_ecp_point *R,
                                   const mbedtls_mpi *m, const mbedtls_ecp_point *P)
{
    int ret = MBEDTLS_ERR_ERROR_CORRUPTION_DETECTED;
    int done = 0;
    unsigned char scalar[BL808_P256_BYTES], px[BL808_P256_BYTES], py[BL808_P256_BYTES];
    unsigned char rx[BL808_P256_BYTES], ry[BL808_P256_BYTES];
    mbedtls_ecp_point T;

    if (grp->id != MBEDTLS_ECP_DP_SECP256R1 || mbedtls_mpi_cmp_int(&P->Z, 1) != 0) {
        return 1;
    }
    /* The checks the software path makes before it multiplies. */
    if ((ret = mbedtls_ecp_check_privkey(grp, m)) != 0 ||
        (ret = mbedtls_ecp_check_pubkey(grp, P)) != 0) {
        return ret;
    }

    /* From here on any failure only means software computes the product. */
    mbedtls_ecp_point_init(&T);
    MBEDTLS_MPI_CHK(mbedtls_mpi_write_binary(m, scalar, sizeof(scalar)));
    MBEDTLS_MPI_CHK(mbedtls_mpi_write_binary(&P->X, px, sizeof(px)));
    MBEDTLS_MPI_CHK(mbedtls_mpi_write_binary(&P->Y, py, sizeof(py)));
    if (bl808_mbedtls_p256_mul(scalar, px, py, rx, ry) != 0) {
        goto cleanup;
    }
    MBEDTLS_MPI_CHK(mbedtls_mpi_read_binary(&T.X, rx, sizeof(rx)));
    MBEDTLS_MPI_CHK(mbedtls_mpi_read_binary(&T.Y, ry, sizeof(ry)));
    MBEDTLS_MPI_CHK(mbedtls_mpi_lset(&T.Z, 1));
    /* A result that is not on the curve is a hardware fault, never an answer. */
    if (mbedtls_ecp_check_pubkey(grp, &T) != 0) {
        bl808_mbedtls_p256_reject();
        goto cleanup;
    }
    MBEDTLS_MPI_CHK(mbedtls_ecp_copy(R, &T));
    done = 1;

cleanup:
    mbedtls_platform_zeroize(scalar, sizeof(scalar));
    mbedtls_platform_zeroize(rx, sizeof(rx));
    mbedtls_platform_zeroize(ry, sizeof(ry));
    mbedtls_ecp_point_free(&T);
    return done ? 0 : 1;
}

int mbedtls_ecp_mul_restartable(mbedtls_ecp_group *grp, mbedtls_ecp_point *R,
                                const mbedtls_mpi *m, const mbedtls_ecp_point *P,
                                int (*f_rng)(void *, unsigned char *, size_t), void *p_rng,
                                mbedtls_ecp_restart_ctx *rs_ctx)
{
    if (f_rng == NULL) {
        return MBEDTLS_ERR_ECP_BAD_INPUT_DATA;
    }
    if (rs_ctx == NULL) {
        int ret = bl808_p256_try_hardware(grp, R, m, P);
        if (ret <= 0) {
            return ret;
        }
    }
    return bl808_software_ecp_mul_restartable(grp, R, m, P, f_rng, p_rng, rs_ctx);
}

int mbedtls_ecp_mul(mbedtls_ecp_group *grp, mbedtls_ecp_point *R,
                    const mbedtls_mpi *m, const mbedtls_ecp_point *P,
                    int (*f_rng)(void *, unsigned char *, size_t), void *p_rng)
{
    return mbedtls_ecp_mul_restartable(grp, R, m, P, f_rng, p_rng, NULL);
}

/* 0: R holds m * P + n * Q, both products from the PKA. 1: the caller runs
 * the software path, which also reports invalid input and handles the
 * scalars the PKA is not given (0, and anything outside [1, order - 1]). */
static int bl808_p256_try_hardware_muladd(mbedtls_ecp_group *grp, mbedtls_ecp_point *R,
                                          const mbedtls_mpi *m, const mbedtls_ecp_point *P,
                                          const mbedtls_mpi *n, const mbedtls_ecp_point *Q)
{
    int ret = MBEDTLS_ERR_ERROR_CORRUPTION_DETECTED;
    int done = 0;
    mbedtls_ecp_point mP, nQ;
    mbedtls_mpi tmp[4];

    mbedtls_ecp_point_init(&mP);
    mbedtls_ecp_point_init(&nQ);
    mpi_init_many(tmp, sizeof(tmp) / sizeof(mbedtls_mpi));
    /* The provider declines multiples of the base point (the software table
     * for G is faster than the PKA): that product is then made here as the
     * stock function makes it, and the other one still comes from the PKA.
     * With neither on the PKA the stock function does all of it. */
    {
        int soft_p = bl808_p256_try_hardware(grp, &mP, m, P) != 0;
        int soft_q = bl808_p256_try_hardware(grp, &nQ, n, Q) != 0;
        if (soft_p && soft_q) {
            goto cleanup;
        }
        if (soft_p) {
            MBEDTLS_MPI_CHK(mbedtls_ecp_mul_shortcuts(grp, &mP, m, P, NULL));
        }
        if (soft_q) {
            MBEDTLS_MPI_CHK(mbedtls_ecp_mul_shortcuts(grp, &nQ, n, Q, NULL));
        }
    }
    /* As the stock function: a mixed addition (it handles equal and opposite
     * points), then back to affine coordinates. */
    MBEDTLS_MPI_CHK(ecp_add_mixed(grp, &nQ, &mP, &nQ, tmp));
    MBEDTLS_MPI_CHK(ecp_normalize_jac(grp, &nQ));
    MBEDTLS_MPI_CHK(mbedtls_ecp_copy(R, &nQ));
    done = 1;

cleanup:
    mpi_free_many(tmp, sizeof(tmp) / sizeof(mbedtls_mpi));
    mbedtls_ecp_point_free(&nQ);
    mbedtls_ecp_point_free(&mP);
    return done ? 0 : 1;
}

int mbedtls_ecp_muladd_restartable(mbedtls_ecp_group *grp, mbedtls_ecp_point *R,
                                   const mbedtls_mpi *m, const mbedtls_ecp_point *P,
                                   const mbedtls_mpi *n, const mbedtls_ecp_point *Q,
                                   mbedtls_ecp_restart_ctx *rs_ctx)
{
    if (rs_ctx == NULL && bl808_p256_try_hardware_muladd(grp, R, m, P, n, Q) == 0) {
        return 0;
    }
    return bl808_software_ecp_muladd_restartable(grp, R, m, P, n, Q, rs_ctx);
}

int mbedtls_ecp_muladd(mbedtls_ecp_group *grp, mbedtls_ecp_point *R,
                       const mbedtls_mpi *m, const mbedtls_ecp_point *P,
                       const mbedtls_mpi *n, const mbedtls_ecp_point *Q)
{
    return mbedtls_ecp_muladd_restartable(grp, R, m, P, n, Q, NULL);
}

#endif /* MBEDTLS_ECP_C && MBEDTLS_ECP_DP_SECP256R1_ENABLED */

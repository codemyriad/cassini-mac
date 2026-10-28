// SPDX-License-Identifier: GPL-3.0-or-later
#include "CassiniZstd.h"
#include "upstream/zstd.h"
void *cassini_zstd_create(void) {
    ZSTD_DCtx *context = ZSTD_createDCtx();
    if (!context) return NULL;
    if (ZSTD_isError(ZSTD_DCtx_setParameter(context, ZSTD_d_windowLogMax, 27))) {
        ZSTD_freeDCtx(context); return NULL;
    }
    return context;
}
void cassini_zstd_free(void *decoder) { ZSTD_freeDCtx((ZSTD_DCtx *)decoder); }
long cassini_zstd_decode(void *decoder, const void *input, size_t length, size_t *consumed,
                        void *output, size_t capacity, size_t *written) {
    ZSTD_inBuffer source = {input,length,0}; ZSTD_outBuffer target = {output,capacity,0};
    size_t result = ZSTD_decompressStream((ZSTD_DCtx *)decoder,&target,&source);
    *consumed = source.pos; *written = target.pos;
    return ZSTD_isError(result) ? -1 : (long)result;
}

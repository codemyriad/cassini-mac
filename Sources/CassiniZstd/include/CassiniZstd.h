// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef CASSINI_ZSTD_H
#define CASSINI_ZSTD_H
#include <stddef.h>
void *cassini_zstd_create(void);
void cassini_zstd_free(void *decoder);
// Returns -1 on invalid data/window, otherwise the decoder's remaining hint.
long cassini_zstd_decode(void *decoder, const void *input, size_t length, size_t *consumed,
                        void *output, size_t capacity, size_t *written);
#endif

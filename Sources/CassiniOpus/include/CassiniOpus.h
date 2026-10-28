// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef CASSINI_OPUS_H
#define CASSINI_OPUS_H
#include <stddef.h>
typedef struct CassiniOpusEncoder CassiniOpusEncoder;
/* Caller verifies the library's signed-bundle identity before this may dlopen. */
CassiniOpusEncoder *cassini_opus_create(const char *path, int bitrate, int cutoff,
    int *lookahead, char *error, size_t capacity);
int cassini_opus_encode(CassiniOpusEncoder *encoder, const float *samples,
    size_t count, unsigned char *output, size_t capacity, char *error, size_t errorCapacity);
void cassini_opus_destroy(CassiniOpusEncoder *encoder);
#endif

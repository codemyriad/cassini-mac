// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <stddef.h>
typedef struct CassiniVAD CassiniVAD;
CassiniVAD *cassini_vad_create(const char *library, const char *model, char *error, size_t capacity);
int cassini_vad_probability(CassiniVAD *, const float *frame512, float *probability, char *error, size_t capacity);
void cassini_vad_reset(CassiniVAD *);
void cassini_vad_destroy(CassiniVAD *);

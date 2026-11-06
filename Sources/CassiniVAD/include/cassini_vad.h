// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <stddef.h>
#include <stdint.h>
typedef struct CassiniVAD CassiniVAD;
CassiniVAD *cassini_vad_create(const char *library, const char *model, char *error, size_t capacity);
int cassini_vad_probability(CassiniVAD *, const float *frame512, float *probability, char *error, size_t capacity);
void cassini_vad_reset(CassiniVAD *);
void cassini_vad_destroy(CassiniVAD *);

// D11's 97-tap centred FIR. Input starts at base; output_count consecutive
// samples begin at first_output. Binary32 inputs, ordered binary64 accumulation.
void cassini_fir_48k_16k(const float *coefficients, const float *samples,
                        int64_t base, int64_t total, int64_t first_output,
                        float *output, size_t output_count);

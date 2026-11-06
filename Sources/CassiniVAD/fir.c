// SPDX-License-Identifier: GPL-3.0-or-later
#include "cassini_vad.h"

// Preserve the Swift/reference multiply-then-add sequence, including Release:
// no contraction, SIMD reduction, reordering, or changed edge padding.
#pragma STDC FP_CONTRACT OFF
void cassini_fir_48k_16k(const float *coefficients, const float *samples,
                        int64_t base, int64_t total, int64_t first_output,
                        float *output, size_t output_count) {
    for (size_t i = 0; i < output_count; ++i) {
        const int64_t center = 3 * (first_output + (int64_t)i) + 48;
        double value = 0;
        for (int n = 0; n < 97; ++n) {
            const int64_t index = center - n;
            if (index >= 0 && index < total) {
                const double product = (double)coefficients[n] * (double)samples[index - base];
                value += product;
            }
        }
        output[i] = (float)value;
    }
}

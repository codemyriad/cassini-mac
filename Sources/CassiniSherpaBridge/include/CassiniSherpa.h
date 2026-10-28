// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef CASSINI_SHERPA_H
#define CASSINI_SHERPA_H
#include <stdint.h>
#include <stddef.h>
typedef struct CassiniSherpa CassiniSherpa;
typedef struct CassiniSherpaResult CassiniSherpaResult;
// Inputs are verified by the Swift asset capability before this call. No
// direct sherpa/ORT symbols are linked, so importing the module loads no engine.
CassiniSherpa *cassini_sherpa_create(const char *library, const char *ort, const char *model, char *error, size_t capacity);
void cassini_sherpa_destroy(CassiniSherpa *engine);
CassiniSherpaResult *cassini_sherpa_decode(CassiniSherpa *engine, const float *samples, int32_t count);
void cassini_sherpa_result_destroy(CassiniSherpa *engine, CassiniSherpaResult *result);
const char *cassini_sherpa_text(const CassiniSherpaResult *result);
int32_t cassini_sherpa_count(const CassiniSherpaResult *result);
const char *cassini_sherpa_token(const CassiniSherpaResult *result, int32_t index);
float cassini_sherpa_timestamp(const CassiniSherpaResult *result, int32_t index);
float cassini_sherpa_duration(const CassiniSherpaResult *result, int32_t index);
#endif

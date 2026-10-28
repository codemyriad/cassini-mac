// SPDX-License-Identifier: GPL-3.0-or-later
#include "CassiniSherpa.h"
#include "vendor/c-api.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>

struct CassiniSherpa {
    void *ort, *library;
    const SherpaOnnxOfflineRecognizer *recognizer;
    const SherpaOnnxOfflineRecognizer *(*create)(const SherpaOnnxOfflineRecognizerConfig *);
    void (*destroy)(const SherpaOnnxOfflineRecognizer *);
    const SherpaOnnxOfflineStream *(*stream)(const SherpaOnnxOfflineRecognizer *);
    void (*destroy_stream)(const SherpaOnnxOfflineStream *);
    void (*accept)(const SherpaOnnxOfflineStream *, int32_t, const float *, int32_t);
    void (*decode)(const SherpaOnnxOfflineRecognizer *, const SherpaOnnxOfflineStream *);
    const SherpaOnnxOfflineRecognizerResult *(*result)(const SherpaOnnxOfflineStream *);
    void (*destroy_result)(const SherpaOnnxOfflineRecognizerResult *);
};
struct CassiniSherpaResult { const SherpaOnnxOfflineRecognizerResult *value; };

static void error_text(char *out, size_t capacity, const char *text) {
    if (out && capacity) snprintf(out,capacity,"%s",text ? text : "Parakeet runtime error");
}
void cassini_sherpa_destroy(CassiniSherpa *engine) {
    if (!engine) return;
    if (engine->recognizer) engine->destroy(engine->recognizer);
    if (engine->library) dlclose(engine->library);
    if (engine->ort) dlclose(engine->ort);
    free(engine);
}
CassiniSherpa *cassini_sherpa_create(const char *library, const char *ort, const char *model, char *error, size_t capacity) {
    const char *telemetry = getenv("ORT_DISABLE_TELEMETRY");
    if (!telemetry || strcmp(telemetry,"1")) { error_text(error,capacity,"ORT_DISABLE_TELEMETRY must be 1"); return NULL; }
    CassiniSherpa *e = calloc(1,sizeof(*e));
    if (!e) return NULL;
    e->ort = dlopen(ort,RTLD_NOW | RTLD_LOCAL);
    if (!e->ort) { error_text(error,capacity,dlerror()); goto fail; }
    e->library = dlopen(library,RTLD_NOW | RTLD_LOCAL);
    if (!e->library) { error_text(error,capacity,dlerror()); goto fail; }
    const char *(*version)(void) = dlsym(e->library,"SherpaOnnxGetVersionStr");
    const char *(*ort_version)(void) = dlsym(e->library,"SherpaOnnxGetOnnxruntimeVersionStr");
    if (!version || !ort_version || !version() || !ort_version() ||
        strcmp(version(),"1.13.7+cassini-parakeet-v3-reference-v1.nemotron-diarization-v2.parakeet-ultra-v1") ||
        strcmp(ort_version(),"1.28.1")) { error_text(error,capacity,"D16 fork/runtime version mismatch"); goto fail; }
#define BIND(field, symbol) do { *(void **)(&e->field) = dlsym(e->library,symbol); if (!e->field) { error_text(error,capacity,"Missing " symbol); goto fail; } } while (0)
    BIND(create,"SherpaOnnxCreateOfflineRecognizer"); BIND(destroy,"SherpaOnnxDestroyOfflineRecognizer");
    BIND(stream,"SherpaOnnxCreateOfflineStream"); BIND(destroy_stream,"SherpaOnnxDestroyOfflineStream");
    BIND(accept,"SherpaOnnxAcceptWaveformOffline"); BIND(decode,"SherpaOnnxDecodeOfflineStream");
    BIND(result,"SherpaOnnxGetOfflineStreamResult"); BIND(destroy_result,"SherpaOnnxDestroyOfflineRecognizerResult");
#undef BIND
    char *encoder = NULL, *decoder = NULL, *joiner = NULL, *tokens = NULL;
    if (asprintf(&encoder,"%s/encoder.int8.onnx",model) < 0 || asprintf(&decoder,"%s/decoder.int8.onnx",model) < 0 ||
        asprintf(&joiner,"%s/joiner.int8.onnx",model) < 0 || asprintf(&tokens,"%s/tokens.txt",model) < 0) {
        free(encoder); free(decoder); free(joiner); free(tokens); error_text(error,capacity,"Model path allocation failed"); goto fail;
    }
    SherpaOnnxOfflineRecognizerConfig config = {0};
    config.feat_config.sample_rate = 16000; config.feat_config.feature_dim = 128;
    config.model_config.transducer.encoder = encoder; config.model_config.transducer.decoder = decoder; config.model_config.transducer.joiner = joiner;
    config.model_config.tokens = tokens; config.model_config.num_threads = 2; config.model_config.provider = "cpu";
    config.model_config.model_type = "nemo_transducer"; config.decoding_method = "greedy_search";
    e->recognizer = e->create(&config);
    free(encoder); free(decoder); free(joiner); free(tokens);
    if (!e->recognizer) { error_text(error,capacity,"Cannot create D16 recognizer"); goto fail; }
    return e;
fail:
    cassini_sherpa_destroy(e); return NULL;
}
CassiniSherpaResult *cassini_sherpa_decode(CassiniSherpa *e, const float *samples, int32_t count) {
    if (!e || !samples || count <= 0 || count > 480000) return NULL;
    for (int32_t i = 0; i < count; i++) if (!isfinite(samples[i])) return NULL;
    const SherpaOnnxOfflineStream *stream = e->stream(e->recognizer);
    if (!stream) return NULL;
    e->accept(stream,16000,samples,count); e->decode(e->recognizer,stream);
    const SherpaOnnxOfflineRecognizerResult *result = e->result(stream);
    e->destroy_stream(stream);
    if (!result) return NULL;
    if (result->count < 0 || result->count > 16384 || !result->text ||
        (result->count && (!result->tokens_arr || !result->timestamps || !result->durations))) { e->destroy_result(result); return NULL; }
    CassiniSherpaResult *out = malloc(sizeof(*out));
    if (!out) { e->destroy_result(result); return NULL; }
    out->value = result; return out;
}
void cassini_sherpa_result_destroy(CassiniSherpa *e, CassiniSherpaResult *result) { if (result) { e->destroy_result(result->value); free(result); } }
const char *cassini_sherpa_text(const CassiniSherpaResult *r) { return r->value->text; }
int32_t cassini_sherpa_count(const CassiniSherpaResult *r) { return r->value->count; }
const char *cassini_sherpa_token(const CassiniSherpaResult *r, int32_t i) { return i >= 0 && i < r->value->count ? r->value->tokens_arr[i] : NULL; }
float cassini_sherpa_timestamp(const CassiniSherpaResult *r, int32_t i) { return i >= 0 && i < r->value->count ? r->value->timestamps[i] : NAN; }
float cassini_sherpa_duration(const CassiniSherpaResult *r, int32_t i) { return i >= 0 && i < r->value->count ? r->value->durations[i] : NAN; }

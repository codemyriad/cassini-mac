// SPDX-License-Identifier: GPL-3.0-or-later
#include "cassini_vad.h"
#include "onnxruntime_c_api.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
struct CassiniVAD {
 void *library; const OrtApi *api; OrtEnv *env; OrtSession *session; OrtMemoryInfo *memory;
 float state[256], context[64];
};
static int checked(CassiniVAD *v, OrtStatus *status, char *error, size_t capacity) {
 if (!status) return 1;
 snprintf(error, capacity, "%s", v->api->GetErrorMessage(status)); v->api->ReleaseStatus(status); return 0;
}
void cassini_vad_destroy(CassiniVAD *v) {
 if (!v) return;
 if (v->memory) v->api->ReleaseMemoryInfo(v->memory);
 if (v->session) v->api->ReleaseSession(v->session);
 if (v->env) v->api->ReleaseEnv(v->env);
 if (v->library) dlclose(v->library); free(v);
}
void cassini_vad_reset(CassiniVAD *v) { memset(v->state, 0, sizeof v->state); memset(v->context, 0, sizeof v->context); }
CassiniVAD *cassini_vad_create(const char *library, const char *model, char *error, size_t capacity) {
 // The Swift caller verifies both pins and the live privacy environment before entry.
 CassiniVAD *v = calloc(1, sizeof *v); if (!v) return NULL;
 v->library = dlopen(library, RTLD_NOW | RTLD_LOCAL);
 if (!v->library) { snprintf(error, capacity, "%s", dlerror()); goto fail; }
 const OrtApiBase *(*base)(void) = dlsym(v->library, "OrtGetApiBase");
 if (!base || !(v->api = base()->GetApi(ORT_API_VERSION))) { snprintf(error, capacity, "Unsupported ONNX Runtime API"); goto fail; }
 OrtSessionOptions *options = NULL;
 #define CHECK(expr) if (!checked(v, (expr), error, capacity)) goto options_fail
 CHECK(v->api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "cassini", &v->env));
 CHECK(v->api->DisableTelemetryEvents(v->env));
 CHECK(v->api->CreateSessionOptions(&options));
 CHECK(v->api->SetIntraOpNumThreads(options, 1)); CHECK(v->api->SetInterOpNumThreads(options, 1));
 CHECK(v->api->CreateSession(v->env, model, options, &v->session));
 CHECK(v->api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &v->memory));
 v->api->ReleaseSessionOptions(options); return v;
 options_fail: if (options) v->api->ReleaseSessionOptions(options);
 fail: cassini_vad_destroy(v); return NULL;
 #undef CHECK
}
int cassini_vad_probability(CassiniVAD *v, const float *frame, float *probability, char *error, size_t capacity) {
 float input[576]; memcpy(input, v->context, sizeof v->context); memcpy(input + 64, frame, 512 * sizeof(float));
 int64_t rate = 16000, input_shape[] = {1,576}, state_shape[] = {2,1,128};
 OrtValue *inputs[3] = {0}, *outputs[2] = {0}; int ok = 0;
 const char *in_names[] = {"input", "state", "sr"}, *out_names[] = {"output", "stateN"};
 #define CHECK(expr) if (!checked(v, (expr), error, capacity)) goto done
 CHECK(v->api->CreateTensorWithDataAsOrtValue(v->memory, input, sizeof input, input_shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &inputs[0]));
 CHECK(v->api->CreateTensorWithDataAsOrtValue(v->memory, v->state, sizeof v->state, state_shape, 3, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &inputs[1]));
 CHECK(v->api->CreateTensorWithDataAsOrtValue(v->memory, &rate, sizeof rate, NULL, 0, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &inputs[2]));
 CHECK(v->api->Run(v->session, NULL, in_names, (const OrtValue *const *)inputs, 3, out_names, 2, outputs));
 void *p = NULL, *s = NULL;
 CHECK(v->api->GetTensorMutableData(outputs[0], &p)); CHECK(v->api->GetTensorMutableData(outputs[1], &s));
 *probability = *(float *)p; memcpy(v->state, s, sizeof v->state); memcpy(v->context, frame + 448, sizeof v->context); ok = 1;
 done: for (int i = 0; i < 3; i++) if (inputs[i]) v->api->ReleaseValue(inputs[i]);
 for (int i = 0; i < 2; i++) if (outputs[i]) v->api->ReleaseValue(outputs[i]); return ok;
 #undef CHECK
}

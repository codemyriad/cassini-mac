// SPDX-License-Identifier: GPL-3.0-or-later
#include "CassiniOpus.h"
#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct CassiniOpusEncoder {
    void *library, *state;
    void *(*create)(int,int,int,int *);
    void (*destroy)(void *);
    int (*control)(void *,int,...);
    int (*encode)(void *,const float *,int,unsigned char *,int32_t);
};
static void failure(char *out, size_t count, const char *message) {
    if (out && count) snprintf(out,count,"%s",message ? message : "Opus operation failed");
}
void cassini_opus_destroy(CassiniOpusEncoder *encoder) {
    if (!encoder) return;
    if (encoder->state && encoder->destroy) encoder->destroy(encoder->state);
    if (encoder->library) dlclose(encoder->library);
    free(encoder);
}
CassiniOpusEncoder *cassini_opus_create(const char *path, int bitrate, int cutoff,
    int *lookahead, char *error, size_t capacity) {
    if (!path || !lookahead || bitrate < 6000 || bitrate > 510000) {
        failure(error,capacity,"Invalid Opus encoder settings"); return NULL;
    }
    int bandwidth = cutoff == 4000 ? 1101 : cutoff == 6000 ? 1102 : cutoff == 8000 ? 1103 :
        cutoff == 12000 ? 1104 : cutoff == 20000 ? 1105 : 0;
    if (!bandwidth) { failure(error,capacity,"Invalid Opus cutoff"); return NULL; }
    CassiniOpusEncoder *encoder = calloc(1,sizeof(*encoder));
    if (!encoder) { failure(error,capacity,"Opus allocation failed"); return NULL; }
    encoder->library = dlopen(path,RTLD_NOW | RTLD_LOCAL);
    if (!encoder->library) { failure(error,capacity,dlerror()); goto failed; }
    encoder->create = dlsym(encoder->library,"opus_encoder_create");
    encoder->destroy = dlsym(encoder->library,"opus_encoder_destroy");
    encoder->control = dlsym(encoder->library,"opus_encoder_ctl");
    encoder->encode = dlsym(encoder->library,"opus_encode_float");
    const char *(*version)(void) = dlsym(encoder->library,"opus_get_version_string");
    if (!encoder->create || !encoder->destroy || !encoder->control || !encoder->encode || !version ||
        strcmp(version(),"libopus 1.6.1") != 0) { failure(error,capacity,"Opus API/version mismatch"); goto failed; }
    int status = 0;
    encoder->state = encoder->create(48000,1,2049,&status); /* OPUS_APPLICATION_AUDIO */
    if (!encoder->state || status) { failure(error,capacity,"Opus encoder initialization failed"); goto failed; }
    /* Public libopus controls: bitrate, VBR, complexity, unconstrained VBR,
       bandwidth and lookahead. 960 mono frames are always 20 ms at 48 kHz. */
    if (encoder->control(encoder->state,4002,bitrate) || encoder->control(encoder->state,4006,1) ||
        encoder->control(encoder->state,4010,10) || encoder->control(encoder->state,4020,0) ||
        encoder->control(encoder->state,4008,bandwidth) || encoder->control(encoder->state,4027,lookahead)) {
        failure(error,capacity,"Opus encoder controls failed"); goto failed;
    }
    return encoder;
failed:
    cassini_opus_destroy(encoder); return NULL;
}
int cassini_opus_encode(CassiniOpusEncoder *encoder, const float *samples,
    size_t count, unsigned char *output, size_t capacity, char *error, size_t errorCapacity) {
    if (!encoder || !samples || count != 960 || !output || capacity < 1276 || capacity > INT32_MAX) {
        failure(error,errorCapacity,"Invalid Opus frame/output buffer"); return -1;
    }
    for (size_t i = 0; i < count; i++) if (!isfinite(samples[i]) || fabsf(samples[i]) > 1) {
        failure(error,errorCapacity,"Invalid Opus input sample"); return -1;
    }
    int result = encoder->encode(encoder->state,samples,960,output,(int32_t)capacity);
    if (result < 0) failure(error,errorCapacity,"Opus frame encoding failed");
    return result;
}

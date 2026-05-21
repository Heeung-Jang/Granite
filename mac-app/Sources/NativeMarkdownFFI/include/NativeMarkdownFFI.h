#ifndef NATIVE_MARKDOWN_FFI_H
#define NATIVE_MARKDOWN_FFI_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint8_t *ptr;
    size_t len;
    size_t capacity;
} EngineReadResultBuffer;

typedef struct {
    void *handle;
    EngineReadResultBuffer result;
} EngineReadOpenResult;

typedef struct {
    EngineReadResultBuffer nodes;
    EngineReadResultBuffer edges;
} EngineReadLocalGraphResult;

#endif

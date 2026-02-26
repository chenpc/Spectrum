#ifndef FFMPEG_BRIDGE_H
#define FFMPEG_BRIDGE_H

#include <stdint.h>

/// Result of decoding an HEIF/HEIC image to RGBA64LE (16bpc).
typedef struct {
    uint16_t *data;      // caller must free()
    int       width;
    int       height;
    int       stride;    // bytes per row
} FFDecodedImage;

/// Decode the main (largest) image from an HEIF file to RGBA 16-bit.
/// Returns 0 on success, negative on error.
/// Caller must free result->data when done.
int ff_decode_heif(const char *path, FFDecodedImage *result);

#endif

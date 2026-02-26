#ifndef PLACEBO_BRIDGE_H
#define PLACEBO_BRIDGE_H

#include <stdint.h>

/// Render an HLG BT.2020 image through libplacebo's tone mapping pipeline.
///
/// Input:  RGBA16 (native-endian, 16 bits/component) in HLG / BT.2020
/// Output: RGBA16 in either Display P3 linear (HDR) or sRGB (SDR)
///
/// @param src_data     Source pixels (RGBA16)
/// @param w            Width
/// @param h            Height
/// @param src_stride   Source row stride in bytes
/// @param dst_data     Output buffer, must be pre-allocated (w * h * 8 bytes)
/// @param dst_stride   Output row stride in bytes
/// @param output_sdr   0 = HDR (Display P3 linear), 1 = SDR (sRGB tone-mapped)
/// @return 0 on success, negative on error
int pl_render_hlg_image(const uint16_t *src_data, int w, int h, int src_stride,
                        uint16_t *dst_data, int dst_stride, int output_sdr);

#endif

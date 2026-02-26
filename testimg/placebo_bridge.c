#include "placebo_bridge.h"

#include <OpenGL/OpenGL.h>

#include <libplacebo/config.h>
#include <libplacebo/log.h>
#include <libplacebo/opengl.h>
#include <libplacebo/gpu.h>
#include <libplacebo/renderer.h>
#include <libplacebo/utils/upload.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// IEEE 754 half-precision → single-precision conversion
static float half_to_float(uint16_t h) {
    uint32_t sign = (uint32_t)(h >> 15) << 31;
    uint32_t exp  = (h >> 10) & 0x1F;
    uint32_t frac = h & 0x3FF;
    uint32_t f;
    if (exp == 0) {
        f = sign;  // zero (treat subnormals as zero)
    } else if (exp == 31) {
        f = sign | 0x7F800000;  // inf/nan
    } else {
        f = sign | ((exp + 112) << 23) | (frac << 13);
    }
    float result;
    memcpy(&result, &f, sizeof(f));
    return result;
}

int pl_render_hlg_image(const uint16_t *src_data, int w, int h, int src_stride,
                        uint16_t *dst_data, int dst_stride, int output_sdr) {
    int ret = -1;

    // --- Create offscreen CGL context ---
    CGLPixelFormatAttribute attrs[] = {
        kCGLPFAAccelerated,
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
        (CGLPixelFormatAttribute)0
    };
    CGLPixelFormatObj pf = NULL;
    GLint npix = 0;
    if (CGLChoosePixelFormat(attrs, &pf, &npix) != kCGLNoError || !pf) {
        fprintf(stderr, "[placebo] CGLChoosePixelFormat failed\n");
        return -1;
    }
    CGLContextObj cgl_ctx = NULL;
    if (CGLCreateContext(pf, NULL, &cgl_ctx) != kCGLNoError || !cgl_ctx) {
        fprintf(stderr, "[placebo] CGLCreateContext failed\n");
        CGLDestroyPixelFormat(pf);
        return -1;
    }
    CGLDestroyPixelFormat(pf);
    CGLSetCurrentContext(cgl_ctx);

    // --- Create libplacebo log + OpenGL GPU ---
    pl_log pl = pl_log_create(PL_API_VER, pl_log_params(
        .log_cb  = pl_log_color,
        .log_priv = stderr,
        .log_level = PL_LOG_WARN,
    ));
    if (!pl) {
        fprintf(stderr, "[placebo] pl_log_create failed\n");
        goto cleanup_cgl;
    }

    pl_opengl gl = pl_opengl_create(pl, pl_opengl_params(
        .allow_software = true,
    ));
    if (!gl) {
        fprintf(stderr, "[placebo] pl_opengl_create failed\n");
        goto cleanup_log;
    }
    pl_gpu gpu = gl->gpu;
    fprintf(stderr, "[placebo] GPU: GL %d.%d, GLSL %d\n",
            gl->major, gl->minor, gpu->glsl.version);

    // --- Upload source texture ---
    struct pl_plane_data src_plane_data = {
        .type            = PL_FMT_UNORM,
        .width           = w,
        .height          = h,
        .component_size  = {16, 16, 16, 16},
        .component_pad   = {0, 0, 0, 0},
        .component_map   = {0, 1, 2, 3},
        .pixel_stride    = 8,  // 4 × 16 bits = 8 bytes
        .row_stride      = (size_t)src_stride,
        .pixels          = src_data,
    };

    pl_tex src_tex = NULL;
    struct pl_plane src_plane = {0};
    if (!pl_upload_plane(gpu, &src_plane, &src_tex, &src_plane_data)) {
        fprintf(stderr, "[placebo] pl_upload_plane failed\n");
        goto cleanup_gl;
    }
    fprintf(stderr, "[placebo] uploaded source texture %dx%d\n", w, h);

    // --- Create output texture (renderable + host_readable) ---
    // Prefer UNORM16 for direct uint16 output; fall back to FLOAT16
    bool is_unorm = false;
    pl_fmt out_fmt = pl_find_fmt(gpu, PL_FMT_UNORM, 4, 16, 16,
                                  PL_FMT_CAP_RENDERABLE | PL_FMT_CAP_HOST_READABLE);
    if (out_fmt) {
        is_unorm = true;
    } else {
        out_fmt = pl_find_fmt(gpu, PL_FMT_FLOAT, 4, 16, 16,
                               PL_FMT_CAP_RENDERABLE | PL_FMT_CAP_HOST_READABLE);
    }
    if (!out_fmt) {
        fprintf(stderr, "[placebo] no suitable output format found\n");
        goto cleanup_src;
    }
    fprintf(stderr, "[placebo] output format: %s (unorm=%d)\n", out_fmt->name, is_unorm);

    pl_tex out_tex = pl_tex_create(gpu, pl_tex_params(
        .w            = w,
        .h            = h,
        .format       = out_fmt,
        .renderable   = true,
        .host_readable = true,
    ));
    if (!out_tex) {
        fprintf(stderr, "[placebo] pl_tex_create for output failed\n");
        goto cleanup_src;
    }

    // --- Setup source frame: HLG / BT.2020 ---
    struct pl_frame src_frame = {
        .num_planes = 1,
        .planes     = { src_plane },
        .repr       = {
            .sys    = PL_COLOR_SYSTEM_RGB,
            .levels = PL_COLOR_LEVELS_FULL,
            .alpha  = PL_ALPHA_PREMULTIPLIED,
            .bits   = { .sample_depth = 16, .color_depth = 16 },
        },
        .color      = {
            .primaries = PL_COLOR_PRIM_BT_2020,
            .transfer  = PL_COLOR_TRC_HLG,
        },
        .crop       = { 0, 0, (float)w, (float)h },
    };

    // --- Setup destination frame ---
    struct pl_frame dst_frame = {
        .num_planes = 1,
        .planes     = {{
            .texture         = out_tex,
            .components      = 4,
            .component_mapping = {0, 1, 2, 3},
        }},
        .repr       = {
            .sys    = PL_COLOR_SYSTEM_RGB,
            .levels = PL_COLOR_LEVELS_FULL,
            .alpha  = PL_ALPHA_PREMULTIPLIED,
        },
        .color      = output_sdr
            ? (struct pl_color_space){
                .primaries = PL_COLOR_PRIM_BT_709,
                .transfer  = PL_COLOR_TRC_SRGB,
              }
            : (struct pl_color_space){
                .primaries = PL_COLOR_PRIM_DISPLAY_P3,
                .transfer  = PL_COLOR_TRC_SRGB,
              },
        .crop       = { 0, 0, (float)w, (float)h },
    };

    // --- Render ---
    pl_renderer renderer = pl_renderer_create(pl, gpu);
    if (!renderer) {
        fprintf(stderr, "[placebo] pl_renderer_create failed\n");
        goto cleanup_out;
    }

    bool ok = pl_render_image(renderer, &src_frame, &dst_frame,
                               &pl_render_default_params);
    if (!ok) {
        fprintf(stderr, "[placebo] pl_render_image failed\n");
        goto cleanup_renderer;
    }
    fprintf(stderr, "[placebo] render complete (SDR=%d)\n", output_sdr);

    // --- Download output pixels via pl_tex_download ---
    {
        size_t texel_sz = out_fmt->texel_size;
        size_t dl_row = (size_t)w * texel_sz;
        void *dl_buf = malloc(dl_row * (size_t)h);
        if (!dl_buf) goto cleanup_renderer;

        ok = pl_tex_download(gpu, pl_tex_transfer_params(
            .tex       = out_tex,
            .ptr       = dl_buf,
            .row_pitch = dl_row,
        ));

        if (ok) {
            if (is_unorm) {
                // UNORM16: direct copy (uint16 → uint16)
                for (int y = 0; y < h; y++) {
                    memcpy((uint8_t *)dst_data + (size_t)y * dst_stride,
                           (uint8_t *)dl_buf + (size_t)y * dl_row,
                           (size_t)w * texel_sz);
                }
            } else {
                // FLOAT16: half → float → uint16 conversion
                for (int y = 0; y < h; y++) {
                    const uint16_t *src_row = (const uint16_t *)((uint8_t *)dl_buf + (size_t)y * dl_row);
                    uint16_t *dst_row = (uint16_t *)((uint8_t *)dst_data + (size_t)y * dst_stride);
                    for (int x = 0; x < w * 4; x++) {
                        float v = half_to_float(src_row[x]);
                        if (v < 0.0f) v = 0.0f;
                        if (v > 1.0f) v = 1.0f;
                        dst_row[x] = (uint16_t)(v * 65535.0f + 0.5f);
                    }
                }
            }
            ret = 0;
        } else {
            fprintf(stderr, "[placebo] pl_tex_download failed\n");
        }

        free(dl_buf);
    }

cleanup_renderer:
    pl_renderer_destroy(&renderer);
cleanup_out:
    pl_tex_destroy(gpu, &out_tex);
cleanup_src:
    pl_tex_destroy(gpu, &src_tex);
cleanup_gl:
    pl_opengl_destroy(&gl);
cleanup_log:
    pl_log_destroy(&pl);
cleanup_cgl:
    CGLSetCurrentContext(NULL);
    CGLDestroyContext(cgl_ctx);
    return ret;
}

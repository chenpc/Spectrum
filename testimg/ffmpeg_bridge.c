#include "ffmpeg_bridge.h"
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

int ff_decode_heif(const char *path, FFDecodedImage *result) {
    memset(result, 0, sizeof(*result));

    AVFormatContext *fmt_ctx = NULL;
    int ret = avformat_open_input(&fmt_ctx, path, NULL, NULL);
    if (ret < 0) {
        fprintf(stderr, "[ff_decode] avformat_open_input failed: %d\n", ret);
        return ret;
    }

    ret = avformat_find_stream_info(fmt_ctx, NULL);
    if (ret < 0) {
        fprintf(stderr, "[ff_decode] find_stream_info failed: %d\n", ret);
        avformat_close_input(&fmt_ctx);
        return ret;
    }

    // List all streams for debugging
    fprintf(stderr, "[ff_decode] %u streams found:\n", fmt_ctx->nb_streams);
    for (unsigned i = 0; i < fmt_ctx->nb_streams; i++) {
        AVStream *st = fmt_ctx->streams[i];
        const char *type_name = av_get_media_type_string(st->codecpar->codec_type);
        const char *codec_name = avcodec_get_name(st->codecpar->codec_id);
        fprintf(stderr, "[ff_decode]   stream %u: type=%s codec=%s %dx%d\n",
                i, type_name ? type_name : "?", codec_name ? codec_name : "?",
                st->codecpar->width, st->codecpar->height);
    }

    // Find the largest video stream (the grid/assembled item should have full dimensions)
    int best_idx = -1;
    int best_area = 0;
    for (unsigned i = 0; i < fmt_ctx->nb_streams; i++) {
        AVStream *st = fmt_ctx->streams[i];
        if (st->codecpar->codec_type != AVMEDIA_TYPE_VIDEO)
            continue;
        int area = st->codecpar->width * st->codecpar->height;
        if (area > best_area) {
            best_area = area;
            best_idx = (int)i;
        }
    }
    if (best_idx < 0) {
        fprintf(stderr, "[ff_decode] no video stream found\n");
        avformat_close_input(&fmt_ctx);
        return -1;
    }

    AVStream *stream = fmt_ctx->streams[best_idx];
    fprintf(stderr, "[ff_decode] selected stream %d: %dx%d (area=%d)\n",
            best_idx, stream->codecpar->width, stream->codecpar->height, best_area);

    // Open decoder
    const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) {
        fprintf(stderr, "[ff_decode] decoder not found for codec_id %d\n",
                stream->codecpar->codec_id);
        avformat_close_input(&fmt_ctx);
        return -1;
    }

    AVCodecContext *dec_ctx = avcodec_alloc_context3(codec);
    if (!dec_ctx) {
        avformat_close_input(&fmt_ctx);
        return -1;
    }
    avcodec_parameters_to_context(dec_ctx, stream->codecpar);
    ret = avcodec_open2(dec_ctx, codec, NULL);
    if (ret < 0) {
        fprintf(stderr, "[ff_decode] avcodec_open2 failed: %d\n", ret);
        avcodec_free_context(&dec_ctx);
        avformat_close_input(&fmt_ctx);
        return ret;
    }

    // Read packets and decode
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    int got_frame = 0;

    while (av_read_frame(fmt_ctx, pkt) >= 0) {
        if (pkt->stream_index != best_idx) {
            av_packet_unref(pkt);
            continue;
        }
        ret = avcodec_send_packet(dec_ctx, pkt);
        av_packet_unref(pkt);
        if (ret < 0) break;

        ret = avcodec_receive_frame(dec_ctx, frame);
        if (ret == 0) {
            got_frame = 1;
            break;
        }
        if (ret != AVERROR(EAGAIN)) break;
    }

    // Flush decoder if needed
    if (!got_frame) {
        avcodec_send_packet(dec_ctx, NULL);
        ret = avcodec_receive_frame(dec_ctx, frame);
        if (ret == 0) got_frame = 1;
    }

    if (!got_frame) {
        fprintf(stderr, "[ff_decode] failed to decode frame\n");
        av_frame_free(&frame);
        av_packet_free(&pkt);
        avcodec_free_context(&dec_ctx);
        avformat_close_input(&fmt_ctx);
        return -1;
    }

    int w = frame->width;
    int h = frame->height;
    fprintf(stderr, "[ff_decode] decoded: %dx%d, pix_fmt=%s\n",
            w, h, av_get_pix_fmt_name(frame->format));

    // Convert to RGBA64LE (16bpc)
    enum AVPixelFormat dst_fmt = AV_PIX_FMT_RGBA64LE;
    int dst_stride = w * 8; // 4 components × 2 bytes
    uint16_t *dst_data = (uint16_t *)malloc((size_t)dst_stride * h);
    if (!dst_data) {
        av_frame_free(&frame);
        av_packet_free(&pkt);
        avcodec_free_context(&dec_ctx);
        avformat_close_input(&fmt_ctx);
        return -1;
    }

    struct SwsContext *sws = sws_getContext(
        w, h, frame->format,
        w, h, dst_fmt,
        SWS_BILINEAR, NULL, NULL, NULL);
    if (!sws) {
        fprintf(stderr, "[ff_decode] sws_getContext failed\n");
        free(dst_data);
        av_frame_free(&frame);
        av_packet_free(&pkt);
        avcodec_free_context(&dec_ctx);
        avformat_close_input(&fmt_ctx);
        return -1;
    }

    uint8_t *dst_planes[1] = { (uint8_t *)dst_data };
    int dst_strides[1] = { dst_stride };
    sws_scale(sws, (const uint8_t * const *)frame->data, frame->linesize,
              0, h, dst_planes, dst_strides);
    sws_freeContext(sws);

    result->data   = dst_data;
    result->width  = w;
    result->height = h;
    result->stride = dst_stride;

    av_frame_free(&frame);
    av_packet_free(&pkt);
    avcodec_free_context(&dec_ctx);
    avformat_close_input(&fmt_ctx);

    fprintf(stderr, "[ff_decode] output: %dx%d RGBA64LE, stride=%d\n", w, h, dst_stride);
    return 0;
}

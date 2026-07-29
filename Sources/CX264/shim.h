#ifndef IPMX_CX264_SHIM_H
#define IPMX_CX264_SHIM_H

#include <stdint.h>
#include <x264.h>

/*
 * Swift's Clang importer does not import function-alias macros, and x264.h
 * defines:
 *     #define x264_encoder_open x264_encoder_open_<X264_BUILD>
 * so the real symbol name changes with every x264 release. Wrapping it in a
 * static inline keeps the Swift side version-independent.
 */
static inline x264_t *ipmx_x264_encoder_open(x264_param_t *param) {
    return x264_encoder_open(param);
}

/*
 * x264_picture_t.img.plane / .i_stride are C arrays, which Swift imports as
 * fixed-size tuples. Setting them from Swift needs withUnsafeMutablePointer
 * gymnastics at every call site; these helpers keep the encoder readable.
 */
static inline void ipmx_x264_pic_set_plane(x264_picture_t *pic,
                                           int index,
                                           uint8_t *base,
                                           int stride) {
    pic->img.plane[index] = base;
    pic->img.i_stride[index] = stride;
}

static inline int ipmx_x264_build_number(void) { return X264_BUILD; }

#endif /* IPMX_CX264_SHIM_H */

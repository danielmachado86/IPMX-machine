#ifndef IPMX_CX265_SHIM_H
#define IPMX_CX265_SHIM_H

#include <stdint.h>
#include <x265.h>

/*
 * Same problem as x264, one layer worse: x265.h defines
 *     #define x265_encoder_open x265_encoder_glue2(x265_encoder_open_, X265_BUILD)
 * a token-pasting glue macro whose expansion changes with every release. Swift's Clang
 * importer does not import it, so the wrapper keeps the Swift side version-independent.
 */
static inline x265_encoder *ipmx_x265_encoder_open(x265_param *param) {
    return x265_encoder_open(param);
}

/*
 * x265_picture.planes / .stride are C arrays, imported into Swift as fixed-size tuples.
 * Unlike x264 these are void* rather than uint8_t*, so the helper also keeps the cast in
 * one place.
 */
static inline void ipmx_x265_pic_set_plane(x265_picture *pic,
                                           int index,
                                           void *base,
                                           int stride) {
    pic->planes[index] = base;
    pic->stride[index] = stride;
}

static inline int ipmx_x265_build_number(void) { return X265_BUILD; }

#endif /* IPMX_CX265_SHIM_H */

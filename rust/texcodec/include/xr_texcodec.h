// iOSRay: C-интерфейс библиотеки распаковки текстур на Rust (rust/texcodec).
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Вид блока (совпадает с xr_texcodec::Kind)
enum
{
    XR_BC1 = 0,  // DXT1
    XR_BC1A = 1, // DXT1 с однобитной альфой
    XR_BC2 = 2,  // DXT3
    XR_BC3 = 3,  // DXT5
    XR_BC4 = 4,  // ATI1
    XR_BC5 = 5,  // ATI2
};

// Распаковать уровень width×height из блоков src в плотный RGBA8 dst.
// false — неверный вид или буферы короче нужного (ничего не записано за край).
bool xr_bc_decode_level(uint32_t kind, const uint8_t* src, size_t src_len, uint32_t width, uint32_t height,
    uint8_t* dst, size_t dst_len);

// Заголовок файла кэша ASTC (.xra), 40 байт
typedef struct XrXraHeader
{
    uint32_t magic, target, format, w, h, d, layers, faces, levels, size;
} XrXraHeader;

// Можно ли верить заголовку файла длиной file_len (проверка до выделения памяти)
bool xr_xra_validate(const XrXraHeader* h, uint64_t file_len);

const char* xr_texcodec_version(void);

#ifdef __cplusplus
}
#endif

//! iOSRay: распаковка текстур, переписанная на Rust.
//!
//! Здесь разбираются данные, пришедшие из файлов игры и из кэша на диске,
//! поэтому главное — никогда не выйти за границы буферов, что бы ни лежало в файле:
//!
//! * [`xr_bc_decode_level`] — BC1–BC5 (DXT1/3/5, ATI1/2) → плотный RGBA8;
//! * [`xr_xra_validate`] — проверка заголовка кэша ASTC (`.xra`) до того, как
//!   C++ выделит под текстуру память по числам из файла.
//!
//! Все функции принимают указатель *и длину* каждого буфера и возвращают `false`
//! вместо записи за край. Паник в рабочем пути нет (сборка с `panic = "abort"`).

#![forbid(unsafe_op_in_unsafe_fn)]
#![allow(clippy::needless_range_loop)] // индексы каналов RGB читаются нагляднее

use core::slice;

/// Вид блока. Числа — часть C ABI (`xr_texcodec.h`).
#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// DXT1 без прозрачности (4-й цвет при c0 <= c1 — чёрный)
    Bc1 = 0,
    /// DXT1 с однобитной прозрачностью
    Bc1a = 1,
    /// DXT3: явная 4-битная альфа
    Bc2 = 2,
    /// DXT5: интерполированная альфа
    Bc3 = 3,
    /// ATI1/BC4: один канал → R (G = B = 0, A = 255)
    Bc4 = 4,
    /// ATI2/BC5: два канала → R, G (B = 0, A = 255)
    Bc5 = 5,
}

impl Kind {
    pub fn from_u32(v: u32) -> Option<Self> {
        Some(match v {
            0 => Kind::Bc1,
            1 => Kind::Bc1a,
            2 => Kind::Bc2,
            3 => Kind::Bc3,
            4 => Kind::Bc4,
            5 => Kind::Bc5,
            _ => return None,
        })
    }

    pub fn block_size(self) -> usize {
        match self {
            Kind::Bc1 | Kind::Bc1a | Kind::Bc4 => 8,
            Kind::Bc2 | Kind::Bc3 | Kind::Bc5 => 16,
        }
    }
}

type Pixels = [[u8; 4]; 16];

fn rgb565(c: u16) -> [u8; 3] {
    let r = u32::from((c >> 11) & 31);
    let g = u32::from((c >> 5) & 63);
    let b = u32::from(c & 31);
    [((r * 527 + 23) >> 6) as u8, ((g * 259 + 33) >> 6) as u8, ((b * 527 + 23) >> 6) as u8]
}

/// Цветовой блок (8 байт) → 16 пикселей. Совпадает побитно с прежним C++.
fn decode_color(block: &[u8; 8], px: &mut Pixels, is_bc1: bool, punch_alpha: bool) {
    let c0 = u16::from_le_bytes([block[0], block[1]]);
    let c1 = u16::from_le_bytes([block[2], block[3]]);
    let mut pal = [[0u8; 4]; 4];
    let (a, b) = (rgb565(c0), rgb565(c1));
    pal[0] = [a[0], a[1], a[2], 255];
    pal[1] = [b[0], b[1], b[2], 255];
    if c0 > c1 || !is_bc1 {
        for k in 0..3 {
            let (p0, p1) = (u32::from(pal[0][k]), u32::from(pal[1][k]));
            pal[2][k] = ((2 * p0 + p1 + 1) / 3) as u8;
            pal[3][k] = ((p0 + 2 * p1 + 1) / 3) as u8;
        }
        pal[2][3] = 255;
        pal[3][3] = 255;
    } else {
        for k in 0..3 {
            let (p0, p1) = (u32::from(pal[0][k]), u32::from(pal[1][k]));
            pal[2][k] = (p0 + p1).div_ceil(2) as u8;
            pal[3][k] = 0;
        }
        pal[2][3] = 255;
        pal[3][3] = if punch_alpha { 0 } else { 255 };
    }
    let idx = u32::from_le_bytes([block[4], block[5], block[6], block[7]]);
    for (i, p) in px.iter_mut().enumerate() {
        *p = pal[((idx >> (2 * i)) & 3) as usize];
    }
}

/// BC2: явная альфа, 4 бита на пиксель
fn decode_alpha_bc2(block: &[u8; 8], px: &mut Pixels) {
    for (i, p) in px.iter_mut().enumerate() {
        let a = (block[i / 2] >> ((i & 1) * 4)) & 15;
        p[3] = a * 17;
    }
}

/// BC3/BC4/BC5: 8-байтный интерполированный канал → 16 значений
fn decode_channel(block: &[u8; 8]) -> [u8; 16] {
    let mut a = [0u8; 8];
    a[0] = block[0];
    a[1] = block[1];
    let (a0, a1) = (u32::from(a[0]), u32::from(a[1]));
    if a[0] > a[1] {
        for i in 1..7u32 {
            a[(i + 1) as usize] = (((7 - i) * a0 + i * a1 + 3) / 7) as u8;
        }
    } else {
        for i in 1..5u32 {
            a[(i + 1) as usize] = (((5 - i) * a0 + i * a1 + 2) / 5) as u8;
        }
        a[6] = 0;
        a[7] = 255;
    }
    let mut bits = 0u64;
    for (i, &b) in block[2..8].iter().enumerate() {
        bits |= u64::from(b) << (8 * i);
    }
    let mut out = [0u8; 16];
    for (i, o) in out.iter_mut().enumerate() {
        *o = a[((bits >> (3 * i)) & 7) as usize];
    }
    out
}

fn half(block: &[u8], from: usize) -> &[u8; 8] {
    // Длина блока проверена вызывающим (chunks_exact), срез ровно 8 байт.
    block[from..from + 8].try_into().unwrap_or(&[0; 8])
}

fn decode_block(kind: Kind, block: &[u8], px: &mut Pixels) {
    match kind {
        Kind::Bc1 => decode_color(half(block, 0), px, true, false),
        Kind::Bc1a => decode_color(half(block, 0), px, true, true),
        Kind::Bc2 => {
            decode_color(half(block, 8), px, false, false);
            decode_alpha_bc2(half(block, 0), px);
        }
        Kind::Bc3 => {
            decode_color(half(block, 8), px, false, false);
            let a = decode_channel(half(block, 0));
            for (p, v) in px.iter_mut().zip(a) {
                p[3] = v;
            }
        }
        Kind::Bc4 => {
            let r = decode_channel(half(block, 0));
            for (p, v) in px.iter_mut().zip(r) {
                *p = [v, 0, 0, 255];
            }
        }
        Kind::Bc5 => {
            let r = decode_channel(half(block, 0));
            let g = decode_channel(half(block, 8));
            for (i, p) in px.iter_mut().enumerate() {
                *p = [r[i], g[i], 0, 255];
            }
        }
    }
}

/// Байт на сжатый уровень `width × height`
pub fn compressed_size(kind: Kind, width: u32, height: u32) -> Option<usize> {
    let bw = (width as usize).div_ceil(4);
    let bh = (height as usize).div_ceil(4);
    bw.checked_mul(bh)?.checked_mul(kind.block_size())
}

/// Байт на распакованный уровень (RGBA8)
pub fn decoded_size(width: u32, height: u32) -> Option<usize> {
    (width as usize).checked_mul(height as usize)?.checked_mul(4)
}

/// Безопасная версия: срезы вместо указателей. `false`, если размеры не сходятся.
pub fn decode_level(kind: Kind, src: &[u8], width: u32, height: u32, dst: &mut [u8]) -> bool {
    if width == 0 || height == 0 {
        return false;
    }
    let (Some(need_src), Some(need_dst)) = (compressed_size(kind, width, height), decoded_size(width, height))
    else {
        return false;
    };
    if src.len() < need_src || dst.len() < need_dst {
        return false;
    }
    let (w, h) = (width as usize, height as usize);
    let bw = w.div_ceil(4);
    let mut px: Pixels = [[0; 4]; 16];
    for (bi, block) in src[..need_src].chunks_exact(kind.block_size()).enumerate() {
        let (bx, by) = (bi % bw, bi / bw);
        decode_block(kind, block, &mut px);
        for y in 0..4 {
            let row = by * 4 + y;
            if row >= h {
                break;
            }
            for x in 0..4 {
                let col = bx * 4 + x;
                if col >= w {
                    break;
                }
                let o = (row * w + col) * 4;
                dst[o..o + 4].copy_from_slice(&px[y * 4 + x]);
            }
        }
    }
    true
}

/// C ABI: распаковать уровень. `src_len`/`dst_len` — реальные размеры буферов.
///
/// # Safety
/// `src` должен указывать на `src_len` читаемых байт, `dst` — на `dst_len`
/// записываемых (или быть null — тогда вернётся `false`).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn xr_bc_decode_level(
    kind: u32,
    src: *const u8,
    src_len: usize,
    width: u32,
    height: u32,
    dst: *mut u8,
    dst_len: usize,
) -> bool {
    let Some(kind) = Kind::from_u32(kind) else { return false };
    if src.is_null() || dst.is_null() {
        return false;
    }
    // SAFETY: длины и непустые указатели гарантирует вызывающий (см. контракт выше)
    let src = unsafe { slice::from_raw_parts(src, src_len) };
    let dst = unsafe { slice::from_raw_parts_mut(dst, dst_len) };
    decode_level(kind, src, width, height, dst)
}

/// Заголовок файла кэша ASTC. Раскладка совпадает с C++ (`XraHeader`).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct XraHeader {
    pub magic: u32,
    pub target: u32,
    pub format: u32,
    pub w: u32,
    pub h: u32,
    pub d: u32,
    pub layers: u32,
    pub faces: u32,
    pub levels: u32,
    pub size: u32,
}

pub const XRA_MAGIC: u32 = 0x3141_5258; // "XRA1"
const XRA_HEADER_SIZE: u64 = core::mem::size_of::<XraHeader>() as u64;
const MAX_EXTENT: u32 = 16384;
const MAX_PAYLOAD: u32 = 256 << 20;

/// Разумно ли верить заголовку из файла длиной `file_len`.
/// Отсекает мусор и битые файлы до того, как по этим числам выделят память.
pub fn xra_is_sane(h: &XraHeader, file_len: u64) -> bool {
    let dims_ok = (1..=MAX_EXTENT).contains(&h.w)
        && (1..=MAX_EXTENT).contains(&h.h)
        && (1..=2048).contains(&h.d)
        && (1..=2048).contains(&h.layers)
        && (h.faces == 1 || h.faces == 6);
    if h.magic != XRA_MAGIC || !dims_ok || h.size == 0 || h.size > MAX_PAYLOAD {
        return false;
    }
    let max_dim = h.w.max(h.h).max(h.d);
    let max_levels = 32 - max_dim.leading_zeros(); // floor(log2) + 1
    if h.levels == 0 || h.levels > max_levels {
        return false;
    }
    // В кэше лежит ASTC 4x4: 16 байт на блок; полезная нагрузка не может быть
    // меньше нулевого уровня всех слоёв и граней.
    let blocks = u64::from(h.w.div_ceil(4)) * u64::from(h.h.div_ceil(4)) * u64::from(h.d);
    let level0 = blocks * 16 * u64::from(h.layers) * u64::from(h.faces);
    if u64::from(h.size) < level0 {
        return false;
    }
    file_len == XRA_HEADER_SIZE + u64::from(h.size)
}

/// C ABI: проверить заголовок `.xra`.
///
/// # Safety
/// `h` — указатель на прочитанный из файла заголовок (или null → `false`).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn xr_xra_validate(h: *const XraHeader, file_len: u64) -> bool {
    // SAFETY: при ненулевом указателе вызывающий передаёт целый XraHeader
    match unsafe { h.as_ref() } {
        Some(h) => xra_is_sane(h, file_len),
        None => false,
    }
}

/// Версия библиотеки — для строки в логе
#[unsafe(no_mangle)]
pub extern "C" fn xr_texcodec_version() -> *const core::ffi::c_char {
    c"xr_texcodec 0.1.0 (Rust)".as_ptr()
}

#[cfg(test)]
mod tests;

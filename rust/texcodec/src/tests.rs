use super::*;

#[test]
fn bc1_solid_red() {
    // c0 = c1 = красный 565 (0xF800), все индексы 0
    let block = [0x00, 0xF8, 0x00, 0xF8, 0, 0, 0, 0];
    let mut dst = [0u8; 4 * 4 * 4];
    assert!(decode_level(Kind::Bc1, &block, 4, 4, &mut dst));
    for px in dst.chunks(4) {
        assert_eq!(px, [255, 0, 0, 255]);
    }
}

#[test]
fn bc1a_transparent_index() {
    // c0 <= c1 → трёхцветный режим, индекс 3 — прозрачный
    let block = [0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];
    let mut dst = [0u8; 64];
    assert!(decode_level(Kind::Bc1a, &block, 4, 4, &mut dst));
    assert!(dst.chunks(4).all(|p| p == [0, 0, 0, 0]));
    assert!(decode_level(Kind::Bc1, &block, 4, 4, &mut dst));
    assert!(dst.chunks(4).all(|p| p == [0, 0, 0, 255]));
}

#[test]
fn bc3_alpha_endpoints() {
    let mut block = [0u8; 16];
    block[0] = 200; // a0
    block[1] = 10; // a1, индексы 0 → везде 200
    let mut dst = [0u8; 64];
    assert!(decode_level(Kind::Bc3, &block, 4, 4, &mut dst));
    assert!(dst.chunks(4).all(|p| p[3] == 200));
}

#[test]
fn non_multiple_of_four() {
    // 5×3: 2×1 блока, края обрезаются, запись не выходит за 5*3*4 байт
    let src = [0xAAu8; 2 * 8];
    let mut dst = vec![0u8; 5 * 3 * 4];
    assert!(decode_level(Kind::Bc1, &src, 5, 3, &mut dst));
}

#[test]
fn rejects_short_buffers() {
    let src = [0u8; 8];
    let mut dst = [0u8; 63]; // нужно 64
    assert!(!decode_level(Kind::Bc1, &src, 4, 4, &mut dst));
    let mut dst = [0u8; 64];
    assert!(!decode_level(Kind::Bc3, &src, 4, 4, &mut dst)); // BC3 нужно 16 байт
    assert!(!decode_level(Kind::Bc1, &src, 0, 4, &mut dst));
}

#[test]
fn ffi_rejects_null_and_bad_kind() {
    let src = [0u8; 8];
    let mut dst = [0u8; 64];
    unsafe {
        assert!(!xr_bc_decode_level(9, src.as_ptr(), 8, 4, 4, dst.as_mut_ptr(), 64));
        assert!(!xr_bc_decode_level(0, core::ptr::null(), 8, 4, 4, dst.as_mut_ptr(), 64));
        assert!(xr_bc_decode_level(0, src.as_ptr(), 8, 4, 4, dst.as_mut_ptr(), 64));
    }
}

#[test]
fn huge_dimensions_do_not_overflow() {
    let src = [0u8; 8];
    let mut dst = [0u8; 64];
    assert!(!decode_level(Kind::Bc1, &src, u32::MAX, u32::MAX, &mut dst));
}

fn header(w: u32, h: u32, levels: u32, size: u32) -> XraHeader {
    XraHeader { magic: XRA_MAGIC, target: 1, format: 0, w, h, d: 1, layers: 1, faces: 1, levels, size }
}

#[test]
fn xra_accepts_good_header() {
    let hd = header(256, 256, 9, 87_408);
    assert!(xra_is_sane(&hd, 40 + 87_408));
}

#[test]
fn xra_rejects_garbage() {
    let good = header(256, 256, 9, 87_408);
    assert!(!xra_is_sane(&XraHeader { magic: 0, ..good }, 40 + 87_408));
    assert!(!xra_is_sane(&XraHeader { w: 0, ..good }, 40 + 87_408));
    assert!(!xra_is_sane(&XraHeader { w: 1 << 20, ..good }, 40 + 87_408));
    assert!(!xra_is_sane(&XraHeader { levels: 20, ..good }, 40 + 87_408));
    assert!(!xra_is_sane(&XraHeader { faces: 3, ..good }, 40 + 87_408));
    assert!(!xra_is_sane(&XraHeader { size: 16, ..good }, 40 + 16)); // меньше нулевого уровня
    assert!(!xra_is_sane(&good, 40 + 87_407)); // обрезанный файл
    assert!(!xra_is_sane(&XraHeader { size: u32::MAX, ..good }, 40 + u64::from(u32::MAX)));
}

/// Детерминированный «случайный» генератор (без внешних зависимостей)
struct Lcg(u64);
impl Lcg {
    fn next(&mut self) -> u8 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        (self.0 >> 33) as u8
    }
}

#[test]
fn random_input_never_panics() {
    let mut rng = Lcg(42);
    for kind in [Kind::Bc1, Kind::Bc1a, Kind::Bc2, Kind::Bc3, Kind::Bc4, Kind::Bc5] {
        for (w, h) in [(1, 1), (3, 7), (4, 4), (13, 9), (64, 32)] {
            let n = compressed_size(kind, w, h).unwrap();
            let src: Vec<u8> = (0..n).map(|_| rng.next()).collect();
            let mut dst = vec![0u8; decoded_size(w, h).unwrap()];
            assert!(decode_level(kind, &src, w, h, &mut dst));
        }
    }
}

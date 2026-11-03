// s2mmx.h: bit-exact C versions of the MMX instructions the engine's hand-written routines use.
// Each function mirrors one instruction (Intel SDM semantics) on a 64-bit value, so an __asm block
// translates line for line and produces identical results on arm64.
#pragma once
#include <stdint.h>
#include <string.h>

typedef uint64_t s2mmx;

static inline int16_t s2w(s2mmx m, int i) { return (int16_t)(uint16_t)(m >> (16 * i)); }
static inline uint8_t s2b(s2mmx m, int i) { return (uint8_t)(m >> (8 * i)); }
static inline int32_t s2d(s2mmx m, int i) { return (int32_t)(uint32_t)(m >> (32 * i)); }
static inline s2mmx s2pack16(int a, int b, int c, int d) { return (uint64_t)(uint16_t)a | ((uint64_t)(uint16_t)b << 16) | ((uint64_t)(uint16_t)c << 32) | ((uint64_t)(uint16_t)d << 48); }
static inline int16_t s2sat16(int v) { return (int16_t)(v > 32767 ? 32767 : v < -32768 ? -32768 : v); }
static inline uint8_t s2satu8(int v) { return (uint8_t)(v > 255 ? 255 : v < 0 ? 0 : v); }

static inline s2mmx movd_load(const void *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static inline s2mmx movq_load(const void *p) { uint64_t v; memcpy(&v, p, 8); return v; }
static inline void movd_store(void *p, s2mmx m) { uint32_t v = (uint32_t)m; memcpy(p, &v, 4); }
static inline void movq_store(void *p, s2mmx m) { memcpy(p, &m, 8); }

static inline s2mmx pxor(s2mmx a, s2mmx b) { return a ^ b; }
static inline s2mmx pcmpeqw(s2mmx a, s2mmx b) { int r[4]; for (int i = 0; i < 4; ++i) r[i] = s2w(a, i) == s2w(b, i) ? 0xFFFF : 0; return s2pack16(r[0], r[1], r[2], r[3]); }
static inline s2mmx paddw(s2mmx a, s2mmx b) { int r[4]; for (int i = 0; i < 4; ++i) r[i] = s2w(a, i) + s2w(b, i); return s2pack16(r[0], r[1], r[2], r[3]); }
static inline s2mmx paddsw(s2mmx a, s2mmx b) { int r[4]; for (int i = 0; i < 4; ++i) r[i] = s2sat16(s2w(a, i) + s2w(b, i)); return s2pack16(r[0], r[1], r[2], r[3]); }
static inline s2mmx psubw(s2mmx a, s2mmx b) { int r[4]; for (int i = 0; i < 4; ++i) r[i] = s2w(a, i) - s2w(b, i); return s2pack16(r[0], r[1], r[2], r[3]); }
static inline s2mmx pmulhw(s2mmx a, s2mmx b) { int r[4]; for (int i = 0; i < 4; ++i) r[i] = (int32_t)(s2w(a, i) * (int32_t)s2w(b, i)) >> 16; return s2pack16(r[0], r[1], r[2], r[3]); }
static inline s2mmx psllw(s2mmx a, int n) { int r[4]; for (int i = 0; i < 4; ++i) r[i] = n > 15 ? 0 : (uint16_t)((uint16_t)s2w(a, i) << n); return s2pack16(r[0], r[1], r[2], r[3]); }
static inline s2mmx psrlw(s2mmx a, int n) { int r[4]; for (int i = 0; i < 4; ++i) r[i] = n > 15 ? 0 : (uint16_t)s2w(a, i) >> n; return s2pack16(r[0], r[1], r[2], r[3]); }
static inline s2mmx psllq(s2mmx a, int n) { return n > 63 ? 0 : a << n; }
static inline s2mmx psrlq(s2mmx a, int n) { return n > 63 ? 0 : a >> n; }
static inline s2mmx paddd(s2mmx a, s2mmx b) { return (uint64_t)(uint32_t)(s2d(a, 0) + s2d(b, 0)) | ((uint64_t)(uint32_t)(s2d(a, 1) + s2d(b, 1)) << 32); }
static inline s2mmx pmaddwd(s2mmx a, s2mmx b)
{
	int32_t lo = s2w(a, 0) * s2w(b, 0) + s2w(a, 1) * s2w(b, 1);
	int32_t hi = s2w(a, 2) * s2w(b, 2) + s2w(a, 3) * s2w(b, 3);
	return (uint64_t)(uint32_t)lo | ((uint64_t)(uint32_t)hi << 32);
}
// interleaves: the destination supplies the even elements, the source the odd ones
static inline s2mmx punpcklbw(s2mmx a, s2mmx b) { s2mmx r = 0; for (int i = 0; i < 4; ++i) r |= ((uint64_t)s2b(a, i) << (16 * i)) | ((uint64_t)s2b(b, i) << (16 * i + 8)); return r; }
static inline s2mmx punpcklwd(s2mmx a, s2mmx b) { return s2pack16(s2w(a, 0), s2w(b, 0), s2w(a, 1), s2w(b, 1)); }
static inline s2mmx punpckhwd(s2mmx a, s2mmx b) { return s2pack16(s2w(a, 2), s2w(b, 2), s2w(a, 3), s2w(b, 3)); }
static inline s2mmx punpckldq(s2mmx a, s2mmx b) { return (a & 0xFFFFFFFFull) | (b << 32); }
static inline s2mmx punpckhdq(s2mmx a, s2mmx b) { return (a >> 32) | (b & 0xFFFFFFFF00000000ull); }
static inline s2mmx packuswb(s2mmx a, s2mmx b)
{
	s2mmx r = 0;
	for (int i = 0; i < 4; ++i) r |= (uint64_t)s2satu8(s2w(a, i)) << (8 * i);
	for (int i = 0; i < 4; ++i) r |= (uint64_t)s2satu8(s2w(b, i)) << (8 * (i + 4));
	return r;
}

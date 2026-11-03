// texpack: HD texture pipeline for the macOS port.
//
//   texpack list    <Textures.res>                         counts by format and size, total pixels
//   texpack extract <Textures.res> <manifest.tsv> <png dir> textures the manifest marks for HD, level 0 as PNG
//   texpack build   <Textures.res> <manifest.tsv> <upscaled dir> <out dir> [--scale 2] [--max 2048]
//                   upscaled PNGs -> MMP files (same pixel format, full mip chain) named <id>.mmp
//
// The manifest comes from the game itself (console command "texture_manifest", Main/GTexture.cpp): one line per
// texture record, "id usage w h dxt bump", so only 3D textures with normalised coordinates are replaced.
// MMP layout (Main/mmpFormat.h, written by Nival's TexConv): 24-byte header, then every mip level, largest first.
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "texpack_pkg.h"
#include "squish.h"
#include <map>
#include <set>
#include <string>
#include <vector>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <atomic>
#include <unistd.h>
#include <dispatch/dispatch.h>

struct MMPHeader { uint32_t sig, format, avg; int32_t w, h, mips; };
static_assert(sizeof(MMPHeader) == 24, "MMP header is 24 bytes");
enum { CF_DXT1 = 1, CF_DXT3 = 3, CF_DXT5 = 5, CF_8888 = 6, CF_4444 = 7, CF_565 = 8, CF_1555 = 9 };

static size_t LevelBytes(int fmt, int w, int h)
{
	switch (fmt)
	{
	case CF_DXT1: return (size_t)std::max(1, (w + 3) / 4) * std::max(1, (h + 3) / 4) * 8;
	case 2: case CF_DXT3: case 4: case CF_DXT5: return (size_t)std::max(1, (w + 3) / 4) * std::max(1, (h + 3) / 4) * 16;
	case CF_8888: return (size_t)w * h * 4;
	default: return (size_t)w * h * 2;
	}
}

// one mip level to RGBA8; on return hdr->w and hdr->h give that level's size
static bool DecodeLevel(const std::vector<unsigned char> &file, int level, MMPHeader *hdr, std::vector<unsigned char> *rgba)
{
	if (file.size() < sizeof(MMPHeader)) return false;
	memcpy(hdr, file.data(), sizeof *hdr);
	if (hdr->sig != 0x00504D4D || hdr->w <= 0 || hdr->h <= 0 || hdr->w > 8192 || hdr->h > 8192 || level < 0 || level >= hdr->mips) return false;
	const unsigned char *src = file.data() + sizeof(MMPHeader);
	for (int i = 0; i < level; ++i)
	{
		src += LevelBytes(hdr->format, hdr->w, hdr->h);
		hdr->w = std::max(1, hdr->w / 2); hdr->h = std::max(1, hdr->h / 2);
	}
	size_t need = LevelBytes(hdr->format, hdr->w, hdr->h);
	if ((size_t)(src - file.data()) + need > file.size()) return false;
	rgba->assign((size_t)hdr->w * hdr->h * 4, 0);
	int w = hdr->w, h = hdr->h;
	switch (hdr->format)
	{
	case CF_DXT1: squish::DecompressImage(rgba->data(), w, h, src, squish::kDxt1); break;
	case 2: case CF_DXT3: squish::DecompressImage(rgba->data(), w, h, src, squish::kDxt3); break;
	case 4: case CF_DXT5: squish::DecompressImage(rgba->data(), w, h, src, squish::kDxt5); break;
	case CF_8888:
		for (int i = 0; i < w * h; ++i) { (*rgba)[i * 4] = src[i * 4 + 2]; (*rgba)[i * 4 + 1] = src[i * 4 + 1]; (*rgba)[i * 4 + 2] = src[i * 4]; (*rgba)[i * 4 + 3] = src[i * 4 + 3]; }
		break;
	case CF_4444:
		for (int i = 0; i < w * h; ++i) { uint16_t p = src[i * 2] | (src[i * 2 + 1] << 8); (*rgba)[i * 4] = ((p >> 8) & 15) * 17; (*rgba)[i * 4 + 1] = ((p >> 4) & 15) * 17; (*rgba)[i * 4 + 2] = (p & 15) * 17; (*rgba)[i * 4 + 3] = (p >> 12) * 17; }
		break;
	case CF_565:
		for (int i = 0; i < w * h; ++i) { uint16_t p = src[i * 2] | (src[i * 2 + 1] << 8); (*rgba)[i * 4] = ((p >> 11) & 31) * 255 / 31; (*rgba)[i * 4 + 1] = ((p >> 5) & 63) * 255 / 63; (*rgba)[i * 4 + 2] = (p & 31) * 255 / 31; (*rgba)[i * 4 + 3] = 255; }
		break;
	case CF_1555:
		for (int i = 0; i < w * h; ++i) { uint16_t p = src[i * 2] | (src[i * 2 + 1] << 8); (*rgba)[i * 4] = ((p >> 10) & 31) * 255 / 31; (*rgba)[i * 4 + 1] = ((p >> 5) & 31) * 255 / 31; (*rgba)[i * 4 + 2] = (p & 31) * 255 / 31; (*rgba)[i * 4 + 3] = (p >> 15) ? 255 : 0; }
		break;
	default: return false;
	}
	return true;
}
static bool DecodeLevel0(const std::vector<unsigned char> &file, MMPHeader *hdr, std::vector<unsigned char> *rgba) { return DecodeLevel(file, 0, hdr, rgba); }
static double MeanColour(const std::vector<unsigned char> &rgba)
{
	double sum = 0;
	for (size_t i = 0; i < rgba.size(); i += 4) sum += (rgba[i] + rgba[i + 1] + rgba[i + 2]) / 3.0;
	return rgba.empty() ? 0 : sum / (rgba.size() / 4);
}

static bool WritePNG(const char *path, const std::vector<unsigned char> &rgba, int w, int h)
{
	// straight (non-premultiplied) RGBA: CGImage from a data provider keeps alpha exactly as stored
	CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGDataProviderRef dp = CGDataProviderCreateWithData(nullptr, rgba.data(), rgba.size(), nullptr);
	CGImageRef im = CGImageCreate(w, h, 8, 32, w * 4, cs, kCGImageAlphaLast | kCGBitmapByteOrderDefault, dp, nullptr, false, kCGRenderingIntentDefault);
	CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(path)], (__bridge CFStringRef)UTTypePNG.identifier, 1, nullptr);
	bool ok = d && im;
	if (ok) { CGImageDestinationAddImage(d, im, nullptr); ok = CGImageDestinationFinalize(d); }
	if (d) CFRelease(d);
	if (im) CGImageRelease(im);
	CGDataProviderRelease(dp); CGColorSpaceRelease(cs);
	return ok;
}

static bool ReadPNG(const char *path, std::vector<unsigned char> *rgba, int *w, int *h)
{
	CGImageSourceRef s = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(path)], nullptr);
	if (!s) return false;
	CGImageRef im = CGImageSourceCreateImageAtIndex(s, 0, nullptr);
	CFRelease(s);
	if (!im) return false;
	*w = (int)CGImageGetWidth(im); *h = (int)CGImageGetHeight(im);
	// CoreGraphics bitmap contexts are premultiplied only, which destroys colour wherever alpha is low. Extract writes
	// opaque images, so this reads them unchanged; anything else is refused rather than silently damaged.
	rgba->assign((size_t)*w * *h * 4, 0);
	CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGContextRef ctx = CGBitmapContextCreate(rgba->data(), *w, *h, 8, *w * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault);
	CGContextSetBlendMode(ctx, kCGBlendModeCopy);
	CGContextDrawImage(ctx, CGRectMake(0, 0, *w, *h), im);
	CGContextRelease(ctx); CGColorSpaceRelease(cs); CGImageRelease(im);
	for (size_t i = 3; i < rgba->size(); i += 4) if ((*rgba)[i] != 255) return false;
	return true;
}

static void MakeOpaque(std::vector<unsigned char> *rgba) { for (size_t i = 3; i < rgba->size(); i += 4) (*rgba)[i] = 255; }

// Alpha never goes through the upscaler: it is a mask or a blend weight, and the network only models colour.
static void CopyAlphaBilinear(const std::vector<unsigned char> &src, int sw, int sh, std::vector<unsigned char> *dst, int dw, int dh)
{
	for (int y = 0; y < dh; ++y)
		for (int x = 0; x < dw; ++x)
		{
			double fx = std::max(0.0, (x + 0.5) * sw / dw - 0.5), fy = std::max(0.0, (y + 0.5) * sh / dh - 0.5);
			int x0 = std::min((int)fx, sw - 1), y0 = std::min((int)fy, sh - 1), x1 = std::min(x0 + 1, sw - 1), y1 = std::min(y0 + 1, sh - 1);
			double tx = fx - x0, ty = fy - y0;
			auto a = [&](int px, int py) { return (double)src[((size_t)py * sw + px) * 4 + 3]; };
			double top = a(x0, y0) * (1 - tx) + a(x1, y0) * tx, bottom = a(x0, y1) * (1 - tx) + a(x1, y1) * tx;
			(*dst)[((size_t)y * dw + x) * 4 + 3] = (unsigned char)lround(top * (1 - ty) + bottom * ty);
		}
}

// Additive effects and lookups keep their colour in transparent pixels, so alpha does not describe their coverage.
static bool HasHiddenColour(const std::vector<unsigned char> &rgba)
{
	size_t hidden = 0, n = rgba.size() / 4;
	for (size_t i = 0; i < rgba.size(); i += 4)
		if (rgba[i + 3] < 16 && std::max(rgba[i], std::max(rgba[i + 1], rgba[i + 2])) > 16) ++hidden;
	return hidden * 1000 > n;
}

// area-average resize in gamma space, the space the game's own mip chains and hardware filtering use: averaging in
// linear light brightens every level below the first, so a surface would change colour as it recedes. Alpha-weighted
// colour keeps cut-out edges from picking up dark fringes; textures with hidden colour must not be weighted.
static void Resize(const std::vector<unsigned char> &src, int sw, int sh, std::vector<unsigned char> *dst, int dw, int dh, bool alphaWeighted)
{
	dst->assign((size_t)dw * dh * 4, 0);
	double fx = (double)sw / dw, fy = (double)sh / dh;
	for (int y = 0; y < dh; ++y)
		for (int x = 0; x < dw; ++x)
		{
			int x0 = (int)floor(x * fx), x1 = std::max(x0 + 1, (int)ceil((x + 1) * fx)), y0 = (int)floor(y * fy), y1 = std::max(y0 + 1, (int)ceil((y + 1) * fy));
			double r = 0, g = 0, b = 0, a = 0, n = 0, wsum = 0;
			for (int yy = y0; yy < std::min(y1, sh); ++yy)
				for (int xx = x0; xx < std::min(x1, sw); ++xx)
				{
					const unsigned char *p = &src[((size_t)yy * sw + xx) * 4];
					double w = alphaWeighted ? p[3] / 255.0 + 1e-4 : 1;
					r += p[0] * w; g += p[1] * w; b += p[2] * w; a += p[3]; n += 1; wsum += w;
				}
			unsigned char *o = &(*dst)[((size_t)y * dw + x) * 4];
			o[0] = (unsigned char)lround(r / wsum); o[1] = (unsigned char)lround(g / wsum); o[2] = (unsigned char)lround(b / wsum);
			o[3] = (unsigned char)lround(a / n);
		}
}

// bump maps hold normals in RGB: renormalise after filtering
static void RenormaliseNormals(std::vector<unsigned char> *rgba)
{
	for (size_t i = 0; i < rgba->size(); i += 4)
	{
		float x = (*rgba)[i] / 127.5f - 1, y = (*rgba)[i + 1] / 127.5f - 1, z = (*rgba)[i + 2] / 127.5f - 1;
		float l = sqrtf(x * x + y * y + z * z);
		if (l < 1e-3f) continue;
		(*rgba)[i] = (unsigned char)lroundf((x / l + 1) * 127.5f); (*rgba)[i + 1] = (unsigned char)lroundf((y / l + 1) * 127.5f); (*rgba)[i + 2] = (unsigned char)lroundf((z / l + 1) * 127.5f);
	}
}

static void Encode(int fmt, const std::vector<unsigned char> &rgba, int w, int h, std::vector<unsigned char> *out)
{
	size_t base = out->size();
	out->resize(base + LevelBytes(fmt, w, h));
	unsigned char *dst = out->data() + base;
	int quality = squish::kColourClusterFit;   // iterative fit is ~8x slower for a barely visible gain
	switch (fmt)
	{
	case CF_DXT1: squish::CompressImage(rgba.data(), w, h, dst, squish::kDxt1 | quality); break;
	case 2: case CF_DXT3: squish::CompressImage(rgba.data(), w, h, dst, squish::kDxt3 | quality); break;
	case 4: case CF_DXT5: squish::CompressImage(rgba.data(), w, h, dst, squish::kDxt5 | quality); break;
	case CF_8888: for (int i = 0; i < w * h; ++i) { dst[i * 4] = rgba[i * 4 + 2]; dst[i * 4 + 1] = rgba[i * 4 + 1]; dst[i * 4 + 2] = rgba[i * 4]; dst[i * 4 + 3] = rgba[i * 4 + 3]; } break;
	case CF_4444: for (int i = 0; i < w * h; ++i) { uint16_t p = (uint16_t)(((rgba[i * 4 + 3] >> 4) << 12) | ((rgba[i * 4] >> 4) << 8) | ((rgba[i * 4 + 1] >> 4) << 4) | (rgba[i * 4 + 2] >> 4)); dst[i * 2] = p & 255; dst[i * 2 + 1] = p >> 8; } break;
	case CF_565: for (int i = 0; i < w * h; ++i) { uint16_t p = (uint16_t)(((rgba[i * 4] >> 3) << 11) | ((rgba[i * 4 + 1] >> 2) << 5) | (rgba[i * 4 + 2] >> 3)); dst[i * 2] = p & 255; dst[i * 2 + 1] = p >> 8; } break;
	case CF_1555: for (int i = 0; i < w * h; ++i) { uint16_t p = (uint16_t)(((rgba[i * 4 + 3] >= 128) << 15) | ((rgba[i * 4] >> 3) << 10) | ((rgba[i * 4 + 1] >> 3) << 5) | (rgba[i * 4 + 2] >> 3)); dst[i * 2] = p & 255; dst[i * 2 + 1] = p >> 8; } break;
	}
}

struct ManifestRow { int usage = 0, w = 0, h = 0, dxt = 0, bump = 0, cube = 0, terrain = 0, protectedAtlas = 0; };
static std::map<int, ManifestRow> ReadManifest(const char *path)
{
	std::map<int, ManifestRow> m;
	FILE *f = fopen(path, "r");
	if (!f) { fprintf(stderr, "cannot read %s\n", path); return m; }
	char line[256];
	while (fgets(line, sizeof line, f))
	{
		int id; ManifestRow r;
		if (sscanf(line, "%d %d %d %d %d %d %d %d %d", &id, &r.usage, &r.w, &r.h, &r.dxt, &r.bump, &r.cube, &r.terrain, &r.protectedAtlas) == 9) m[id] = r;
		else { fclose(f); fprintf(stderr, "obsolete manifest: regenerate with texture_manifest (policy v2)\n"); return {}; }
	}
	fclose(f);
	return m;
}
// 3D textures and terrain tile colours only: interface (usage 0) textures use pixel coordinates, cube maps need all
// faces together, terrain masks are blend weights, and bump maps keep their originals (an AI upscaler invents
// texture detail, which in a normal map is noise). Terrain tiles pay off with the 512/1024 terrain bake.
static bool WantsHD(const ManifestRow &r) { return r.usage != 0 && !r.protectedAtlas && !r.cube && r.terrain != 2 && !r.bump; }

int main(int argc, char **argv)
{
	@autoreleasepool
	{
		if (argc < 3) { fprintf(stderr, "usage: texpack list|extract|build ...\n"); return 2; }
		std::string cmd = argv[1];
		if (!PkgOpen(argv[2])) { fprintf(stderr, "cannot open package %s\n", argv[2]); return 1; }
		std::vector<std::pair<int, unsigned>> files;
		PkgList(&files);
		std::sort(files.begin(), files.end());

		if (cmd == "ids")
		{
			for (auto &fi : files) printf("%d\n", fi.first);
			return 0;
		}

		if (cmd == "list")
		{
			std::map<std::string, std::pair<int, double>> bySize;
			std::map<int, int> byFmt;
			double pixels = 0; int bad = 0;
			std::vector<unsigned char> buf;
			for (auto &fi : files)
			{
				if (!PkgRead(fi.first, &buf) || buf.size() < sizeof(MMPHeader)) { ++bad; continue; }
				MMPHeader h; memcpy(&h, buf.data(), sizeof h);
				if (h.sig != 0x00504D4D) { ++bad; continue; }
				byFmt[h.format]++;
				char k[32]; snprintf(k, sizeof k, "%dx%d", h.w, h.h);
				bySize[k].first++; bySize[k].second += (double)h.w * h.h;
				pixels += (double)h.w * h.h;
			}
			printf("entries %zu, not MMP %d, level-0 pixels %.0f (%.1f megapixels)\n", files.size(), bad, pixels, pixels / 1e6);
			for (auto &f : byFmt) printf("format %d: %d\n", f.first, f.second);
			for (auto &s : bySize) printf("%s: %d\n", s.first.c_str(), s.second.first);
			return 0;
		}

		if (cmd == "extract" && argc >= 5)
		{
			auto man = ReadManifest(argv[3]);
			if (man.empty()) return 2;
			[NSFileManager.defaultManager createDirectoryAtPath:@(argv[4]) withIntermediateDirectories:YES attributes:nil error:nil];
			int n = 0, skipped = 0;
			std::vector<unsigned char> buf, rgba;
			for (auto &fi : files)
			{
				int id = fi.first & 0x00FFFFFF;
				auto it = man.find(id);
				if (it == man.end() || !WantsHD(it->second) || (fi.first & 0x01000000)) { ++skipped; continue; }
				MMPHeader h;
				if (!PkgRead(fi.first, &buf) || !DecodeLevel0(buf, &h, &rgba)) { ++skipped; continue; }
				MakeOpaque(&rgba);   // the upscaler sees colour only, including what transparent pixels hold
				if (it->second.terrain == 1 && h.h > 0 && h.w % h.h == 0)
				{
					// terrain strip: square variants side by side, each tiling with itself. Upscale each with a
					// wrap-around border so the result stays seamless; build crops the border off again.
					int t = h.h, pad = t / 4, pw = t + 2 * pad;
					std::vector<unsigned char> v((size_t)pw * pw * 4);
					for (int k = 0; k < h.w / t; ++k)
					{
						for (int y = 0; y < pw; ++y)
							for (int x = 0; x < pw; ++x)
							{
								int sx = k * t + ((x - pad) % t + t) % t, sy = ((y - pad) % t + t) % t;
								memcpy(&v[((size_t)y * pw + x) * 4], &rgba[((size_t)sy * h.w + sx) * 4], 4);
							}
						char out[1024]; snprintf(out, sizeof out, "%s/%d_%d.png", argv[4], fi.first, k);
						WritePNG(out, v, pw, pw);
					}
					++n;
					continue;
				}
				char out[1024]; snprintf(out, sizeof out, "%s/%d.png", argv[4], fi.first);
				if (WritePNG(out, rgba, h.w, h.h)) ++n;
			}
			printf("extracted %d textures, skipped %d\n", n, skipped);
			return 0;
		}

		// texpack compare <Textures.res> <hd dir> <out.tsv>: every override's pixels against its source. Structure
		// checks cannot see lost colour; this averages level 0 down to the source size and measures the difference.
		if (cmd == "compare" && argc >= 5)
		{
			FILE *out = fopen(argv[4], "w");
			if (!out) { fprintf(stderr, "cannot write %s\n", argv[4]); return 1; }
			fprintf(out, "id format w h hdw hdh src_mean hd_mean rgb_err alpha_err hidden_frac hidden_src hidden_hd alpha_frac mip_src mip_hd\n");
			int compared = 0;
			std::vector<unsigned char> buf, hdBuf, src, hd;
			for (auto &fi : files)
			{
				if (fi.first & 0x01000000) continue;
				NSData *data = [NSData dataWithContentsOfFile:[NSString stringWithFormat:@"%s/%d", argv[3], fi.first]];
				if (!data) continue;
				hdBuf.assign((const unsigned char *)data.bytes, (const unsigned char *)data.bytes + data.length);
				MMPHeader sh, hh;
				if (!PkgRead(fi.first, &buf) || !DecodeLevel0(buf, &sh, &src) || !DecodeLevel0(hdBuf, &hh, &hd)) { fprintf(stderr, "cannot decode %d\n", fi.first); continue; }
				int fx = hh.w / sh.w, fy = hh.h / sh.h;
				if (fx < 1 || fy < 1) continue;
				double srcSum = 0, hdSum = 0, rgbErr = 0, alphaErr = 0, hiddenSrc = 0, hiddenHd = 0, hidden = 0, transparent = 0, n = (double)sh.w * sh.h;
				for (int y = 0; y < sh.h; ++y)
					for (int x = 0; x < sh.w; ++x)
					{
						const unsigned char *p = &src[((size_t)y * sh.w + x) * 4];
						double c[4] = {};
						for (int yy = y * fy; yy < (y + 1) * fy; ++yy)
							for (int xx = x * fx; xx < (x + 1) * fx; ++xx)
							{
								const unsigned char *q = &hd[((size_t)yy * hh.w + xx) * 4];
								for (int k = 0; k < 4; ++k) c[k] += q[k];
							}
						for (int k = 0; k < 4; ++k) c[k] /= fx * fy;
						double sm = (p[0] + p[1] + p[2]) / 3.0, hm = (c[0] + c[1] + c[2]) / 3.0;
						srcSum += sm; hdSum += hm;
						rgbErr += (fabs(p[0] - c[0]) + fabs(p[1] - c[1]) + fabs(p[2] - c[2])) / 3;
						alphaErr += fabs(p[3] - c[3]);
						if (p[3] < 16 && std::max(p[0], std::max(p[1], p[2])) > 16) { ++hidden; hiddenSrc += sm; hiddenHd += hm; }
						if (p[3] < 255) ++transparent;
					}
				// a distant view of the same texture: the source's third mip against the matching HD level
				int level = 0, scale = 1;
				while (scale < fx) { scale *= 2; ++level; }
				MMPHeader sm, hm;
				std::vector<unsigned char> srcMip, hdMip;
				bool mips = DecodeLevel(buf, 3, &sm, &srcMip) && DecodeLevel(hdBuf, 3 + level, &hm, &hdMip);
				fprintf(out, "%d %d %d %d %d %d %.2f %.2f %.2f %.2f %.4f %.2f %.2f %.4f %.2f %.2f\n", fi.first, sh.format, sh.w, sh.h, hh.w, hh.h, srcSum / n, hdSum / n, rgbErr / n, alphaErr / n, hidden / n, hidden ? hiddenSrc / hidden : 0, hidden ? hiddenHd / hidden : 0, transparent / n, mips ? MeanColour(srcMip) : -1, mips ? MeanColour(hdMip) : -1);
				++compared;
			}
			fclose(out);
			printf("compared %d overrides\n", compared);
			return 0;
		}

		if (cmd == "build" && argc >= 6)
		{
			auto man = ReadManifest(argv[3]);
			if (man.empty()) return 2;
			const char *upDir = argv[4], *outDir = argv[5];
			int scale = 2, maxSize = 2048;
			for (int i = 6; i + 1 < argc; ++i) { if (!strcmp(argv[i], "--scale")) scale = atoi(argv[i + 1]); if (!strcmp(argv[i], "--max")) maxSize = atoi(argv[i + 1]); }
			[NSFileManager.defaultManager createDirectoryAtPath:@(outDir) withIntermediateDirectories:YES attributes:nil error:nil];
			std::vector<int> jobs;
			for (auto &fi : files)
			{
				auto it = man.find(fi.first & 0x00FFFFFF);
				if (it == man.end() || !WantsHD(it->second) || (fi.first & 0x01000000)) continue;
				char in[1024]; snprintf(in, sizeof in, "%s/%d.png", upDir, fi.first);
				char in0[1024]; snprintf(in0, sizeof in0, "%s/%d_0.png", upDir, fi.first);
				if (access(in, R_OK) == 0 || (it->second.terrain == 1 && access(in0, R_OK) == 0)) jobs.push_back(fi.first);
			}
			static std::atomic<int> built{0};
			static std::atomic<long long> inBytes{0}, outBytes{0};
			std::vector<int> *jp = &jobs;
			std::map<int, ManifestRow> *mp = &man;
			dispatch_apply(jobs.size(), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(size_t k) {
				int id = (*jp)[k];
				std::vector<unsigned char> buf, up, lvl, next, file;
				if (!PkgRead(id, &buf) || buf.size() < sizeof(MMPHeader)) return;
				MMPHeader h; memcpy(&h, buf.data(), sizeof h);
				bool terrain = (*mp)[id & 0x00FFFFFF].terrain == 1;
				int uw, uh;
				if (terrain && h.h > 0 && h.w % h.h == 0)
				{
					// reassemble the strip from its padded variants, cropping each border
					int t = h.h, pad = t / 4, n = h.w / t, vs = 0;
					for (int k = 0; k < n; ++k)
					{
						char in[1024]; snprintf(in, sizeof in, "%s/%d_%d.png", upDir, id, k);
						std::vector<unsigned char> v; int vw, vh;
						if (!ReadPNG(in, &v, &vw, &vh)) return;
						int f = vw / (t + 2 * pad), cs = t * f, off = pad * f;
						if (k == 0) { vs = cs; up.assign((size_t)cs * n * cs * 4, 0); }
						if (cs != vs) return;
						for (int y = 0; y < cs; ++y)
							memcpy(&up[((size_t)y * cs * n + (size_t)k * cs) * 4], &v[((size_t)(y + off) * vw + off) * 4], (size_t)cs * 4);
					}
					uw = vs * n; uh = vs;
				}
				else
				{
					char in[1024]; snprintf(in, sizeof in, "%s/%d.png", upDir, id);
					if (!ReadPNG(in, &up, &uw, &uh)) return;
				}
				int tw = h.w * (terrain ? 4 : scale), th = h.h * (terrain ? 4 : scale);   // tiles: 4x for the 1024 bake
				while ((tw > maxSize || th > maxSize) && tw > h.w) { tw /= 2; th /= 2; }
				if (tw <= h.w) return;   // already at the cap: keep the original
				Resize(up, uw, uh, &lvl, tw, th, false);
				std::vector<unsigned char> source;
				MMPHeader sh;
				if (!DecodeLevel0(buf, &sh, &source)) return;
				CopyAlphaBilinear(source, sh.w, sh.h, &lvl, tw, th);
				const bool weighted = !HasHiddenColour(source);
				file.assign(sizeof(MMPHeader), 0);
				// same smallest level as the original (Nival's DXT chains stop at 4x4): original count + the extra levels
				int extra = 0; for (int s2 = tw / h.w; s2 > 1; s2 /= 2) ++extra;
				int wantMips = std::max(1, h.mips + extra);
				int mips = 0, w = tw, hh = th;
				while (true)
				{
					Encode(h.format, lvl, w, hh, &file);
					++mips;
					if (mips >= wantMips || (w == 1 && hh == 1)) break;
					int nw = std::max(1, w / 2), nh = std::max(1, hh / 2);
					Resize(lvl, w, hh, &next, nw, nh, weighted);
					lvl.swap(next); w = nw; hh = nh;
				}
				MMPHeader oh = h; oh.w = tw; oh.h = th; oh.mips = mips;
				memcpy(file.data(), &oh, sizeof oh);
				char out[1024], tmp[1100]; snprintf(out, sizeof out, "%s/%d", outDir, id); snprintf(tmp, sizeof tmp, "%s.part", out);
				if (FILE *o = fopen(tmp, "wb")) { fwrite(file.data(), 1, file.size(), o); fclose(o); rename(tmp, out); built++; inBytes += buf.size(); outBytes += file.size(); }
			});
			printf("built %d HD textures (%.0f MB from %.0f MB)\n", built.load(), outBytes.load() / 1e6, inBytes.load() / 1e6);
			return 0;
		}
		fprintf(stderr, "unknown command or missing arguments\n");
		return 2;
	}
}

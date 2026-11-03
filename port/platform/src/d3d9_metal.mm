// d3d9_metal.mm: Direct3D 9 implemented on Metal, covering what the Silent Storm engine uses.
// Conventions handled here: D3D9's half-pixel raster offset, left-handed clockwise front faces,
// 16-bit and luminance formats (converted or swizzled), DXT via BC, gamma ramps applied at present,
// DISCARD / NOOVERWRITE buffer locking without GPU races, and occlusion / event queries.
#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "d3d9_metal.h"
#include "s2platform.h"
#include "s2settings.h"
#include <cmath>
#include <algorithm>

using namespace s2gfx;

void S2Unimplemented(const char *what)
{
	static std::mutex m; static std::vector<std::string> seen;
	std::lock_guard<std::mutex> l(m);
	for (auto &s : seen) if (s == what) return;
	seen.push_back(what);
	fprintf(stderr, "[d3d9] unimplemented: %s\n", what);
}

namespace s2gfx {

// bump whenever generated shader code changes, so cached pipelines are rebuilt
static const uint64_t kShaderGenVersion = 5;	// 5: invariant positions (the road z-fighting stripes)

uint64_t Hash64(const void *data, size_t n, uint64_t h)
{
	const BYTE *p = (const BYTE*)data;
	for (size_t i = 0; i < n; ++i) { h ^= p[i]; h *= 1099511628211ull; }
	return h;
}

// ---------------------------------------------------------------------------------------------------
// formats
static const MTLTextureSwizzleChannels kIdentity = { MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha };
static const MTLTextureSwizzleChannels kOpaque = { MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleOne };
static const MTLTextureSwizzleChannels kLum = { MTLTextureSwizzleRed, MTLTextureSwizzleRed, MTLTextureSwizzleRed, MTLTextureSwizzleOne };
static const MTLTextureSwizzleChannels kLumAlpha = { MTLTextureSwizzleRed, MTLTextureSwizzleRed, MTLTextureSwizzleRed, MTLTextureSwizzleGreen };
static const MTLTextureSwizzleChannels kBump = { MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleOne, MTLTextureSwizzleOne };

const FormatInfo *GetFormat(D3DFORMAT f)
{
	static const FormatInfo bgra = { MTLPixelFormatBGRA8Unorm, 4, false, false, kIdentity, false, false };
	static const FormatInfo bgrx = { MTLPixelFormatBGRA8Unorm, 4, false, false, kOpaque, false, false };
	static const FormatInfo conv16 = { MTLPixelFormatBGRA8Unorm, 2, false, true, kIdentity, false, false };
	static const FormatInfo conv16x = { MTLPixelFormatBGRA8Unorm, 2, false, true, kOpaque, false, false };
	static const FormatInfo conv24 = { MTLPixelFormatBGRA8Unorm, 3, false, true, kOpaque, false, false };
	static const FormatInfo conv8 = { MTLPixelFormatBGRA8Unorm, 1, false, true, kIdentity, false, false };
	static const FormatInfo a8 = { MTLPixelFormatA8Unorm, 1, false, false, kIdentity, false, false };
	static const FormatInfo l8 = { MTLPixelFormatR8Unorm, 1, false, false, kLum, false, false };
	static const FormatInfo a8l8 = { MTLPixelFormatRG8Unorm, 2, false, false, kLumAlpha, false, false };
	static const FormatInfo v8u8 = { MTLPixelFormatRG8Snorm, 2, false, false, kBump, false, false };
	static const FormatInfo xlvu = { MTLPixelFormatRGBA8Snorm, 4, false, true, kIdentity, false, false };
	static const FormatInfo dxt1 = { MTLPixelFormatBC1_RGBA, 8, true, false, kIdentity, false, false };
	static const FormatInfo dxt3 = { MTLPixelFormatBC2_RGBA, 16, true, false, kIdentity, false, false };
	static const FormatInfo dxt5 = { MTLPixelFormatBC3_RGBA, 16, true, false, kIdentity, false, false };
	static const FormatInfo depthStencil = { MTLPixelFormatDepth32Float_Stencil8, 4, false, false, kIdentity, true, true };
	static const FormatInfo depthOnly = { MTLPixelFormatDepth32Float, 4, false, false, kIdentity, true, false };
	switch (f)
	{
	case D3DFMT_A8R8G8B8: return &bgra;
	case D3DFMT_X8R8G8B8: return &bgrx;
	case D3DFMT_R5G6B5: case D3DFMT_X1R5G5B5: case D3DFMT_X4R4G4B4: return &conv16x;
	case D3DFMT_A1R5G5B5: case D3DFMT_A4R4G4B4: case D3DFMT_A8R3G3B2: return &conv16;
	case D3DFMT_R8G8B8: return &conv24;
	case D3DFMT_R3G3B2: return &conv8;
	case D3DFMT_A4L4: return &conv8;
	case D3DFMT_A8: return &a8;
	case D3DFMT_L8: return &l8;
	case D3DFMT_A8L8: return &a8l8;
	case D3DFMT_V8U8: return &v8u8;
	case D3DFMT_X8L8V8U8: case D3DFMT_L6V5U5: return &xlvu;
	case D3DFMT_DXT1: return &dxt1;
	case D3DFMT_DXT2: case D3DFMT_DXT3: return &dxt3;
	case D3DFMT_DXT4: case D3DFMT_DXT5: return &dxt5;
	case D3DFMT_D24S8: case D3DFMT_D15S1: case D3DFMT_D24X4S4: return &depthStencil;
	case D3DFMT_D16: case D3DFMT_D24X8: case D3DFMT_D32: return &depthOnly;
	default: return nullptr;
	}
}
static int D3DBytes(D3DFORMAT f)
{
	switch (f)
	{
	case D3DFMT_R5G6B5: case D3DFMT_X1R5G5B5: case D3DFMT_X4R4G4B4: case D3DFMT_A1R5G5B5: case D3DFMT_A4R4G4B4: case D3DFMT_A8R3G3B2:
	case D3DFMT_A8L8: case D3DFMT_V8U8: case D3DFMT_L6V5U5: case D3DFMT_D16: case D3DFMT_D15S1: return 2;
	case D3DFMT_R8G8B8: return 3;
	case D3DFMT_R3G3B2: case D3DFMT_A4L4: case D3DFMT_A8: case D3DFMT_L8: case D3DFMT_P8: return 1;
	default: return 4;
	}
}
static bool IsCompressed(D3DFORMAT f) { return f == D3DFMT_DXT1 || f == D3DFMT_DXT2 || f == D3DFMT_DXT3 || f == D3DFMT_DXT4 || f == D3DFMT_DXT5; }
size_t LevelPitch(D3DFORMAT f, UINT w)
{
	if (IsCompressed(f)) return (size_t)std::max(1u, (w + 3) / 4) * (f == D3DFMT_DXT1 ? 8 : 16);
	return (size_t)w * D3DBytes(f);
}
UINT LevelRows(D3DFORMAT f, UINT h) { return IsCompressed(f) ? std::max(1u, (h + 3) / 4) : h; }

static inline BYTE X5(unsigned v) { return (BYTE)((v << 3) | (v >> 2)); }
static inline BYTE X6(unsigned v) { return (BYTE)((v << 2) | (v >> 4)); }
static inline BYTE X4(unsigned v) { return (BYTE)((v << 4) | v); }
static inline BYTE X3(unsigned v) { return (BYTE)((v << 5) | (v << 2) | (v >> 1)); }
static inline BYTE X2(unsigned v) { return (BYTE)(v * 0x55); }
void ConvertToBGRA8(D3DFORMAT f, const BYTE *src, size_t srcPitch, BYTE *dst, size_t dstPitch, UINT w, UINT h)
{
	for (UINT y = 0; y < h; ++y)
	{
		const BYTE *s = src + y * srcPitch; BYTE *d = dst + y * dstPitch;
		for (UINT x = 0; x < w; ++x, d += 4)
		{
			unsigned v;
			switch (f)
			{
			case D3DFMT_R5G6B5: v = ((const WORD*)s)[x]; d[0] = X5(v & 31); d[1] = X6((v >> 5) & 63); d[2] = X5(v >> 11); d[3] = 255; break;
			case D3DFMT_X1R5G5B5: case D3DFMT_A1R5G5B5: v = ((const WORD*)s)[x]; d[0] = X5(v & 31); d[1] = X5((v >> 5) & 31); d[2] = X5((v >> 10) & 31); d[3] = (f == D3DFMT_X1R5G5B5 || (v & 0x8000)) ? 255 : 0; break;
			case D3DFMT_X4R4G4B4: case D3DFMT_A4R4G4B4: v = ((const WORD*)s)[x]; d[0] = X4(v & 15); d[1] = X4((v >> 4) & 15); d[2] = X4((v >> 8) & 15); d[3] = f == D3DFMT_X4R4G4B4 ? 255 : X4(v >> 12); break;
			case D3DFMT_A8R3G3B2: v = ((const WORD*)s)[x]; d[0] = X2(v & 3); d[1] = X3((v >> 2) & 7); d[2] = X3((v >> 5) & 7); d[3] = (BYTE)(v >> 8); break;
			case D3DFMT_R3G3B2: v = s[x]; d[0] = X2(v & 3); d[1] = X3((v >> 2) & 7); d[2] = X3((v >> 5) & 7); d[3] = 255; break;
			case D3DFMT_R8G8B8: d[0] = s[x * 3]; d[1] = s[x * 3 + 1]; d[2] = s[x * 3 + 2]; d[3] = 255; break;
			case D3DFMT_A4L4: v = s[x]; d[0] = d[1] = d[2] = X4(v & 15); d[3] = X4(v >> 4); break;
			case D3DFMT_X8L8V8U8: memcpy(d, s + x * 4, 4); d[3] = 127; break;   // RGBA8Snorm: U, V, L, 1
			case D3DFMT_L6V5U5:
			{
				v = ((const WORD*)s)[x];
				int u = (int)((v & 31) << 27) >> 27, vv = (int)(((v >> 5) & 31) << 27) >> 27;
				d[0] = (BYTE)(int8_t)(u * 127 / 15); d[1] = (BYTE)(int8_t)(vv * 127 / 15); d[2] = (BYTE)((v >> 10) * 127 / 63); d[3] = 127; break;
			}
			default: d[0] = d[1] = d[2] = d[3] = 255;
			}
		}
	}
}

// ---------------------------------------------------------------------------------------------------
// textures and surfaces
static UINT FullChain(UINT w, UINT h) { UINT n = 1; while (w > 1 || h > 1) { w = std::max(1u, w / 2); h = std::max(1u, h / 2); ++n; } return n; }

void TextureBase::CreateTexture()
{
	const FormatInfo *fi = GetFormat(format);
	MTLTextureDescriptor *d = [MTLTextureDescriptor new];
	d.textureType = cube ? MTLTextureTypeCube : MTLTextureType2D;
	d.pixelFormat = fi ? fi->metal : MTLPixelFormatBGRA8Unorm;
	d.width = width; d.height = cube ? width : height;
	d.mipmapLevelCount = levels;
	d.usage = MTLTextureUsageShaderRead;
	bool rt = (usage & (D3DUSAGE_RENDERTARGET | D3DUSAGE_DEPTHSTENCIL)) != 0;
	if (rt) d.usage |= MTLTextureUsageRenderTarget;
	d.storageMode = rt ? MTLStorageModePrivate : MTLStorageModeShared;
	bool swz = fi && memcmp(&fi->swizzle, &kIdentity, sizeof kIdentity) != 0;
	if (fi && !rt) d.swizzle = fi->swizzle;
	tex = [dev->mtl newTextureWithDescriptor:d];
	if (tex && rt && swz && !fi->depth)
		sampleView = [tex newTextureViewWithPixelFormat:tex.pixelFormat textureType:tex.textureType levels:NSMakeRange(0, levels) slices:NSMakeRange(0, cube ? 6 : 1) swizzle:fi->swizzle];
}
void TextureBase::ReleaseSurfaces() { for (Surface *s : surfaces) delete s; surfaces.clear(); }

id<MTLTexture> Surface::Texture() const { return owner ? owner->tex : own; }
ULONG Surface::AddRef() { return container ? container->AddRef() : ++refs; }
ULONG Surface::Release()
{
	if (container) return container->Release();
	ULONG r = --refs; if (r == 0) delete this; return r;
}
HRESULT Surface::GetDevice(IDirect3DDevice9 **pp) { *pp = dev; dev->AddRef(); return D3D_OK; }
HRESULT Surface::GetContainer(REFIID, void **pp) { if (!container) return E_NOINTERFACE; *pp = container; container->AddRef(); return D3D_OK; }
HRESULT Surface::GetDesc(D3DSURFACE_DESC *d)
{
	memset(d, 0, sizeof *d);
	d->Format = format; d->Type = D3DRTYPE_SURFACE; d->Usage = usage; d->Pool = pool; d->Width = width; d->Height = height;
	d->MultiSampleType = D3DMULTISAMPLE_NONE;
	return D3D_OK;
}

HRESULT Surface::LockRect(D3DLOCKED_RECT *out, const RECT *r, DWORD flags)
{
	std::lock_guard<std::recursive_mutex> l(dev->lock);
	if (locked) return D3DERR_INVALIDCALL;
	RECT rc = r ? *r : RECT { 0, 0, (LONG)width, (LONG)height };
	size_t pitch = LevelPitch(format, width);
	bool comp = IsCompressed(format);
	UINT rowY = comp ? rc.top / 4 : rc.top;
	size_t colBytes = comp ? (size_t)(rc.left / 4) * (format == D3DFMT_DXT1 ? 8 : 16) : (size_t)rc.left * D3DBytes(format);
	if (IsCPU())
	{
		if (sysmem.empty()) sysmem.resize(pitch * LevelRows(format, height));
		out->pBits = sysmem.data() + rowY * pitch + colBytes; out->Pitch = (INT)pitch;
		locked = true; lockRect = rc; lockFlags = flags;
		return D3D_OK;
	}
	const FormatInfo *fi = GetFormat(format);
	id<MTLTexture> t = Texture();
	if (!t || !fi) return D3DERR_INVALIDCALL;
	if (t.storageMode == MTLStorageModePrivate)
	{
		// lockable render target: read the GPU image back, write it again on unlock
		std::vector<BYTE> img; size_t rp = 0; dev->ReadbackTexture(t, &img, &rp);
		shadow.assign(pitch * height, 0);
		for (UINT y = 0; y < height; ++y) memcpy(&shadow[y * pitch], &img[y * rp], std::min(pitch, rp));
	}
	if (fi->convert || t.storageMode == MTLStorageModePrivate)
	{
		if (shadow.empty()) shadow.assign(pitch * LevelRows(format, height), 0);
		out->pBits = shadow.data() + rowY * pitch + colBytes; out->Pitch = (INT)pitch;
	}
	else
	{
		UINT rows = comp ? LevelRows(format, rc.bottom - rc.top) : (UINT)(rc.bottom - rc.top);
		size_t rowBytes = comp ? (size_t)std::max(1L, (long)((rc.right - rc.left + 3) / 4)) * (format == D3DFMT_DXT1 ? 8 : 16) : (size_t)(rc.right - rc.left) * D3DBytes(format);
		lockBuf.resize(rowBytes * rows);
		if (!(flags & D3DLOCK_DISCARD))
		{
			MTLRegion region = MTLRegionMake2D(rc.left, rc.top, rc.right - rc.left, rc.bottom - rc.top);
			[t getBytes:lockBuf.data() bytesPerRow:rowBytes bytesPerImage:rowBytes * rows fromRegion:region mipmapLevel:level slice:face];
		}
		out->pBits = lockBuf.data(); out->Pitch = (INT)rowBytes;
	}
	locked = true; lockRect = rc; lockFlags = flags;
	return D3D_OK;
}

HRESULT Surface::UnlockRect()
{
	std::lock_guard<std::recursive_mutex> l(dev->lock);
	if (!locked) return D3DERR_INVALIDCALL;
	locked = false;
	if (IsCPU() || (lockFlags & D3DLOCK_READONLY)) return D3D_OK;
	id<MTLTexture> t = Texture();
	const FormatInfo *fi = GetFormat(format);
	RECT rc = lockRect;
	UINT w = rc.right - rc.left, h = rc.bottom - rc.top;
	if (t.storageMode == MTLStorageModePrivate)
	{
		// write the shadow back through a staging texture
		size_t pitch = LevelPitch(format, width);
		MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:t.pixelFormat width:width height:height mipmapped:NO];
		d.storageMode = MTLStorageModeShared;
		id<MTLTexture> stage = [dev->mtl newTextureWithDescriptor:d];
		[stage replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:shadow.data() bytesPerRow:pitch];
		dev->EndPass();
		dev->BeginFrame();
		id<MTLBlitCommandEncoder> b = [dev->cmd blitCommandEncoder];
		[b copyFromTexture:stage sourceSlice:0 sourceLevel:0 toTexture:t destinationSlice:face destinationLevel:level sliceCount:1 levelCount:1];
		[b endEncoding];
		shadow.clear(); shadow.shrink_to_fit();
		return D3D_OK;
	}
	MTLRegion region = MTLRegionMake2D(rc.left, rc.top, w, h);
	if (fi->convert)
	{
		size_t pitch = LevelPitch(format, width);
		std::vector<BYTE> tmp((size_t)w * h * 4);
		ConvertToBGRA8(format, shadow.data() + rc.top * pitch + (size_t)rc.left * D3DBytes(format), pitch, tmp.data(), (size_t)w * 4, w, h);
		[t replaceRegion:region mipmapLevel:level slice:face withBytes:tmp.data() bytesPerRow:(size_t)w * 4 bytesPerImage:tmp.size()];
	}
	else
	{
		size_t rowBytes = IsCompressed(format) ? (size_t)std::max(1u, (w + 3) / 4) * (format == D3DFMT_DXT1 ? 8 : 16) : (size_t)w * D3DBytes(format);
		[t replaceRegion:region mipmapLevel:level slice:face withBytes:lockBuf.data() bytesPerRow:rowBytes bytesPerImage:lockBuf.size()];
		lockBuf.clear(); lockBuf.shrink_to_fit();
	}
	return D3D_OK;
}

template<class T> static Surface *LevelSurface(T *tex, UINT face, UINT level)
{
	size_t idx = (size_t)face * tex->levels + level;
	if (tex->surfaces.size() <= idx) tex->surfaces.resize(idx + 1, nullptr);
	Surface *&s = tex->surfaces[idx];
	if (!s)
	{
		s = new Surface();
		s->dev = tex->dev; s->owner = tex; s->container = tex; s->level = level; s->face = face;
		s->width = std::max(1u, tex->width >> level); s->height = std::max(1u, (tex->cube ? tex->width : tex->height) >> level);
		s->format = tex->format; s->usage = tex->usage; s->pool = tex->pool;
	}
	return s;
}
HRESULT Texture::GetDevice(IDirect3DDevice9 **pp) { *pp = dev; dev->AddRef(); return D3D_OK; }
HRESULT Texture::GetLevelDesc(UINT level, D3DSURFACE_DESC *d) { if (level >= levels) return D3DERR_INVALIDCALL; return LevelSurface(this, 0, level)->GetDesc(d); }
HRESULT Texture::GetSurfaceLevel(UINT level, IDirect3DSurface9 **pp) { if (level >= levels) return D3DERR_INVALIDCALL; *pp = LevelSurface(this, 0, level); (*pp)->AddRef(); return D3D_OK; }
HRESULT Texture::LockRect(UINT level, D3DLOCKED_RECT *out, const RECT *r, DWORD flags) { if (level >= levels) return D3DERR_INVALIDCALL; return LevelSurface(this, 0, level)->LockRect(out, r, flags); }
HRESULT Texture::UnlockRect(UINT level) { if (level >= levels) return D3DERR_INVALIDCALL; return LevelSurface(this, 0, level)->UnlockRect(); }
HRESULT CubeTexture::GetDevice(IDirect3DDevice9 **pp) { *pp = dev; dev->AddRef(); return D3D_OK; }
HRESULT CubeTexture::GetLevelDesc(UINT level, D3DSURFACE_DESC *d) { if (level >= levels) return D3DERR_INVALIDCALL; return LevelSurface(this, 0, level)->GetDesc(d); }
HRESULT CubeTexture::GetCubeMapSurface(D3DCUBEMAP_FACES f, UINT level, IDirect3DSurface9 **pp) { if (level >= levels) return D3DERR_INVALIDCALL; *pp = LevelSurface(this, (UINT)f, level); (*pp)->AddRef(); return D3D_OK; }
HRESULT CubeTexture::LockRect(D3DCUBEMAP_FACES f, UINT level, D3DLOCKED_RECT *out, const RECT *r, DWORD flags) { return LevelSurface(this, (UINT)f, level)->LockRect(out, r, flags); }
HRESULT CubeTexture::UnlockRect(D3DCUBEMAP_FACES f, UINT level) { return LevelSurface(this, (UINT)f, level)->UnlockRect(); }

// ---------------------------------------------------------------------------------------------------
// buffers
void Buffer::Create() { buf = [dev->mtl newBufferWithLength:std::max<UINT>(length, 16) options:MTLResourceStorageModeShared]; }
void *Buffer::Lock(UINT offset, UINT, DWORD flags)
{
	if (flags & D3DLOCK_DISCARD)
	{
		if (lastUse > dev->completed)
		{
			retired.push_back({ buf, lastUse });
			id<MTLBuffer> reuse = nil;
			for (size_t i = 0; i < retired.size(); ++i)
				if (retired[i].second <= dev->completed && retired[i].first != buf) { reuse = retired[i].first; retired.erase(retired.begin() + i); break; }
			buf = reuse ? reuse : [dev->mtl newBufferWithLength:std::max<UINT>(length, 16) options:MTLResourceStorageModeShared];
			lastUse = 0;
		}
	}
	else if (!(flags & (D3DLOCK_NOOVERWRITE | D3DLOCK_READONLY)) && lastUse > dev->completed)
		dev->WaitForSerial(lastUse);
	return (BYTE*)buf.contents + offset;
}
HRESULT VertexBuffer::GetDevice(IDirect3DDevice9 **pp) { *pp = dev; dev->AddRef(); return D3D_OK; }
HRESULT VertexBuffer::Lock(UINT off, UINT size, void **pp, DWORD flags) { std::lock_guard<std::recursive_mutex> l(dev->lock); *pp = Buffer::Lock(off, size, flags); return D3D_OK; }
HRESULT VertexBuffer::GetDesc(D3DVERTEXBUFFER_DESC *d) { memset(d, 0, sizeof *d); d->Format = D3DFMT_VERTEXDATA; d->Type = D3DRTYPE_VERTEXBUFFER; d->Usage = usage; d->Pool = pool; d->Size = length; d->FVF = fvf; return D3D_OK; }
HRESULT IndexBuffer::GetDevice(IDirect3DDevice9 **pp) { *pp = dev; dev->AddRef(); return D3D_OK; }
HRESULT IndexBuffer::Lock(UINT off, UINT size, void **pp, DWORD flags) { std::lock_guard<std::recursive_mutex> l(dev->lock); *pp = Buffer::Lock(off, size, flags); return D3D_OK; }
HRESULT IndexBuffer::GetDesc(D3DINDEXBUFFER_DESC *d) { memset(d, 0, sizeof *d); d->Format = format; d->Type = D3DRTYPE_INDEXBUFFER; d->Usage = usage; d->Pool = pool; d->Size = length; return D3D_OK; }

HRESULT VertexDecl::GetDevice(IDirect3DDevice9 **pp) { *pp = dev; dev->AddRef(); return D3D_OK; }
HRESULT VertexDecl::GetDeclaration(D3DVERTEXELEMENT9 *out, UINT *n)
{
	if (n) *n = (UINT)elements.size() + 1;
	if (out) { memcpy(out, elements.data(), elements.size() * sizeof(D3DVERTEXELEMENT9)); D3DVERTEXELEMENT9 end = D3DDECL_END(); out[elements.size()] = end; }
	return D3D_OK;
}
HRESULT VertexShader::GetDevice(IDirect3DDevice9 **pp) { *pp = dev; dev->AddRef(); return D3D_OK; }
HRESULT VertexShader::GetFunction(void *p, UINT *n) { if (n) *n = (UINT)(code.size() * 4); if (p) memcpy(p, code.data(), code.size() * 4); return D3D_OK; }
HRESULT PixelShader::GetDevice(IDirect3DDevice9 **pp) { *pp = dev; dev->AddRef(); return D3D_OK; }
HRESULT PixelShader::GetFunction(void *p, UINT *n) { if (n) *n = (UINT)(code.size() * 4); if (p) memcpy(p, code.data(), code.size() * 4); return D3D_OK; }

// ---------------------------------------------------------------------------------------------------
// queries
HRESULT Query::GetDevice(IDirect3DDevice9 **pp) { *pp = dev; dev->AddRef(); return D3D_OK; }
Query::~Query()
{
	std::lock_guard<std::recursive_mutex> l(dev->lock);
	if (dev->activeQuery == this) dev->activeQuery = nullptr;
	if (slot >= 0) dev->freeVisibilitySlots.push_back(slot);
}
HRESULT Query::Issue(DWORD flags)
{
	std::lock_guard<std::recursive_mutex> l(dev->lock);
	if (type == D3DQUERYTYPE_OCCLUSION)
	{
		if (flags & D3DISSUE_BEGIN)
		{
			if (slot < 0) { if (dev->freeVisibilitySlots.empty()) return D3DERR_NOTAVAILABLE; slot = dev->freeVisibilitySlots.back(); dev->freeVisibilitySlots.pop_back(); }
			((uint64_t*)dev->visibility.contents)[slot] = 0;
			dev->activeQuery = this;
			dev->EnsurePass();
			[dev->enc setVisibilityResultMode:MTLVisibilityResultModeCounting offset:slot * 8];
		}
		if (flags & D3DISSUE_END)
		{
			if (dev->activeQuery == this && dev->enc) [dev->enc setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:0];
			if (dev->activeQuery == this) dev->activeQuery = nullptr;
			endSerial = dev->serial; issued = true;
		}
		return D3D_OK;
	}
	if (flags & D3DISSUE_END) { endSerial = dev->serial; issued = true; }
	return D3D_OK;
}
HRESULT Query::GetData(void *data, DWORD size, DWORD flags)
{
	std::lock_guard<std::recursive_mutex> l(dev->lock);
	if (!issued) return S_FALSE;
	if (dev->completed < endSerial)
	{
		if ((flags & D3DGETDATA_FLUSH) && dev->serial == endSerial) dev->Submit(false);
		return S_FALSE;
	}
	if (type == D3DQUERYTYPE_OCCLUSION) { if (data && size >= 4) *(DWORD*)data = (DWORD)((uint64_t*)dev->visibility.contents)[slot]; }
	else if (data && size >= sizeof(BOOL)) *(BOOL*)data = TRUE;
	return S_OK;
}

// ---------------------------------------------------------------------------------------------------
// Direct3D9
Direct3D::Direct3D()
{
	mtl = MTLCreateSystemDefaultDevice();
	NSScreen *scr = NSScreen.mainScreen;
	UINT nw = (UINT)(scr.frame.size.width * scr.backingScaleFactor), nh = (UINT)(scr.frame.size.height * scr.backingScaleFactor);
	// the 2003 menus offer what the adapter reports: classic 4:3 sizes, 16:10 and 16:9 sizes, the screen in
	// points (Retina "looks like" size) and the panel's native pixel size
	static const UINT sizes[][2] = { { 640, 480 }, { 800, 600 }, { 1024, 768 }, { 1152, 864 }, { 1280, 720 }, { 1280, 800 }, { 1280, 960 }, { 1280, 1024 },
		{ 1366, 768 }, { 1440, 900 }, { 1600, 900 }, { 1600, 1000 }, { 1600, 1200 }, { 1680, 1050 }, { 1920, 1080 }, { 1920, 1200 }, { 2560, 1440 }, { 2560, 1600 }, { 2880, 1800 }, { 3840, 2160 } };
	auto add = [&](UINT w, UINT h) {
		for (auto &m : modes) if (m.Width == w && m.Height == h) return;
		D3DDISPLAYMODE m = { w, h, 60, D3DFMT_X8R8G8B8 }; modes.push_back(m);
	};
	for (auto &s : sizes) if (s[0] <= nw && s[1] <= nh) add(s[0], s[1]);
	add((UINT)scr.frame.size.width, (UINT)scr.frame.size.height);
	add(nw, nh);
	for (const S2Mode &m : S2DisplayModes()) add((UINT)m.w, (UINT)m.h);   // everything the Settings window offers
	std::sort(modes.begin(), modes.end(), [](const D3DDISPLAYMODE &a, const D3DDISPLAYMODE &b) { return a.Width != b.Width ? a.Width < b.Width : a.Height < b.Height; });
}
HRESULT Direct3D::GetAdapterIdentifier(UINT, DWORD, D3DADAPTER_IDENTIFIER9 *id)
{
	memset(id, 0, sizeof *id);
	snprintf(id->Driver, sizeof id->Driver, "Metal");
	snprintf(id->Description, sizeof id->Description, "%s (Metal)", mtl.name.UTF8String);
	id->VendorId = 0x106B; id->DeviceId = 0x0001;
	return D3D_OK;
}
UINT Direct3D::GetAdapterModeCount(UINT, D3DFORMAT f) { return (f == D3DFMT_X8R8G8B8 || f == D3DFMT_A8R8G8B8 || f == D3DFMT_R5G6B5) ? (UINT)modes.size() : 0; }
HRESULT Direct3D::EnumAdapterModes(UINT, D3DFORMAT f, UINT i, D3DDISPLAYMODE *m) { if (i >= modes.size()) return D3DERR_INVALIDCALL; *m = modes[i]; m->Format = f; return D3D_OK; }
HRESULT Direct3D::GetAdapterDisplayMode(UINT, D3DDISPLAYMODE *m)
{
	NSScreen *scr = NSScreen.mainScreen;
	m->Width = (UINT)(scr.frame.size.width * scr.backingScaleFactor); m->Height = (UINT)(scr.frame.size.height * scr.backingScaleFactor);
	m->RefreshRate = 60; m->Format = D3DFMT_X8R8G8B8;
	return D3D_OK;
}
HRESULT Direct3D::CheckDeviceFormat(UINT, D3DDEVTYPE, D3DFORMAT, DWORD usage, D3DRESOURCETYPE, D3DFORMAT f)
{
	const FormatInfo *fi = GetFormat(f);
	if (!fi) return D3DERR_NOTAVAILABLE;
	if (usage & D3DUSAGE_DEPTHSTENCIL) return fi->depth ? D3D_OK : D3DERR_NOTAVAILABLE;
	if (usage & D3DUSAGE_RENDERTARGET) return (f == D3DFMT_A8R8G8B8 || f == D3DFMT_X8R8G8B8 || f == D3DFMT_R5G6B5 || f == D3DFMT_X1R5G5B5 || f == D3DFMT_A1R5G5B5) ? D3D_OK : D3DERR_NOTAVAILABLE;
	return fi->depth ? D3DERR_NOTAVAILABLE : D3D_OK;
}
HRESULT Direct3D::CheckDeviceMultiSampleType(UINT, D3DDEVTYPE, D3DFORMAT, WINBOOL, D3DMULTISAMPLE_TYPE t, DWORD *q)
{
	if (q) *q = 1;
	return t == D3DMULTISAMPLE_NONE ? D3D_OK : D3DERR_NOTAVAILABLE;
}
HRESULT Direct3D::GetDeviceCaps(UINT, D3DDEVTYPE, D3DCAPS9 *c)
{
	memset(c, 0, sizeof *c);
	c->DeviceType = D3DDEVTYPE_HAL;
	c->Caps2 = D3DCAPS2_CANAUTOGENMIPMAP | D3DCAPS2_FULLSCREENGAMMA;
	c->PresentationIntervals = D3DPRESENT_INTERVAL_ONE | D3DPRESENT_INTERVAL_IMMEDIATE;
	c->DevCaps = D3DDEVCAPS_HWTRANSFORMANDLIGHT | D3DDEVCAPS_PUREDEVICE | D3DDEVCAPS_HWRASTERIZATION | D3DDEVCAPS_DRAWPRIMTLVERTEX;
	c->PrimitiveMiscCaps = D3DPMISCCAPS_COLORWRITEENABLE | D3DPMISCCAPS_CULLNONE | D3DPMISCCAPS_CULLCW | D3DPMISCCAPS_CULLCCW | D3DPMISCCAPS_MASKZ | D3DPMISCCAPS_BLENDOP;
	c->RasterCaps = D3DPRASTERCAPS_ANISOTROPY | D3DPRASTERCAPS_MIPMAPLODBIAS | D3DPRASTERCAPS_ZTEST | D3DPRASTERCAPS_SCISSORTEST | D3DPRASTERCAPS_DEPTHBIAS | D3DPRASTERCAPS_SLOPESCALEDEPTHBIAS;
	c->ZCmpCaps = c->AlphaCmpCaps = 0xFF;
	c->SrcBlendCaps = c->DestBlendCaps = 0x1FFF;
	c->ShadeCaps = D3DPSHADECAPS_COLORGOURAUDRGB | D3DPSHADECAPS_ALPHAGOURAUDBLEND;
	c->TextureCaps = D3DPTEXTURECAPS_ALPHA | D3DPTEXTURECAPS_MIPMAP | D3DPTEXTURECAPS_CUBEMAP | D3DPTEXTURECAPS_MIPCUBEMAP | D3DPTEXTURECAPS_PROJECTED;
	c->TextureFilterCaps = c->CubeTextureFilterCaps = D3DPTFILTERCAPS_MINFPOINT | D3DPTFILTERCAPS_MINFLINEAR | D3DPTFILTERCAPS_MINFANISOTROPIC | D3DPTFILTERCAPS_MIPFPOINT | D3DPTFILTERCAPS_MIPFLINEAR | D3DPTFILTERCAPS_MAGFPOINT | D3DPTFILTERCAPS_MAGFLINEAR;
	c->TextureAddressCaps = D3DPTADDRESSCAPS_WRAP | D3DPTADDRESSCAPS_MIRROR | D3DPTADDRESSCAPS_CLAMP | D3DPTADDRESSCAPS_BORDER;
	c->StencilCaps = 0xFF;
	c->TextureOpCaps = 0x03FFFFFF;
	c->FVFCaps = 8;
	c->MaxTextureWidth = c->MaxTextureHeight = 8192;
	c->MaxTextureRepeat = 8192; c->MaxTextureAspectRatio = 8192; c->MaxAnisotropy = 16;
	c->MaxVertexW = 1e10f; c->GuardBandLeft = -1e8f; c->GuardBandTop = -1e8f; c->GuardBandRight = 1e8f; c->GuardBandBottom = 1e8f;
	c->MaxTextureBlendStages = 8; c->MaxSimultaneousTextures = 8;
	c->VertexProcessingCaps = D3DVTXPCAPS_TEXGEN | D3DVTXPCAPS_MATERIALSOURCE7 | D3DVTXPCAPS_DIRECTIONALLIGHTS | D3DVTXPCAPS_POSITIONALLIGHTS;
	c->MaxActiveLights = 8; c->MaxUserClipPlanes = 6; c->MaxVertexBlendMatrices = 4;
	c->MaxPointSize = 256; c->MaxPrimitiveCount = 0xFFFFFF; c->MaxVertexIndex = 0xFFFFFF; c->MaxStreams = 4; c->MaxStreamStride = 255;
	c->VertexShaderVersion = D3DVS_VERSION(1, 1);
	c->MaxVertexShaderConst = 96;
	// The engine ships ps_1_1 and ps_1_4 code only; reporting 2.0 also selects its top hardware tier
	// (GetVideoConfigInfo: level 4 needs >= 2.0). S2_NO_PS=1 falls back to fixed-function texture stages.
	c->PixelShaderVersion = getenv("S2_NO_PS") ? 0 : D3DPS_VERSION(2, 0);
	c->PixelShader1xMaxValue = 8.0f;
	c->NumSimultaneousRTs = 1;
	return D3D_OK;
}
HRESULT Direct3D::CreateDevice(UINT, D3DDEVTYPE, HWND w, DWORD, D3DPRESENT_PARAMETERS *pp, IDirect3DDevice9 **out)
{
	Device *d = new Device(this, pp->hDeviceWindow ? pp->hDeviceWindow : w, *pp);
	if (!d->CreateSwapResources()) { d->Release(); return D3DERR_NOTAVAILABLE; }
	*pp = d->pp;
	*out = d;
	return D3D_OK;
}

} // namespace s2gfx

extern "C" IDirect3D9 *Direct3DCreate9(UINT) { return new s2gfx::Direct3D(); }

// ===================================================================================================
// Device
namespace s2gfx {

Device *s2currentDevice;
} // namespace s2gfx
float s2hdrHeadroom;   // EDR headroom in use (0 = SDR), for the overlay
namespace s2gfx {

Device::Device(Direct3D *d, HWND w, const D3DPRESENT_PARAMETERS &p) : d3d(d), hwnd(w), pp(p)
{
	d3d->AddRef();
	mtl = d3d->mtl;
	s2currentDevice = this;
	queue = [mtl newCommandQueue];
	layer = (__bridge CAMetalLayer*)S2GetMetalLayer(hwnd);
	layer.device = mtl;
	inflight = dispatch_semaphore_create(3);
	visibility = [mtl newBufferWithLength:8 * 4096 options:MTLResourceStorageModeShared];
	for (int i = 4095; i >= 0; --i) freeVisibilitySlots.push_back(i);
	for (int i = 0; i < 256; ++i) gamma.red[i] = gamma.green[i] = gamma.blue[i] = (WORD)(i * 257);
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:256 height:1 mipmapped:NO];
	td.storageMode = MTLStorageModeShared;
	gammaLUT = [mtl newTextureWithDescriptor:td];
	SetGammaRamp(0, 0, &gamma);
	// a white texel for stages that sample with no texture bound (D3D returns opaque white there)
	td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:1 height:1 mipmapped:NO];
	td.storageMode = MTLStorageModeShared;
	dummy2D = [mtl newTextureWithDescriptor:td];
	uint32_t white = 0xFFFFFFFF;
	[dummy2D replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&white bytesPerRow:4];
	td = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm size:1 mipmapped:NO];
	td.storageMode = MTLStorageModeShared;
	dummyCube = [mtl newTextureWithDescriptor:td];
	for (int f = 0; f < 6; ++f) [dummyCube replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 slice:f withBytes:&white bytesPerRow:4 bytesPerImage:4];
	SetDefaults();
	WarmPipelineCache();
}
Device::~Device()
{
	// the warm-up threads use this object: stop them before it goes, or quitting early aborts on a destroyed mutex
	warmCancelled = true;
	if (warmGroup) dispatch_group_wait(warmGroup, DISPATCH_TIME_FOREVER);
	if (s2currentDevice == this) s2currentDevice = nullptr;
	Submit(true);
	if (backBuffer) backBuffer->Release();
	if (autoDepth) autoDepth->Release();
	d3d->Release();
}

void Device::SetDefaults()
{
	memset(rs, 0, sizeof rs);
	rs[D3DRS_ZENABLE] = pp.EnableAutoDepthStencil ? D3DZB_TRUE : D3DZB_FALSE;
	rs[D3DRS_FILLMODE] = D3DFILL_SOLID; rs[D3DRS_SHADEMODE] = D3DSHADE_GOURAUD;
	rs[D3DRS_ZWRITEENABLE] = TRUE; rs[D3DRS_SRCBLEND] = D3DBLEND_ONE; rs[D3DRS_DESTBLEND] = D3DBLEND_ZERO;
	rs[D3DRS_CULLMODE] = D3DCULL_CCW; rs[D3DRS_ZFUNC] = D3DCMP_LESSEQUAL; rs[D3DRS_ALPHAFUNC] = D3DCMP_ALWAYS;
	rs[D3DRS_STENCILFAIL] = rs[D3DRS_STENCILZFAIL] = rs[D3DRS_STENCILPASS] = D3DSTENCILOP_KEEP; rs[D3DRS_STENCILFUNC] = D3DCMP_ALWAYS;
	rs[D3DRS_STENCILMASK] = rs[D3DRS_STENCILWRITEMASK] = 0xFFFFFFFF; rs[D3DRS_TEXTUREFACTOR] = 0xFFFFFFFF;
	rs[D3DRS_COLORWRITEENABLE] = 0xF; rs[D3DRS_BLENDOP] = D3DBLENDOP_ADD; rs[D3DRS_LIGHTING] = TRUE;
	for (int s = 0; s < 8; ++s)
	{
		memset(tss[s], 0, sizeof tss[s]);
		tss[s][D3DTSS_COLOROP] = s == 0 ? D3DTOP_MODULATE : D3DTOP_DISABLE; tss[s][D3DTSS_COLORARG1] = D3DTA_TEXTURE; tss[s][D3DTSS_COLORARG2] = D3DTA_CURRENT;
		tss[s][D3DTSS_ALPHAOP] = s == 0 ? D3DTOP_SELECTARG1 : D3DTOP_DISABLE; tss[s][D3DTSS_ALPHAARG1] = D3DTA_TEXTURE; tss[s][D3DTSS_ALPHAARG2] = D3DTA_CURRENT;
		tss[s][D3DTSS_TEXCOORDINDEX] = s;
		memset(samp[s], 0, sizeof samp[s]);
		samp[s][D3DSAMP_ADDRESSU] = samp[s][D3DSAMP_ADDRESSV] = samp[s][D3DSAMP_ADDRESSW] = D3DTADDRESS_WRAP;
		samp[s][D3DSAMP_MAGFILTER] = samp[s][D3DSAMP_MINFILTER] = D3DTEXF_POINT; samp[s][D3DSAMP_MIPFILTER] = D3DTEXF_NONE;
		samp[s][D3DSAMP_MAXANISOTROPY] = 1;
	}
	for (int i = 0; i < 512; ++i) { memset(&transforms[i], 0, sizeof(D3DMATRIX)); transforms[i]._11 = transforms[i]._22 = transforms[i]._33 = transforms[i]._44 = 1; }
}

static Surface *NewStandaloneSurface(Device *dev, UINT w, UINT h, D3DFORMAT f, DWORD usage)
{
	Surface *s = new Surface();
	s->dev = dev; s->width = w; s->height = h; s->format = f; s->usage = usage; s->pool = D3DPOOL_DEFAULT;
	const FormatInfo *fi = GetFormat(f);
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fi ? fi->metal : MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
	d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	d.storageMode = MTLStorageModePrivate;
	s->own = [dev->mtl newTextureWithDescriptor:d];
	return s;
}

bool Device::CreateSwapResources()
{
	NSScreen *scr = NSScreen.mainScreen;
	if (pp.BackBufferWidth == 0 || pp.BackBufferHeight == 0)
	{
		RECT r; GetClientRect(hwnd, &r);
		pp.BackBufferWidth = r.right ? r.right : (UINT)(scr.frame.size.width); pp.BackBufferHeight = r.bottom ? r.bottom : (UINT)(scr.frame.size.height);
	}
	if (pp.BackBufferFormat == D3DFMT_UNKNOWN) pp.BackBufferFormat = D3DFMT_X8R8G8B8;
	pp.BackBufferCount = std::max(1u, pp.BackBufferCount);
	if (backBuffer) backBuffer->Release();
	if (autoDepth) { autoDepth->Release(); autoDepth = nullptr; }
	// the back buffer is always 32-bit on the GPU; 16-bit modes are rendered in BGRA8
	backBuffer = NewStandaloneSurface(this, pp.BackBufferWidth, pp.BackBufferHeight, pp.BackBufferFormat == D3DFMT_A8R8G8B8 ? D3DFMT_A8R8G8B8 : D3DFMT_X8R8G8B8, D3DUSAGE_RENDERTARGET);
	backBuffer->format = pp.BackBufferFormat;
	if (pp.EnableAutoDepthStencil)
		autoDepth = NewStandaloneSurface(this, pp.BackBufferWidth, pp.BackBufferHeight, pp.AutoDepthStencilFormat, D3DUSAGE_DEPTHSTENCIL);
	rt = backBuffer; ds = autoDepth;
	viewport = { 0, 0, pp.BackBufferWidth, pp.BackBufferHeight, 0.0f, 1.0f };
	scissor = { 0, 0, (LONG)pp.BackBufferWidth, (LONG)pp.BackBufferHeight };
	passDirty = true;
	dispatch_async(dispatch_get_main_queue(), ^{});
	S2SetBackBufferSize(hwnd, pp.BackBufferWidth, pp.BackBufferHeight);
	{
		// gfx_fullscreen maps to macOS full screen (its own Space); windowed mode leaves it
		NSWindow *win = layer.delegate ? ((NSView*)layer.delegate).window : nil;
		bool isFull = win && (win.styleMask & NSWindowStyleMaskFullScreen);
		if (win && isFull == (bool)pp.Windowed) [win toggleFullScreen:nil];
	}
	return backBuffer && backBuffer->own;
}

void Device::BeginFrame()
{
	if (cmd) return;
	dispatch_semaphore_wait(inflight, DISPATCH_TIME_FOREVER);
	cmd = [queue commandBuffer];
	uint64_t s = serial;
	dispatch_semaphore_t sem = inflight;
	std::atomic<uint64_t> *done = &completed;
	[cmd addCompletedHandler:^(id<MTLCommandBuffer>) {
		uint64_t c = done->load();
		while (c < s && !done->compare_exchange_weak(c, s)) {}
		dispatch_semaphore_signal(sem);
	}];
}

void Device::EndPass()
{
	if (enc) { [enc endEncoding]; enc = nil; }
	passDirty = true;
}

void Device::EnsurePass()
{
	if (enc && !passDirty) return;
	EndPass();
	BeginFrame();
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = rt ? rt->Texture() : nil;
	rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	if (ds && ds->Texture())
	{
		const FormatInfo *fi = GetFormat(ds->format);
		rp.depthAttachment.texture = ds->Texture();
		rp.depthAttachment.loadAction = MTLLoadActionLoad; rp.depthAttachment.storeAction = MTLStoreActionStore;
		if (fi && fi->stencil) { rp.stencilAttachment.texture = ds->Texture(); rp.stencilAttachment.loadAction = MTLLoadActionLoad; rp.stencilAttachment.storeAction = MTLStoreActionStore; }
	}
	rp.visibilityResultBuffer = visibility;
	enc = [cmd renderCommandEncoderWithDescriptor:rp];
	passDirty = false;
	if (activeQuery && activeQuery->slot >= 0) [enc setVisibilityResultMode:MTLVisibilityResultModeCounting offset:activeQuery->slot * 8];
}

void Device::Submit(bool wait)
{
	EndPass();
	if (!cmd) { if (wait) WaitForSerial(serial - 1); return; }
	id<MTLCommandBuffer> c = cmd;
	[c commit];
	cmd = nil;
	++serial;
	if (wait) [c waitUntilCompleted];
}

void Device::WaitForSerial(uint64_t s)
{
	if (completed >= s) return;
	if (s >= serial) Submit(false);
	while (completed < s) usleep(100);
}

id<MTLTexture> Device::ReadbackTexture(id<MTLTexture> t, std::vector<BYTE> *out, size_t *pitch)
{
	size_t bpp = t.pixelFormat == MTLPixelFormatBGRA8Unorm ? 4 : 4;
	*pitch = t.width * bpp;
	id<MTLBuffer> b = [mtl newBufferWithLength:*pitch * t.height options:MTLResourceStorageModeShared];
	EndPass();
	BeginFrame();
	id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
	[blit copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(t.width, t.height, 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:*pitch destinationBytesPerImage:*pitch * t.height];
	[blit endEncoding];
	Submit(true);
	out->assign((BYTE*)b.contents, (BYTE*)b.contents + *pitch * t.height);
	return t;
}

// ---------------------------------------------------------------------------------------------------
HRESULT Device::GetDirect3D(IDirect3D9 **pp) { *pp = d3d; d3d->AddRef(); return D3D_OK; }
HRESULT Device::GetDeviceCaps(D3DCAPS9 *c) { return d3d->GetDeviceCaps(0, D3DDEVTYPE_HAL, c); }
HRESULT Device::GetDisplayMode(UINT, D3DDISPLAYMODE *m) { m->Width = pp.BackBufferWidth; m->Height = pp.BackBufferHeight; m->RefreshRate = 60; m->Format = pp.BackBufferFormat; return D3D_OK; }
HRESULT Device::GetCreationParameters(D3DDEVICE_CREATION_PARAMETERS *p) { memset(p, 0, sizeof *p); p->DeviceType = D3DDEVTYPE_HAL; p->hFocusWindow = hwnd; p->BehaviorFlags = D3DCREATE_HARDWARE_VERTEXPROCESSING; return D3D_OK; }

HRESULT Device::Reset(D3DPRESENT_PARAMETERS *p)
{
	std::lock_guard<std::recursive_mutex> l(lock);
	Submit(true);
	pp = *p;
	if (!CreateSwapResources()) return D3DERR_DEVICELOST;
	*p = pp;
	SetDefaults();
	return D3D_OK;
}

void Device::SetGammaRamp(UINT, DWORD, const D3DGAMMARAMP *r)
{
	gamma = *r;
	BYTE lut[256 * 4];
	gammaIdentity = true;
	for (int i = 0; i < 256; ++i)
	{
		lut[i * 4] = (BYTE)(r->red[i] >> 8); lut[i * 4 + 1] = (BYTE)(r->green[i] >> 8); lut[i * 4 + 2] = (BYTE)(r->blue[i] >> 8); lut[i * 4 + 3] = 255;
		if (lut[i * 4] != i || lut[i * 4 + 1] != i || lut[i * 4 + 2] != i) gammaIdentity = false;
	}
	[gammaLUT replaceRegion:MTLRegionMake2D(0, 0, 256, 1) mipmapLevel:0 withBytes:lut bytesPerRow:sizeof lut];
}

HRESULT Device::Present(const RECT *, const RECT *, HWND, const RGNDATA *)
{
	std::lock_guard<std::recursive_mutex> l(lock);
	EndPass();
	BeginFrame();
	id<MTLTexture> finalDiagnostic = nil;
	@autoreleasepool
	{
		static const bool headless = getenv("S2_HEADLESS") != nullptr;
		id<CAMetalDrawable> drawable = headless ? nil : [layer nextDrawable];
		id<MTLTexture> destination = drawable.texture;
		// Exercise the real presentation shaders without asking WindowServer for a
		// drawable. This is a developer render target, never a screen capture.
		if (headless && getenv("S2_HEADLESS_PRESENT"))
		{
			int w = backBuffer->width, h = backBuffer->height;
			if (const char *size = getenv("S2_HEADLESS_PRESENT_SIZE")) sscanf(size, "%dx%d", &w, &h);
			w = std::max(1, std::min(8192, w)); h = std::max(1, std::min(8192, h));
			if (!diagnosticPresent || diagnosticPresent.width != (NSUInteger)w || diagnosticPresent.height != (NSUInteger)h)
			{
				MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
				td.storageMode = MTLStorageModePrivate;
				td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
				diagnosticPresent = [mtl newTextureWithDescriptor:td];
			}
			destination = diagnosticPresent;
		}
		if (destination)
		{
			if (!presentPipeline)
			{
				// Present: sharpen (contrast-adaptive, after AMD FidelityFX CAS), colour grade, vignette, grain, then the
				// game's gamma ramp. FXAA (after Timothy Lottes' FXAA, PC variant) runs before upscaling.
				const char *src =
					"#include <metal_stdlib>\nusing namespace metal;\n"
					"struct V { float4 p [[position]]; float2 uv; };\n"
					"struct PP { uint useLut; float sharpen, brightness, contrast, saturation, vibrance, temperature, tint, vignette, grain, time, pad; float2 uvMax, pad2; uint hdr, worldValid; float headroom, edrStrength; float4 rect; };\n"
					"vertex V pv(uint id [[vertex_id]]) { float2 t = float2((id << 1) & 2, id & 2); V o; o.p = float4(t * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = t; return o; }\n"
					"constant float3 kLuma = float3(0.299, 0.587, 0.114);\n"
					"static float3 ToLinear(float3 c) { return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045); }\n"
					"fragment float4 pf(V in [[stage_in]], texture2d<float> bb [[texture(0)]], texture2d<float> lut [[texture(1)]], texture2d<float> world [[texture(2)]], texture2d<float> orig [[texture(3)]], sampler s [[sampler(0)]], constant PP &p [[buffer(0)]]) {\n"
					"  float2 uv = min(in.uv, p.uvMax);\n"
					"  float3 e = bb.sample(s, uv).rgb;\n"
					"  if (p.sharpen > 0) {\n"
					"    float2 px = 1.0 / float2(bb.get_width(), bb.get_height());\n"
					"    float3 b = bb.sample(s, min(uv + float2(0, -px.y), p.uvMax)).rgb, d = bb.sample(s, min(uv + float2(-px.x, 0), p.uvMax)).rgb;\n"
					"    float3 f = bb.sample(s, min(uv + float2(px.x, 0), p.uvMax)).rgb, h = bb.sample(s, min(uv + float2(0, px.y), p.uvMax)).rgb;\n"
					"    float3 mn = min(min(min(d, e), min(f, b)), h), mx = max(max(max(d, e), max(f, b)), h);\n"
					"    float3 amp = sqrt(saturate(min(mn, 2.0 - mx) / max(mx, 1e-4)));\n"
					"    float3 w = amp * (-1.0 / mix(8.0, 5.0, p.sharpen));\n"
					"    e = saturate((b * w + d * w + f * w + h * w + e) / (1.0 + 4.0 * w)); }\n"
					"  e = (e + p.brightness - 0.5) * p.contrast + 0.5;\n"
					"  float l = dot(e, kLuma);\n"
					"  e = mix(float3(l), e, p.saturation);\n"
					"  if (p.vibrance != 0) { float sat = max3(e.r, e.g, e.b) - min3(e.r, e.g, e.b); e = mix(float3(l), e, 1.0 + p.vibrance * (1.0 - saturate(sat))); }\n"
					"  e *= float3(1.0 + p.temperature * 0.08 + p.tint * 0.04, 1.0 - p.tint * 0.06, 1.0 - p.temperature * 0.08 + p.tint * 0.04);\n"
					"  if (p.vignette > 0) { float2 q = in.uv - 0.5; e *= 1.0 - p.vignette * smoothstep(0.25, 0.75, length(q * float2(1.0, 0.8)) * 1.1); }\n"
					"  if (p.grain > 0) { float n = fract(sin(dot(in.p.xy + p.time * 61.0, float2(12.9898, 78.233))) * 43758.5453); e += (n - 0.5) * p.grain * 0.08; }\n"
					"  e = saturate(e);\n"
					"  if (p.useLut != 0) { constexpr sampler ls(filter::linear, address::clamp_to_edge);\n"
					"    e = float3(lut.sample(ls, float2(e.r * 255.0 / 256.0 + 0.5 / 256.0, 0.5)).r, lut.sample(ls, float2(e.g * 255.0 / 256.0 + 0.5 / 256.0, 0.5)).g, lut.sample(ls, float2(e.b * 255.0 / 256.0 + 0.5 / 256.0, 0.5)).b); }\n"
					"  if (p.hdr != 0) {\n"
					"    // extended linear sRGB: 1.0 is SDR white; bright pixels that still match the 3D world (not the interface) go above it\n"
					"    float3 lin = ToLinear(e);\n"
					"    float2 r = (uv - p.rect.xy) / max(p.rect.zw - p.rect.xy, 1e-5);\n"
					"    if (p.worldValid != 0 && all(r >= 0) && all(r <= 1)) {\n"
					"      constexpr sampler ls(filter::linear, address::clamp_to_edge);\n"
					"      float3 w = world.sample(ls, r).rgb, b = orig.sample(ls, uv).rgb;\n"
					"      float match = 1 - smoothstep(0.04, 0.12, length(w - b));\n"
					"      float m = smoothstep(0.62, 1.0, max3(b.r, b.g, b.b)) * match;\n"
					"      lin *= 1 + m * m * (p.headroom - 1) * p.edrStrength; }\n"
					"    return float4(lin, 1); }\n"
					"  return float4(e, 1); }\n"
					"fragment float4 fxaa(V in [[stage_in]], texture2d<float> t [[texture(0)]]) {\n"
					"  constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
					"  float2 r = 1.0 / float2(t.get_width(), t.get_height()), uv = in.uv;\n"
					"  float3 nw = t.sample(s, uv + float2(-1, -1) * r).rgb, ne = t.sample(s, uv + float2(1, -1) * r).rgb;\n"
					"  float3 sw = t.sample(s, uv + float2(-1, 1) * r).rgb, se = t.sample(s, uv + float2(1, 1) * r).rgb, m = t.sample(s, uv).rgb;\n"
					"  float lNW = dot(nw, kLuma), lNE = dot(ne, kLuma), lSW = dot(sw, kLuma), lSE = dot(se, kLuma), lM = dot(m, kLuma);\n"
					"  float lMin = min(lM, min(min(lNW, lNE), min(lSW, lSE))), lMax = max(lM, max(max(lNW, lNE), max(lSW, lSE)));\n"
					"  if (lMax - lMin < max(0.0312, lMax * 0.125)) return float4(m, 1);\n"
					"  float2 dir = float2(-((lNW + lNE) - (lSW + lSE)), (lNW + lSW) - (lNE + lSE));\n"
					"  float reduce = max((lNW + lNE + lSW + lSE) * (0.25 / 8.0), 1.0 / 128.0);\n"
					"  dir = clamp(dir / (min(abs(dir.x), abs(dir.y)) + reduce), -8.0, 8.0) * r;\n"
					"  float3 a = 0.5 * (t.sample(s, uv + dir * (1.0 / 3.0 - 0.5)).rgb + t.sample(s, uv + dir * (2.0 / 3.0 - 0.5)).rgb);\n"
					"  float3 b = a * 0.5 + 0.25 * (t.sample(s, uv - dir * 0.5).rgb + t.sample(s, uv + dir * 0.5).rgb);\n"
					"  float lB = dot(b, kLuma);\n"
					"  return float4((lB < lMin || lB > lMax) ? a : b, 1); }\n";
				MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
				d.vertexFunction = Function(src, "pv"); d.fragmentFunction = Function(src, "pf");
				d.colorAttachments[0].pixelFormat = layer.pixelFormat;
				NSError *err = nil;
				d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
				presentPipeline = [mtl newRenderPipelineStateWithDescriptor:d error:&err];
				if (!presentPipeline) fprintf(stderr, "[d3d9] present pipeline: %s\n", err.localizedDescription.UTF8String);
				d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
				presentPipelineHDR = [mtl newRenderPipelineStateWithDescriptor:d error:&err];
				d.fragmentFunction = Function(src, "fxaa");
				d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
				fxaaPipeline = [mtl newRenderPipelineStateWithDescriptor:d error:&err];
				if (!fxaaPipeline) fprintf(stderr, "[d3d9] fxaa pipeline: %s\n", err.localizedDescription.UTF8String);
				MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
				sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
				sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
				presentLinear = [mtl newSamplerStateWithDescriptor:sd];
				sd.minFilter = MTLSamplerMinMagFilterLinear; sd.magFilter = MTLSamplerMinMagFilterNearest;
				presentNearest = [mtl newSamplerStateWithDescriptor:sd];
			}
			const S2Settings &cfg = g_s2;
			if (layer.displaySyncEnabled != (cfg.vsync != 0)) layer.displaySyncEnabled = cfg.vsync != 0;
			// HDR (EDR): a 16-bit float, extended linear sRGB drawable when the display can go above SDR white
			NSScreen *screen = ((NSView*)layer.delegate).window.screen ?: NSScreen.mainScreen;
			bool hdr = !headless && cfg.edr && cfg.edrStrength > 0 && screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.05 && presentPipelineHDR;
			if (!headless && hdr != (layer.pixelFormat == MTLPixelFormatRGBA16Float))
			{
				layer.wantsExtendedDynamicRangeContent = hdr;
				layer.pixelFormat = hdr ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm;
				CGColorSpaceRef cs = hdr ? CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB) : nullptr;
				layer.colorspace = cs;
				if (cs) CGColorSpaceRelease(cs);
				drawable = [layer nextDrawable];   // the one taken above has the old format
				if (!drawable) return D3D_OK;
				destination = drawable.texture;
			}
			NSUInteger drawables = cfg.tripleBuffer ? 3 : 2;
			if (layer.maximumDrawableCount != drawables) layer.maximumDrawableCount = drawables;
			id<MTLTexture> src = backBuffer->own;
			// FXAA at game resolution
			if (cfg.fxaa && fxaaPipeline)
			{
				if (!fxaaTex || fxaaTex.width != backBuffer->width || fxaaTex.height != backBuffer->height)
				{
					MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:backBuffer->width height:backBuffer->height mipmapped:NO];
					td.storageMode = MTLStorageModePrivate;
					td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
					fxaaTex = [mtl newTextureWithDescriptor:td];
				}
				MTLRenderPassDescriptor *fp = [MTLRenderPassDescriptor renderPassDescriptor];
				fp.colorAttachments[0].texture = fxaaTex;
				fp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
				fp.colorAttachments[0].storeAction = MTLStoreActionStore;
				id<MTLRenderCommandEncoder> fe = [cmd renderCommandEncoderWithDescriptor:fp];
				[fe setRenderPipelineState:fxaaPipeline];
				[fe setFragmentTexture:src atIndex:0];
				[fe drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
				[fe endEncoding];
				src = fxaaTex;
			}
			// fit the game image into the drawable, then upscale with MetalFX when the drawable is larger
			double vx, vy, vw, vh;
			S2ContentRect(destination.width, destination.height, backBuffer->width, backBuffer->height, &vx, &vy, &vw, &vh);
			NSUInteger ow = (NSUInteger)llround(vw), oh = (NSUInteger)llround(vh);
			static const bool noFX = getenv("S2_NO_METALFX") != nullptr;
			const char *how = ow == backBuffer->width && oh == backBuffer->height ? "native" : ow < backBuffer->width ? "supersampled" : cfg.upscaler == 2 ? "nearest" : "bilinear";
			bool usedFX = false;
			if (!noFX && cfg.upscaler == 0 && (ow > backBuffer->width || oh > backBuffer->height) && [MTLFXSpatialScalerDescriptor supportsDevice:mtl])
			{
				if (!scaler || scaler.outputWidth != ow || scaler.outputHeight != oh || scaler.inputWidth != backBuffer->width || scaler.inputHeight != backBuffer->height)
				{
					MTLFXSpatialScalerDescriptor *sd = [MTLFXSpatialScalerDescriptor new];
					sd.inputWidth = backBuffer->width; sd.inputHeight = backBuffer->height; sd.outputWidth = ow; sd.outputHeight = oh;
					sd.colorTextureFormat = MTLPixelFormatBGRA8Unorm; sd.outputTextureFormat = MTLPixelFormatBGRA8Unorm;
					sd.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
					scaler = [sd newSpatialScalerWithDevice:mtl];
					MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:ow height:oh mipmapped:NO];
					td.storageMode = MTLStorageModePrivate;
					td.usage = scaler.outputTextureUsage | MTLTextureUsageShaderRead;
					upscaled = [mtl newTextureWithDescriptor:td];
				}
				if (scaler && upscaled)
				{
					scaler.colorTexture = src;
					scaler.inputContentWidth = backBuffer->width; scaler.inputContentHeight = backBuffer->height;
					scaler.outputTexture = upscaled;
					[scaler encodeToCommandBuffer:cmd];
					src = upscaled;
					usedFX = true; how = "MetalFX";
				}
			}
			MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
			rp.colorAttachments[0].texture = destination;
			rp.colorAttachments[0].loadAction = MTLLoadActionClear;   // black bars around a letterboxed image
			rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
			rp.colorAttachments[0].storeAction = MTLStoreActionStore;
			id<MTLRenderCommandEncoder> e = [cmd renderCommandEncoderWithDescriptor:rp];
			[e setViewport:(MTLViewport){ vx, vy, vw, vh, 0, 1 }];
			[e setRenderPipelineState:hdr ? presentPipelineHDR : presentPipeline];
			[e setFragmentTexture:src atIndex:0];
			[e setFragmentTexture:gammaLUT atIndex:1];
			bool worldValid = hdr && wfx.world && wfx.worldPresent == presentCount;
			[e setFragmentTexture:(worldValid ? wfx.world : src) atIndex:2];
			[e setFragmentTexture:backBuffer->own atIndex:3];
			[e setFragmentSamplerState:(cfg.upscaler == 2 && !usedFX ? presentNearest : presentLinear) atIndex:0];
			// MetalFX leaves an invalid band along the right and bottom edges of its output (measured: magenta fill
			// and a blend into it, 2 columns at 1.29x and 4 at 2.94x, about scale + 1): keep reads inside it
			float uvMaxX = 1, uvMaxY = 1;
			if (usedFX)
			{
				double f = std::min((double)ow / backBuffer->width, (double)oh / backBuffer->height), margin = ceil(f) + 1.5;
				uvMaxX = (float)std::min(1.0, (floor(backBuffer->width * f) - margin) / ow);
				uvMaxY = (float)std::min(1.0, (floor(backBuffer->height * f) - margin) / oh);
			}
			// macOS changes the current headroom continuously with brightness and display conditions (NSScreen documents
			// it as dynamic). Multiplying highlights by a live reading makes them pulse, which reads as colour flicker,
			// so follow it over a couple of seconds and cap the boost.
			static float easedHeadroom = 1;
			static uint64_t headroomTime = 0;
			uint64_t headroomNow = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
			float headroomTarget = (float)std::min<CGFloat>(3.0, std::max<CGFloat>(1.0, screen.maximumExtendedDynamicRangeColorComponentValue));
			if (headroomTime) easedHeadroom += (headroomTarget - easedHeadroom) * (1.0f - expf(-(float)((headroomNow - headroomTime) / 1e9) / 2.0f));
			headroomTime = headroomNow;
			float headroom = easedHeadroom;
			float bw = (float)backBuffer->width, bh = (float)backBuffer->height;
			struct { uint32_t useLut; float sharpen, brightness, contrast, saturation, vibrance, temperature, tint, vignette, grain, time, pad; float uvMax[2], pad2[2];
				uint32_t hdr, worldValid; float headroom, edrStrength; float rect[4]; } pp = {
				gammaIdentity ? 0u : 1u, cfg.sharpen, cfg.brightness, cfg.contrast, cfg.saturation, cfg.vibrance, cfg.temperature, cfg.tint, cfg.vignette, cfg.grain,
				(float)fmod(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9, 1000.0), 0, { uvMaxX, uvMaxY }, { 0, 0 },
				hdr ? 1u : 0u, worldValid ? 1u : 0u, headroom, cfg.edrStrength, { wfx.rect[0] / bw, wfx.rect[1] / bh, wfx.rect[2] / bw, wfx.rect[3] / bh } };
			hdrHeadroom = hdr ? headroom : 0;
			[e setFragmentBytes:&pp length:sizeof pp atIndex:0];
			[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
			[e endEncoding];
			// test hook: "_shotscreen.req" reports the surface that actually goes to the display, after every stage,
			// including the HDR path. Every other capture reads an earlier image and cannot see a black screen.
			if (drawable && access("_shotscreen.req", F_OK) == 0)
			{
				unlink("_shotscreen.req");
				size_t pixel = destination.pixelFormat == MTLPixelFormatRGBA16Float ? 8 : 4, rowBytes = destination.width * pixel;
				screenProbe = [mtl newBufferWithLength:rowBytes * destination.height options:MTLResourceStorageModeShared];
				screenProbeFormat = destination.pixelFormat; screenProbeWidth = destination.width; screenProbeHeight = destination.height;
				id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
				[blit copyFromTexture:destination sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(destination.width, destination.height, 1)
					toBuffer:screenProbe destinationOffset:0 destinationBytesPerRow:rowBytes destinationBytesPerImage:rowBytes * destination.height];
				[blit endEncoding];
				screenProbeCommand = cmd;
			}
			if (drawable) [cmd presentDrawable:drawable];
			if (headless) finalDiagnostic = destination;
			if (!usedFX) { scaler = nil; upscaled = nil; }
			frameInfo = { (int)backBuffer->width, (int)backBuffer->height, (int)ow, (int)oh, how };
			s2hdrHeadroom = hdrHeadroom;
			if (getenv("S2_RENDER_AUDIT") && presentCount % 120 == 0)
				fprintf(stderr, "[present-audit] source=%ux%u output=%lux%lu path=%s sharpen=%g fxaa=%d hdr=%d headroom=%g device=%s\n", backBuffer->width, backBuffer->height, (unsigned long)ow, (unsigned long)oh, how, cfg.sharpen, cfg.fxaa, hdr, headroom, mtl.name.UTF8String);
		}
	}
	++presentCount;
	lastFrame = backBuffer->own;
	id<MTLCommandBuffer> screenWait = screenProbeCommand;
	id<MTLTexture> shown = upscaled && scaler ? upscaled : backBuffer->own;
	Submit(false);
	if (screenWait)
	{
		[screenWait waitUntilCompleted];
		screenProbeCommand = nil;
		bool wide = screenProbeFormat == MTLPixelFormatRGBA16Float;
		double sum[3] = {}, peak = 0, n = 0;
		const char *base = (const char *)screenProbe.contents;
		size_t rowBytes = screenProbeWidth * (wide ? 8 : 4);
		for (NSUInteger y = 0; y < screenProbeHeight; y += 4)
			for (NSUInteger x = 0; x < screenProbeWidth; x += 4)
			{
				double c[3];
				if (wide) { const __fp16 *p = (const __fp16 *)(base + y * rowBytes + x * 8); for (int i = 0; i < 3; ++i) c[i] = p[i]; }
				else { const unsigned char *p = (const unsigned char *)(base + y * rowBytes + x * 4); c[0] = p[2] / 255.0; c[1] = p[1] / 255.0; c[2] = p[0] / 255.0; }
				for (int i = 0; i < 3; ++i) { if (std::isfinite(c[i])) { sum[i] += c[i]; peak = std::max(peak, c[i]); } }
				n += 1;
			}
		if (FILE *f = ::fopen("_screen.txt", "ab"))
		{
			fprintf(f, "screen format=%lu size=%lux%lu mean=%.5f,%.5f,%.5f peak=%.4f hdrHeadroom=%.3f layerFormat=%lu\n", (unsigned long)screenProbeFormat, (unsigned long)screenProbeWidth, (unsigned long)screenProbeHeight, sum[0] / n, sum[1] / n, sum[2] / n, peak, hdrHeadroom, (unsigned long)layer.pixelFormat);
			fclose(f);
		}
		screenProbe = nil;
	}
	if (access("_shotfinal.req", F_OK) == 0 && finalDiagnostic)
	{
		unlink("_shotfinal.req");
		std::vector<BYTE> img; size_t pitch;
		ReadbackTexture(finalDiagnostic, &img, &pitch);
		for (size_t i = 0; i < img.size(); i += 4) img[i + 3] = 255;
		CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
		CGContextRef ctx = CGBitmapContextCreate(img.data(), finalDiagnostic.width, finalDiagnostic.height, 8, pitch, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
		CGImageRef im = CGBitmapContextCreateImage(ctx);
		CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@"_shotfinal.tmp.png"], (__bridge CFStringRef)UTTypePNG.identifier, 1, nullptr);
		if (dst) { CGImageDestinationAddImage(dst, im, nullptr); CGImageDestinationFinalize(dst); CFRelease(dst); rename("_shotfinal.tmp.png", "_shotfinal.png"); }
		CGImageRelease(im); CGContextRelease(ctx); CGColorSpaceRelease(cs);
		bool worldActive = wfx.worldPresent + 1 == presentCount;
		if (FILE *audit = ::fopen("_renderaudit.json", "wb"))
		{
			fprintf(audit, "{\"headless\":true,\"hdr_output\":false,\"frame\":%llu,\"source\":[%u,%u],\"output\":[%lu,%lu],\"scaling_path\":\"%s\",\"world_effects_current_frame\":%s,\"world_target\":[%lu,%lu],\"ao_target\":[%lu,%lu],\"ao_samples\":16,\"bloom_levels\":[", (unsigned long long)presentCount, backBuffer->width, backBuffer->height, (unsigned long)finalDiagnostic.width, (unsigned long)finalDiagnostic.height, frameInfo.how, worldActive ? "true" : "false", (unsigned long)(wfx.scenePresent + 1 == presentCount ? wfx.sceneWidth : 0), (unsigned long)(wfx.scenePresent + 1 == presentCount ? wfx.sceneHeight : 0), (unsigned long)(worldActive && g_s2.ao ? wfx.ao.width : 0), (unsigned long)(worldActive && g_s2.ao ? wfx.ao.height : 0));
			for (int i = 0; i < 6; ++i) fprintf(audit, "%s[%lu,%lu]", i ? "," : "", (unsigned long)(worldActive && g_s2.bloom ? wfx.bloom[i].width : 0), (unsigned long)(worldActive && g_s2.bloom ? wfx.bloom[i].height : 0));
			fprintf(audit, "],\"sharpen\":%g,\"fxaa\":%d,\"anisotropic_override\":%d,\"lod_bias\":%g,\"edr_requested\":%d}\n", g_s2.sharpen, g_s2.fxaa, g_s2.anisoOverride, g_s2.lodBias, g_s2.edr);
			fclose(audit);
		}
	}
	{
		// frame-rate cap: wait out the rest of the frame after submitting, before the engine starts the next one
		uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
		if (g_s2.frameCap > 0 && lastPresentNs)
		{
			uint64_t target = lastPresentNs + 1000000000ull / (uint64_t)g_s2.frameCap;
			if (target > now && target - now < 200000000ull) { struct timespec ts = { 0, (long)(target - now) }; nanosleep(&ts, nullptr); now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
		}
		S2SettingsFrame(lastPresentNs ? (now - lastPresentNs) / 1e6 : 0, frameInfo.srcW, frameInfo.srcH, frameInfo.outW, frameInfo.outH, frameInfo.how);
		lastPresentNs = now;
	}
	if (access("_shotfx.req", F_OK) == 0)
	{
		// the image as displayed (after MetalFX), before gamma
		unlink("_shotfx.req");
		std::vector<BYTE> img; size_t pitch;
		ReadbackTexture(shown, &img, &pitch);
		for (size_t i = 0; i < img.size(); i += 4) img[i + 3] = 255;
		CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
		CGContextRef ctx = CGBitmapContextCreate(img.data(), shown.width, shown.height, 8, pitch, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
		CGImageRef im = CGBitmapContextCreateImage(ctx);
		CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@"_shotfx.png"], (__bridge CFStringRef)UTTypePNG.identifier, 1, nullptr);
		if (dst) { CGImageDestinationAddImage(dst, im, nullptr); CGImageDestinationFinalize(dst); CFRelease(dst); }
		CGImageRelease(im); CGContextRelease(ctx); CGColorSpaceRelease(cs);
	}
	static const bool perf = getenv("S2_PERF") != nullptr;
	if (perf)
	{
		uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
		if (perfLast)
		{
			double ms = (now - perfLast) / 1e6;
			perfSum += ms; ++perfFrames; perfMax = std::max(perfMax, ms); if (ms > 33.4) ++perfSlow;
		}
		else perfStart = now;
		perfLast = now;
		if (now - perfStart >= 2000000000ull && perfFrames)
		{
			if (FILE *f = ::fopen("_perf.txt", "a"))
			{
				fprintf(f, "frames=%d fps=%.1f mean_ms=%.2f max_ms=%.1f over33ms=%d new_pipelines=%d total_pipelines=%zu\n", perfFrames, perfFrames * 1000.0 / perfSum, perfSum / perfFrames, perfMax, perfSlow, perfNewPipelines, pipelines.size());
				fclose(f);
			}
			perfStart = now; perfFrames = perfSlow = perfNewPipelines = 0; perfMax = perfSum = 0;
		}
	}
	if (dumpFile) { fclose(dumpFile); dumpFile = nullptr; rename("_draws.tmp", "_draws.txt"); }
	if (access("_dump.req", F_OK) == 0) { unlink("_dump.req"); dumpFile = ::fopen("_draws.tmp", "w"); dumpDraws = 0; }
	// test hook: "_shot.req" in the game folder saves this frame as "_shot.png" (the exact back buffer)
	if (access("_shot.req", F_OK) == 0)
	{
		unlink("_shot.req");
		std::vector<BYTE> img; size_t pitch;
		ReadbackTexture(backBuffer->own, &img, &pitch);
		for (size_t i = 0; i < img.size(); i += 4) img[i + 3] = 255;
		CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
		CGContextRef ctx = CGBitmapContextCreate(img.data(), backBuffer->width, backBuffer->height, 8, pitch, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
		CGImageRef im = CGBitmapContextCreateImage(ctx);
		CFURLRef url = (__bridge CFURLRef)[NSURL fileURLWithPath:@"_shot.tmp.png"];
		CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, (__bridge CFStringRef)UTTypePNG.identifier, 1, nullptr);
		if (dst) { CGImageDestinationAddImage(dst, im, nullptr); CGImageDestinationFinalize(dst); CFRelease(dst); rename("_shot.tmp.png", "_shot.png"); }
		CGImageRelease(im); CGContextRelease(ctx); CGColorSpaceRelease(cs);
	}
	// test hook: S2_FRAME_PROBE=<file> logs each frame's mean colour and the largest change in a 16x16 grid, so flicker
	// is a number rather than an impression. It reads the whole back buffer every frame: never for timing runs.
	static const char *frameProbe = getenv("S2_FRAME_PROBE");
	if (frameProbe)
	{
		static double previous[16][16];
		static bool havePrevious = false;
		static FILE *out = ::fopen(frameProbe, "wb");
		std::vector<BYTE> img; size_t pitch;
		ReadbackTexture(backBuffer->own, &img, &pitch);
		double cells[16][16] = {}, counts[16][16] = {}, total[3] = {};
		for (UINT y = 0; y < backBuffer->height; y += 3)
			for (UINT x = 0; x < backBuffer->width; x += 3)
			{
				const BYTE *p = &img[y * pitch + x * 4];
				int cx = x * 16 / backBuffer->width, cy = y * 16 / backBuffer->height;
				cells[cy][cx] += (p[0] + p[1] + p[2]) / 3.0; counts[cy][cx] += 1;
				total[0] += p[2]; total[1] += p[1]; total[2] += p[0];
			}
		double n = 0;
		std::vector<double> changes;
		for (int i = 0; i < 16; ++i)
			for (int j = 0; j < 16; ++j)
			{
				n += counts[i][j];
				double mean = counts[i][j] ? cells[i][j] / counts[i][j] : 0;
				if (havePrevious) changes.push_back(fabs(mean - previous[i][j]));
				previous[i][j] = mean;
			}
		havePrevious = true;
		if (out && n > 0 && !changes.empty())
		{
			std::sort(changes.begin(), changes.end());
			fprintf(out, "%llu %.3f %.2f %.2f %.2f %.4f %.4f %.4f %d %d %.3f\n", (unsigned long long)presentCount, clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6, total[0] / n, total[1] / n, total[2] / n, changes[changes.size() / 2], changes[changes.size() * 9 / 10], changes.back(), wfx.worldPresent + 1 == presentCount ? 1 : 0, hdrHeadroom > 0 ? 1 : 0, hdrHeadroom);
			fflush(out);
		}
	}
	return D3D_OK;
}

HRESULT Device::GetBackBuffer(UINT, UINT, D3DBACKBUFFER_TYPE, IDirect3DSurface9 **pp) { *pp = backBuffer; backBuffer->AddRef(); return D3D_OK; }

HRESULT Device::CreateTexture(UINT w, UINT h, UINT levels, DWORD usage, D3DFORMAT f, D3DPOOL pool, IDirect3DTexture9 **out, HANDLE *)
{
	std::lock_guard<std::recursive_mutex> l(lock);
	if (!GetFormat(f) || w == 0 || h == 0) return D3DERR_INVALIDCALL;
	Texture *t = new Texture();
	t->dev = this; t->width = w; t->height = h; t->format = f; t->usage = usage; t->pool = pool;
	t->levels = levels ? std::min(levels, FullChain(w, h)) : FullChain(w, h);
	if (usage & D3DUSAGE_AUTOGENMIPMAP) t->levels = 1;
	t->CreateTexture();
	if (!t->tex) { delete t; return D3DERR_OUTOFVIDEOMEMORY; }
	if (getenv("S2_RENDER_AUDIT") && (usage & (D3DUSAGE_RENDERTARGET | D3DUSAGE_DEPTHSTENCIL))) fprintf(stderr, "[texture-allocation] 2d=%ux%u usage=%u format=%u\n", w, h, (unsigned)usage, (unsigned)f);
	*out = t;
	return D3D_OK;
}
HRESULT Device::CreateCubeTexture(UINT edge, UINT levels, DWORD usage, D3DFORMAT f, D3DPOOL pool, IDirect3DCubeTexture9 **out, HANDLE *)
{
	std::lock_guard<std::recursive_mutex> l(lock);
	if (!GetFormat(f) || edge == 0) return D3DERR_INVALIDCALL;
	CubeTexture *t = new CubeTexture();
	t->dev = this; t->width = t->height = edge; t->format = f; t->usage = usage; t->pool = pool; t->cube = true;
	t->levels = levels ? std::min(levels, FullChain(edge, edge)) : FullChain(edge, edge);
	t->CreateTexture();
	if (!t->tex) { delete t; return D3DERR_OUTOFVIDEOMEMORY; }
	if (getenv("S2_RENDER_AUDIT") && (usage & (D3DUSAGE_RENDERTARGET | D3DUSAGE_DEPTHSTENCIL))) fprintf(stderr, "[texture-allocation] cube=%u faces=6 usage=%u format=%u\n", edge, (unsigned)usage, (unsigned)f);
	*out = t;
	return D3D_OK;
}
HRESULT Device::CreateVertexBuffer(UINT len, DWORD usage, DWORD f, D3DPOOL pool, IDirect3DVertexBuffer9 **out, HANDLE *)
{
	std::lock_guard<std::recursive_mutex> l(lock);
	VertexBuffer *b = new VertexBuffer(); b->dev = this; b->length = len; b->usage = usage; b->pool = pool; b->fvf = f; b->Create();
	*out = b; return D3D_OK;
}
HRESULT Device::CreateIndexBuffer(UINT len, DWORD usage, D3DFORMAT f, D3DPOOL pool, IDirect3DIndexBuffer9 **out, HANDLE *)
{
	std::lock_guard<std::recursive_mutex> l(lock);
	IndexBuffer *b = new IndexBuffer(); b->dev = this; b->length = len; b->usage = usage; b->pool = pool; b->format = f; b->Create();
	*out = b; return D3D_OK;
}
HRESULT Device::CreateRenderTarget(UINT w, UINT h, D3DFORMAT f, D3DMULTISAMPLE_TYPE, DWORD, WINBOOL, IDirect3DSurface9 **out, HANDLE *)
{
	std::lock_guard<std::recursive_mutex> l(lock);
	*out = NewStandaloneSurface(this, w, h, f, D3DUSAGE_RENDERTARGET); return D3D_OK;
}
HRESULT Device::CreateDepthStencilSurface(UINT w, UINT h, D3DFORMAT f, D3DMULTISAMPLE_TYPE, DWORD, WINBOOL, IDirect3DSurface9 **out, HANDLE *)
{
	std::lock_guard<std::recursive_mutex> l(lock);
	if (!GetFormat(f) || !GetFormat(f)->depth) return D3DERR_INVALIDCALL;
	*out = NewStandaloneSurface(this, w, h, f, D3DUSAGE_DEPTHSTENCIL); return D3D_OK;
}
HRESULT Device::CreateOffscreenPlainSurface(UINT w, UINT h, D3DFORMAT f, D3DPOOL pool, IDirect3DSurface9 **out, HANDLE *)
{
	Surface *s = new Surface(); s->dev = this; s->width = w; s->height = h; s->format = f; s->pool = pool;
	s->sysmem.assign(LevelPitch(f, w) * LevelRows(f, h), 0);
	*out = s; return D3D_OK;
}

static void CopyRect(Surface *src, const RECT &sr, Surface *dst, POINT dp)
{
	D3DLOCKED_RECT a, b;
	RECT dr = { dp.x, dp.y, dp.x + (sr.right - sr.left), dp.y + (sr.bottom - sr.top) };
	if (FAILED(src->LockRect(&a, &sr, D3DLOCK_READONLY))) return;
	if (FAILED(dst->LockRect(&b, &dr, 0))) { src->UnlockRect(); return; }
	UINT rows = LevelRows(src->format, sr.bottom - sr.top);
	size_t bytes = std::min(LevelPitch(src->format, sr.right - sr.left), LevelPitch(dst->format, dr.right - dr.left));
	for (UINT y = 0; y < rows; ++y) memcpy((BYTE*)b.pBits + y * b.Pitch, (BYTE*)a.pBits + y * a.Pitch, bytes);
	dst->UnlockRect(); src->UnlockRect();
}
HRESULT Device::UpdateSurface(IDirect3DSurface9 *s, const RECT *sr, IDirect3DSurface9 *d, const POINT *dp)
{
	std::lock_guard<std::recursive_mutex> l(lock);
	Surface *src = (Surface*)s, *dst = (Surface*)d;
	RECT r = sr ? *sr : RECT { 0, 0, (LONG)src->width, (LONG)src->height };
	POINT p = dp ? *dp : POINT { 0, 0 };
	CopyRect(src, r, dst, p);
	return D3D_OK;
}
HRESULT Device::UpdateTexture(IDirect3DBaseTexture9 *s, IDirect3DBaseTexture9 *d)
{
	std::lock_guard<std::recursive_mutex> l(lock);
	Texture *src = dynamic_cast<Texture*>(s), *dst = dynamic_cast<Texture*>(d);
	if (!src || !dst) return D3DERR_INVALIDCALL;
	for (UINT i = 0; i < std::min(src->levels, dst->levels); ++i)
	{
		Surface *a = LevelSurface(src, 0, i), *b = LevelSurface(dst, 0, i);
		CopyRect(a, RECT { 0, 0, (LONG)a->width, (LONG)a->height }, b, POINT { 0, 0 });
	}
	return D3D_OK;
}
HRESULT Device::GetRenderTargetData(IDirect3DSurface9 *r, IDirect3DSurface9 *d)
{
	std::lock_guard<std::recursive_mutex> l(lock);
	Surface *src = (Surface*)r, *dst = (Surface*)d;
	id<MTLTexture> t = src->Texture(); if (!t) return D3DERR_INVALIDCALL;
	std::vector<BYTE> img; size_t pitch;
	ReadbackTexture(t, &img, &pitch);
	D3DLOCKED_RECT lr; if (FAILED(dst->LockRect(&lr, nullptr, 0))) return D3DERR_INVALIDCALL;
	UINT h = std::min(dst->height, (UINT)t.height), w = std::min(dst->width, (UINT)t.width);
	for (UINT y = 0; y < h; ++y) memcpy((BYTE*)lr.pBits + y * lr.Pitch, &img[y * pitch], (size_t)w * 4);
	dst->UnlockRect();
	return D3D_OK;
}
HRESULT Device::GetFrontBufferData(UINT, IDirect3DSurface9 *d)
{
	// Direct3D returns the desktop-sized screen; the game window's last image is placed at the origin
	std::lock_guard<std::recursive_mutex> l(lock);
	if (!lastFrame) return D3DERR_INVALIDCALL;
	std::vector<BYTE> img; size_t pitch;
	ReadbackTexture(lastFrame, &img, &pitch);
	Surface *dst = (Surface*)d;
	D3DLOCKED_RECT lr; if (FAILED(dst->LockRect(&lr, nullptr, 0))) return D3DERR_INVALIDCALL;
	UINT h = std::min(dst->height, (UINT)lastFrame.height), w = std::min(dst->width, (UINT)lastFrame.width);
	for (UINT y = 0; y < h; ++y) { BYTE *row = (BYTE*)lr.pBits + y * lr.Pitch; memcpy(row, &img[y * pitch], (size_t)w * 4); for (UINT x = 0; x < w; ++x) row[x * 4 + 3] = 255; }
	dst->UnlockRect();
	return D3D_OK;
}
HRESULT Device::StretchRect(IDirect3DSurface9 *s, const RECT *, IDirect3DSurface9 *d, const RECT *, D3DTEXTUREFILTERTYPE)
{
	std::lock_guard<std::recursive_mutex> l(lock);
	Surface *src = (Surface*)s, *dst = (Surface*)d;
	id<MTLTexture> a = src->Texture(), b = dst->Texture();
	if (!a || !b || a.width != b.width || a.height != b.height || a.pixelFormat != b.pixelFormat) { S2Unimplemented("StretchRect (scaled)"); return D3D_OK; }
	EndPass(); BeginFrame();
	id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
	[blit copyFromTexture:a sourceSlice:src->face sourceLevel:src->level toTexture:b destinationSlice:dst->face destinationLevel:dst->level sliceCount:1 levelCount:1];
	[blit endEncoding];
	return D3D_OK;
}
HRESULT Device::ColorFill(IDirect3DSurface9 *s, const RECT *, D3DCOLOR c)
{
	IDirect3DSurface9 *oldRT = rt, *oldDS = ds;
	rt = (Surface*)s; ds = nullptr; passDirty = true;
	Clear(0, nullptr, D3DCLEAR_TARGET, c, 1, 0);
	rt = (Surface*)oldRT; ds = (Surface*)oldDS; passDirty = true;
	return D3D_OK;
}

HRESULT Device::SetRenderTarget(DWORD i, IDirect3DSurface9 *s)
{
	std::lock_guard<std::recursive_mutex> l(lock);
	if (i != 0) return s ? D3DERR_INVALIDCALL : D3D_OK;
	if (!s) return D3DERR_INVALIDCALL;
	if ((Surface*)s != rt) { rt = (Surface*)s; passDirty = true; }
	viewport = { 0, 0, rt->width, rt->height, 0.0f, 1.0f };
	scissor = { 0, 0, (LONG)rt->width, (LONG)rt->height };
	return D3D_OK;
}
HRESULT Device::GetRenderTarget(DWORD i, IDirect3DSurface9 **pp) { if (i != 0 || !rt) return D3DERR_NOTFOUND; *pp = rt; rt->AddRef(); return D3D_OK; }
HRESULT Device::SetDepthStencilSurface(IDirect3DSurface9 *s) { std::lock_guard<std::recursive_mutex> l(lock); if ((Surface*)s != ds) { ds = (Surface*)s; passDirty = true; } return D3D_OK; }
HRESULT Device::GetDepthStencilSurface(IDirect3DSurface9 **pp) { if (!ds) return D3DERR_NOTFOUND; *pp = ds; ds->AddRef(); return D3D_OK; }

HRESULT Device::SetViewport(const D3DVIEWPORT9 *v) { viewport = *v; return D3D_OK; }
HRESULT Device::SetTransform(D3DTRANSFORMSTATETYPE s, const D3DMATRIX *m) { if ((UINT)s < 512) transforms[s] = *m; return D3D_OK; }
HRESULT Device::GetTransform(D3DTRANSFORMSTATETYPE s, D3DMATRIX *m) { if ((UINT)s < 512) *m = transforms[s]; return D3D_OK; }
HRESULT Device::MultiplyTransform(D3DTRANSFORMSTATETYPE s, const D3DMATRIX *m)
{
	if ((UINT)s >= 512) return D3D_OK;
	D3DMATRIX r = {}; const D3DMATRIX &a = transforms[s];
	for (int i = 0; i < 4; ++i) for (int j = 0; j < 4; ++j) for (int k = 0; k < 4; ++k) r.m[i][j] += a.m[i][k] * m->m[k][j];
	transforms[s] = r; return D3D_OK;
}
HRESULT Device::SetRenderState(D3DRENDERSTATETYPE s, DWORD v) { if ((UINT)s < 256) rs[s] = v; return D3D_OK; }
HRESULT Device::GetTexture(DWORD stage, IDirect3DBaseTexture9 **pp) { *pp = stage < 8 ? textures[stage] : nullptr; if (*pp) (*pp)->AddRef(); return D3D_OK; }
HRESULT Device::SetTexture(DWORD stage, IDirect3DBaseTexture9 *t)
{
	if (stage >= 8) return D3D_OK;
	if (t) t->AddRef();
	if (textures[stage]) textures[stage]->Release();
	textures[stage] = t;
	return D3D_OK;
}
template<class T> static void Rebind(T *&slot, T *v) { if (v) v->AddRef(); if (slot) slot->Release(); slot = v; }
HRESULT Device::CreateVertexDeclaration(const D3DVERTEXELEMENT9 *e, IDirect3DVertexDeclaration9 **out)
{
	VertexDecl *d = new VertexDecl(); d->dev = this;
	for (; e->Stream != 0xFF; ++e) d->elements.push_back(*e);
	d->hash = Hash64(d->elements.data(), d->elements.size() * sizeof(D3DVERTEXELEMENT9));
	*out = d; return D3D_OK;
}
HRESULT Device::SetVertexDeclaration(IDirect3DVertexDeclaration9 *d) { Rebind(decl, (VertexDecl*)d); fvf = 0; return D3D_OK; }
HRESULT Device::GetVertexDeclaration(IDirect3DVertexDeclaration9 **pp) { *pp = decl; if (decl) decl->AddRef(); return D3D_OK; }
VertexDecl *Device::DeclForFVF(DWORD f)
{
	auto it = fvfDecls.find(f);
	if (it != fvfDecls.end()) return it->second;
	std::vector<D3DVERTEXELEMENT9> e; WORD off = 0;
	auto add = [&](BYTE type, BYTE usage, BYTE idx, WORD size) { e.push_back({ 0, off, type, D3DDECLMETHOD_DEFAULT, usage, idx }); off += size; };
	switch (f & D3DFVF_POSITION_MASK)
	{
	case D3DFVF_XYZ: add(D3DDECLTYPE_FLOAT3, D3DDECLUSAGE_POSITION, 0, 12); break;
	case D3DFVF_XYZRHW: add(D3DDECLTYPE_FLOAT4, D3DDECLUSAGE_POSITIONT, 0, 16); break;
	default: break;
	}
	if (f & D3DFVF_NORMAL) add(D3DDECLTYPE_FLOAT3, D3DDECLUSAGE_NORMAL, 0, 12);
	if (f & D3DFVF_DIFFUSE) add(D3DDECLTYPE_D3DCOLOR, D3DDECLUSAGE_COLOR, 0, 4);
	if (f & D3DFVF_SPECULAR) add(D3DDECLTYPE_D3DCOLOR, D3DDECLUSAGE_COLOR, 1, 4);
	int ntex = (f & D3DFVF_TEXCOUNT_MASK) >> D3DFVF_TEXCOUNT_SHIFT;
	for (int i = 0; i < ntex; ++i) add(D3DDECLTYPE_FLOAT2, D3DDECLUSAGE_TEXCOORD, (BYTE)i, 8);
	VertexDecl *d = new VertexDecl(); d->dev = this; d->elements = e;
	d->hash = Hash64(e.data(), e.size() * sizeof(D3DVERTEXELEMENT9), 77);
	fvfDecls[f] = d;
	return d;
}
HRESULT Device::SetFVF(DWORD f) { fvf = f; if (f) Rebind(decl, DeclForFVF(f)); return D3D_OK; }
HRESULT Device::CreateVertexShader(const DWORD *code, IDirect3DVertexShader9 **out)
{
	VertexShader *s = new VertexShader(); s->dev = this; s->version = code[0];
	const DWORD *p = code; while (*p != 0x0000FFFF) ++p;
	s->code.assign(code, p + 1);
	s->hash = Hash64(s->code.data(), s->code.size() * 4);
	*out = s; return D3D_OK;
}
HRESULT Device::SetVertexShader(IDirect3DVertexShader9 *s) { Rebind(vs, (VertexShader*)s); return D3D_OK; }
HRESULT Device::GetVertexShader(IDirect3DVertexShader9 **pp) { *pp = vs; if (vs) vs->AddRef(); return D3D_OK; }
HRESULT Device::SetVertexShaderConstantF(UINT r, const float *d, UINT n) { if (r + n <= 256) memcpy(vsConst[r], d, n * 16); return D3D_OK; }
HRESULT Device::GetVertexShaderConstantF(UINT r, float *d, UINT n) { if (r + n <= 256) memcpy(d, vsConst[r], n * 16); return D3D_OK; }
HRESULT Device::CreatePixelShader(const DWORD *code, IDirect3DPixelShader9 **out)
{
	PixelShader *s = new PixelShader(); s->dev = this; s->version = code[0];
	const DWORD *p = code; while (*p != 0x0000FFFF) ++p;
	s->code.assign(code, p + 1);
	s->hash = Hash64(s->code.data(), s->code.size() * 4) | 1;
	*out = s; return D3D_OK;
}
HRESULT Device::SetPixelShader(IDirect3DPixelShader9 *s) { Rebind(ps, (PixelShader*)s); return D3D_OK; }
HRESULT Device::GetPixelShader(IDirect3DPixelShader9 **pp) { *pp = ps; if (ps) ps->AddRef(); return D3D_OK; }
HRESULT Device::SetPixelShaderConstantF(UINT r, const float *d, UINT n) { if (r + n <= 8) memcpy(psConst[r], d, n * 16); return D3D_OK; }
HRESULT Device::GetPixelShaderConstantF(UINT r, float *d, UINT n) { if (r + n <= 8) memcpy(d, psConst[r], n * 16); return D3D_OK; }
HRESULT Device::SetStreamSource(UINT i, IDirect3DVertexBuffer9 *b, UINT off, UINT stride)
{
	if (i >= 4) return D3DERR_INVALIDCALL;
	Rebind(streams[i].vb, (VertexBuffer*)b); streams[i].offset = off; streams[i].stride = stride;
	return D3D_OK;
}
HRESULT Device::GetStreamSource(UINT i, IDirect3DVertexBuffer9 **pp, UINT *off, UINT *stride)
{
	if (i >= 4) return D3DERR_INVALIDCALL;
	*pp = streams[i].vb; if (*pp) (*pp)->AddRef(); *off = streams[i].offset; *stride = streams[i].stride; return D3D_OK;
}
HRESULT Device::SetIndices(IDirect3DIndexBuffer9 *b) { Rebind(ib, (IndexBuffer*)b); return D3D_OK; }
HRESULT Device::GetIndices(IDirect3DIndexBuffer9 **pp) { *pp = ib; if (ib) ib->AddRef(); return D3D_OK; }
HRESULT Device::CreateQuery(D3DQUERYTYPE t, IDirect3DQuery9 **out)
{
	if (t != D3DQUERYTYPE_OCCLUSION && t != D3DQUERYTYPE_EVENT) return D3DERR_NOTAVAILABLE;
	if (!out) return D3D_OK;   // capability probe
	Query *q = new Query(); q->dev = this; q->type = t; *out = q; return D3D_OK;
}

// ---------------------------------------------------------------------------------------------------
// pipeline state
static MTLBlendFactor BlendFactor(DWORD b)
{
	switch (b)
	{
	case D3DBLEND_ZERO: return MTLBlendFactorZero;
	case D3DBLEND_ONE: return MTLBlendFactorOne;
	case D3DBLEND_SRCCOLOR: return MTLBlendFactorSourceColor;
	case D3DBLEND_INVSRCCOLOR: return MTLBlendFactorOneMinusSourceColor;
	case D3DBLEND_SRCALPHA: return MTLBlendFactorSourceAlpha;
	case D3DBLEND_INVSRCALPHA: return MTLBlendFactorOneMinusSourceAlpha;
	case D3DBLEND_DESTALPHA: return MTLBlendFactorDestinationAlpha;
	case D3DBLEND_INVDESTALPHA: return MTLBlendFactorOneMinusDestinationAlpha;
	case D3DBLEND_DESTCOLOR: return MTLBlendFactorDestinationColor;
	case D3DBLEND_INVDESTCOLOR: return MTLBlendFactorOneMinusDestinationColor;
	case D3DBLEND_SRCALPHASAT: return MTLBlendFactorSourceAlphaSaturated;
	case D3DBLEND_BLENDFACTOR: return MTLBlendFactorBlendColor;
	case D3DBLEND_INVBLENDFACTOR: return MTLBlendFactorOneMinusBlendColor;
	default: return MTLBlendFactorOne;
	}
}
static MTLBlendOperation BlendOp(DWORD o)
{
	switch (o) { case D3DBLENDOP_SUBTRACT: return MTLBlendOperationSubtract; case D3DBLENDOP_REVSUBTRACT: return MTLBlendOperationReverseSubtract; case D3DBLENDOP_MIN: return MTLBlendOperationMin; case D3DBLENDOP_MAX: return MTLBlendOperationMax; default: return MTLBlendOperationAdd; }
}
static MTLCompareFunction CompareFunc(DWORD c)
{
	switch (c)
	{
	case D3DCMP_NEVER: return MTLCompareFunctionNever; case D3DCMP_LESS: return MTLCompareFunctionLess; case D3DCMP_EQUAL: return MTLCompareFunctionEqual;
	case D3DCMP_LESSEQUAL: return MTLCompareFunctionLessEqual; case D3DCMP_GREATER: return MTLCompareFunctionGreater; case D3DCMP_NOTEQUAL: return MTLCompareFunctionNotEqual;
	case D3DCMP_GREATEREQUAL: return MTLCompareFunctionGreaterEqual; default: return MTLCompareFunctionAlways;
	}
}
static MTLStencilOperation StencilOp(DWORD o)
{
	switch (o)
	{
	case D3DSTENCILOP_ZERO: return MTLStencilOperationZero; case D3DSTENCILOP_REPLACE: return MTLStencilOperationReplace; case D3DSTENCILOP_INCRSAT: return MTLStencilOperationIncrementClamp;
	case D3DSTENCILOP_DECRSAT: return MTLStencilOperationDecrementClamp; case D3DSTENCILOP_INVERT: return MTLStencilOperationInvert; case D3DSTENCILOP_INCR: return MTLStencilOperationIncrementWrap;
	case D3DSTENCILOP_DECR: return MTLStencilOperationDecrementWrap; default: return MTLStencilOperationKeep;
	}
}
static MTLVertexFormat VertexFormat(BYTE t)
{
	switch (t)
	{
	case D3DDECLTYPE_FLOAT1: return MTLVertexFormatFloat; case D3DDECLTYPE_FLOAT2: return MTLVertexFormatFloat2; case D3DDECLTYPE_FLOAT3: return MTLVertexFormatFloat3;
	case D3DDECLTYPE_FLOAT4: return MTLVertexFormatFloat4; case D3DDECLTYPE_D3DCOLOR: return MTLVertexFormatUChar4Normalized_BGRA; case D3DDECLTYPE_UBYTE4: return MTLVertexFormatUChar4;
	case D3DDECLTYPE_SHORT2: return MTLVertexFormatShort2; case D3DDECLTYPE_SHORT4: return MTLVertexFormatShort4; case D3DDECLTYPE_UBYTE4N: return MTLVertexFormatUChar4Normalized;
	case D3DDECLTYPE_SHORT2N: return MTLVertexFormatShort2Normalized; case D3DDECLTYPE_SHORT4N: return MTLVertexFormatShort4Normalized;
	case D3DDECLTYPE_USHORT2N: return MTLVertexFormatUShort2Normalized; case D3DDECLTYPE_USHORT4N: return MTLVertexFormatUShort4Normalized;
	case D3DDECLTYPE_FLOAT16_2: return MTLVertexFormatHalf2; case D3DDECLTYPE_FLOAT16_4: return MTLVertexFormatHalf4;
	default: return MTLVertexFormatInvalid;
	}
}

id<MTLFunction> Device::Function(const std::string &src, const char *name)
{
	uint64_t h = Hash64(src.data(), src.size(), Hash64(name, strlen(name)));
	{
		std::lock_guard<std::mutex> l(functionLock);
		auto it = functions.find(h);
		if (it != functions.end()) return it->second;
	}
	NSError *err = nil;
	MTLCompileOptions *o = [MTLCompileOptions new];
	// D3D9 shader math: no reassociation that changes results
	if (@available(macOS 15.0, *)) o.mathMode = MTLMathModeSafe; else o.fastMathEnabled = NO;
	// every vertex shader computes its position in exactly the same way ([[position, invariant]]): the game draws its
	// road and terrain layers over the same vertices with an equal-or-nearer depth test and no depth bias, which held on
	// Direct3D. Without it each shader rounded the depth its own way and the layers z-fought in horizontal stripes.
	o.preserveInvariance = YES;
	id<MTLLibrary> lib = [mtl newLibraryWithSource:[NSString stringWithUTF8String:src.c_str()] options:o error:&err];
	id<MTLFunction> f = lib ? [lib newFunctionWithName:[NSString stringWithUTF8String:name]] : nil;
	if (!f)
	{
		fprintf(stderr, "[d3d9] shader compile failed: %s\n", err.localizedDescription.UTF8String);
		static int dumps = 0;
		if (dumps++ < 8) { char path[64]; snprintf(path, sizeof path, "/tmp/s2_shader_fail_%d.metal", dumps); FILE *fp = ::fopen(path, "w"); if (fp) { fputs(src.c_str(), fp); fclose(fp); } }
	}
	std::lock_guard<std::mutex> l(functionLock);
	functions[h] = f;
	return f;
}

id<MTLSamplerState> Device::Sampler(int s)
{
	const DWORD *st = samp[s];
	DWORD key[7] = { st[D3DSAMP_ADDRESSU], st[D3DSAMP_ADDRESSV], st[D3DSAMP_MAGFILTER], st[D3DSAMP_MINFILTER], st[D3DSAMP_MIPFILTER], st[D3DSAMP_MAXANISOTROPY], (DWORD)g_s2.anisoOverride };
	uint64_t h = Hash64(key, sizeof key);
	auto it = samplers.find(h);
	if (it != samplers.end()) return it->second;
	MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
	auto addr = [](DWORD a) {
		switch (a) { case D3DTADDRESS_CLAMP: return MTLSamplerAddressModeClampToEdge; case D3DTADDRESS_MIRROR: return MTLSamplerAddressModeMirrorRepeat;
		case D3DTADDRESS_BORDER: return MTLSamplerAddressModeClampToBorderColor; case D3DTADDRESS_MIRRORONCE: return MTLSamplerAddressModeMirrorClampToEdge; default: return MTLSamplerAddressModeRepeat; }
	};
	d.sAddressMode = addr(key[0]); d.tAddressMode = addr(key[1]); d.rAddressMode = addr(key[1]);
	bool aniso = key[3] == D3DTEXF_ANISOTROPIC || key[2] == D3DTEXF_ANISOTROPIC;
	d.magFilter = key[2] == D3DTEXF_POINT ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear;
	d.minFilter = key[3] == D3DTEXF_POINT ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear;
	d.mipFilter = key[4] == D3DTEXF_NONE ? MTLSamplerMipFilterNotMipmapped : key[4] == D3DTEXF_POINT ? MTLSamplerMipFilterNearest : MTLSamplerMipFilterLinear;
	d.maxAnisotropy = aniso ? std::max(1u, std::min(16u, (unsigned)key[5])) : 1;
	// Settings override: anisotropic filtering on every filtered, mipmapped texture (render-target reads have no mips)
	if (key[6] > 1 && key[3] != D3DTEXF_POINT && key[4] != D3DTEXF_NONE)
	{
		d.maxAnisotropy = std::min(16u, (unsigned)key[6]);
		d.minFilter = d.magFilter = MTLSamplerMinMagFilterLinear;
		d.mipFilter = MTLSamplerMipFilterLinear;
	}
	d.borderColor = MTLSamplerBorderColorTransparentBlack;
	id<MTLSamplerState> s2 = [mtl newSamplerStateWithDescriptor:d];
	if (getenv("S2_RENDER_AUDIT")) fprintf(stderr, "[sampler-audit] anisotropy=%lu mipFilter=%lu minFilter=%lu magFilter=%lu\n", (unsigned long)d.maxAnisotropy, (unsigned long)d.mipFilter, (unsigned long)d.minFilter, (unsigned long)d.magFilter);
	samplers[h] = s2;
	return s2;
}

// ---------------------------------------------------------------------------------------------------
// drawing
static int TextureType(IDirect3DBaseTexture9 *t)
{
	if (!t) return 0;
	return t->GetType() == D3DRTYPE_CUBETEXTURE ? 2 : 1;
}
static id<MTLTexture> MetalTexture(IDirect3DBaseTexture9 *t)
{
	if (!t) return nil;
	TextureBase *b = t->GetType() == D3DRTYPE_CUBETEXTURE ? (TextureBase*)static_cast<CubeTexture*>((IDirect3DCubeTexture9*)t) : (TextureBase*)static_cast<Texture*>((IDirect3DTexture9*)t);
	return b->sampleView ? b->sampleView : b->tex;
}

id<MTLRenderPipelineState> Device::BuildPipeline(const Recipe &r)
{
	MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
	pd.vertexFunction = Function(r.vsrc, "vs_main");
	pd.fragmentFunction = Function(r.fsrc, "fs_main");
	if (!pd.vertexFunction || !pd.fragmentFunction) return nil;
	MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
	// attribute n is declaration element n; the generated shader reads [[attribute(n)]] for the elements it uses
	bool usedStream[4] = {};
	for (size_t i = 0; i < r.elements.size(); ++i)
	{
		const D3DVERTEXELEMENT9 &e = r.elements[i];
		MTLVertexFormat f = VertexFormat(e.Type);
		if (f == MTLVertexFormatInvalid || e.Stream >= 4) continue;
		vd.attributes[i].format = f; vd.attributes[i].offset = e.Offset; vd.attributes[i].bufferIndex = 4 + e.Stream;
		usedStream[e.Stream] = true;
	}
	for (int s = 0; s < 4; ++s) if (usedStream[s]) { vd.layouts[4 + s].stride = std::max(4u, r.strides[s]); vd.layouts[4 + s].stepFunction = MTLVertexStepFunctionPerVertex; }
	pd.vertexDescriptor = vd;
	MTLRenderPipelineColorAttachmentDescriptor *ca = pd.colorAttachments[0];
	ca.pixelFormat = (MTLPixelFormat)r.colorFormat;
	ca.blendingEnabled = r.blendEnable != 0;
	ca.sourceRGBBlendFactor = ca.sourceAlphaBlendFactor = BlendFactor(r.srcBlend);
	ca.destinationRGBBlendFactor = ca.destinationAlphaBlendFactor = BlendFactor(r.dstBlend);
	ca.rgbBlendOperation = ca.alphaBlendOperation = BlendOp(r.blendOp);
	DWORD wm = r.writeMask;
	ca.writeMask = ((wm & 1) ? MTLColorWriteMaskRed : 0) | ((wm & 2) ? MTLColorWriteMaskGreen : 0) | ((wm & 4) ? MTLColorWriteMaskBlue : 0) | ((wm & 8) ? MTLColorWriteMaskAlpha : 0);
	if (r.depthFormat) { pd.depthAttachmentPixelFormat = (MTLPixelFormat)r.depthFormat; if (r.depthFormat == MTLPixelFormatDepth32Float_Stencil8) pd.stencilAttachmentPixelFormat = (MTLPixelFormat)r.depthFormat; }
	NSError *err = nil;
	id<MTLRenderPipelineState> pso = [mtl newRenderPipelineStateWithDescriptor:pd error:&err];
	if (!pso && err) fprintf(stderr, "[d3d9] pipeline failed: %s\n", err.localizedDescription.UTF8String);
	return pso;
}

// record format: key, two length-prefixed sources, element count + elements, strides, seven state words
static void PutString(FILE *f, const std::string &s) { uint32_t n = (uint32_t)s.size(); fwrite(&n, 4, 1, f); fwrite(s.data(), 1, n, f); }
static bool GetString(FILE *f, std::string *s) { uint32_t n; if (fread(&n, 4, 1, f) != 1 || n > (1u << 24)) return false; s->resize(n); return fread(&(*s)[0], 1, n, f) == n; }
void Device::SaveRecipe(uint64_t key, const Recipe &r)
{
	if (cachePath.empty()) return;
	FILE *f = ::fopen(cachePath.c_str(), "ab");
	if (!f) return;
	fwrite(&key, 8, 1, f);
	PutString(f, r.vsrc); PutString(f, r.fsrc);
	uint32_t n = (uint32_t)r.elements.size(); fwrite(&n, 4, 1, f); fwrite(r.elements.data(), sizeof(D3DVERTEXELEMENT9), n, f);
	fwrite(r.strides, 4, 4, f);
	uint32_t st[7] = { r.colorFormat, r.depthFormat, r.blendEnable, r.srcBlend, r.dstBlend, r.blendOp, r.writeMask };
	fwrite(st, 4, 7, f);
	fclose(f);
}
void Device::WarmPipelineCache()
{
	NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
	NSString *dir = [caches stringByAppendingPathComponent:@"org.silentstorm.mac"];
	[[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
	char name[64]; snprintf(name, sizeof name, "pipelines-v%llu.bin", (unsigned long long)kShaderGenVersion);
	cachePath = std::string(dir.UTF8String) + "/" + name;
	std::vector<std::pair<uint64_t, Recipe>> recipes;
	if (FILE *f = ::fopen(cachePath.c_str(), "rb"))
	{
		for (;;)
		{
			uint64_t key; Recipe r; uint32_t n, st[7];
			if (fread(&key, 8, 1, f) != 1 || !GetString(f, &r.vsrc) || !GetString(f, &r.fsrc) || fread(&n, 4, 1, f) != 1 || n > 64) break;
			r.elements.resize(n);
			if (fread(r.elements.data(), sizeof(D3DVERTEXELEMENT9), n, f) != n || fread(r.strides, 4, 4, f) != 4 || fread(st, 4, 7, f) != 7) break;
			r.colorFormat = st[0]; r.depthFormat = st[1]; r.blendEnable = st[2]; r.srcBlend = st[3]; r.dstBlend = st[4]; r.blendOp = st[5]; r.writeMask = st[6];
			recipes.push_back({ key, r });
		}
		fclose(f);
	}
	if (recipes.empty()) return;
	// build every known pipeline in parallel at utility priority; the game uses whichever are ready
	auto shared = std::make_shared<std::vector<std::pair<uint64_t, Recipe>>>(std::move(recipes));
	dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
	warmGroup = dispatch_group_create();
	dispatch_group_async(warmGroup, q, ^{
		dispatch_apply(shared->size(), q, ^(size_t i) {
			if (warmCancelled) return;
			@autoreleasepool
			{
				id<MTLRenderPipelineState> pso = BuildPipeline((*shared)[i].second);
				if (pso) { std::lock_guard<std::mutex> l(warmLock); warm[(*shared)[i].first] = pso; }
			}
		});
		fprintf(stderr, "[d3d9] pipeline cache warmed: %zu pipelines\n", shared->size());
	});
}

void Device::ApplyState()
{
	EnsurePass();
	VertexDecl *d = decl;
	if (!d) return;

	// fragment key
	FragmentKey fk; memset(&fk, 0, sizeof fk);
	for (int i = 0; i < 8; ++i) fk.texType[i] = (uint8_t)TextureType(textures[i]);
	if (ps) fk.psHash = ps->hash;
	else
		for (int i = 0; i < 4; ++i)
		{
			StageState &s = fk.stages[i];
			s.colorOp = tss[i][D3DTSS_COLOROP]; s.colorArg1 = tss[i][D3DTSS_COLORARG1]; s.colorArg2 = tss[i][D3DTSS_COLORARG2]; s.colorArg0 = tss[i][D3DTSS_COLORARG0];
			s.alphaOp = tss[i][D3DTSS_ALPHAOP]; s.alphaArg1 = tss[i][D3DTSS_ALPHAARG1]; s.alphaArg2 = tss[i][D3DTSS_ALPHAARG2]; s.alphaArg0 = tss[i][D3DTSS_ALPHAARG0];
			s.transformFlags = tss[i][D3DTSS_TEXTURETRANSFORMFLAGS];
			if (s.colorOp == D3DTOP_DISABLE) { for (int j = i + 1; j < 4; ++j) memset(&fk.stages[j], 0, sizeof(StageState)); break; }
		}
	fk.alphaTest = rs[D3DRS_ALPHATESTENABLE] ? (uint8_t)rs[D3DRS_ALPHAFUNC] : 0;
	uint64_t fragHash = Hash64(&fk, sizeof fk);

	// vertex inputs
	UINT strides[4] = { streams[0].stride, streams[1].stride, streams[2].stride, streams[3].stride };
	uint64_t vertHash = Hash64(strides, sizeof strides, d->hash ^ (vs ? vs->hash : 0x5151));

	struct { uint64_t v, f; uint32_t blend[5]; uint32_t rtFmt, dsFmt; } pk;
	memset(&pk, 0, sizeof pk);   // the struct has tail padding; it must not leak into the hash
	pk.v = vertHash; pk.f = fragHash;
	pk.blend[0] = rs[D3DRS_ALPHABLENDENABLE]; pk.blend[1] = rs[D3DRS_SRCBLEND]; pk.blend[2] = rs[D3DRS_DESTBLEND]; pk.blend[3] = rs[D3DRS_BLENDOP]; pk.blend[4] = rs[D3DRS_COLORWRITEENABLE];
	pk.rtFmt = rt ? (uint32_t)rt->Texture().pixelFormat : 0;
	pk.dsFmt = (ds && ds->Texture()) ? (uint32_t)ds->Texture().pixelFormat : 0;
	uint64_t pipeKey = Hash64(&pk, sizeof pk, kShaderGenVersion);
	id<MTLRenderPipelineState> pso;
	auto it = pipelines.find(pipeKey);
	if (it != pipelines.end()) pso = it->second;
	else
	{
		{
			std::lock_guard<std::mutex> l(warmLock);
			auto w = warm.find(pipeKey);
			if (w != warm.end()) pso = w->second;
		}
		if (!pso)
		{
			uint32_t mask[1] = { 0 };
			Recipe r;
			r.vsrc = vs ? GenerateVertexShaderMSL(*vs, *d, mask) : GenerateFixedFunctionVertexMSL(*d);
			r.fsrc = GenerateFragmentMSL(fk, ps);
			r.elements = d->elements;
			memcpy(r.strides, strides, sizeof strides);
			r.colorFormat = pk.rtFmt ? pk.rtFmt : (uint32_t)MTLPixelFormatBGRA8Unorm; r.depthFormat = pk.dsFmt;
			r.blendEnable = rs[D3DRS_ALPHABLENDENABLE]; r.srcBlend = rs[D3DRS_SRCBLEND]; r.dstBlend = rs[D3DRS_DESTBLEND]; r.blendOp = rs[D3DRS_BLENDOP];
			r.writeMask = rs[D3DRS_COLORWRITEENABLE];
			pso = BuildPipeline(r);
			if (pso) SaveRecipe(pipeKey, r);
			++perfNewPipelines;
		}
		pipelines[pipeKey] = pso;
	}
	if (!pso) return;
	[enc setRenderPipelineState:pso];

	// depth / stencil
	bool zOn = rs[D3DRS_ZENABLE] != D3DZB_FALSE && pk.dsFmt;
	DWORD dk[10] = { zOn, rs[D3DRS_ZWRITEENABLE] && zOn, rs[D3DRS_ZFUNC], rs[D3DRS_STENCILENABLE] && pk.dsFmt == MTLPixelFormatDepth32Float_Stencil8, rs[D3DRS_STENCILFUNC], rs[D3DRS_STENCILMASK] & 0xFF, rs[D3DRS_STENCILWRITEMASK] & 0xFF, rs[D3DRS_STENCILFAIL], rs[D3DRS_STENCILZFAIL], rs[D3DRS_STENCILPASS] };
	uint64_t dh = Hash64(dk, sizeof dk);
	id<MTLDepthStencilState> dss;
	auto dit = depthStates.find(dh);
	if (dit != depthStates.end()) dss = dit->second;
	else
	{
		MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
		dd.depthCompareFunction = dk[0] ? CompareFunc(dk[2]) : MTLCompareFunctionAlways;
		dd.depthWriteEnabled = dk[1] != 0;
		if (dk[3])
		{
			MTLStencilDescriptor *sd = [MTLStencilDescriptor new];
			sd.stencilCompareFunction = CompareFunc(dk[4]); sd.readMask = dk[5]; sd.writeMask = dk[6];
			sd.stencilFailureOperation = StencilOp(dk[7]); sd.depthFailureOperation = StencilOp(dk[8]); sd.depthStencilPassOperation = StencilOp(dk[9]);
			dd.frontFaceStencil = sd; dd.backFaceStencil = sd;
		}
		dss = [mtl newDepthStencilStateWithDescriptor:dd];
		depthStates[dh] = dss;
	}
	[enc setDepthStencilState:dss];
	[enc setStencilReferenceValue:rs[D3DRS_STENCILREF] & 0xFF];

	// raster state: D3D9 front faces wind clockwise; CULL_CCW removes counter-clockwise triangles
	[enc setFrontFacingWinding:MTLWindingClockwise];
	DWORD cull = rs[D3DRS_CULLMODE];
	[enc setCullMode:cull == D3DCULL_CCW ? MTLCullModeBack : cull == D3DCULL_CW ? MTLCullModeFront : MTLCullModeNone];
	[enc setTriangleFillMode:rs[D3DRS_FILLMODE] == D3DFILL_WIREFRAME ? MTLTriangleFillModeLines : MTLTriangleFillModeFill];
	float bias = *(float*)&rs[D3DRS_DEPTHBIAS], slope = *(float*)&rs[D3DRS_SLOPESCALEDEPTHBIAS];
	[enc setDepthBias:bias * 16777216.0f slopeScale:slope clamp:0];

	MTLViewport mv = { (double)viewport.X, (double)viewport.Y, (double)viewport.Width, (double)viewport.Height, viewport.MinZ, viewport.MaxZ };
	[enc setViewport:mv];
	UINT tw = rt ? rt->width : pp.BackBufferWidth, th = rt ? rt->height : pp.BackBufferHeight;
	MTLScissorRect sr = { 0, 0, tw, th };
	if (rs[D3DRS_SCISSORTESTENABLE])
	{
		LONG l = std::max(0L, (long)scissor.left), t = std::max(0L, (long)scissor.top);
		LONG r = std::min((LONG)tw, scissor.right), b = std::min((LONG)th, scissor.bottom);
		sr = { (NSUInteger)l, (NSUInteger)t, (NSUInteger)std::max(0L, (long)(r - l)), (NSUInteger)std::max(0L, (long)(b - t)) };
	}
	[enc setScissorRect:sr];

	// buffers
	for (int s = 0; s < 4; ++s)
		if (streams[s].vb) { [enc setVertexBuffer:streams[s].vb->buf offset:streams[s].offset atIndex:4 + s]; streams[s].vb->lastUse = serial; }
	[enc setVertexBytes:vsConst length:96 * 16 atIndex:1];
	VSParams vp = { { (float)viewport.Width, (float)viewport.Height, 1.0f / std::max(1u, viewport.Width), 1.0f / std::max(1u, viewport.Height) } };
	[enc setVertexBytes:&vp length:sizeof vp atIndex:2];
	if (!vs)
	{
		// fixed-function vertex path: world * view * projection
		D3DMATRIX wvp = {}, wv = {};
		const D3DMATRIX &w = transforms[256], &v = transforms[D3DTS_VIEW], &p = transforms[D3DTS_PROJECTION];
		for (int i = 0; i < 4; ++i) for (int j = 0; j < 4; ++j) for (int k = 0; k < 4; ++k) wv.m[i][j] += w.m[i][k] * v.m[k][j];
		for (int i = 0; i < 4; ++i) for (int j = 0; j < 4; ++j) for (int k = 0; k < 4; ++k) wvp.m[i][j] += wv.m[i][k] * p.m[k][j];
		[enc setVertexBytes:&wvp length:sizeof wvp atIndex:3];
	}

	PSParams pp2; memset(&pp2, 0, sizeof pp2);
	DWORD tf = rs[D3DRS_TEXTUREFACTOR];
	pp2.tfactor[0] = ((tf >> 16) & 255) / 255.0f; pp2.tfactor[1] = ((tf >> 8) & 255) / 255.0f; pp2.tfactor[2] = (tf & 255) / 255.0f; pp2.tfactor[3] = (tf >> 24) / 255.0f;
	pp2.alphaRef = (rs[D3DRS_ALPHAREF] & 255) / 255.0f;
	for (int i = 0; i < 8; ++i) pp2.lodBias[i] = *(float*)&samp[i][D3DSAMP_MIPMAPLODBIAS] + g_s2.lodBias;
	memcpy(pp2.c, psConst, sizeof pp2.c);
	for (int i = 0; i < 8; ++i)
	{
		// bump-environment matrix and luminance scale/offset for texbem / texbeml
		pp2.bump[i][0] = *(float*)&tss[i][D3DTSS_BUMPENVMAT00]; pp2.bump[i][1] = *(float*)&tss[i][D3DTSS_BUMPENVMAT01];
		pp2.bump[i][2] = *(float*)&tss[i][D3DTSS_BUMPENVMAT10]; pp2.bump[i][3] = *(float*)&tss[i][D3DTSS_BUMPENVMAT11];
		pp2.lum[i][0] = *(float*)&tss[i][D3DTSS_BUMPENVLSCALE]; pp2.lum[i][1] = *(float*)&tss[i][D3DTSS_BUMPENVLOFFSET];
	}
	[enc setFragmentBytes:&pp2 length:sizeof pp2 atIndex:0];
	for (int i = 0; i < 8; ++i)
	{
		id<MTLTexture> t = MetalTexture(textures[i]);
		if (!t) t = fk.texType[i] == 2 ? dummyCube : dummy2D;
		[enc setFragmentTexture:t atIndex:i];
		[enc setFragmentSamplerState:Sampler(i) atIndex:i];
	}
}

static MTLPrimitiveType PrimType(D3DPRIMITIVETYPE t, UINT count, UINT *verts)
{
	switch (t)
	{
	case D3DPT_POINTLIST: *verts = count; return MTLPrimitiveTypePoint;
	case D3DPT_LINELIST: *verts = count * 2; return MTLPrimitiveTypeLine;
	case D3DPT_LINESTRIP: *verts = count + 1; return MTLPrimitiveTypeLineStrip;
	case D3DPT_TRIANGLESTRIP: *verts = count + 2; return MTLPrimitiveTypeTriangleStrip;
	default: *verts = count * 3; return MTLPrimitiveTypeTriangle;
	}
}

void Device::DumpDraw(const char *kind, UINT first, UINT count, INT base, bool indexed)
{
	if (!dumpFile || !decl) return;
	FILE *f = dumpFile;
	fprintf(f, "#%d %s prims=%u vs=%016llx ps=%016llx rt=%ux%u vp=%u,%u %ux%u blend=%lu %lu/%lu atest=%lu z=%lu cull=%lu\n", dumpDraws++, kind, count,
		vs ? (unsigned long long)vs->hash : 0ull, ps ? (unsigned long long)ps->hash : 0ull, rt ? rt->width : 0, rt ? rt->height : 0,
		viewport.X, viewport.Y, viewport.Width, viewport.Height, (unsigned long)rs[D3DRS_ALPHABLENDENABLE], (unsigned long)rs[D3DRS_SRCBLEND], (unsigned long)rs[D3DRS_DESTBLEND],
		(unsigned long)(rs[D3DRS_ALPHATESTENABLE] ? rs[D3DRS_ALPHAREF] : 0), (unsigned long)rs[D3DRS_ZENABLE], (unsigned long)rs[D3DRS_CULLMODE]);
	for (int i = 0; i < 4; ++i)
	{
		if (!textures[i]) continue;
		D3DSURFACE_DESC dsc = {};
		if (textures[i]->GetType() == D3DRTYPE_TEXTURE) ((IDirect3DTexture9*)textures[i])->GetLevelDesc(0, &dsc);
		fprintf(f, "  tex%d %ux%u fmt=%d op=%lu a1=%lx a2=%lx aop=%lu\n", i, dsc.Width, dsc.Height, (int)dsc.Format, (unsigned long)tss[i][D3DTSS_COLOROP],
			(unsigned long)tss[i][D3DTSS_COLORARG1], (unsigned long)tss[i][D3DTSS_COLORARG2], (unsigned long)tss[i][D3DTSS_ALPHAOP]);
	}
	// save each BGRA texture this frame uses once, as _tex_<draw>_<stage>.png
	for (int i = 0; i < 2; ++i)
	{
		if (!textures[i] || textures[i]->GetType() != D3DRTYPE_TEXTURE) continue;
		Texture *t = static_cast<Texture*>((IDirect3DTexture9*)textures[i]);
		static std::vector<void*> saved;
		if (std::find(saved.begin(), saved.end(), (void*)t) != saved.end() || t->tex.pixelFormat != MTLPixelFormatBGRA8Unorm || t->tex.storageMode == MTLStorageModePrivate) continue;
		saved.push_back(t);
		size_t w = t->tex.width, h = t->tex.height;
		std::vector<BYTE> px(w * h * 4);
		[t->tex getBytes:px.data() bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
		CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
		CGContextRef ctx = CGBitmapContextCreate(px.data(), w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
		CGImageRef im = CGBitmapContextCreateImage(ctx);
		char name[64]; snprintf(name, sizeof name, "_tex_%d_%d.png", dumpDraws - 1, i);
		CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:[NSString stringWithUTF8String:name]], (__bridge CFStringRef)UTTypePNG.identifier, 1, nullptr);
		if (dst) { CGImageDestinationAddImage(dst, im, nullptr); CGImageDestinationFinalize(dst); CFRelease(dst); }
		CGImageRelease(im); CGContextRelease(ctx); CGColorSpaceRelease(cs);
	}
	// first vertices, decoded through the declaration
	for (UINT v = 0; v < 4; ++v)
	{
		UINT idx = first + v;
		if (indexed && ib) { const BYTE *ip = (const BYTE*)ib->buf.contents; idx = ib->format == D3DFMT_INDEX32 ? ((const uint32_t*)ip)[first + v] : ((const uint16_t*)ip)[first + v]; idx += base; }
		fprintf(f, "  v%u:", idx);
		for (auto &e : decl->elements)
		{
			Stream &st = streams[e.Stream];
			if (!st.vb) continue;
			const BYTE *p = (const BYTE*)st.vb->buf.contents + st.offset + (size_t)idx * st.stride + e.Offset;
			if ((size_t)(p - (const BYTE*)st.vb->buf.contents) + 16 > st.vb->buf.length) continue;
			const float *fp = (const float*)p;
			switch (e.Type)
			{
			case D3DDECLTYPE_FLOAT2: fprintf(f, " u%d.%d=(%.3f,%.3f)", e.Usage, e.UsageIndex, fp[0], fp[1]); break;
			case D3DDECLTYPE_FLOAT3: fprintf(f, " u%d.%d=(%.3f,%.3f,%.3f)", e.Usage, e.UsageIndex, fp[0], fp[1], fp[2]); break;
			case D3DDECLTYPE_FLOAT4: fprintf(f, " u%d.%d=(%.3f,%.3f,%.3f,%.3f)", e.Usage, e.UsageIndex, fp[0], fp[1], fp[2], fp[3]); break;
			case D3DDECLTYPE_D3DCOLOR: fprintf(f, " u%d.%d=#%08x", e.Usage, e.UsageIndex, *(const uint32_t*)p); break;
			case D3DDECLTYPE_SHORT2: fprintf(f, " u%d.%d=(%d,%d)", e.Usage, e.UsageIndex, ((const short*)p)[0], ((const short*)p)[1]); break;
			default: fprintf(f, " u%d.%d=type%d", e.Usage, e.UsageIndex, e.Type);
			}
		}
		fprintf(f, "\n");
	}
	if (vs)
	{
		char name[64]; snprintf(name, sizeof name, "_vs_%016llx.metal", (unsigned long long)vs->hash);
		if (access(name, F_OK) != 0) { uint32_t m[1]; std::string src = GenerateVertexShaderMSL(*vs, *decl, m); if (FILE *o = ::fopen(name, "w")) { fputs(src.c_str(), o); fclose(o); } }
		fprintf(f, "  c12..c23:"); for (int i = 12; i < 24; ++i) fprintf(f, " (%.4g %.4g %.4g %.4g)", vsConst[i][0], vsConst[i][1], vsConst[i][2], vsConst[i][3]); fprintf(f, "\n");
	}
	if (vs) { fprintf(f, "  c0..c11:"); for (int i = 0; i < 12; ++i) fprintf(f, " (%.3g %.3g %.3g %.3g)", vsConst[i][0], vsConst[i][1], vsConst[i][2], vsConst[i][3]); fprintf(f, "\n"); }
}

HRESULT Device::DrawPrimitive(D3DPRIMITIVETYPE t, UINT start, UINT count)
{
	std::lock_guard<std::recursive_mutex> l(lock);
	if (!count) return D3D_OK;
	if (t == D3DPT_TRIANGLEFAN)
	{
		// Metal has no fans: expand to a list through a temporary index buffer
		std::vector<uint32_t> idx; for (UINT i = 0; i < count; ++i) { idx.push_back(start); idx.push_back(start + i + 1); idx.push_back(start + i + 2); }
		ApplyState();
		[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:idx.size() indexType:MTLIndexTypeUInt32 indexBuffer:[mtl newBufferWithBytes:idx.data() length:idx.size() * 4 options:MTLResourceStorageModeShared] indexBufferOffset:0];
		return D3D_OK;
	}
	UINT n; MTLPrimitiveType pt = PrimType(t, count, &n);
	ApplyState();
	DumpDraw("draw", start, count, 0, false);
	[enc drawPrimitives:pt vertexStart:start vertexCount:n];
	return D3D_OK;
}
HRESULT Device::DrawIndexedPrimitive(D3DPRIMITIVETYPE t, INT base, UINT, UINT, UINT startIndex, UINT count)
{
	std::lock_guard<std::recursive_mutex> l(lock);
	if (!count || !ib) return D3D_OK;
	UINT n; MTLPrimitiveType pt = PrimType(t, count, &n);
	bool i32 = ib->format == D3DFMT_INDEX32;
	ApplyState();
	DumpDraw("indexed", startIndex, count, base, true);
	ib->lastUse = serial;
	[enc drawIndexedPrimitives:pt indexCount:n indexType:i32 ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16 indexBuffer:ib->buf indexBufferOffset:startIndex * (i32 ? 4 : 2) instanceCount:1 baseVertex:base baseInstance:0];
	return D3D_OK;
}
HRESULT Device::DrawPrimitiveUP(D3DPRIMITIVETYPE t, UINT count, const void *data, UINT stride)
{
	std::lock_guard<std::recursive_mutex> l(lock);
	UINT n; PrimType(t, count, &n);
	Stream saved = streams[0];
	VertexBuffer tmp; tmp.dev = this; tmp.length = n * stride; tmp.buf = [mtl newBufferWithBytes:data length:std::max(16u, n * stride) options:MTLResourceStorageModeShared];
	streams[0] = { &tmp, 0, stride };
	DrawPrimitive(t, 0, count);
	streams[0] = saved;
	tmp.refs = 0;
	return D3D_OK;
}
HRESULT Device::DrawIndexedPrimitiveUP(D3DPRIMITIVETYPE t, UINT minIndex, UINT numVerts, UINT count, const void *idx, D3DFORMAT f, const void *data, UINT stride)
{
	std::lock_guard<std::recursive_mutex> l(lock);
	UINT n; MTLPrimitiveType pt = PrimType(t, count, &n);
	Stream saved = streams[0];
	VertexBuffer tmp; tmp.dev = this; tmp.buf = [mtl newBufferWithBytes:data length:std::max(16u, (minIndex + numVerts) * stride) options:MTLResourceStorageModeShared];
	streams[0] = { &tmp, 0, stride };
	ApplyState();
	bool i32 = f == D3DFMT_INDEX32;
	[enc drawIndexedPrimitives:pt indexCount:n indexType:i32 ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16 indexBuffer:[mtl newBufferWithBytes:idx length:n * (i32 ? 4 : 2) options:MTLResourceStorageModeShared] indexBufferOffset:0];
	streams[0] = saved;
	tmp.refs = 0;
	return D3D_OK;
}

// Clear: a full-target clear starts a fresh render pass with clear load actions; partial clears
// (rects or a smaller viewport) draw a quad that writes exactly the cleared values
HRESULT Device::Clear(DWORD count, const D3DRECT *rects, DWORD flags, D3DCOLOR color, float z, DWORD stencil)
{
	std::lock_guard<std::recursive_mutex> l(lock);
	if (!rt) return D3D_OK;
	bool full = (count == 0 || !rects) && viewport.X == 0 && viewport.Y == 0 && viewport.Width == rt->width && viewport.Height == rt->height;
	const FormatInfo *dfi = (ds && ds->Texture()) ? GetFormat(ds->format) : nullptr;
	if (!dfi) flags &= ~(D3DCLEAR_ZBUFFER | D3DCLEAR_STENCIL);
	if (dfi && !dfi->stencil) flags &= ~D3DCLEAR_STENCIL;
	float cr = ((color >> 16) & 255) / 255.0f, cg = ((color >> 8) & 255) / 255.0f, cb = (color & 255) / 255.0f, ca = (color >> 24) / 255.0f;
	if (full)
	{
		EndPass(); BeginFrame();
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
		rp.colorAttachments[0].texture = rt->Texture();
		rp.colorAttachments[0].loadAction = (flags & D3DCLEAR_TARGET) ? MTLLoadActionClear : MTLLoadActionLoad;
		rp.colorAttachments[0].clearColor = MTLClearColorMake(cr, cg, cb, ca);
		rp.colorAttachments[0].storeAction = MTLStoreActionStore;
		if (dfi)
		{
			rp.depthAttachment.texture = ds->Texture();
			rp.depthAttachment.loadAction = (flags & D3DCLEAR_ZBUFFER) ? MTLLoadActionClear : MTLLoadActionLoad;
			rp.depthAttachment.clearDepth = z; rp.depthAttachment.storeAction = MTLStoreActionStore;
			if (dfi->stencil)
			{
				rp.stencilAttachment.texture = ds->Texture();
				rp.stencilAttachment.loadAction = (flags & D3DCLEAR_STENCIL) ? MTLLoadActionClear : MTLLoadActionLoad;
				rp.stencilAttachment.clearStencil = stencil & 0xFF; rp.stencilAttachment.storeAction = MTLStoreActionStore;
			}
		}
		rp.visibilityResultBuffer = visibility;
		enc = [cmd renderCommandEncoderWithDescriptor:rp];
		passDirty = false;
		if (activeQuery && activeQuery->slot >= 0) [enc setVisibilityResultMode:MTLVisibilityResultModeCounting offset:activeQuery->slot * 8];
		return D3D_OK;
	}
	// partial clear
	EnsurePass();
	static const char *src =
		"#include <metal_stdlib>\nusing namespace metal;\n"
		"struct V { float4 p [[position]]; };\n"
		"vertex V cv(uint id [[vertex_id]], constant float4 *r [[buffer(0)]]) { float2 t = float2((id & 1) ? r->z : r->x, (id & 2) ? r->w : r->y); V o; o.p = float4(t, r[1].x, 1); return o; }\n"
		"fragment float4 cf(V in [[stage_in]], constant float4 *r [[buffer(0)]]) { return r[2]; }\n";
	uint64_t key = Hash64(&flags, 4, (uint64_t)rt->Texture().pixelFormat * 31 + (dfi ? dfi->metal : 0));
	id<MTLRenderPipelineState> pso = pipelines[key];
	if (!pso)
	{
		MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
		pd.vertexFunction = Function(src, "cv"); pd.fragmentFunction = Function(src, "cf");
		pd.colorAttachments[0].pixelFormat = rt->Texture().pixelFormat;
		pd.colorAttachments[0].writeMask = (flags & D3DCLEAR_TARGET) ? MTLColorWriteMaskAll : MTLColorWriteMaskNone;
		if (dfi) { pd.depthAttachmentPixelFormat = dfi->metal; if (dfi->stencil) pd.stencilAttachmentPixelFormat = dfi->metal; }
		pso = [mtl newRenderPipelineStateWithDescriptor:pd error:nil];
		pipelines[key] = pso;
	}
	MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
	dd.depthCompareFunction = MTLCompareFunctionAlways; dd.depthWriteEnabled = (flags & D3DCLEAR_ZBUFFER) != 0;
	if (flags & D3DCLEAR_STENCIL) { MTLStencilDescriptor *sd = [MTLStencilDescriptor new]; sd.depthStencilPassOperation = MTLStencilOperationReplace; sd.writeMask = 0xFF; dd.frontFaceStencil = dd.backFaceStencil = sd; }
	[enc setRenderPipelineState:pso];
	[enc setDepthStencilState:[mtl newDepthStencilStateWithDescriptor:dd]];
	[enc setStencilReferenceValue:stencil & 0xFF];
	[enc setCullMode:MTLCullModeNone];
	[enc setTriangleFillMode:MTLTriangleFillModeFill];
	MTLViewport mv = { 0, 0, (double)rt->width, (double)rt->height, 0, 1 };
	[enc setViewport:mv];
	[enc setScissorRect:(MTLScissorRect){ 0, 0, rt->width, rt->height }];
	auto quad = [&](LONG x1, LONG y1, LONG x2, LONG y2) {
		x1 = std::max(x1, (LONG)viewport.X); y1 = std::max(y1, (LONG)viewport.Y);
		x2 = std::min(x2, (LONG)(viewport.X + viewport.Width)); y2 = std::min(y2, (LONG)(viewport.Y + viewport.Height));
		if (x2 <= x1 || y2 <= y1) return;
		float r[12] = { x1 * 2.0f / rt->width - 1, 1 - y1 * 2.0f / rt->height, x2 * 2.0f / rt->width - 1, 1 - y2 * 2.0f / rt->height, z, 0, 0, 0, cr, cg, cb, ca };
		[enc setVertexBytes:r length:sizeof r atIndex:0];
		[enc setFragmentBytes:r length:sizeof r atIndex:0];
		[enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	};
	if (count && rects) for (DWORD i = 0; i < count; ++i) quad(rects[i].x1, rects[i].y1, rects[i].x2, rects[i].y2);
	else quad(viewport.X, viewport.Y, viewport.X + viewport.Width, viewport.Y + viewport.Height);
	return D3D_OK;
}

} // namespace s2gfx

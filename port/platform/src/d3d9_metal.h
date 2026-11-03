// d3d9_metal.h: internal classes of the Direct3D 9 implementation on Metal (port/platform/src/d3d9_*.mm).
#pragma once
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <MetalFX/MetalFX.h>
#include "s2win32.h"
#include "s2com.h"
#include "win/d3d9.h"
#include "gen/d3d9_stubs.h"
#include <vector>
#include <unordered_map>
#include <string>
#include <mutex>
#include <atomic>

void S2Unimplemented(const char *what);

namespace s2gfx {

struct Device;

// ---- reference counting shared by every object -----------------------------------------------------
template<class Base> struct RefCounted : public Base
{
	std::atomic<ULONG> refs { 1 };
	HRESULT QueryInterface(REFIID, void **ppv) override { *ppv = this; this->AddRef(); return S_OK; }
	ULONG AddRef() override { return ++refs; }
	ULONG Release() override { ULONG r = --refs; if (r == 0) delete this; return r; }
	virtual ~RefCounted() {}
};

// ---- formats ---------------------------------------------------------------------------------------
struct FormatInfo
{
	MTLPixelFormat metal;     // storage format on the GPU
	int blockBytes;           // bytes per pixel, or per 4x4 block when compressed
	bool compressed;
	bool convert;             // CPU conversion on upload (16-bit and other legacy layouts -> BGRA8)
	MTLTextureSwizzleChannels swizzle;
	bool depth, stencil;
};
const FormatInfo *GetFormat(D3DFORMAT f);
size_t LevelPitch(D3DFORMAT f, UINT width);                 // bytes per row (per block row when compressed)
UINT LevelRows(D3DFORMAT f, UINT height);                    // rows (block rows when compressed)
void ConvertToBGRA8(D3DFORMAT f, const BYTE *src, size_t srcPitch, BYTE *dst, size_t dstPitch, UINT w, UINT h);

// ---- resources -------------------------------------------------------------------------------------
struct Surface;

struct TextureBase
{
	Device *dev = nullptr;
	id<MTLTexture> tex = nil;
	id<MTLTexture> sampleView = nil;   // swizzled view for render targets (Metal forbids swizzle on render-target textures)
	D3DFORMAT format = D3DFMT_UNKNOWN;
	UINT width = 0, height = 0, levels = 1;
	DWORD usage = 0;
	D3DPOOL pool = D3DPOOL_MANAGED;
	bool cube = false;
	DWORD lod = 0, priority = 0;
	std::vector<Surface*> surfaces;   // [face * levels + level]
	void CreateTexture();
	void ReleaseSurfaces();
};

struct Surface : RefCounted<StubIDirect3DSurface9>
{
	Device *dev = nullptr;
	TextureBase *owner = nullptr;   // null for stand-alone surfaces
	IUnknown *container = nullptr;  // the texture whose reference count this surface shares
	UINT level = 0, face = 0;
	UINT width = 0, height = 0;
	D3DFORMAT format = D3DFMT_UNKNOWN;
	DWORD usage = 0;
	D3DPOOL pool = D3DPOOL_DEFAULT;
	id<MTLTexture> own = nil;       // stand-alone render target / depth stencil
	std::vector<BYTE> sysmem;       // system-memory / offscreen plain surfaces live on the CPU
	std::vector<BYTE> shadow;       // D3D-format copy for converted formats
	std::vector<BYTE> lockBuf;
	RECT lockRect = {};
	DWORD lockFlags = 0;
	bool locked = false;

	id<MTLTexture> Texture() const;
	bool IsCPU() const { return !owner && !own; }
	ULONG AddRef() override;
	ULONG Release() override;
	HRESULT GetDevice(IDirect3DDevice9 **ppDevice) override;
	D3DRESOURCETYPE GetType() override { return D3DRTYPE_SURFACE; }
	HRESULT GetContainer(REFIID riid, void **ppContainer) override;
	HRESULT GetDesc(D3DSURFACE_DESC *pDesc) override;
	HRESULT LockRect(D3DLOCKED_RECT *pLockedRect, const RECT *pRect, DWORD Flags) override;
	HRESULT UnlockRect() override;
	HRESULT SetPrivateData(REFGUID, const void *, DWORD, DWORD) override { return S_OK; }
	HRESULT GetDC(HDC *) override { return E_NOTIMPL; }
	HRESULT ReleaseDC(HDC) override { return E_NOTIMPL; }
};

struct Texture : RefCounted<StubIDirect3DTexture9>, TextureBase
{
	~Texture() { ReleaseSurfaces(); }
	HRESULT GetDevice(IDirect3DDevice9 **ppDevice) override;
	D3DRESOURCETYPE GetType() override { return D3DRTYPE_TEXTURE; }
	DWORD SetLOD(DWORD l) override { DWORD o = lod; lod = l; return o; }
	DWORD GetLOD() override { return lod; }
	DWORD GetLevelCount() override { return levels; }
	DWORD SetPriority(DWORD p) override { DWORD o = priority; priority = p; return o; }
	DWORD GetPriority() override { return priority; }
	void PreLoad() override {}
	HRESULT SetAutoGenFilterType(D3DTEXTUREFILTERTYPE) override { return S_OK; }
	void GenerateMipSubLevels() override {}
	HRESULT GetLevelDesc(UINT Level, D3DSURFACE_DESC *pDesc) override;
	HRESULT GetSurfaceLevel(UINT Level, IDirect3DSurface9 **ppSurfaceLevel) override;
	HRESULT LockRect(UINT Level, D3DLOCKED_RECT *pLockedRect, const RECT *pRect, DWORD Flags) override;
	HRESULT UnlockRect(UINT Level) override;
	HRESULT AddDirtyRect(const RECT *) override { return S_OK; }
	HRESULT SetPrivateData(REFGUID, const void *, DWORD, DWORD) override { return S_OK; }
};

struct CubeTexture : RefCounted<StubIDirect3DCubeTexture9>, TextureBase
{
	~CubeTexture() { ReleaseSurfaces(); }
	HRESULT GetDevice(IDirect3DDevice9 **ppDevice) override;
	D3DRESOURCETYPE GetType() override { return D3DRTYPE_CUBETEXTURE; }
	DWORD SetLOD(DWORD l) override { DWORD o = lod; lod = l; return o; }
	DWORD GetLOD() override { return lod; }
	DWORD GetLevelCount() override { return levels; }
	DWORD SetPriority(DWORD p) override { DWORD o = priority; priority = p; return o; }
	DWORD GetPriority() override { return priority; }
	void PreLoad() override {}
	HRESULT SetAutoGenFilterType(D3DTEXTUREFILTERTYPE) override { return S_OK; }
	void GenerateMipSubLevels() override {}
	HRESULT GetLevelDesc(UINT Level, D3DSURFACE_DESC *pDesc) override;
	HRESULT GetCubeMapSurface(D3DCUBEMAP_FACES FaceType, UINT Level, IDirect3DSurface9 **ppCubeMapSurface) override;
	HRESULT LockRect(D3DCUBEMAP_FACES FaceType, UINT Level, D3DLOCKED_RECT *pLockedRect, const RECT *pRect, DWORD Flags) override;
	HRESULT UnlockRect(D3DCUBEMAP_FACES FaceType, UINT Level) override;
	HRESULT AddDirtyRect(D3DCUBEMAP_FACES, const RECT *) override { return S_OK; }
	HRESULT SetPrivateData(REFGUID, const void *, DWORD, DWORD) override { return S_OK; }
};

// Dynamic buffers are written while the GPU may still read the previous contents. DISCARD switches to
// a fresh MTLBuffer whose last GPU use has completed; plain locks wait for the GPU, as Direct3D does.
struct Buffer
{
	Device *dev = nullptr;
	UINT length = 0;
	DWORD usage = 0;
	D3DPOOL pool = D3DPOOL_DEFAULT;
	id<MTLBuffer> buf = nil;
	uint64_t lastUse = 0;   // frame serial of the last command buffer that read it
	std::vector<std::pair<id<MTLBuffer>, uint64_t>> retired;
	void Create();
	void *Lock(UINT offset, UINT size, DWORD flags);
};

struct VertexBuffer : RefCounted<StubIDirect3DVertexBuffer9>, Buffer
{
	DWORD fvf = 0;
	HRESULT GetDevice(IDirect3DDevice9 **ppDevice) override;
	D3DRESOURCETYPE GetType() override { return D3DRTYPE_VERTEXBUFFER; }
	HRESULT Lock(UINT OffsetToLock, UINT SizeToLock, void **ppbData, DWORD Flags) override;
	HRESULT Unlock() override { return S_OK; }
	HRESULT GetDesc(D3DVERTEXBUFFER_DESC *pDesc) override;
	DWORD SetPriority(DWORD) override { return 0; }
	DWORD GetPriority() override { return 0; }
	void PreLoad() override {}
};

struct IndexBuffer : RefCounted<StubIDirect3DIndexBuffer9>, Buffer
{
	D3DFORMAT format = D3DFMT_INDEX16;
	HRESULT GetDevice(IDirect3DDevice9 **ppDevice) override;
	D3DRESOURCETYPE GetType() override { return D3DRTYPE_INDEXBUFFER; }
	HRESULT Lock(UINT OffsetToLock, UINT SizeToLock, void **ppbData, DWORD Flags) override;
	HRESULT Unlock() override { return S_OK; }
	HRESULT GetDesc(D3DINDEXBUFFER_DESC *pDesc) override;
	DWORD SetPriority(DWORD) override { return 0; }
	DWORD GetPriority() override { return 0; }
	void PreLoad() override {}
};

struct VertexDecl : RefCounted<StubIDirect3DVertexDeclaration9>
{
	Device *dev = nullptr;
	std::vector<D3DVERTEXELEMENT9> elements;   // without the D3DDECL_END terminator
	uint64_t hash = 0;
	HRESULT GetDevice(IDirect3DDevice9 **ppDevice) override;
	HRESULT GetDeclaration(D3DVERTEXELEMENT9 *pElement, UINT *pNumElements) override;
};

struct Shader
{
	Device *dev = nullptr;
	std::vector<DWORD> code;
	uint64_t hash = 0;
	DWORD version = 0;
};
struct VertexShader : RefCounted<StubIDirect3DVertexShader9>, Shader
{
	HRESULT GetDevice(IDirect3DDevice9 **ppDevice) override;
	HRESULT GetFunction(void *pData, UINT *pSizeOfData) override;
};
struct PixelShader : RefCounted<StubIDirect3DPixelShader9>, Shader
{
	HRESULT GetDevice(IDirect3DDevice9 **ppDevice) override;
	HRESULT GetFunction(void *pData, UINT *pSizeOfData) override;
};

struct Query : RefCounted<StubIDirect3DQuery9>
{
	Device *dev = nullptr;
	D3DQUERYTYPE type;
	int slot = -1;          // visibility-result slot for occlusion queries
	uint64_t endSerial = 0; // frame serial the result belongs to
	bool issued = false;
	HRESULT GetDevice(IDirect3DDevice9 **ppDevice) override;
	D3DQUERYTYPE GetType() override { return type; }
	DWORD GetDataSize() override { return type == D3DQUERYTYPE_OCCLUSION ? sizeof(DWORD) : sizeof(BOOL); }
	HRESULT Issue(DWORD dwIssueFlags) override;
	HRESULT GetData(void *pData, DWORD dwSize, DWORD dwGetDataFlags) override;
	~Query();
};

// ---- shader generation (d3d9_shaders.mm) -----------------------------------------------------------
struct StageState
{
	DWORD colorOp, colorArg1, colorArg2, colorArg0, alphaOp, alphaArg1, alphaArg2, alphaArg0, transformFlags;
};
struct FragmentKey
{
	// fixed-function path (no pixel shader bound)
	StageState stages[4];
	uint8_t texType[8];        // 0 none, 1 2D, 2 cube
	uint8_t alphaTest;         // D3DCMP_* or 0 when disabled
	uint64_t psHash;           // non-zero when a pixel shader is bound
	bool operator==(const FragmentKey &o) const { return memcmp(this, &o, sizeof *this) == 0; }
};
std::string GenerateVertexShaderMSL(const Shader &vs, const VertexDecl &decl, uint32_t attribMask[1]);
std::string GenerateFragmentMSL(const FragmentKey &key, const Shader *ps);
std::string GenerateFixedFunctionVertexMSL(const VertexDecl &decl);
uint64_t Hash64(const void *data, size_t n, uint64_t seed = 1469598103934665603ull);

struct VSParams { float viewport[4]; };            // width, height, half-pixel x, half-pixel y (clip units)
struct PSParams { float tfactor[4]; float alphaRef; float lodBias[8]; float pad[3]; float c[8][4]; float bump[8][4]; float lum[8][4]; };

// ---- the device ------------------------------------------------------------------------------------
struct Direct3D;
struct Device : RefCounted<StubIDirect3DDevice9>
{
	std::recursive_mutex lock;
	Direct3D *d3d = nullptr;
	id<MTLDevice> mtl = nil;
	id<MTLCommandQueue> queue = nil;
	CAMetalLayer *layer = nil;
	HWND hwnd = nullptr;
	D3DPRESENT_PARAMETERS pp = {};

	// frame bookkeeping
	id<MTLCommandBuffer> cmd = nil;
	id<MTLRenderCommandEncoder> enc = nil;
	uint64_t serial = 1;                       // current frame
	std::atomic<uint64_t> completed { 0 };     // last finished frame
	dispatch_semaphore_t inflight;

	// render targets
	Surface *backBuffer = nullptr, *autoDepth = nullptr;
	Surface *rt = nullptr, *ds = nullptr;
	bool passDirty = true;
	D3DVIEWPORT9 viewport = {};
	RECT scissor = {};

	// state
	DWORD rs[256] = {};
	DWORD tss[8][33] = {};
	DWORD samp[8][14] = {};
	IDirect3DBaseTexture9 *textures[8] = {};
	VertexDecl *decl = nullptr;
	DWORD fvf = 0;
	VertexShader *vs = nullptr;
	PixelShader *ps = nullptr;
	float vsConst[256][4] = {};
	float psConst[8][4] = {};
	struct Stream { VertexBuffer *vb; UINT offset, stride; } streams[4] = {};
	IndexBuffer *ib = nullptr;
	D3DMATRIX transforms[512] = {};
	D3DMATERIAL9 material = {};
	D3DLIGHT9 lights[8] = {};
	BOOL lightEnabled[8] = {};
	D3DGAMMARAMP gamma = {};
	bool gammaIdentity = true;

	// caches
	std::unordered_map<uint64_t, id<MTLRenderPipelineState>> pipelines;
	// persistent pipeline cache: recipes are saved to disk and rebuilt on a background queue at startup
	struct Recipe
	{
		std::string vsrc, fsrc;
		std::vector<D3DVERTEXELEMENT9> elements;
		UINT strides[4];
		uint32_t colorFormat, depthFormat, blendEnable, srcBlend, dstBlend, blendOp, writeMask;
	};
	std::mutex warmLock;
	id<MTLBuffer> screenProbe = nil;        // "_shotscreen.req": the drawable as it goes to the display
	id<MTLCommandBuffer> screenProbeCommand = nil;
	MTLPixelFormat screenProbeFormat = MTLPixelFormatInvalid;
	NSUInteger screenProbeWidth = 0, screenProbeHeight = 0;
	dispatch_group_t warmGroup = nullptr;   // the background cache warm-up, which the destructor waits out
	std::atomic<bool> warmCancelled{false};
	std::unordered_map<uint64_t, id<MTLRenderPipelineState>> warm;
	std::string cachePath;
	id<MTLRenderPipelineState> BuildPipeline(const Recipe &r);
	void SaveRecipe(uint64_t key, const Recipe &r);
	void WarmPipelineCache();
	std::unordered_map<uint64_t, id<MTLFunction>> functions;
	std::unordered_map<uint64_t, id<MTLDepthStencilState>> depthStates;
	std::unordered_map<uint64_t, id<MTLSamplerState>> samplers;
	std::unordered_map<uint64_t, VertexDecl*> fvfDecls;
	id<MTLRenderPipelineState> presentPipeline = nil;
	// world effects (d3d9_worldfx.mm): ambient occlusion, bloom, haze on the 3D scene before the interface
	struct WorldFX
	{
		id<MTLLibrary> lib = nil;
		std::unordered_map<std::string, id<MTLRenderPipelineState>> pipes;
		id<MTLTexture> scene = nil, ao = nil, aoBlur = nil, world = nil;
		float rect[4] = {};          // where the world was copied on screen, back-buffer pixels
		uint64_t worldPresent = ~0ull;   // presentCount when it was made (HDR uses it only in that frame)
		id<MTLTexture> bloom[6] = {};
		uint32_t frame = 0;
		NSUInteger sceneWidth = 0, sceneHeight = 0;
		uint64_t scenePresent = ~0ull;
	} wfx;
	void WorldEffects(const float *clipToWorld, const float *worldToClip, const float *screenRect);
	uint64_t presentCount = 0;
	float hdrHeadroom = 0;
	id<MTLRenderPipelineState> presentPipelineHDR = nil;
	id<MTLRenderPipelineState> WfxPipe(const char *fn, MTLPixelFormat fmt, bool additive);
	id<MTLRenderPipelineState> fxaaPipeline = nil;   // FXAA at game resolution, before upscaling
	id<MTLTexture> fxaaTex = nil;
	id<MTLSamplerState> presentLinear = nil, presentNearest = nil;
	uint64_t lastPresentNs = 0;
	struct { int srcW, srcH, outW, outH; const char *how; } frameInfo = { 0, 0, 0, 0, "" };
	uint32_t samplerGeneration = 0;
	id<MTLFXSpatialScaler> scaler = nil;      // MetalFX upscale from the game resolution to the window's pixels
	id<MTLTexture> upscaled = nil;
	id<MTLTexture> diagnosticPresent = nil;  // offscreen SDR target, only with S2_HEADLESS_PRESENT
	id<MTLTexture> gammaLUT = nil;
	id<MTLTexture> dummy2D = nil, dummyCube = nil;
	id<MTLTexture> lastFrame = nil;            // last presented image, for GetFrontBufferData

	// diagnostics: "_dump.req" in the game folder logs the next frame's draws to "_draws.txt"
	FILE *dumpFile = nullptr;
	// S2_PERF=1: frame-time statistics every 2 s to _perf.txt (frames, mean/max ms, frames over 33 ms, new pipelines)
	uint64_t perfStart = 0, perfLast = 0; int perfFrames = 0, perfSlow = 0, perfNewPipelines = 0; double perfMax = 0, perfSum = 0;
	int dumpDraws = 0;
	void DumpDraw(const char *kind, UINT first, UINT count, INT base, bool indexed);

	// occlusion queries
	id<MTLBuffer> visibility = nil;
	std::vector<int> freeVisibilitySlots;
	Query *activeQuery = nullptr;

	Device(Direct3D *d, HWND w, const D3DPRESENT_PARAMETERS &p);
	~Device();
	bool CreateSwapResources();
	void BeginFrame();
	void EnsurePass();
	void EndPass();
	void Submit(bool wait);
	void WaitForSerial(uint64_t s);
	void ApplyState();
	id<MTLFunction> Function(const std::string &src, const char *name);
	std::mutex functionLock;
	id<MTLSamplerState> Sampler(int stage);
	VertexDecl *DeclForFVF(DWORD fvf);
	id<MTLTexture> ReadbackTexture(id<MTLTexture> t, std::vector<BYTE> *out, size_t *pitch);
	void SetDefaults();

	// IDirect3DDevice9
	HRESULT TestCooperativeLevel() override { return D3D_OK; }
	UINT GetAvailableTextureMem() override { return 0x60000000u; }
	HRESULT EvictManagedResources() override { return D3D_OK; }
	HRESULT GetDirect3D(IDirect3D9 **ppD3D9) override;
	HRESULT GetDeviceCaps(D3DCAPS9 *pCaps) override;
	HRESULT GetDisplayMode(UINT iSwapChain, D3DDISPLAYMODE *pMode) override;
	HRESULT GetCreationParameters(D3DDEVICE_CREATION_PARAMETERS *p) override;
	HRESULT SetCursorProperties(UINT, UINT, IDirect3DSurface9 *) override { return D3D_OK; }
	void SetCursorPosition(int, int, DWORD) override {}
	WINBOOL ShowCursor(WINBOOL) override { return FALSE; }
	HRESULT Reset(D3DPRESENT_PARAMETERS *pPresentationParameters) override;
	HRESULT Present(const RECT *, const RECT *, HWND, const RGNDATA *) override;
	HRESULT GetBackBuffer(UINT iSwapChain, UINT iBackBuffer, D3DBACKBUFFER_TYPE Type, IDirect3DSurface9 **ppBackBuffer) override;
	HRESULT GetRasterStatus(UINT, D3DRASTER_STATUS *p) override { memset(p, 0, sizeof *p); return D3D_OK; }
	HRESULT SetDialogBoxMode(WINBOOL) override { return D3D_OK; }
	void SetGammaRamp(UINT iSwapChain, DWORD Flags, const D3DGAMMARAMP *pRamp) override;
	void GetGammaRamp(UINT iSwapChain, D3DGAMMARAMP *pRamp) override { *pRamp = gamma; }
	HRESULT CreateTexture(UINT Width, UINT Height, UINT Levels, DWORD Usage, D3DFORMAT Format, D3DPOOL Pool, IDirect3DTexture9 **ppTexture, HANDLE *pSharedHandle) override;
	HRESULT CreateCubeTexture(UINT EdgeLength, UINT Levels, DWORD Usage, D3DFORMAT Format, D3DPOOL Pool, IDirect3DCubeTexture9 **ppCubeTexture, HANDLE *pSharedHandle) override;
	HRESULT CreateVertexBuffer(UINT Length, DWORD Usage, DWORD FVF, D3DPOOL Pool, IDirect3DVertexBuffer9 **ppVertexBuffer, HANDLE *pSharedHandle) override;
	HRESULT CreateIndexBuffer(UINT Length, DWORD Usage, D3DFORMAT Format, D3DPOOL Pool, IDirect3DIndexBuffer9 **ppIndexBuffer, HANDLE *pSharedHandle) override;
	HRESULT CreateRenderTarget(UINT Width, UINT Height, D3DFORMAT Format, D3DMULTISAMPLE_TYPE MultiSample, DWORD MultisampleQuality, WINBOOL Lockable, IDirect3DSurface9 **ppSurface, HANDLE *pSharedHandle) override;
	HRESULT CreateDepthStencilSurface(UINT Width, UINT Height, D3DFORMAT Format, D3DMULTISAMPLE_TYPE MultiSample, DWORD MultisampleQuality, WINBOOL Discard, IDirect3DSurface9 **ppSurface, HANDLE *pSharedHandle) override;
	HRESULT UpdateSurface(IDirect3DSurface9 *pSourceSurface, const RECT *pSourceRect, IDirect3DSurface9 *pDestinationSurface, const POINT *pDestPoint) override;
	HRESULT UpdateTexture(IDirect3DBaseTexture9 *pSourceTexture, IDirect3DBaseTexture9 *pDestinationTexture) override;
	HRESULT GetRenderTargetData(IDirect3DSurface9 *pRenderTarget, IDirect3DSurface9 *pDestSurface) override;
	HRESULT GetFrontBufferData(UINT iSwapChain, IDirect3DSurface9 *pDestSurface) override;
	HRESULT StretchRect(IDirect3DSurface9 *pSourceSurface, const RECT *pSourceRect, IDirect3DSurface9 *pDestSurface, const RECT *pDestRect, D3DTEXTUREFILTERTYPE Filter) override;
	HRESULT ColorFill(IDirect3DSurface9 *pSurface, const RECT *pRect, D3DCOLOR color) override;
	HRESULT CreateOffscreenPlainSurface(UINT Width, UINT Height, D3DFORMAT Format, D3DPOOL Pool, IDirect3DSurface9 **ppSurface, HANDLE *pSharedHandle) override;
	HRESULT SetRenderTarget(DWORD RenderTargetIndex, IDirect3DSurface9 *pRenderTarget) override;
	HRESULT GetRenderTarget(DWORD RenderTargetIndex, IDirect3DSurface9 **ppRenderTarget) override;
	HRESULT SetDepthStencilSurface(IDirect3DSurface9 *pNewZStencil) override;
	HRESULT GetDepthStencilSurface(IDirect3DSurface9 **ppZStencilSurface) override;
	HRESULT BeginScene() override { return D3D_OK; }
	HRESULT EndScene() override { return D3D_OK; }
	HRESULT Clear(DWORD Count, const D3DRECT *pRects, DWORD Flags, D3DCOLOR Color, float Z, DWORD Stencil) override;
	HRESULT SetTransform(D3DTRANSFORMSTATETYPE State, const D3DMATRIX *pMatrix) override;
	HRESULT GetTransform(D3DTRANSFORMSTATETYPE State, D3DMATRIX *pMatrix) override;
	HRESULT MultiplyTransform(D3DTRANSFORMSTATETYPE, const D3DMATRIX *) override;
	HRESULT SetViewport(const D3DVIEWPORT9 *pViewport) override;
	HRESULT GetViewport(D3DVIEWPORT9 *pViewport) override { *pViewport = viewport; return D3D_OK; }
	HRESULT SetMaterial(const D3DMATERIAL9 *pMaterial) override { material = *pMaterial; return D3D_OK; }
	HRESULT GetMaterial(D3DMATERIAL9 *pMaterial) override { *pMaterial = material; return D3D_OK; }
	HRESULT SetLight(DWORD Index, const D3DLIGHT9 *pLight) override { if (Index < 8) lights[Index] = *pLight; return D3D_OK; }
	HRESULT GetLight(DWORD Index, D3DLIGHT9 *pLight) override { if (Index < 8) *pLight = lights[Index]; return D3D_OK; }
	HRESULT LightEnable(DWORD Index, WINBOOL Enable) override { if (Index < 8) lightEnabled[Index] = Enable; return D3D_OK; }
	HRESULT GetLightEnable(DWORD Index, WINBOOL *pEnable) override { *pEnable = Index < 8 ? lightEnabled[Index] : FALSE; return D3D_OK; }
	HRESULT SetClipPlane(DWORD, const float *) override { return D3D_OK; }
	HRESULT SetRenderState(D3DRENDERSTATETYPE State, DWORD Value) override;
	HRESULT GetRenderState(D3DRENDERSTATETYPE State, DWORD *pValue) override { *pValue = State < 256 ? rs[State] : 0; return D3D_OK; }
	HRESULT SetClipStatus(const D3DCLIPSTATUS9 *) override { return D3D_OK; }
	HRESULT GetTexture(DWORD Stage, IDirect3DBaseTexture9 **ppTexture) override;
	HRESULT SetTexture(DWORD Stage, IDirect3DBaseTexture9 *pTexture) override;
	HRESULT GetTextureStageState(DWORD Stage, D3DTEXTURESTAGESTATETYPE Type, DWORD *pValue) override { *pValue = (Stage < 8 && Type < 33) ? tss[Stage][Type] : 0; return D3D_OK; }
	HRESULT SetTextureStageState(DWORD Stage, D3DTEXTURESTAGESTATETYPE Type, DWORD Value) override { if (Stage < 8 && Type < 33) tss[Stage][Type] = Value; return D3D_OK; }
	HRESULT GetSamplerState(DWORD Sampler, D3DSAMPLERSTATETYPE Type, DWORD *pValue) override { *pValue = (Sampler < 8 && Type < 14) ? samp[Sampler][Type] : 0; return D3D_OK; }
	HRESULT SetSamplerState(DWORD Sampler, D3DSAMPLERSTATETYPE Type, DWORD Value) override { if (Sampler < 8 && Type < 14) samp[Sampler][Type] = Value; return D3D_OK; }
	HRESULT ValidateDevice(DWORD *pNumPasses) override { if (pNumPasses) *pNumPasses = 1; return D3D_OK; }
	HRESULT SetScissorRect(const RECT *pRect) override { scissor = *pRect; return D3D_OK; }
	HRESULT GetScissorRect(RECT *pRect) override { *pRect = scissor; return D3D_OK; }
	HRESULT SetSoftwareVertexProcessing(WINBOOL) override { return D3D_OK; }
	WINBOOL GetSoftwareVertexProcessing() override { return FALSE; }
	HRESULT DrawPrimitive(D3DPRIMITIVETYPE PrimitiveType, UINT StartVertex, UINT PrimitiveCount) override;
	HRESULT DrawIndexedPrimitive(D3DPRIMITIVETYPE PrimitiveType, INT BaseVertexIndex, UINT MinVertexIndex, UINT NumVertices, UINT startIndex, UINT primCount) override;
	HRESULT DrawPrimitiveUP(D3DPRIMITIVETYPE PrimitiveType, UINT PrimitiveCount, const void *pVertexStreamZeroData, UINT VertexStreamZeroStride) override;
	HRESULT DrawIndexedPrimitiveUP(D3DPRIMITIVETYPE PrimitiveType, UINT MinVertexIndex, UINT NumVertices, UINT PrimitiveCount, const void *pIndexData, D3DFORMAT IndexDataFormat, const void *pVertexStreamZeroData, UINT VertexStreamZeroStride) override;
	HRESULT CreateVertexDeclaration(const D3DVERTEXELEMENT9 *pVertexElements, IDirect3DVertexDeclaration9 **ppDecl) override;
	HRESULT SetVertexDeclaration(IDirect3DVertexDeclaration9 *pDecl) override;
	HRESULT GetVertexDeclaration(IDirect3DVertexDeclaration9 **ppDecl) override;
	HRESULT SetFVF(DWORD FVF) override;
	HRESULT GetFVF(DWORD *pFVF) override { *pFVF = fvf; return D3D_OK; }
	HRESULT CreateVertexShader(const DWORD *pFunction, IDirect3DVertexShader9 **ppShader) override;
	HRESULT SetVertexShader(IDirect3DVertexShader9 *pShader) override;
	HRESULT GetVertexShader(IDirect3DVertexShader9 **ppShader) override;
	HRESULT SetVertexShaderConstantF(UINT StartRegister, const float *pConstantData, UINT Vector4fCount) override;
	HRESULT GetVertexShaderConstantF(UINT StartRegister, float *pConstantData, UINT Vector4fCount) override;
	HRESULT SetStreamSource(UINT StreamNumber, IDirect3DVertexBuffer9 *pStreamData, UINT OffsetInBytes, UINT Stride) override;
	HRESULT GetStreamSource(UINT StreamNumber, IDirect3DVertexBuffer9 **ppStreamData, UINT *pOffsetInBytes, UINT *pStride) override;
	HRESULT SetStreamSourceFreq(UINT, UINT) override { return D3D_OK; }
	HRESULT SetIndices(IDirect3DIndexBuffer9 *pIndexData) override;
	HRESULT GetIndices(IDirect3DIndexBuffer9 **ppIndexData) override;
	HRESULT CreatePixelShader(const DWORD *pFunction, IDirect3DPixelShader9 **ppShader) override;
	HRESULT SetPixelShader(IDirect3DPixelShader9 *pShader) override;
	HRESULT GetPixelShader(IDirect3DPixelShader9 **ppShader) override;
	HRESULT SetPixelShaderConstantF(UINT StartRegister, const float *pConstantData, UINT Vector4fCount) override;
	HRESULT GetPixelShaderConstantF(UINT StartRegister, float *pConstantData, UINT Vector4fCount) override;
	HRESULT CreateQuery(D3DQUERYTYPE Type, IDirect3DQuery9 **ppQuery) override;
	UINT GetNumberOfSwapChains() override { return 1; }
};

struct Direct3D : RefCounted<StubIDirect3D9>
{
	id<MTLDevice> mtl = nil;
	std::vector<D3DDISPLAYMODE> modes;
	Direct3D();
	HRESULT RegisterSoftwareDevice(void *) override { return D3D_OK; }
	UINT GetAdapterCount() override { return 1; }
	HRESULT GetAdapterIdentifier(UINT Adapter, DWORD Flags, D3DADAPTER_IDENTIFIER9 *pIdentifier) override;
	UINT GetAdapterModeCount(UINT Adapter, D3DFORMAT Format) override;
	HRESULT EnumAdapterModes(UINT Adapter, D3DFORMAT Format, UINT Mode, D3DDISPLAYMODE *pMode) override;
	HRESULT GetAdapterDisplayMode(UINT Adapter, D3DDISPLAYMODE *pMode) override;
	HRESULT CheckDeviceType(UINT, D3DDEVTYPE, D3DFORMAT, D3DFORMAT, WINBOOL) override { return D3D_OK; }
	HRESULT CheckDeviceFormat(UINT Adapter, D3DDEVTYPE DeviceType, D3DFORMAT AdapterFormat, DWORD Usage, D3DRESOURCETYPE RType, D3DFORMAT CheckFormat) override;
	HRESULT CheckDeviceMultiSampleType(UINT Adapter, D3DDEVTYPE DeviceType, D3DFORMAT SurfaceFormat, WINBOOL Windowed, D3DMULTISAMPLE_TYPE MultiSampleType, DWORD *pQualityLevels) override;
	HRESULT CheckDepthStencilMatch(UINT, D3DDEVTYPE, D3DFORMAT, D3DFORMAT, D3DFORMAT) override { return D3D_OK; }
	HRESULT CheckDeviceFormatConversion(UINT, D3DDEVTYPE, D3DFORMAT, D3DFORMAT) override { return D3D_OK; }
	HRESULT GetDeviceCaps(UINT Adapter, D3DDEVTYPE DeviceType, D3DCAPS9 *pCaps) override;
	HMONITOR GetAdapterMonitor(UINT) override { return (HMONITOR)(intptr_t)1; }
	HRESULT CreateDevice(UINT Adapter, D3DDEVTYPE DeviceType, HWND hFocusWindow, DWORD BehaviorFlags, D3DPRESENT_PARAMETERS *pPresentationParameters, IDirect3DDevice9 **ppReturnedDeviceInterface) override;
};

} // namespace s2gfx

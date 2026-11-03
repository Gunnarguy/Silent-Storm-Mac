// d3d9_worldfx.mm: effects on the 3D world only, run by the engine between drawing the scene into its off-screen
// "register 0" and copying that onto the screen (Main/GView.cpp, CGameView::Draw). The interface is drawn afterwards,
// so text and HUD stay untouched.
//
//  - Ambient occlusion: world positions rebuilt from the 32-bit scene depth with the engine's own inverse clip matrix,
//    16 hemisphere samples at half resolution, a depth-aware 4x4 blur, applied as darkening (after Crytek/McGuire SSAO).
//  - Bloom: soft-knee bright pass with a Karis average, a 6-level 13-tap downsample chain and a tent upsample
//    (after Jimenez, "Next Generation Post Processing in Call of Duty: Advanced Warfare", SIGGRAPH 2014).
//  - Haze: distance-based blend towards a fixed warm-grey horizon colour.
#import <Metal/Metal.h>
#include "d3d9_metal.h"
#include "s2settings.h"
#include <cmath>

namespace s2gfx {
extern Device *s2currentDevice;

static const char *kWorldFX = R"MSL(
#include <metal_stdlib>
using namespace metal;
struct V { float4 p [[position]]; float2 uv; };
vertex V wv(uint id [[vertex_id]]) { float2 t = float2((id << 1) & 2, id & 2); V o; o.p = float4(t * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = t; return o; }
constant float3 kLuma = float3(0.2126, 0.7152, 0.0722);

struct AOP { float4x4 inv, fwd; float2 texel; float radius, strength; uint frame; float pad[3]; };

// engine matrices are row-major with column vectors; passed as-is they read as their transpose here, so v * m
static float3 Recon(float2 uv, float d, float4x4 inv)
{
	float4 w = float4(uv.x * 2 - 1, 1 - uv.y * 2, d, 1) * inv;
	return w.xyz / w.w;
}

fragment float ao(V in [[stage_in]], depth2d<float> dt [[texture(0)]], constant AOP &p [[buffer(0)]])
{
	constexpr sampler ps(filter::nearest, address::clamp_to_edge);
	float d = dt.sample(ps, in.uv);
	if (d >= 0.99999) return 1;
	float3 P = Recon(in.uv, d, p.inv);
	// normal from the neighbour on each axis with the smaller depth step (no smearing across silhouettes)
	float2 tx = p.texel;
	float dl = dt.sample(ps, in.uv - float2(tx.x, 0)), dr = dt.sample(ps, in.uv + float2(tx.x, 0));
	float du = dt.sample(ps, in.uv - float2(0, tx.y)), dd = dt.sample(ps, in.uv + float2(0, tx.y));
	float3 Px = abs(dr - d) < abs(dl - d) ? Recon(in.uv + float2(tx.x, 0), dr, p.inv) - P : P - Recon(in.uv - float2(tx.x, 0), dl, p.inv);
	float3 Py = abs(dd - d) < abs(du - d) ? Recon(in.uv + float2(0, tx.y), dd, p.inv) - P : P - Recon(in.uv - float2(0, tx.y), du, p.inv);
	float3 N = normalize(cross(Px, Py));
	float3 toEye = Recon(in.uv, 0, p.inv) - P;
	if (dot(N, toEye) < 0) N = -N;
	// per-pixel rotation from a 4x4 interleaved pattern (removed exactly by the 4x4 blur). It must not change from
	// frame to frame: nothing accumulates frames here, so a moving pattern only makes contact shadows shimmer.
	int2 q = int2(in.p.xy) & 3;
	float ang = (float(q.x * 4 + q.y) + 0.5) * (6.2831853 / 16.0);
	float3 up = abs(N.z) < 0.9 ? float3(0, 0, 1) : float3(1, 0, 0);
	float3 T = normalize(cross(up, N)), B = cross(N, T);
	float c = cos(ang), s = sin(ang);
	float3 T2 = T * c + B * s, B2 = B * c - T * s;
	float occ = 0;
	const int n = 16;
	for (int i = 0; i < n; ++i)
	{
		// spiral hemisphere kernel, denser near the centre
		float fi = (float(i) + 0.5) / float(n);
		float r = mix(0.12, 1.0, fi * fi);
		float a = float(i) * 2.39996;
		float z = sqrt(1 - fi * 0.85);
		float rr = sqrt(max(0.0, 1 - z * z));
		float3 dir = T2 * (cos(a) * rr) + B2 * (sin(a) * rr) + N * z;
		float3 S = P + dir * (r * p.radius);
		float4 cs = float4(S, 1) * p.fwd;
		if (cs.w <= 0) continue;
		float3 ndc = cs.xyz / cs.w;
		float2 uvS = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
		if (any(uvS < 0) || any(uvS > 1)) continue;
		float dS = dt.sample(ps, uvS);
		float3 Q = Recon(uvS, dS, p.inv);
		float range = smoothstep(0.0, 1.0, p.radius / max(length(Q - P), 1e-4));
		occ += (dS < ndc.z - 2e-6 ? 1.0 : 0.0) * range;
	}
	float a = 1 - occ / float(n);
	return saturate(pow(a, p.strength * 1.6));
}

struct BlurP { float2 texel; };
fragment float aoblur(V in [[stage_in]], texture2d<float> a [[texture(0)]], depth2d<float> dt [[texture(1)]], constant BlurP &p [[buffer(0)]])
{
	constexpr sampler ps(filter::nearest, address::clamp_to_edge);
	float d0 = dt.sample(ps, in.uv);
	float sum = 0, wsum = 0;
	for (int y = -2; y < 2; ++y)
		for (int x = -2; x < 2; ++x)
		{
			float2 o = (float2(x, y) + 0.5) * p.texel;
			float d = dt.sample(ps, in.uv + o);
			float w = 1.0 / (1e-6 + abs(d - d0) * 4000.0);
			w = min(w, 1.0);
			sum += a.sample(ps, in.uv + o).r * w; wsum += w;
		}
	return wsum > 0 ? sum / wsum : 1;
}

struct BloomP { float2 texel; float threshold, knee; uint prefilter; float pad[3]; };
static float3 Prefilter(float3 c, float threshold, float knee)
{
	float br = max3(c.r, c.g, c.b);
	float rq = clamp(br - threshold + knee, 0.0, 2 * knee);
	rq = rq * rq / (4 * knee + 1e-5);
	return c * max(rq, br - threshold) / max(br, 1e-5);
}
fragment float4 bdown(V in [[stage_in]], texture2d<float> t [[texture(0)]], constant BloomP &p [[buffer(0)]])
{
	constexpr sampler ls(filter::linear, address::clamp_to_edge);
	float2 x = p.texel;
	float3 a = t.sample(ls, in.uv + x * float2(-2, -2)).rgb, b = t.sample(ls, in.uv + x * float2(0, -2)).rgb, c = t.sample(ls, in.uv + x * float2(2, -2)).rgb;
	float3 d = t.sample(ls, in.uv + x * float2(-2, 0)).rgb, e = t.sample(ls, in.uv).rgb, f = t.sample(ls, in.uv + x * float2(2, 0)).rgb;
	float3 g = t.sample(ls, in.uv + x * float2(-2, 2)).rgb, h = t.sample(ls, in.uv + x * float2(0, 2)).rgb, i = t.sample(ls, in.uv + x * float2(2, 2)).rgb;
	float3 j = t.sample(ls, in.uv + x * float2(-1, -1)).rgb, k = t.sample(ls, in.uv + x * float2(1, -1)).rgb;
	float3 l = t.sample(ls, in.uv + x * float2(-1, 1)).rgb, m = t.sample(ls, in.uv + x * float2(1, 1)).rgb;
	if (p.prefilter != 0)
	{
		// Karis average on the first level keeps single bright pixels from flickering
		float3 g0 = (a + b + d + e) * 0.25, g1 = (b + c + e + f) * 0.25, g2 = (d + e + g + h) * 0.25, g3 = (e + f + h + i) * 0.25, g4 = (j + k + l + m) * 0.25;
		float w0 = 1 / (1 + dot(g0, kLuma)), w1 = 1 / (1 + dot(g1, kLuma)), w2 = 1 / (1 + dot(g2, kLuma)), w3 = 1 / (1 + dot(g3, kLuma)), w4 = 1 / (1 + dot(g4, kLuma));
		float3 r = (g0 * w0 * 0.125 + g1 * w1 * 0.125 + g2 * w2 * 0.125 + g3 * w3 * 0.125 + g4 * w4 * 0.5) / (w0 * 0.125 + w1 * 0.125 + w2 * 0.125 + w3 * 0.125 + w4 * 0.5);
		return float4(Prefilter(r, p.threshold, p.knee), 1);
	}
	float3 r = e * 0.125 + (a + c + g + i) * 0.03125 + (b + d + f + h) * 0.0625 + (j + k + l + m) * 0.125;
	return float4(r, 1);
}
fragment float4 bup(V in [[stage_in]], texture2d<float> t [[texture(0)]], constant BloomP &p [[buffer(0)]])
{
	constexpr sampler ls(filter::linear, address::clamp_to_edge);
	float2 x = p.texel;
	float3 r = t.sample(ls, in.uv).rgb * 4;
	r += (t.sample(ls, in.uv + float2(-x.x, 0)).rgb + t.sample(ls, in.uv + float2(x.x, 0)).rgb + t.sample(ls, in.uv + float2(0, -x.y)).rgb + t.sample(ls, in.uv + float2(0, x.y)).rgb) * 2;
	r += t.sample(ls, in.uv + float2(-x.x, -x.y)).rgb + t.sample(ls, in.uv + float2(x.x, -x.y)).rgb + t.sample(ls, in.uv + float2(-x.x, x.y)).rgb + t.sample(ls, in.uv + float2(x.x, x.y)).rgb;
	return float4(r / 16, 1);
}

struct CompP { float4x4 inv; float aoOn, bloom, haze, debug; float4 hazeColor; };
fragment float4 wcomp(V in [[stage_in]], texture2d<float> scene [[texture(0)]], texture2d<float> aot [[texture(1)]], texture2d<float> bl [[texture(2)]],
	depth2d<float> dt [[texture(3)]], constant CompP &p [[buffer(0)]])
{
	constexpr sampler ps(filter::nearest, address::clamp_to_edge);
	constexpr sampler ls(filter::linear, address::clamp_to_edge);
	float4 c = scene.sample(ps, in.uv);
	// debug 1: the occlusion buffer; debug 2: split screen, original on the left
	if (p.debug > 1.5 && in.uv.x < 0.5) return abs(in.uv.x - 0.5) < 0.0008 ? float4(1, 1, 1, c.a) : c;
	float a = p.aoOn > 0 ? aot.sample(ls, in.uv).r : 1;
	if (p.debug > 0.5 && p.debug < 1.5) return float4(a, a, a, c.a);
	float3 r = c.rgb * a;
	if (p.haze > 0)
	{
		float d = dt.sample(ps, in.uv);
		if (d < 0.99999)
		{
			float3 P = Recon(in.uv, d, p.inv), E = Recon(in.uv, 0, p.inv);
			float dist = length(P - E);
			float h = 1 - exp(-dist * 0.012 * p.haze);
			r = mix(r, p.hazeColor.rgb, saturate(h) * 0.85);
		}
	}
	// the upsample chain sums six levels; average them so strength 1 adds the full glow once
	if (p.bloom > 0) r += bl.sample(ls, in.uv).rgb * (p.bloom / 6.0);
	return float4(r, c.a);
}
)MSL";

id<MTLRenderPipelineState> Device::WfxPipe(const char *fn, MTLPixelFormat fmt, bool additive)
{
	std::string key = std::string(fn) + "/" + std::to_string((int)fmt) + (additive ? "+" : "");
	auto it = wfx.pipes.find(key);
	if (it != wfx.pipes.end()) return it->second;
	if (!wfx.lib)
	{
		NSError *err = nil;
		wfx.lib = [mtl newLibraryWithSource:@(kWorldFX) options:[MTLCompileOptions new] error:&err];
		if (!wfx.lib) { fprintf(stderr, "[worldfx] %s\n", err.localizedDescription.UTF8String); return nil; }
	}
	MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
	d.vertexFunction = [wfx.lib newFunctionWithName:@"wv"];
	d.fragmentFunction = [wfx.lib newFunctionWithName:@(fn)];
	d.colorAttachments[0].pixelFormat = fmt;
	if (additive)
	{
		d.colorAttachments[0].blendingEnabled = YES;
		d.colorAttachments[0].sourceRGBBlendFactor = d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
		d.colorAttachments[0].sourceAlphaBlendFactor = d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
	}
	NSError *err = nil;
	id<MTLRenderPipelineState> ps = [mtl newRenderPipelineStateWithDescriptor:d error:&err];
	if (!ps) fprintf(stderr, "[worldfx] %s: %s\n", fn, err.localizedDescription.UTF8String);
	wfx.pipes[key] = ps;
	return ps;
}

static id<MTLTexture> Ensure(id<MTLDevice> mtl, id<MTLTexture> t, MTLPixelFormat f, NSUInteger w, NSUInteger h)
{
	w = std::max<NSUInteger>(w, 1); h = std::max<NSUInteger>(h, 1);
	if (t && t.width == w && t.height == h && t.pixelFormat == f) return t;
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
	d.storageMode = MTLStorageModePrivate;
	d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	return [mtl newTextureWithDescriptor:d];
}

void Device::WorldEffects(const float *clipToWorld, const float *worldToClip, const float *screenRect)
{
	const S2Settings &cfg = g_s2;
	if (getenv("S2_RENDER_AUDIT") && rt && rt->Texture())
	{
		wfx.sceneWidth = rt->Texture().width; wfx.sceneHeight = rt->Texture().height;
		wfx.scenePresent = presentCount;
	}
	bool aoOn = cfg.ao && cfg.aoStrength > 0, bloomOn = cfg.bloom && cfg.bloomStrength > 0, hazeOn = cfg.haze > 0;
	if (!aoOn && !bloomOn && !hazeOn && !cfg.worldFxDebug && !cfg.edr) return;
	std::lock_guard<std::recursive_mutex> l(lock);
	static int logged;
	if (!rt || !ds || !rt->Texture() || !ds->Texture()) { if (logged++ < 3) fprintf(stderr, "[worldfx] no target (rt %p ds %p)\n", rt, ds); return; }
	id<MTLTexture> color = rt->Texture(), depth = ds->Texture();
	if (color.pixelFormat != MTLPixelFormatBGRA8Unorm || depth.width != color.width || depth.height != color.height)
	{
		if (logged++ < 3) fprintf(stderr, "[worldfx] skipped: color %lux%lu fmt %lu, depth %lux%lu\n", (unsigned long)color.width, (unsigned long)color.height, (unsigned long)color.pixelFormat, (unsigned long)depth.width, (unsigned long)depth.height);
		return;
	}
	if (!logged++) fprintf(stderr, "[worldfx] active on %lux%lu\n", (unsigned long)color.width, (unsigned long)color.height);
	EndPass();
	BeginFrame();
	NSUInteger W = color.width, H = color.height;
	++wfx.frame;

	wfx.scene = Ensure(mtl, wfx.scene, MTLPixelFormatBGRA8Unorm, W, H);
	id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
	[blit copyFromTexture:color toTexture:wfx.scene];
	[blit endEncoding];

	auto pass = [&](id<MTLTexture> target, id<MTLRenderPipelineState> ps, bool load, void (^bind)(id<MTLRenderCommandEncoder>)) {
		if (!ps) return;
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
		rp.colorAttachments[0].texture = target;
		rp.colorAttachments[0].loadAction = load ? MTLLoadActionLoad : MTLLoadActionDontCare;
		rp.colorAttachments[0].storeAction = MTLStoreActionStore;
		id<MTLRenderCommandEncoder> e = [cmd renderCommandEncoderWithDescriptor:rp];
		[e setRenderPipelineState:ps];
		bind(e);
		[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[e endEncoding];
	};

	if (aoOn || cfg.worldFxDebug)
	{
		NSUInteger aw = (W + 1) / 2, ah = (H + 1) / 2;
		wfx.ao = Ensure(mtl, wfx.ao, MTLPixelFormatR16Float, aw, ah);
		wfx.aoBlur = Ensure(mtl, wfx.aoBlur, MTLPixelFormatR16Float, aw, ah);
		struct { float inv[16], fwd[16]; float texel[2]; float radius, strength; uint32_t frame; float pad[3]; } ap;
		memcpy(ap.inv, clipToWorld, sizeof ap.inv); memcpy(ap.fwd, worldToClip, sizeof ap.fwd);
		ap.texel[0] = 1.0f / W; ap.texel[1] = 1.0f / H; ap.radius = cfg.aoRadius; ap.strength = cfg.aoStrength; ap.frame = wfx.frame;
		pass(wfx.ao, WfxPipe("ao", MTLPixelFormatR16Float, false), false, ^(id<MTLRenderCommandEncoder> e) {
			[e setFragmentTexture:depth atIndex:0]; [e setFragmentBytes:&ap length:sizeof ap atIndex:0]; });
		struct { float texel[2]; } bp = { { 1.0f / aw, 1.0f / ah } };
		id<MTLTexture> aoSrc = wfx.ao;
		pass(wfx.aoBlur, WfxPipe("aoblur", MTLPixelFormatR16Float, false), false, ^(id<MTLRenderCommandEncoder> e) {
			[e setFragmentTexture:aoSrc atIndex:0]; [e setFragmentTexture:depth atIndex:1]; [e setFragmentBytes:&bp length:sizeof bp atIndex:0]; });
	}

	if (bloomOn)
	{
		NSUInteger w = W, h = H;
		id<MTLTexture> src = wfx.scene;
		for (int i = 0; i < 6; ++i)
		{
			NSUInteger sw = w, sh = h;
			w = std::max<NSUInteger>(1, w / 2); h = std::max<NSUInteger>(1, h / 2);
			wfx.bloom[i] = Ensure(mtl, wfx.bloom[i], MTLPixelFormatRGBA16Float, w, h);
			struct { float texel[2]; float threshold, knee; uint32_t prefilter; float pad[3]; } bp = { { 1.0f / sw, 1.0f / sh }, cfg.bloomThreshold, 0.25f, i == 0 ? 1u : 0u, {} };
			id<MTLTexture> s = src;
			pass(wfx.bloom[i], WfxPipe("bdown", MTLPixelFormatRGBA16Float, false), false, ^(id<MTLRenderCommandEncoder> e) {
				[e setFragmentTexture:s atIndex:0]; [e setFragmentBytes:&bp length:sizeof bp atIndex:0]; });
			src = wfx.bloom[i];
		}
		for (int i = 5; i > 0; --i)
		{
			struct { float texel[2]; float threshold, knee; uint32_t prefilter; float pad[3]; } bp = { { 1.0f / wfx.bloom[i].width, 1.0f / wfx.bloom[i].height }, 0, 0, 0, {} };
			id<MTLTexture> s = wfx.bloom[i];
			pass(wfx.bloom[i - 1], WfxPipe("bup", MTLPixelFormatRGBA16Float, true), true, ^(id<MTLRenderCommandEncoder> e) {
				[e setFragmentTexture:s atIndex:0]; [e setFragmentBytes:&bp length:sizeof bp atIndex:0]; });
		}
	}

	struct { float inv[16]; float aoOn, bloom, haze, debug; float hazeColor[4]; } cp;
	memcpy(cp.inv, clipToWorld, sizeof cp.inv);
	cp.aoOn = (aoOn || cfg.worldFxDebug == 1) ? 1 : 0; cp.bloom = bloomOn ? cfg.bloomStrength : 0; cp.haze = cfg.haze; cp.debug = (float)cfg.worldFxDebug;
	// horizon colour: a warm grey; the scene's own sky is not known here
	cp.hazeColor[0] = 0.62f; cp.hazeColor[1] = 0.64f; cp.hazeColor[2] = 0.66f; cp.hazeColor[3] = 1;
	id<MTLTexture> sceneT = wfx.scene, aoT = wfx.aoBlur ?: wfx.scene, blT = wfx.bloom[0] ?: wfx.scene;
	pass(color, WfxPipe("wcomp", MTLPixelFormatBGRA8Unorm, false), false, ^(id<MTLRenderCommandEncoder> e) {
		[e setFragmentTexture:sceneT atIndex:0]; [e setFragmentTexture:aoT atIndex:1]; [e setFragmentTexture:blT atIndex:2];
		[e setFragmentTexture:depth atIndex:3]; [e setFragmentBytes:&cp length:sizeof cp atIndex:0]; });
	// keep the finished world and where it lands on screen: Present uses it to find world pixels for HDR highlights
	wfx.world = Ensure(mtl, wfx.world, MTLPixelFormatBGRA8Unorm, W, H);
	blit = [cmd blitCommandEncoder];
	[blit copyFromTexture:color toTexture:wfx.world];
	[blit endEncoding];
	memcpy(wfx.rect, screenRect, sizeof wfx.rect);
	wfx.worldPresent = presentCount;
	passDirty = true;
}
} // namespace s2gfx

void S2WorldEffects(const float *clipToWorld, const float *worldToClip, const float *screenRect)
{
	if (s2gfx::s2currentDevice) s2gfx::s2currentDevice->WorldEffects(clipToWorld, worldToClip, screenRect);
}

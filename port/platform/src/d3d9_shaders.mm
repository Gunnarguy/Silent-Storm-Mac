// d3d9_shaders.mm: Direct3D 9 shader model 1.x bytecode and fixed-function texture stages, translated to
// Metal Shading Language. Instruction semantics follow the DirectX 9 SDK reference for vs_1_1 and ps_1_x.
#include "d3d9_metal.h"
#include <sstream>
#include <array>
#include <cmath>

namespace s2gfx {

// ---------------------------------------------------------------------------------------------------
// bytecode decoding
enum
{
	OP_NOP = 0, OP_MOV, OP_ADD, OP_SUB, OP_MAD, OP_MUL, OP_RCP, OP_RSQ, OP_DP3, OP_DP4, OP_MIN, OP_MAX, OP_SLT, OP_SGE, OP_EXP, OP_LOG,
	OP_LIT, OP_DST, OP_LRP, OP_FRC, OP_M4x4, OP_M4x3, OP_M3x4, OP_M3x3, OP_M3x2, OP_DCL = 31,
	OP_TEXCOORD = 64, OP_TEXKILL, OP_TEX, OP_TEXBEM, OP_TEXBEML, OP_TEXREG2AR, OP_TEXREG2GB, OP_TEXM3x2PAD, OP_TEXM3x2TEX, OP_TEXM3x3PAD,
	OP_TEXM3x3TEX, OP_TEXM3x3DIFF, OP_TEXM3x3SPEC, OP_TEXM3x3VSPEC, OP_EXPP, OP_LOGP, OP_CND, OP_DEF, OP_TEXREG2RGB, OP_TEXDP3TEX,
	OP_TEXM3x2DEPTH, OP_TEXDP3, OP_TEXM3x3, OP_TEXDEPTH, OP_CMP, OP_BEM,
	OP_PHASE = 0xFFFD, OP_COMMENT = 0xFFFE, OP_END = 0xFFFF
};
enum { RT_TEMP = 0, RT_INPUT = 1, RT_CONST = 2, RT_ADDR = 3, RT_TEXTURE = 3, RT_RASTOUT = 4, RT_ATTROUT = 5, RT_TEXCRDOUT = 6 };

struct Param { DWORD tok; int type() const { return ((tok >> 28) & 7) | ((tok >> 8) & 0x18); } int num() const { return tok & 0x7FF; } bool rel() const { return (tok >> 13) & 1; } };

static int SrcCount(int op)
{
	switch (op)
	{
	case OP_NOP: case OP_PHASE: return 0;
	case OP_MOV: case OP_RCP: case OP_RSQ: case OP_EXP: case OP_LOG: case OP_LIT: case OP_FRC: case OP_EXPP: case OP_LOGP: return 1;
	case OP_MAD: case OP_LRP: case OP_CND: case OP_CMP: return 3;
	case OP_TEXCOORD: case OP_TEXKILL: case OP_TEX: case OP_TEXDEPTH: return 0;
	case OP_TEXBEM: case OP_TEXBEML: case OP_TEXREG2AR: case OP_TEXREG2GB: case OP_TEXREG2RGB: case OP_TEXM3x2PAD: case OP_TEXM3x2TEX:
	case OP_TEXM3x3PAD: case OP_TEXM3x3TEX: case OP_TEXM3x3DIFF: case OP_TEXM3x3VSPEC: case OP_TEXDP3TEX: case OP_TEXM3x2DEPTH: case OP_TEXDP3: case OP_TEXM3x3: return 1;
	case OP_TEXM3x3SPEC: return 2;
	default: return 2;
	}
}
static bool HasDest(int op) { return op != OP_NOP && op != OP_PHASE && op != OP_END; }

static const char *Comp = "xyzw";
static std::string Swz(DWORD tok)
{
	int s = (tok >> 16) & 0xFF;
	if (s == 0xE4) return "";
	std::string r = ".";
	for (int i = 0; i < 4; ++i) r += Comp[(s >> (2 * i)) & 3];
	return r;
}
static std::string Mask(DWORD tok)
{
	int m = (tok >> 16) & 0xF;
	if (m == 0xF || m == 0) return ".xyzw";
	std::string r = ".";
	for (int i = 0; i < 4; ++i) if (m & (1 << i)) r += Comp[i];
	return r;
}
static std::string F(float f)
{
	if (std::isnan(f)) return "0.0";
	if (std::isinf(f)) return f > 0 ? "FLT_MAX" : "(-FLT_MAX)";
	char b[48]; snprintf(b, sizeof b, "%.9g", f);
	std::string s = b; if (s.find_first_of(".eE") == std::string::npos) s += ".0";
	return s;
}

// ===================================================================================================
// vertex shader 1.1
struct VSDecl { int reg, usage, index; };

static int FindElement(const VertexDecl &d, int usage, int index)
{
	for (size_t i = 0; i < d.elements.size(); ++i)
	{
		int u = d.elements[i].Usage;
		if (u == D3DDECLUSAGE_POSITIONT) u = D3DDECLUSAGE_POSITION;
		if (u == usage && d.elements[i].UsageIndex == index) return (int)i;
	}
	return -1;
}

std::string GenerateVertexShaderMSL(const Shader &vs, const VertexDecl &decl, uint32_t *)
{
	const DWORD *p = vs.code.data() + 1, *end = vs.code.data() + vs.code.size();
	std::vector<VSDecl> dcls;
	std::vector<std::pair<int, std::array<float, 4>>> defs;
	std::ostringstream body;
	bool usesRel = false;
	int maxConst = 95;

	auto src = [&](Param pr, bool scalar = false) -> std::string {
		std::string r;
		int t = pr.type(), n = pr.num();
		switch (t)
		{
		case RT_TEMP: r = "r[" + std::to_string(n) + "]"; break;
		case RT_INPUT: r = "v[" + std::to_string(n) + "]"; break;
		case RT_CONST:
			if (pr.rel()) { usesRel = true; r = "C(a0 + " + std::to_string(n) + ")"; }
			else r = "C(" + std::to_string(n) + ")";
			break;
		case RT_ADDR: r = "float4(a0)"; break;
		default: r = "float4(0)"; break;
		}
		r += Swz(pr.tok);
		int mod = (pr.tok >> 24) & 0xF;
		if (mod == 1) r = "(-" + r + ")";
		if (scalar) r = "(" + r + ").w";   // scalar ops read the replicated component (w when unswizzled)
		return r;
	};
	auto dst = [&](Param pr, bool *isAddr) -> std::string {
		int t = pr.type(), n = pr.num();
		*isAddr = false;
		switch (t)
		{
		case RT_TEMP: return "r[" + std::to_string(n) + "]";
		case RT_ADDR: *isAddr = true; return "a0";
		case RT_RASTOUT: return n == 0 ? "oPos" : n == 1 ? "oFog4" : "oPts4";
		case RT_ATTROUT: return n == 0 ? "oD0" : "oD1";
		case RT_TEXCRDOUT: return "oT[" + std::to_string(n & 7) + "]";
		default: return "junk";
		}
	};

	while (p < end && *p != 0x0000FFFF)
	{
		DWORD ins = *p++;
		int op = ins & 0xFFFF;
		if (op == OP_COMMENT) { p += (ins >> 16) & 0x7FFF; continue; }
		if (op == OP_DCL)
		{
			DWORD usageTok = *p++; Param d { *p++ };
			dcls.push_back({ d.num(), (int)(usageTok & 0x1F), (int)((usageTok >> 16) & 0xF) });
			continue;
		}
		if (op == OP_DEF)
		{
			Param d { *p++ }; std::array<float, 4> f; memcpy(f.data(), p, 16); p += 4;
			defs.push_back({ d.num(), f });
			continue;
		}
		int nsrc = SrcCount(op);
		Param d { HasDest(op) ? *p++ : 0 };
		Param s[3] = {};
		for (int i = 0; i < nsrc; ++i) { s[i].tok = *p++; if (s[i].rel() && (vs.version & 0xFFFF) >= 0x200) ++p; }
		bool addr = false;
		std::string D = HasDest(op) ? dst(d, &addr) : "", M = Mask(d.tok);
		std::string e;
		switch (op)
		{
		case OP_NOP: continue;
		case OP_MOV: e = src(s[0]); break;
		case OP_ADD: e = src(s[0]) + " + " + src(s[1]); break;
		case OP_SUB: e = src(s[0]) + " - " + src(s[1]); break;
		case OP_MUL: e = src(s[0]) + " * " + src(s[1]); break;
		case OP_MAD: e = src(s[0]) + " * " + src(s[1]) + " + " + src(s[2]); break;
		case OP_DP3: e = "float4(dot((" + src(s[0]) + ").xyz, (" + src(s[1]) + ").xyz))"; break;
		case OP_DP4: e = "float4(dot(" + src(s[0]) + ", " + src(s[1]) + "))"; break;
		case OP_MIN: e = "min(" + src(s[0]) + ", " + src(s[1]) + ")"; break;
		case OP_MAX: e = "max(" + src(s[0]) + ", " + src(s[1]) + ")"; break;
		case OP_SLT: e = "select(float4(0), float4(1), " + src(s[0]) + " < " + src(s[1]) + ")"; break;
		case OP_SGE: e = "select(float4(0), float4(1), " + src(s[0]) + " >= " + src(s[1]) + ")"; break;
		case OP_RCP: e = "float4(rcp1(" + src(s[0], true) + "))"; break;
		case OP_RSQ: e = "float4(rsq1(" + src(s[0], true) + "))"; break;
		case OP_EXP: e = "float4(exp2(" + src(s[0], true) + "))"; break;
		case OP_EXPP: e = "expp1(" + src(s[0], true) + ")"; break;
		case OP_LOG: case OP_LOGP: e = "float4(log1(" + src(s[0], true) + "))"; break;
		case OP_FRC: { std::string a = src(s[0]); e = a + " - floor(" + a + ")"; break; }
		case OP_LIT: e = "lit1(" + src(s[0]) + ")"; break;
		case OP_DST: e = "dst1(" + src(s[0]) + ", " + src(s[1]) + ")"; break;
		case OP_LRP: e = "mix(" + src(s[2]) + ", " + src(s[1]) + ", " + src(s[0]) + ")"; break;
		case OP_M4x4: case OP_M4x3: case OP_M3x4: case OP_M3x3: case OP_M3x2:
		{
			int rows = (op == OP_M4x4 || op == OP_M3x4) ? 4 : (op == OP_M4x3 || op == OP_M3x3) ? 3 : 2;
			bool four = op == OP_M4x4 || op == OP_M4x3;
			std::string a = src(s[0]);
			e = "float4(";
			for (int i = 0; i < 4; ++i)
			{
				if (i) e += ", ";
				if (i >= rows) { e += "0"; continue; }
				Param row = s[1]; row.tok = (row.tok & ~0x7FFu) | (DWORD)(row.num() + i);
				std::string b = src(row);
				e += four ? "dot(" + a + ", " + b + ")" : "dot((" + a + ").xyz, (" + b + ").xyz)";
			}
			e += ")";
			break;
		}
		default:
			fprintf(stderr, "[d3d9] vs opcode %d not translated\n", op);
			continue;
		}
		if (addr) body << "\ta0 = int(floor((" << e << ").x));\n";
		else
		{
			int sat = (d.tok >> 20) & 1;
			std::string v = "(" + e + ")";
			if (sat) v = "saturate" + v;
			body << "\t" << D << M << " = " << v << M << ";\n";
		}
	}

	std::ostringstream o;
	o << "#include <metal_stdlib>\nusing namespace metal;\n";
	o << "struct VIn {\n";
	std::vector<int> elemForReg(16, -1);
	for (auto &dc : dcls)
	{
		int e = FindElement(decl, dc.usage, dc.index);
		if (e >= 0 && dc.reg < 16) { elemForReg[dc.reg] = e; o << "\tfloat4 a" << e << " [[attribute(" << e << ")]];\n"; }
	}
	o << "\tfloat4 unused_ [[attribute(30)]];\n};\n";
	o << "struct VOut { float4 pos [[position, invariant]]; float4 d0; float4 d1; float4 t0; float4 t1; float4 t2; float4 t3; float4 t4; float4 t5; float4 t6; float4 t7; float fog; float psize [[point_size]]; };\n";
	o << "static inline float rcp1(float x) { return x == 0.0 ? FLT_MAX : (x == 1.0 ? 1.0 : 1.0 / x); }\n";
	o << "static inline float rsq1(float x) { x = fabs(x); return x == 0.0 ? FLT_MAX : (x == 1.0 ? 1.0 : rsqrt(x)); }\n";
	o << "static inline float log1(float x) { x = fabs(x); return x == 0.0 ? -FLT_MAX : log2(x); }\n";
	o << "static inline float4 expp1(float x) { float f = floor(x); return float4(exp2(f), x - f, exp2(x), 1.0); }\n";
	o << "static inline float4 lit1(float4 s) { float4 r = float4(1, 0, 0, 1); if (s.x > 0) { r.y = s.x; if (s.y > 0) r.z = pow(s.y, clamp(s.w, -127.9961, 127.9961)); } return r; }\n";
	o << "static inline float4 dst1(float4 a, float4 b) { return float4(1, a.y * b.y, a.z, b.w); }\n";
	o << "vertex VOut vs_main(VIn vin [[stage_in]], constant float4 *c [[buffer(1)]], constant float4 &vp [[buffer(2)]]) {\n";
	o << "\tfloat4 v[16];\n";
	for (int i = 0; i < 16; ++i)
		o << "\tv[" << i << "] = " << (elemForReg[i] >= 0 ? "vin.a" + std::to_string(elemForReg[i]) : "float4(0, 0, 0, 1)") << ";\n";
	o << "\tfloat4 r[12]; for (int i = 0; i < 12; ++i) r[i] = float4(0);\n";
	o << "\tint a0 = 0;\n";
	o << "\tfloat4 oPos = float4(0, 0, 0, 1), oD0 = float4(0), oD1 = float4(0), oFog4 = float4(1), oPts4 = float4(1), junk = float4(0);\n";
	o << "\tfloat4 oT[8]; for (int i = 0; i < 8; ++i) oT[i] = float4(0, 0, 0, 1);\n";
	// constants: shader-local def values override the constant buffer
	o << "\tauto C = [&](int i) -> float4 {\n";
	for (auto &df : defs) o << "\t\tif (i == " << df.first << ") return float4(" << F(df.second[0]) << ", " << F(df.second[1]) << ", " << F(df.second[2]) << ", " << F(df.second[3]) << ");\n";
	o << "\t\treturn (i >= 0 && i <= " << maxConst << ") ? c[i] : float4(0);\n\t};\n";
	o << body.str();
	o << "\tVOut o;\n";
	o << "\to.pos = oPos;\n";
	o << "\t// Direct3D 9 samples pixel centres at integer coordinates and Metal at .5, so a D3D position lands half a pixel\n\t// to the right and down here. The other sign offsets the image a whole pixel and leaves the last row and column unpainted.\n";
	o << "\to.pos.x += oPos.w * vp.z;\n\to.pos.y -= oPos.w * vp.w;\n";
	o << "\to.d0 = saturate(oD0); o.d1 = saturate(oD1);\n";
	for (int i = 0; i < 8; ++i) o << "\to.t" << i << " = oT[" << i << "];\n";
	o << "\to.fog = saturate(oFog4.x); o.psize = max(oPts4.x, 1.0);\n";
	o << "\treturn o;\n}\n";
	(void)usesRel;
	return o.str();
}

// fixed-function vertex processing for the few draws made without a vertex shader
std::string GenerateFixedFunctionVertexMSL(const VertexDecl &decl)
{
	std::ostringstream o;
	o << "#include <metal_stdlib>\nusing namespace metal;\nstruct VIn {\n";
	int pos = -1, rhw = 0, col0 = -1, col1 = -1, tex[8]; for (int &t : tex) t = -1;
	for (size_t i = 0; i < decl.elements.size(); ++i)
	{
		const D3DVERTEXELEMENT9 &e = decl.elements[i];
		bool use = false;
		if (e.Usage == D3DDECLUSAGE_POSITION || e.Usage == D3DDECLUSAGE_POSITIONT) { pos = (int)i; rhw = e.Usage == D3DDECLUSAGE_POSITIONT; use = true; }
		else if (e.Usage == D3DDECLUSAGE_COLOR && e.UsageIndex == 0) { col0 = (int)i; use = true; }
		else if (e.Usage == D3DDECLUSAGE_COLOR && e.UsageIndex == 1) { col1 = (int)i; use = true; }
		else if (e.Usage == D3DDECLUSAGE_TEXCOORD && e.UsageIndex < 8) { tex[e.UsageIndex] = (int)i; use = true; }
		if (use) o << "\tfloat4 a" << i << " [[attribute(" << i << ")]];\n";
	}
	o << "\tfloat4 unused_ [[attribute(30)]];\n};\n";
	o << "struct VOut { float4 pos [[position, invariant]]; float4 d0; float4 d1; float4 t0; float4 t1; float4 t2; float4 t3; float4 t4; float4 t5; float4 t6; float4 t7; float fog; float psize [[point_size]]; };\n";
	o << "vertex VOut vs_main(VIn vin [[stage_in]], constant float4 &vp [[buffer(2)]], constant float4x4 &wvp [[buffer(3)]]) {\n\tVOut o;\n";
	if (pos < 0) o << "\to.pos = float4(0, 0, 0, 1);\n";
	else if (rhw)
	{
		o << "\tfloat4 p = vin.a" << pos << ";\n\tfloat w = p.w != 0 ? 1.0 / p.w : 1.0;\n";
		o << "\to.pos = float4(((p.x + 0.5) * 2.0 * vp.z - 1.0) * w, (1.0 - (p.y + 0.5) * 2.0 * vp.w) * w, p.z * w, w);\n";
	}
	else o << "\to.pos = wvp * float4(vin.a" << pos << ".xyz, 1.0);\n\to.pos.x += o.pos.w * vp.z;\n\to.pos.y -= o.pos.w * vp.w;\n";
	o << "\to.d0 = " << (col0 >= 0 ? "vin.a" + std::to_string(col0) : "float4(1)") << ";\n";
	o << "\to.d1 = " << (col1 >= 0 ? "vin.a" + std::to_string(col1) : "float4(0)") << ";\n";
	for (int i = 0; i < 8; ++i) o << "\to.t" << i << " = " << (tex[i] >= 0 ? "vin.a" + std::to_string(tex[i]) : "float4(0, 0, 0, 1)") << ";\n";
	o << "\to.fog = 1.0; o.psize = 1.0;\n\treturn o;\n}\n";
	return o.str();
}

// ===================================================================================================
// fragment: fixed-function texture stages
static std::string Arg(DWORD a, bool alpha)
{
	std::string r;
	switch (a & D3DTA_SELECTMASK)
	{
	case D3DTA_DIFFUSE: r = "diffuse"; break;
	case D3DTA_CURRENT: r = "current"; break;
	case D3DTA_TEXTURE: r = "texel"; break;
	case D3DTA_TFACTOR: r = "p.tfactor"; break;
	case D3DTA_SPECULAR: r = "specular"; break;
	case D3DTA_TEMP: r = "temp"; break;
	default: r = "current";
	}
	if (a & D3DTA_ALPHAREPLICATE) r = r + ".wwww";
	if (a & D3DTA_COMPLEMENT) r = "(1.0 - " + r + ")";
	return alpha ? "(" + r + ").w" : "(" + r + ").xyz";
}
static std::string Op(DWORD op, const std::string &a1, const std::string &a2, const std::string &a0, bool alpha)
{
	const char *one = alpha ? "1.0" : "float3(1.0)";
	switch (op)
	{
	case D3DTOP_SELECTARG1: return a1;
	case D3DTOP_SELECTARG2: return a2;
	case D3DTOP_MODULATE: return a1 + " * " + a2;
	case D3DTOP_MODULATE2X: return a1 + " * " + a2 + " * 2.0";
	case D3DTOP_MODULATE4X: return a1 + " * " + a2 + " * 4.0";
	case D3DTOP_ADD: return a1 + " + " + a2;
	case D3DTOP_ADDSIGNED: return a1 + " + " + a2 + " - 0.5";
	case D3DTOP_ADDSIGNED2X: return "(" + a1 + " + " + a2 + " - 0.5) * 2.0";
	case D3DTOP_SUBTRACT: return a1 + " - " + a2;
	case D3DTOP_ADDSMOOTH: return a1 + " + " + a2 + " * (" + one + " - " + a1 + ")";
	case D3DTOP_BLENDDIFFUSEALPHA: return "mix(" + a2 + ", " + a1 + ", diffuse.w)";
	case D3DTOP_BLENDTEXTUREALPHA: return "mix(" + a2 + ", " + a1 + ", texel.w)";
	case D3DTOP_BLENDFACTORALPHA: return "mix(" + a2 + ", " + a1 + ", p.tfactor.w)";
	case D3DTOP_BLENDCURRENTALPHA: return "mix(" + a2 + ", " + a1 + ", current.w)";
	case D3DTOP_BLENDTEXTUREALPHAPM: return a1 + " + " + a2 + " * (1.0 - texel.w)";
	case D3DTOP_MULTIPLYADD: return a0 + " + " + a1 + " * " + a2;
	case D3DTOP_LERP: return "mix(" + a2 + ", " + a1 + ", " + a0 + ")";
	default: return a1;
	}
}

static bool StageUsesTexture(const StageState &s)
{
	auto tex = [](DWORD a) { return (a & D3DTA_SELECTMASK) == D3DTA_TEXTURE; };
	return tex(s.colorArg1) || tex(s.colorArg2) || tex(s.alphaArg1) || tex(s.alphaArg2) ||
		((s.colorOp == D3DTOP_MULTIPLYADD || s.colorOp == D3DTOP_LERP) && tex(s.colorArg0)) ||
		s.colorOp == D3DTOP_BLENDTEXTUREALPHA || s.alphaOp == D3DTOP_BLENDTEXTUREALPHA || s.colorOp == D3DTOP_BLENDTEXTUREALPHAPM;
}

static std::string FragmentHeader(const FragmentKey &k)
{
	std::ostringstream o;
	o << "#include <metal_stdlib>\nusing namespace metal;\n";
	o << "struct VOut { float4 pos [[position, invariant]]; float4 d0; float4 d1; float4 t0; float4 t1; float4 t2; float4 t3; float4 t4; float4 t5; float4 t6; float4 t7; float fog; };\n";
	o << "struct PSParams { float4 tfactor; float alphaRef; float lodBias[8]; float pad[3]; float4 c[8]; float4 bump[8]; float4 lum[8]; };\n";
	o << "fragment float4 fs_main(VOut in [[stage_in]], constant PSParams &p [[buffer(0)]]";
	for (int i = 0; i < 8; ++i)
		o << ", " << (k.texType[i] == 2 ? "texturecube<float>" : "texture2d<float>") << " tex" << i << " [[texture(" << i << ")]], sampler smp" << i << " [[sampler(" << i << ")]]";
	o << ") {\n";
	o << "\tfloat4 tc[8] = { in.t0, in.t1, in.t2, in.t3, in.t4, in.t5, in.t6, in.t7 };\n";
	return o.str();
}
static std::string AlphaTest(int func)
{
	if (!func || func == D3DCMP_ALWAYS) return "";
	// Direct3D compares the 8-bit alpha with the 8-bit reference
	const char *op = func == D3DCMP_NEVER ? "false" : nullptr;
	std::string cmp;
	switch (func)
	{
	case D3DCMP_LESS: cmp = "<"; break; case D3DCMP_EQUAL: cmp = "=="; break; case D3DCMP_LESSEQUAL: cmp = "<="; break;
	case D3DCMP_GREATER: cmp = ">"; break; case D3DCMP_NOTEQUAL: cmp = "!="; break; case D3DCMP_GREATEREQUAL: cmp = ">="; break;
	}
	if (op) return "\tdiscard_fragment();\n";
	return "\t{ float a8 = round(saturate(result.w) * 255.0), r8 = round(p.alphaRef * 255.0); if (!(a8 " + cmp + " r8)) discard_fragment(); }\n";
}

static std::string SampleExpr(const FragmentKey &k, int i, DWORD transformFlags)
{
	std::string uv;
	if (k.texType[i] == 2) uv = "tc[" + std::to_string(i) + "].xyz";
	else if (transformFlags & D3DTTFF_PROJECTED)
	{
		int count = transformFlags & 0xFF;
		uv = count == 3 ? "tc[" + std::to_string(i) + "].xy / tc[" + std::to_string(i) + "].z" : "tc[" + std::to_string(i) + "].xy / tc[" + std::to_string(i) + "].w";
	}
	else uv = "tc[" + std::to_string(i) + "].xy";
	return "tex" + std::to_string(i) + ".sample(smp" + std::to_string(i) + ", " + uv + ", bias(p.lodBias[" + std::to_string(i) + "]))";
}

static std::string GeneratePixelShaderMSL(const FragmentKey &k, const Shader &ps);

std::string GenerateFragmentMSL(const FragmentKey &k, const Shader *ps)
{
	if (ps) return GeneratePixelShaderMSL(k, *ps);
	std::ostringstream o;
	o << FragmentHeader(k);
	o << "\tfloat4 diffuse = in.d0, specular = in.d1, current = in.d0, temp = float4(0), texel = float4(1);\n";
	for (int i = 0; i < 4; ++i)
	{
		const StageState &s = k.stages[i];
		if (s.colorOp == D3DTOP_DISABLE || s.colorOp == 0) break;
		o << "\t// stage " << i << "\n";
		if (StageUsesTexture(s)) o << "\ttexel = " << SampleExpr(k, i, s.transformFlags) << ";\n";
		std::string color;
		if (s.colorOp == D3DTOP_DOTPRODUCT3)
			color = "float3(saturate(dot(" + Arg(s.colorArg1, false) + " - 0.5, " + Arg(s.colorArg2, false) + " - 0.5) * 4.0))";
		else if (s.colorOp == D3DTOP_MODULATEALPHA_ADDCOLOR)
			color = Arg(s.colorArg1, false) + " + " + Arg(s.colorArg1, true) + " * " + Arg(s.colorArg2, false);
		else if (s.colorOp == D3DTOP_MODULATECOLOR_ADDALPHA)
			color = Arg(s.colorArg1, false) + " * " + Arg(s.colorArg2, false) + " + " + Arg(s.colorArg1, true);
		else
			color = Op(s.colorOp, Arg(s.colorArg1, false), Arg(s.colorArg2, false), Arg(s.colorArg0, false), false);
		std::string alpha;
		if (s.colorOp == D3DTOP_DOTPRODUCT3) alpha = "saturate(dot(" + Arg(s.colorArg1, false) + " - 0.5, " + Arg(s.colorArg2, false) + " - 0.5) * 4.0)";   // dp3 also writes alpha
		else if (s.alphaOp == D3DTOP_DISABLE || s.alphaOp == 0) alpha = i == 0 ? "diffuse.w" : "current.w";
		else alpha = Op(s.alphaOp, Arg(s.alphaArg1, true), Arg(s.alphaArg2, true), Arg(s.alphaArg0, true), true);
		o << "\t{ float3 c = " << color << "; float a = " << alpha << "; current = saturate(float4(c, a)); }\n";
	}
	o << "\tfloat4 result = current;\n";
	o << AlphaTest(k.alphaTest);
	o << "\treturn result;\n}\n";
	return o.str();
}

// ===================================================================================================
// pixel shader 1.1 - 1.4
static std::string GeneratePixelShaderMSL(const FragmentKey &k, const Shader &ps)
{
	const DWORD *p = ps.code.data() + 1, *end = ps.code.data() + ps.code.size();
	int minor = ps.version & 0xFF;
	bool v14 = minor >= 4;
	std::ostringstream body;
	std::vector<std::pair<int, std::array<float, 4>>> defs;

	auto reg = [&](Param pr) -> std::string {
		int t = pr.type(), n = pr.num();
		switch (t)
		{
		case RT_TEMP: return "r[" + std::to_string(n) + "]";
		case RT_INPUT: return n == 0 ? "in.d0" : "in.d1";
		case RT_CONST: return "C" + std::to_string(n & 7);
		case RT_TEXTURE: return v14 ? "tc[" + std::to_string(n & 7) + "]" : "t[" + std::to_string(n & 7) + "]";
		default: return "float4(0)";
		}
	};
	auto src = [&](Param pr) -> std::string {
		std::string r = "(" + reg(pr) + Swz(pr.tok) + ")";
		switch ((pr.tok >> 24) & 0xF)
		{
		case 1: r = "(-" + r + ")"; break;                         // neg
		case 2: r = "(" + r + " - 0.5)"; break;                    // bias
		case 3: r = "(-(" + r + " - 0.5))"; break;                 // bias + neg
		case 4: r = "((" + r + " - 0.5) * 2.0)"; break;            // bx2
		case 5: r = "(-((" + r + " - 0.5) * 2.0))"; break;         // bx2 + neg
		case 6: r = "(1.0 - " + r + ")"; break;                    // complement
		case 7: r = "(" + r + " * 2.0)"; break;                    // x2
		case 8: r = "(-(" + r + " * 2.0))"; break;                 // x2 + neg
		case 9: r = "(" + r + " / " + r + ".z)"; break;            // dz (1.4 texld)
		case 10: r = "(" + r + " / " + r + ".w)"; break;           // dw
		}
		return r;
	};
	auto dstWrite = [&](Param d, const std::string &expr) {
		std::string D = reg(d), M = Mask(d.tok);
		int shift = (d.tok >> 24) & 0xF;   // 1 = _x2, 2 = _x4, 3 = _x8, 15 = _d2, 14 = _d4, 13 = _d8
		std::string v = "(" + expr + ")";
		if (shift >= 1 && shift <= 3) v = "(" + v + " * " + std::to_string(1 << shift) + ".0)";
		else if (shift >= 13) v = "(" + v + " / " + std::to_string(1 << (16 - shift)) + ".0)";
		if ((d.tok >> 20) & 1) v = "saturate" + v;
		else v = "clamp(" + v + ", -8.0, 8.0)";   // ps_1_x registers hold [-PixelShader1xMaxValue, +max]
		body << "\t" << D << M << " = " << v << M << ";\n";
	};
	auto sample = [&](int stage, const std::string &coord) {
		std::string uv = k.texType[stage] == 2 ? "(" + coord + ").xyz" : "(" + coord + ").xy";
		return "tex" + std::to_string(stage) + ".sample(smp" + std::to_string(stage) + ", " + uv + ", bias(p.lodBias[" + std::to_string(stage) + "]))";
	};

	std::string pendingCoissue;
	while (p < end && *p != 0x0000FFFF)
	{
		DWORD ins = *p++;
		int op = ins & 0xFFFF;
		if (op == OP_COMMENT) { p += (ins >> 16) & 0x7FFF; continue; }
		if (op == OP_PHASE) { body << "\t// phase\n"; continue; }
		if (op == OP_DEF) { Param d { *p++ }; std::array<float, 4> f; memcpy(f.data(), p, 16); p += 4; defs.push_back({ d.num() & 7, f }); continue; }
		int nsrc = SrcCount(op);
		Param d { HasDest(op) ? *p++ : 0 };
		Param s[3] = {};
		if (op == OP_TEX && v14) nsrc = 1;          // texld r, t/r
		if (op == OP_TEXCOORD && v14) nsrc = 1;     // texcrd r, t
		for (int i = 0; i < nsrc; ++i) s[i].tok = *p++;
		int dn = d.num();
		switch (op)
		{
		case OP_NOP: break;
		case OP_MOV: dstWrite(d, src(s[0])); break;
		case OP_ADD: dstWrite(d, src(s[0]) + " + " + src(s[1])); break;
		case OP_SUB: dstWrite(d, src(s[0]) + " - " + src(s[1])); break;
		case OP_MUL: dstWrite(d, src(s[0]) + " * " + src(s[1])); break;
		case OP_MAD: dstWrite(d, src(s[0]) + " * " + src(s[1]) + " + " + src(s[2])); break;
		case OP_LRP: dstWrite(d, "mix(" + src(s[2]) + ", " + src(s[1]) + ", " + src(s[0]) + ")"); break;
		case OP_DP3: dstWrite(d, "float4(dot(" + src(s[0]) + ".xyz, " + src(s[1]) + ".xyz))"); break;
		case OP_DP4: dstWrite(d, "float4(dot(" + src(s[0]) + ", " + src(s[1]) + "))"); break;
		case OP_CND:
			// ps_1_1-1_3: r0.a > 0.5 selects src1; ps_1_4 compares per component
			if (v14) dstWrite(d, "select(" + src(s[2]) + ", " + src(s[1]) + ", " + src(s[0]) + " > 0.5)");
			else dstWrite(d, "(" + src(s[0]) + ".w > 0.5 ? " + src(s[1]) + " : " + src(s[2]) + ")");
			break;
		case OP_CMP: dstWrite(d, "select(" + src(s[2]) + ", " + src(s[1]) + ", " + src(s[0]) + " >= 0.0)"); break;
		case OP_TEXCOORD:
			if (v14) dstWrite(d, src(s[0]));                                            // texcrd: coordinates as data
			else body << "\tt[" << dn << "] = saturate(float4(tc[" << dn << "].xyz, 1.0));\n";
			break;
		case OP_TEX:
			if (v14) body << "\tr[" << dn << "] = " << sample(dn, src(s[0])) << ";\n";       // texld r#, src (sampler = dest number)
			else body << "\tt[" << dn << "] = " << sample(dn, "tc[" + std::to_string(dn) + "]") << ";\n";
			break;
		case OP_TEXKILL:
			body << "\tif (any((" << (v14 ? reg(d) : "tc[" + std::to_string(dn) + "]") << ").xyz < 0.0)) discard_fragment();\n";
			break;
		case OP_TEXBEM: case OP_TEXBEML:
		{
			// u' = u + M00*du + M10*dv, v' = v + M01*du + M11*dv with the bump map in t[src]; texbeml also scales by luminance
			int sn = s[0].num();
			body << "\t{ float4 m = p.bump[" << dn << "]; float2 du = t[" << sn << "].xy; float2 uv = tc[" << dn << "].xy + float2(m.x * du.x + m.z * du.y, m.y * du.x + m.w * du.y);"
			     << " t[" << dn << "] = " << sample(dn, "float4(uv, 0, 1)") << ";";
			if (op == OP_TEXBEML) body << " t[" << dn << "] *= saturate(t[" << sn << "].z * p.lum[" << dn << "].x + p.lum[" << dn << "].y);";
			body << " }\n";
			break;
		}
		case OP_TEXM3x2PAD: body << "\tm3x2u = dot(tc[" << dn << "].xyz, t[" << s[0].num() << "].xyz);\n"; break;
		case OP_TEXM3x2TEX: body << "\tt[" << dn << "] = " << sample(dn, "float4(m3x2u, dot(tc[" + std::to_string(dn) + "].xyz, t[" + std::to_string(s[0].num()) + "].xyz), 0, 1)") << ";\n"; break;
		case OP_TEXM3x3PAD: body << "\tm3[m3n++] = dot(tc[" << dn << "].xyz, t[" << s[0].num() << "].xyz);\n"; break;
		case OP_TEXM3x3TEX: body << "\tt[" << dn << "] = " << sample(dn, "float4(m3[0], m3[1], dot(tc[" + std::to_string(dn) + "].xyz, t[" + std::to_string(s[0].num()) + "].xyz), 1)") << "; m3n = 0;\n"; break;
		case OP_TEXM3x3:
			body << "\tt[" << dn << "] = float4(m3[0], m3[1], dot(tc[" << dn << "].xyz, t[" << s[0].num() << "].xyz), 1); m3n = 0;\n"; break;
		case OP_TEXM3x3VSPEC:
			body << "\t{ float3 n = float3(m3[0], m3[1], dot(tc[" << dn << "].xyz, t[" << s[0].num() << "].xyz)); float3 e = float3(tc[" << dn - 2 << "].w, tc[" << dn - 1 << "].w, tc[" << dn << "].w);"
			     << " float3 r = 2.0 * n * dot(n, e) / dot(n, n) - e; t[" << dn << "] = " << sample(dn, "float4(r, 1)") << "; m3n = 0; }\n";
			break;
		case OP_TEXM3x3SPEC:
			body << "\t{ float3 n = float3(m3[0], m3[1], dot(tc[" << dn << "].xyz, t[" << s[0].num() << "].xyz)); float3 e = " << src(s[1]) << ".xyz;"
			     << " float3 r = 2.0 * n * dot(n, e) / dot(n, n) - e; t[" << dn << "] = " << sample(dn, "float4(r, 1)") << "; m3n = 0; }\n";
			break;
		case OP_TEXREG2AR: body << "\tt[" << dn << "] = " << sample(dn, "float4(t[" + std::to_string(s[0].num()) + "].wx, 0, 1)") << ";\n"; break;
		case OP_TEXREG2GB: body << "\tt[" << dn << "] = " << sample(dn, "float4(t[" + std::to_string(s[0].num()) + "].yz, 0, 1)") << ";\n"; break;
		case OP_TEXDP3: body << "\tt[" << dn << "] = float4(dot(tc[" << dn << "].xyz, t[" << s[0].num() << "].xyz));\n"; break;
		case OP_TEXDP3TEX: body << "\tt[" << dn << "] = " << sample(dn, "float4(dot(tc[" + std::to_string(dn) + "].xyz, t[" + std::to_string(s[0].num()) + "].xyz), 0, 0, 1)") << ";\n"; break;
		default: fprintf(stderr, "[d3d9] ps opcode %d not translated\n", op); break;
		}
	}

	std::ostringstream o;
	o << FragmentHeader(k);
	o << "\tfloat4 r[6]; for (int i = 0; i < 6; ++i) r[i] = float4(0);\n";
	o << "\tfloat4 t[8]; for (int i = 0; i < 8; ++i) t[i] = float4(0);\n";
	o << "\tfloat m3[3] = { 0, 0, 0 }; int m3n = 0; float m3x2u = 0; (void)m3n; (void)m3x2u;\n";
	for (int i = 0; i < 8; ++i)
	{
		bool def = false;
		for (auto &df : defs) if (df.first == i) { o << "\tfloat4 C" << i << " = float4(" << F(df.second[0]) << ", " << F(df.second[1]) << ", " << F(df.second[2]) << ", " << F(df.second[3]) << ");\n"; def = true; }
		if (!def) o << "\tfloat4 C" << i << " = p.c[" << i << "];\n";
	}
	o << body.str();
	o << "\tfloat4 result = r[0];\n";
	o << AlphaTest(k.alphaTest);
	o << "\treturn result;\n}\n";
	return o.str();
}

} // namespace s2gfx

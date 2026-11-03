// lifestudio.cpp: native implementation of the LifeStudio:Head facial-animation API (LifeMode Interactive, 2003)
// that Silent Storm uses for character heads, written for the macOS port from a study of the shipped DLL's
// behaviour and validated against it (the DLL run under Wine as a test oracle; see port/tools/lifestudio_oracle/run.sh).
//
// Model. A head segment ("animator") is a set of linear muscles, a few bones and a list of vertices:
//  - a muscle runs from point A to point B; tension t in [-1,1] pulls its moving end along it, so its current
//    vector is (1-t)(B-A). Each muscle owns a falloff spline (distance -> weight in [0,1]).
//  - a bone holds a rest matrix M1, its inverse M2 and a rotation R; its local transform is M2*R*M1 (row
//    vectors), chained to an optional parent. Muscles attached to a bone move with it.
//  - a deformable vertex lists (muscle, parameter a, weight w) influences. Its displacement from one muscle
//    is ((1-t)(B-A) - (B-A)) * a * w, i.e. -t(B-A)aw, rotated by the muscle's bone. Several influences are
//    blended with an exponential damping of their mutual projections, and the rest position (moved by the
//    bones) is added back with weights w_i / sum(w).
//  - "unused" vertices are static and only written when FillUnused(true).
// Macro muscles (IMMTree, tree.mma) are named expressions that drive many muscle/bone channels; the animator
// accumulates Add/Mult contributions per channel and ComputePhysics turns them into tensions and rotations.
// Sequences (ISequencer) are keyed macro-muscle tracks rendered into an animator at a time in ms.
//
// Data. The animator buffers in Heads.res come in two layouts, both little-endian 32-bit:
//  - "full" (magic 0xAD5A018D): fixed 64-byte names, per-vertex weights stored but recomputed on load;
//  - "compact" (magic 0x37D30DC0): length-prefixed names, (muscle, a) pairs, bone parents, user items
//    (named vertex sets, e.g. Neck_Zone_n) and optional splines.
// Everything is parsed field by field, so the 2003 32-bit layouts never meet a 64-bit struct.
// The FaceGen character creator (ITransformer, IGDPFile, IAnimator::Save) is at the end of the namespace: a
// head space of sculpted heads (Res\FaceGenHead.gdp, an OLE compound file) blended by the Age, Gender and race
// sliders, sculpted further by the morph muscles, and written into an output animator.
// Not implemented: the geometry half of IGDPObject (materials, triangulation, textures, sub-objects), which
// the engine never reads because the "Heads" pack supplies the topology, and the simplex search of TriangLib for
// slider grids with missing corners (the shipped grid is complete; see MorphSpace). The per-frame neck refit of
// NeckProcessing2(true) is approximate (the engine never enables it).
#define LIFESTUDIOHEADAPI_EXPORTS_LIB
#include "LifeStudioHeadAPI.h"
#include "LifeStudioHeadAPIGDP.h"
#include "LifeStudioHeadAPIMMTS.h"
#include "LifeStudioHeadAPITransform.h"
#include "LifeStudioHeadAPIInit.h"
#include <ctype.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <vector>
#include <map>
#include <algorithm>

// The reference arithmetic is single precision with every intermediate stored; keep the compiler from fusing
// multiply-adds so results stay within an ulp of it.
#pragma clang fp contract(off)

// port/platform/src/win32.cpp: engine path ('\\', any case) -> host path
extern "C" const char *S2HostPath(const char *winPath, char *out, size_t outSize);

namespace LifeStudioHeadAPI
{
// Opaque handle types of the public API (only forward-declared in the headers).
struct IMuscle {};
struct IBone {};
struct IMacroMuscle {};

namespace {

// ---------------------------------------------------------------------------------------------------------
// little-endian reader over a caller's buffer; every read is bounds-checked and sets `bad` on overrun
struct Reader
{
	const unsigned char *p, *end;
	bool bad = false;
	Reader(const char *b, int n) : p((const unsigned char *)b), end((const unsigned char *)b + (n > 0 ? n : 0)) {}
	bool Need(size_t n) { if (bad || (size_t)(end - p) < n) { bad = true; return false; } return true; }
	int32_t I() { if (!Need(4)) return 0; int32_t v; memcpy(&v, p, 4); p += 4; return v; }
	uint32_t U() { return (uint32_t)I(); }
	float F() { if (!Need(4)) return 0; float v; memcpy(&v, p, 4); p += 4; return v; }
	void Skip(size_t n) { if (Need(n)) p += n; }
	std::string FixedName(size_t n)
	{
		if (!Need(n)) return std::string();
		size_t len = strnlen((const char *)p, n);
		std::string s((const char *)p, len);
		p += n;
		return s;
	}
	std::string ShortName()   // one length byte, then that many characters (no terminator)
	{
		if (!Need(1)) return std::string();
		size_t len = *p++;
		if (!Need(len)) return std::string();
		std::string s((const char *)p, len);
		p += len;
		return s;
	}
};

// ---------------------------------------------------------------------------------------------------------
// 4x4 row-vector matrices (p' = p * M, translation in row 3)
struct Mat4
{
	float m[4][4];
	void Identity() { memset(m, 0, sizeof m); m[0][0] = m[1][1] = m[2][2] = m[3][3] = 1.0f; }
};
static void Mul(const Mat4 &a, const Mat4 &b, Mat4 &out)
{
	Mat4 r;
	for (int i = 0; i < 4; ++i)
		for (int j = 0; j < 4; ++j)
		{
			float s = 0.0f;
			for (int k = 0; k < 4; ++k)
				s = a.m[i][k] * b.m[k][j] + s;
			r.m[i][j] = s;
		}
	out = r;
}
// point (w = 1) through a full matrix, with the homogeneous divide applied term by term
static void TransformPoint(const float p[3], const Mat4 &M, float out[3])
{
	float w = 0.0f;
	for (int j = 0; j < 4; ++j)
		w = (j == 3 ? 1.0f : p[j]) * M.m[j][3] + w;
	float r[3];
	for (int i = 0; i < 3; ++i)
	{
		float s = 0.0f;
		for (int j = 0; j < 4; ++j)
			s = ((j == 3 ? 1.0f : p[j]) * M.m[j][i]) / w + s;
		r[i] = s;
	}
	out[0] = r[0]; out[1] = r[1]; out[2] = r[2];
}
// inverse of a rigid transform: (p - t) * R^T
static void RigidInverse(const Mat4 &a, Mat4 &out)
{
	Mat4 r;
	r.Identity();
	for (int i = 0; i < 3; ++i)
		for (int j = 0; j < 3; ++j)
			r.m[i][j] = a.m[j][i];
	Mat4 t;
	t.Identity();
	for (int j = 0; j < 3; ++j) t.m[3][j] = -a.m[3][j];
	Mul(t, r, out);
}
// rotation from the three bone angles (radians), the order LifeStudio uses for its bones
static void EulerMatrix(float a0, float a1, float a2, Mat4 &M)
{
	double ca = cos((double)a0), sa = sin((double)a0);
	double cb = cos((double)a1), sb = sin((double)a1);
	double cc = cos((double)a2), sc = sin((double)a2);
	M.m[0][0] = (float)(cb * ca); M.m[0][1] = (float)(sa * cb); M.m[0][2] = (float)-sb; M.m[0][3] = 0.0f;
	M.m[1][0] = (float)(sc * (sb * ca) - cc * sa); M.m[1][1] = (float)(cc * ca + sb * sa * sc); M.m[1][2] = (float)(sc * cb); M.m[1][3] = 0.0f;
	M.m[2][0] = (float)(sc * sa + cc * (sb * ca)); M.m[2][1] = (float)(sb * sa * cc - sc * ca); M.m[2][2] = (float)(cc * cb); M.m[2][3] = 0.0f;
	M.m[3][0] = M.m[3][1] = M.m[3][2] = 0.0f; M.m[3][3] = 1.0f;
}

// ---------------------------------------------------------------------------------------------------------
// Piecewise cubic Hermite spline through (x_i, y_i); the tangent at an inner key is the slope between its two
// neighbours and at an end key the slope of the end segment. Per segment the value is stored in the form
//   f = c0*dl + c1*dr + c2*dl^2*dr + c3*dl*dr^2,   dl = x - x_i, dr = x - x_{i+1}
struct Spline
{
	int n = 0;
	std::vector<float> kx, ky, c;   // c: 4 per segment
	bool Build(const float *x, const float *y, int count)
	{
		n = 0; kx.clear(); ky.clear(); c.clear();
		if (count < 3 || !x || !y)
			return false;
		n = count;
		kx.assign(x, x + count);
		ky.assign(y, y + count);
		c.assign((count - 1) * 4, 0.0f);
		float prevSlope = (ky[1] - ky[0]) / (kx[1] - kx[0]);
		float slope = prevSlope;
		int seg = 0;
		for (int i = 1; i < count - 1; ++i, ++seg)
		{
			slope = (ky[i + 1] - ky[i - 1]) / (kx[i + 1] - kx[i - 1]);
			float h = kx[i] - kx[i - 1];
			float *q = &c[seg * 4];
			q[0] = ky[i] / h;
			q[1] = ky[i - 1] / -h;
			q[2] = (slope - (q[1] + q[0])) / (h * h);
			q[3] = (prevSlope - (q[1] + q[0])) / (-h * -h);
			prevSlope = slope;
		}
		float h = kx[count - 1] - kx[count - 2];
		float endSlope = (ky[count - 1] - ky[count - 2]) / (kx[count - 1] - kx[count - 2]);
		float *q = &c[seg * 4];
		q[0] = ky[count - 1] / h;
		q[1] = ky[count - 2] / -h;
		q[2] = (endSlope - (q[1] + q[0])) / (h * h);
		q[3] = (slope - (q[1] + q[0])) / (-h * -h);
		return true;
	}
	float Eval(float x) const
	{
		for (int i = 0; i < n - 1; ++i)
			if (kx[i] <= x && x <= kx[i + 1])
			{
				const float *q = &c[i * 4];
				float dl = x - kx[i], dr = x - kx[i + 1];
				return q[0] * dl + q[1] * dr + q[2] * dl * dl * dr + q[3] * dl * dr * dr;
			}
		return 0.0f;
	}
};

struct BoneData;

// ---------------------------------------------------------------------------------------------------------
struct MuscleData : IMuscle
{
	std::string name;
	float A[3] = {0, 0, 0}, B[3] = {0, 0, 0};
	float D[3] = {0, 0, 0};          // B - A
	float len = 0, lenSq = 0, dir[3] = {0, 0, 0};
	int nKeys = 0;
	float keyX[10] = {0}, keyY[10] = {0};
	Spline falloff;
	float tension = 0, slack = 1;   // t and 1 - t
	float cur[3] = {0, 0, 0};        // current muscle vector (1-t)(B-A), measured from A
	float curLen = 0, curLenSq = 0;
	BoneData *bone = nullptr;
	int channel = 0;

	void UpdateRest()
	{
		for (int i = 0; i < 3; ++i) D[i] = B[i] - A[i];
		lenSq = D[2] * D[2] + D[1] * D[1] + D[0] * D[0];
		len = sqrtf(lenSq);
		for (int i = 0; i < 3; ++i) dir[i] = D[i] / len;
	}
	void SetSpline(const float *x, const float *y, int n)
	{
		nKeys = n < 0 ? 0 : (n > 10 ? 10 : n);
		for (int i = 0; i < nKeys; ++i) { keyX[i] = x[i]; keyY[i] = y[i]; }
		falloff.Build(keyX, keyY, nKeys);
	}
	void SetTension(float t)
	{
		tension = t;
		slack = 1.0f - t;
		float end[3];
		for (int i = 0; i < 3; ++i) end[i] = slack * D[i] + A[i];
		for (int i = 0; i < 3; ++i) cur[i] = end[i] - A[i];
		curLenSq = cur[2] * cur[2] + cur[1] * cur[1] + cur[0] * cur[0];
		curLen = sqrtf(curLenSq);
	}
	// weight of a point at distance d from the muscle: 0 outside the spline's key range, else clamped to [0,1]
	float Falloff(float d) const
	{
		if (nKeys < 1 || d < keyX[0] || keyX[nKeys - 1] <= d)
			return 0.0f;
		float v = falloff.Eval(d);
		if (v < 0.0f) return 0.0f;
		if (1.0f < v) return 1.0f;
		return v;
	}
	void PointAt(float a, float out[3]) const { for (int i = 0; i < 3; ++i) out[i] = a * D[i] + A[i]; }
	// position of p along the muscle, 0 at A and 1 at B
	float Parameter(const float p[3]) const
	{
		float d[3];
		for (int i = 0; i < 3; ++i) d[i] = p[i] - A[i];
		return (d[0] * dir[0] + d[1] * dir[1] + d[2] * dir[2]) / len;
	}
	void Displacement(float a, float w, float out[3]) const;
};

// ---------------------------------------------------------------------------------------------------------
struct BoneData : IBone
{
	std::string name;
	Mat4 rest, restInv;              // M1 and M2
	Mat4 rot;                        // R (identity at rest)
	Mat4 local, world, restWorld, localRot;
	uint32_t flags = 0;              // bit 31: R is applied inverted
	std::vector<int> muscles;
	BoneData *parent = nullptr;
	int parentIndex = -1;
	int channel = 0;                 // first of its three animator channels
	float angle[3] = {0, 0, 0};
	BoneData() { rest.Identity(); restInv.Identity(); rot.Identity(); local.Identity(); world.Identity(); restWorld.Identity(); localRot.Identity(); }

	static void Load12(Mat4 &M, Reader &r)
	{
		for (int row = 0; row < 4; ++row)
		{
			for (int col = 0; col < 3; ++col) M.m[row][col] = r.F();
			M.m[row][3] = row == 3 ? 1.0f : 0.0f;
		}
	}
	void UpdateLocal()
	{
		Mat4 t;
		if (flags & 0x80000000u)
		{
			Mat4 inv;
			RigidInverse(rot, inv);
			Mul(restInv, inv, t);
		}
		else
			Mul(restInv, rot, t);
		Mul(t, rest, local);
		localRot = local;
		localRot.m[3][0] = localRot.m[3][1] = localRot.m[3][2] = 0.0f;
		localRot.m[3][3] = 1.0f;
	}
	void UpdateWorld()
	{
		if (!parent)
		{
			world = local;
			restWorld = rest;
			return;
		}
		parent->UpdateWorld();
		Mul(local, parent->world, world);
		Mul(rest, parent->world, restWorld);
	}
};

void MuscleData::Displacement(float a, float w, float out[3]) const
{
	if (0.0f <= a)
	{
		float s = a * w;
		for (int i = 0; i < 3; ++i) out[i] = (cur[i] - D[i]) * s;
	}
	else
		out[0] = out[1] = out[2] = 0.0f;
	if (bone)
		TransformPoint(out, bone->localRot, out);
}

// ---------------------------------------------------------------------------------------------------------
struct Influence { int muscle; float a, w; };
struct Vertex
{
	int index = 0;
	float rest[3] = {0, 0, 0};
	std::vector<Influence> infl;
	double damping = 0;   // -ln(n) / (2(n-1)): exponent scale for the multi-muscle blend
	void SetInfluences(std::vector<Influence> &&v)
	{
		infl = std::move(v);
		int n = (int)infl.size();
		damping = n > 1 ? (log(1.0 / n) * 0.5) / (double)(n - 1) : 0.0;
	}
};
struct StaticVertex { int index; float pos[3]; };

// a named vertex set (compact buffers): bit per vertex
struct UserSet
{
	std::string name;
	std::vector<int> indices;
};

static bool ReadSelection(Reader &r, std::vector<int> &out)
{
	int nbits = r.I();
	if (r.bad) return false;
	if (nbits == 0) return true;
	uint32_t count = r.U();
	if (count == 0xffffffffu)
	{
		int words = (nbits + 31) >> 5;
		for (int w = 0; w < words && !r.bad; ++w)
		{
			uint32_t bits = r.U();
			for (int b = 0; b < 32; ++b)
				if ((bits >> b) & 1u)
				{
					int i = w * 32 + b;
					if (i < nbits) out.push_back(i);
				}
		}
	}
	else
		for (uint32_t i = 0; i < count && !r.bad; ++i)
			out.push_back(r.I());
	return !r.bad;
}

// ---------------------------------------------------------------------------------------------------------
// Macro-muscle tree (tree.mma, FaceGenHead.mmt: "MMLF"). Every record is a 32-byte header
//   [kind, flags, curveBytes, payloadBytes, subtreeBytes, refOffset, 0, 0]
// followed by its payload; flag 2 = children follow, 4 = a sibling follows, 1 = unnamed reference to the
// record at file offset refOffset (it keeps its own curve). The payload starts with a response curve
//   [int muted][int n][x * n][y * n][float hi][float lo]   (curveBytes = 16 + 8n)
// then, for named records, an int-prefixed name and a kind-specific tail (bones: an axis 1..3 at +8).
// kind 1/2 = macro (group), 3 = muscle, 4 = bone angle, 5 = FaceGen output (user item).
// A value sent into a macro travels down each child edge through that edge's curve (clamped to [lo, hi]);
// muted edges are skipped; leaves add the value to their animator channel.
struct MMNode : IMacroMuscle
{
	int kind = 0;
	uint32_t flags = 0;
	int muted = 0;
	std::string name;
	Spline curve;
	float hi = 1, lo = -1;
	int axis = 0;                    // bone leaves: angle index + 1
	uint32_t offset = 0, refOffset = 0;
	MMNode *target = this;           // the named record this one stands for
	std::vector<MMNode *> children;
	bool IsLeaf() const { return kind >= 3; }
	float Response(float v) const
	{
		float r = curve.n >= 3 ? curve.Eval(v) : 0.0f;
		if (r > hi) r = hi;
		if (r < lo) r = lo;
		return r;
	}
};

static std::vector<char> ReadWholeFile(const char *name)
{
	std::vector<char> data;
	if (!name) return data;
	char path[1024];
	S2HostPath(name, path, sizeof path);
	FILE *f = fopen(path, "rb");
	if (!f) return data;
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	if (n > 0)
	{
		data.resize((size_t)n);
		if (fread(data.data(), 1, (size_t)n, f) != (size_t)n) data.clear();
	}
	fclose(f);
	return data;
}

struct Tree final : IMMTree
{
	std::vector<MMNode *> nodes;     // file order
	MMNode *root = nullptr;
	~Tree() { Clear(); }
	void Clear() { for (MMNode *n : nodes) delete n; nodes.clear(); root = nullptr; }

	// one record and its siblings (and children); returns false on malformed data
	bool ParseLevel(const unsigned char *base, size_t size, size_t &pos, MMNode *parent, int depth)
	{
		if (depth > 64) return false;
		for (;;)
		{
			if (pos + 32 > size) return false;
			uint32_t h[8];
			memcpy(h, base + pos, 32);
			size_t payload = pos + 32, plen = h[3];
			if (payload + plen > size) return false;
			MMNode *n = new MMNode();
			nodes.push_back(n);
			n->kind = (int)h[0]; n->flags = h[1]; n->offset = (uint32_t)pos; n->refOffset = h[5];
			Reader r((const char *)base + payload, (int)plen);
			uint32_t curveBytes = h[2];
			if (curveBytes >= 16 && curveBytes <= plen)
			{
				n->muted = r.I();
				int k = r.I();
				if (k > 0 && (size_t)(16 + 8 * (size_t)k) <= curveBytes)
				{
					std::vector<float> x(k), y(k);
					for (int i = 0; i < k; ++i) x[i] = r.F();
					for (int i = 0; i < k; ++i) y[i] = r.F();
					n->curve.Build(x.data(), y.data(), k);
				}
				Reader c((const char *)base + payload + 8 + 8 * (size_t)(k > 0 ? k : 0), 8);
				n->hi = c.F(); n->lo = c.F();
				r = Reader((const char *)base + payload + curveBytes, (int)(plen - curveBytes));
			}
			if (!(n->flags & 1))
			{
				int len = r.I();
				if (len >= 0 && r.Need((size_t)len)) { n->name.assign((const char *)r.p, (size_t)len); r.p += len; }
				if (n->kind == 4) { r.Skip(8); n->axis = r.I(); }
			}
			if (parent) parent->children.push_back(n);
			else if (!root) root = n;
			pos = payload + plen;
			if (n->flags & 2)
				if (!ParseLevel(base, size, pos, n, depth + 1)) return false;
			if (!(n->flags & 4)) return true;
		}
	}
	bool Load(const char *buffer, int size) override
	{
		Clear();
		if (!buffer || size < 64 || memcmp(buffer, "MMLF", 4) != 0) return false;
		size_t pos = 32;
		if (!ParseLevel((const unsigned char *)buffer, (size_t)size, pos, nullptr, 0)) { Clear(); return false; }
		// resolve references: an unnamed record stands for the named one at its offset
		std::map<uint32_t, MMNode *> byOffset;
		for (MMNode *n : nodes) byOffset[n->offset] = n;
		for (MMNode *n : nodes)
			if (n->flags & 1)
			{
				std::map<uint32_t, MMNode *>::iterator it = byOffset.find(n->refOffset);
				MMNode *t = it == byOffset.end() ? nullptr : it->second;
				for (int guard = 0; t && (t->flags & 1) && guard < 16; ++guard)
				{
					std::map<uint32_t, MMNode *>::iterator j = byOffset.find(t->refOffset);
					t = j == byOffset.end() ? nullptr : j->second;
				}
				n->target = t ? t : n;
			}
		return root != nullptr;
	}
	bool Load(const char *fileName) override
	{
		std::vector<char> d = ReadWholeFile(fileName);
		return !d.empty() && Load(d.data(), (int)d.size());
	}
	IMacroMuscle *RootMacroMuscle() const override { return root; }
	IMacroMuscle *FindMacroMuscle(const char *name) override
	{
		if (!name) return nullptr;
		for (MMNode *n : nodes)
			if (!(n->flags & 1) && n->name == name)
				return n;
		return nullptr;
	}
	void Destroy() override { delete this; }
};

struct NeckLine { int upper = -1, lower = -1; float org[3] = {0, 0, 0}, dir[3] = {0, 0, 0}; };
struct NeckVertex { int v; int l0, l1; float t[3], w[3]; };
struct CollectedItem { std::string name; std::vector<float> values; };

// ---------------------------------------------------------------------------------------------------------
template<class Base> struct AnimatorT : public Base
{
	using Base::Load;
	std::vector<MuscleData> muscles;
	std::vector<BoneData> bones;
	std::vector<Vertex> verts;
	std::vector<StaticVertex> unused;
	std::vector<UserSet> userItems;
	int nVertices = 0;
	bool recomputeWeights = true;
	bool fill = false, collect = false, neck2 = false;
	// macro-muscle channel accumulators (muscles first, then three per bone)
	std::vector<float> addSum, addWeight, multSum, multWeight, multBlend;

	void Reset()
	{
		muscles.clear(); bones.clear(); verts.clear(); unused.clear(); userItems.clear();
		nVertices = 0;
		addSum.clear(); addWeight.clear(); multSum.clear(); multWeight.clear(); multBlend.clear();
		neckLines.clear(); neckRest.clear(); neckVerts.clear(); neckCount.clear();
	}
	void LinkBones()
	{
		for (BoneData &b : bones)
		{
			b.parent = (b.parentIndex >= 0 && b.parentIndex < (int)bones.size()) ? &bones[b.parentIndex] : nullptr;
			for (int m : b.muscles)
				if (m >= 0 && m < (int)muscles.size())
					muscles[m].bone = &b;
		}
	}
	void SetupChannels()
	{
		int nm = (int)muscles.size(), nb = (int)bones.size();
		for (int i = 0; i < nm; ++i) muscles[i].channel = i;
		for (int i = 0; i < nb; ++i) bones[i].channel = nm + 3 * i;
		int n = nm + 3 * nb;
		addSum.assign(n, 0); addWeight.assign(n, 0); multSum.assign(n, 0); multWeight.assign(n, 0); multBlend.assign(n, 0);
	}
	// weight of each influence = muscle falloff at the distance from the rest vertex to the muscle point at a
	void UpdateWeights(Vertex &v) const
	{
		for (Influence &f : v.infl)
		{
			if (f.muscle < 0 || f.muscle >= (int)muscles.size()) { f.w = 0; continue; }
			const MuscleData &m = muscles[f.muscle];
			float dx, dy, dz;
			if (0.0f <= f.a)
			{
				float p[3];
				if (f.a <= 1.0f) m.PointAt(f.a, p);
				else { p[0] = m.B[0]; p[1] = m.B[1]; p[2] = m.B[2]; }
				dx = v.rest[0] - p[0]; dy = v.rest[1] - p[1]; dz = v.rest[2] - p[2];
			}
			else
			{
				dx = v.rest[0] - m.A[0]; dy = v.rest[1] - m.A[1]; dz = v.rest[2] - m.A[2];
			}
			f.w = m.Falloff(sqrtf(dx * dx + (dy * dy + dz * dz)));
		}
	}
	void RecomputeWeights() { for (Vertex &v : verts) UpdateWeights(v); }
	// the morph moved rest vertices and muscles: every influence gets its position along its muscle again
	// (0x6600e850), then the falloff weights when this animator keeps splines (0x66004d40)
	void UpdateParameters(const float *positions)
	{
		for (Vertex &v : verts)
		{
			for (int k = 0; k < 3; ++k) v.rest[k] = positions[(size_t)v.index * 3 + k];
			for (Influence &f : v.infl)
				if (f.muscle >= 0 && f.muscle < (int)muscles.size())
					f.a = muscles[f.muscle].Parameter(v.rest);
		}
		if (recomputeWeights) RecomputeWeights();
		for (StaticVertex &s : unused)
			for (int k = 0; k < 3; ++k) s.pos[k] = positions[(size_t)s.index * 3 + k];
	}

	bool LoadFull(Reader &r)
	{
		r.U();
		int nm = r.I(); nVertices = r.I(); int nrec = r.I(); int nb = r.I(); r.I(); r.I();
		if (r.bad || nm < 0 || nrec < 0 || nb < 0 || nVertices < nrec) return false;
		muscles.resize(nm);
		for (int i = 0; i < nm && !r.bad; ++i)
		{
			MuscleData &m = muscles[i];
			m.name = r.FixedName(64);
			for (int k = 0; k < 3; ++k) m.A[k] = r.F();
			for (int k = 0; k < 3; ++k) m.B[k] = r.F();
			float x[10], y[10];
			for (int k = 0; k < 10; ++k) x[k] = r.F();
			for (int k = 0; k < 10; ++k) y[k] = r.F();
			int n = r.I();
			m.UpdateRest();
			m.SetSpline(x, y, n);
			m.SetTension(0.0f);
		}
		verts.resize(nrec);
		for (int i = 0; i < nrec && !r.bad; ++i)
		{
			Vertex &v = verts[i];
			v.index = r.I(); r.I(); r.I();
			for (int k = 0; k < 3; ++k) v.rest[k] = r.F();
			int n = r.I();
			if (n < 0 || !r.Need((size_t)n * 12)) return false;
			std::vector<Influence> in(n);
			for (int k = 0; k < n; ++k) { in[k].muscle = r.I(); in[k].a = r.F(); in[k].w = r.F(); }
			v.SetInfluences(std::move(in));
		}
		bones.resize(nb);
		for (int i = 0; i < nb && !r.bad; ++i)
		{
			BoneData &b = bones[i];
			b.name = r.FixedName(64);
			int n = r.I();
			BoneData::Load12(b.rest, r);
			BoneData::Load12(b.restInv, r);
			if (n < 0 || !r.Need((size_t)n * 4)) return false;
			b.muscles.resize(n);
			for (int k = 0; k < n; ++k) b.muscles[k] = r.I();
			b.UpdateLocal();
		}
		int nu = nVertices - nrec;
		unused.resize(nu);
		for (int i = 0; i < nu && !r.bad; ++i)
		{
			unused[i].index = r.I(); r.I(); r.I();
			for (int k = 0; k < 3; ++k) unused[i].pos[k] = r.F();
		}
		recomputeWeights = true;
		return !r.bad;
	}

	bool LoadCompact(Reader &r)
	{
		r.U();
		int nm = r.I(); nVertices = r.I(); int nrec = r.I(); int nb = r.I(); r.I(); int nui = r.I(); r.I();
		uint32_t flags = r.U();
		if (r.bad || nm < 0 || nrec < 0 || nb < 0 || nui < 0 || nVertices < nrec) return false;
		recomputeWeights = (flags & 1) != 0;
		muscles.resize(nm);
		for (int i = 0; i < nm && !r.bad; ++i)
		{
			MuscleData &m = muscles[i];
			m.name = r.ShortName();
			for (int k = 0; k < 3; ++k) m.A[k] = r.F();
			for (int k = 0; k < 3; ++k) m.B[k] = r.F();
			r.I();
			m.UpdateRest();
			if (recomputeWeights)
			{
				float x[10], y[10];
				for (int k = 0; k < 10; ++k) x[k] = r.F();
				for (int k = 0; k < 10; ++k) y[k] = r.F();
				m.SetSpline(x, y, r.I());
			}
			m.SetTension(0.0f);
		}
		verts.resize(nrec);
		for (int i = 0; i < nrec && !r.bad; ++i)
		{
			Vertex &v = verts[i];
			v.index = r.I();
			for (int k = 0; k < 3; ++k) v.rest[k] = r.F();
			int n = r.I();
			if (n < 0 || !r.Need((size_t)n * 8)) return false;
			std::vector<Influence> in(n);
			for (int k = 0; k < n; ++k) { in[k].muscle = r.I(); in[k].a = r.F(); in[k].w = 0.0f; }
			v.SetInfluences(std::move(in));
		}
		bones.resize(nb);
		for (int i = 0; i < nb && !r.bad; ++i)
		{
			BoneData &b = bones[i];
			b.name = r.ShortName();
			int n = r.I();
			b.parentIndex = r.I();
			BoneData::Load12(b.rest, r);
			BoneData::Load12(b.restInv, r);
			b.flags = r.U();
			if (n < 0 || !r.Need((size_t)n * 4)) return false;
			b.muscles.resize(n);
			for (int k = 0; k < n; ++k) b.muscles[k] = r.I();
			b.UpdateLocal();
		}
		int nu = nVertices - nrec;
		unused.resize(nu);
		for (int i = 0; i < nu && !r.bad; ++i)
		{
			unused[i].index = r.I();
			for (int k = 0; k < 3; ++k) unused[i].pos[k] = r.F();
		}
		userItems.resize(nui);
		for (int i = 0; i < nui && !r.bad; ++i)
		{
			userItems[i].name = r.ShortName();
			if (!ReadSelection(r, userItems[i].indices)) return false;
		}
		return !r.bad;
	}

	bool Load(const char *buffer, int size) override
	{
		// research aid: S2_LS_DUMP=1 writes the first 40 animator buffers to _ls_<n>.bin in the game folder
		static int dumped = 0;
		if (buffer && size > 0 && dumped < 40 && getenv("S2_LS_DUMP"))
		{
			char name[32];
			snprintf(name, sizeof name, "_ls_%02d.bin", dumped++);
			if (FILE *f = fopen(name, "wb")) { fwrite(buffer, 1, (size_t)size, f); fclose(f); }
		}
		Reset();
		if (!buffer || size < 4) return false;
		uint32_t magic;
		memcpy(&magic, buffer, 4);
		Reader r(buffer, size);
		bool ok;
		if (magic == 0xAD5A018Du) ok = LoadFull(r);
		else if (magic == 0x37D30DC0u) ok = LoadCompact(r);
		else return false;
		if (!ok) { Reset(); return false; }
		LinkBones();
		SetupChannels();
		if (recomputeWeights)
			RecomputeWeights();
		SetupNeck();
		return true;
	}

	void ProcessVertex(const Vertex &v, float *out) const
	{
		const int n = (int)v.infl.size();
		if (n == 0)
		{
			out[0] = v.rest[0]; out[1] = v.rest[1]; out[2] = v.rest[2];
			return;
		}
		if (n == 1)
		{
			const Influence &f = v.infl[0];
			const MuscleData &m = muscles[f.muscle];
			float d[3];
			m.Displacement(f.a, f.w, d);
			float p[3] = {v.rest[0], v.rest[1], v.rest[2]};
			if (m.bone) TransformPoint(v.rest, m.bone->world, p);
			out[0] = d[0] + p[0]; out[1] = d[1] + p[1]; out[2] = d[2] + p[2];
			return;
		}
		// several muscles: each displacement d_i is damped by exp(k * sum_j|d_j . u_i| w_j / (w_i |d_i|)),
		// u_i = d_i / |d_i|, so muscles pulling the same way do not simply add up
		float dsp[64][3], unit[64][3], dlen[64];
		std::vector<float> big;
		float (*d)[3] = dsp, (*u)[3] = unit;
		float *L = dlen;
		if (n > 64)
		{
			big.resize(n * 7);
			d = (float (*)[3])&big[0]; u = (float (*)[3])&big[n * 3]; L = &big[n * 6];
		}
		float sumW = 0.0f;
		for (int i = 0; i < n; ++i)
		{
			const Influence &f = v.infl[i];
			sumW = f.w + sumW;
			muscles[f.muscle].Displacement(f.a, f.w, d[i]);
			float l = sqrtf(d[i][1] * d[i][1] + d[i][0] * d[i][0] + d[i][2] * d[i][2]);
			L[i] = l;
			if (l <= 1e-4f) u[i][0] = u[i][1] = u[i][2] = 0.0f;
			else { float s = 1.0f / l; u[i][0] = s * d[i][0]; u[i][1] = s * d[i][1]; u[i][2] = s * d[i][2]; }
		}
		float acc[3] = {0, 0, 0};
		for (int i = 0; i < n; ++i)
		{
			double s = 0.0;
			for (int j = 0; j < n; ++j)
			{
				if (i == j) continue;
				double p = ((double)d[j][0] * u[i][0] + (double)u[i][1] * d[j][1] + (double)d[j][2] * u[i][2]) * (double)v.infl[j].w;
				s = 0.0 <= p ? p + s : s - p;
			}
			double q = (double)v.infl[i].w * (double)L[i];
			if (1e-4 < q)
			{
				double e = exp((s * v.damping) / q);
				for (int k = 0; k < 3; ++k)
					acc[k] = (float)(e * d[i][k] + acc[k]);
			}
		}
		for (int i = 0; i < n; ++i)
		{
			const Influence &f = v.infl[i];
			float share = 1e-4f <= sumW ? f.w / sumW : 1.0f / (float)n;
			const MuscleData &m = muscles[f.muscle];
			if (!m.bone)
				for (int k = 0; k < 3; ++k) acc[k] = share * v.rest[k] + acc[k];
			else
			{
				float p[3];
				TransformPoint(v.rest, m.bone->world, p);
				for (int k = 0; k < 3; ++k) acc[k] = p[k] * share + acc[k];
			}
		}
		out[0] = acc[0]; out[1] = acc[1]; out[2] = acc[2];
	}

	bool Process(float *vertexArray, int step) override
	{
		if (!vertexArray) return false;
		for (BoneData &b : bones)
			b.UpdateWorld();
		for (const Vertex &v : verts)
			if (v.index >= 0 && v.index < nVertices)
				ProcessVertex(v, vertexArray + (size_t)v.index * step);
		if (fill)
			for (const StaticVertex &s : unused)
				if (s.index >= 0 && s.index < nVertices)
				{
					float *o = vertexArray + (size_t)s.index * step;
					o[0] = s.pos[0]; o[1] = s.pos[1]; o[2] = s.pos[2];
				}
		ProcessNeck(vertexArray, step);
		return true;
	}
	int VerticesCount() const override { return nVertices; }

	// Save writes the compact layout (0x6600ae10 with the weights left out); Load reads it back. A baked custom
	// head travels through saved games in this form.
	void Serialize(std::vector<char> &out) const
	{
		const auto I = [&out](uint32_t v) { const char *p = (const char *)&v; out.insert(out.end(), p, p + 4); };
		const auto F = [&out](float v) { const char *p = (const char *)&v; out.insert(out.end(), p, p + 4); };
		const auto Name = [&out](const std::string &n)
		{
			size_t len = n.size() > 255 ? 255 : n.size();
			out.push_back((char)len);
			out.insert(out.end(), n.begin(), n.begin() + len);
		};
		const auto Matrix = [&F](const Mat4 &M)
		{
			for (int row = 0; row < 4; ++row)
				for (int col = 0; col < 3; ++col) F(M.m[row][col]);
		};
		I(0x37D30DC0u); I((uint32_t)muscles.size()); I((uint32_t)nVertices); I((uint32_t)verts.size());
		I((uint32_t)bones.size()); I(0); I((uint32_t)userItems.size()); I(0); I(recomputeWeights ? 1u : 0u);
		for (const MuscleData &m : muscles)
		{
			Name(m.name);
			for (int k = 0; k < 3; ++k) F(m.A[k]);
			for (int k = 0; k < 3; ++k) F(m.B[k]);
			I(0);
			if (recomputeWeights)
			{
				for (int k = 0; k < 10; ++k) F(k < m.nKeys ? m.keyX[k] : 0.0f);
				for (int k = 0; k < 10; ++k) F(k < m.nKeys ? m.keyY[k] : 0.0f);
				I((uint32_t)m.nKeys);
			}
		}
		for (const Vertex &v : verts)
		{
			I((uint32_t)v.index);
			for (int k = 0; k < 3; ++k) F(v.rest[k]);
			I((uint32_t)v.infl.size());
			for (const Influence &f : v.infl) { I((uint32_t)f.muscle); F(f.a); }
		}
		for (const BoneData &b : bones)
		{
			Name(b.name);
			I((uint32_t)b.muscles.size());
			I((uint32_t)b.parentIndex);
			Matrix(b.rest);
			Matrix(b.restInv);
			I(b.flags);
			for (int m : b.muscles) I((uint32_t)m);
		}
		for (const StaticVertex &s : unused)
		{
			I((uint32_t)s.index);
			for (int k = 0; k < 3; ++k) F(s.pos[k]);
		}
		for (const UserSet &u : userItems)
		{
			Name(u.name);
			I((uint32_t)nVertices);
			I((uint32_t)u.indices.size());
			for (int i : u.indices) I((uint32_t)i);
		}
	}
	int SaveBufferSize() override
	{
		std::vector<char> buffer;
		Serialize(buffer);
		return (int)buffer.size();
	}
	bool Save(char *buffer) override
	{
		if (!buffer) return false;
		std::vector<char> data;
		Serialize(data);
		memcpy(buffer, data.data(), data.size());
		return true;
	}
	IMuscle *MuscleByName(const char *name) override
	{
		for (MuscleData &m : muscles) if (name && m.name == name) return &m;
		return nullptr;
	}
	IMuscle *Muscle(int i) override { return i >= 0 && i < (int)muscles.size() ? &muscles[i] : nullptr; }
	int MusclesCount() const override { return (int)muscles.size(); }
	IBone *BoneByName(const char *name) override
	{
		for (BoneData &b : bones) if (name && b.name == name) return &b;
		return nullptr;
	}
	IBone *Bone(int i) override { return i >= 0 && i < (int)bones.size() ? &bones[i] : nullptr; }
	IBone *BoneByType(unsigned long type, IBone *prev) override
	{
		bool started = prev == nullptr;
		for (BoneData &b : bones)
		{
			if (!started) { if (&b == prev) started = true; continue; }
			if ((b.flags & 0xffu) == type) return &b;
		}
		return nullptr;
	}
	int BonesCount() const override { return (int)bones.size(); }
	void FillUnused(bool f) override { fill = f; }
	bool FillUnused() const override { return fill; }
	// --- neck (compact heads with Neck_Upper_n / Neck_Lower_n / Neck_Zone_n vertex sets) -----------------
	// Line n runs from the Neck_Lower_n vertex to the Neck_Upper_n vertex; a third "axis" line runs between
	// the pivots of the bones typed 4 and 3. Every vertex of Neck_Zone_n is rebuilt each frame as a weighted
	// sum of points on lines n, n+1 and the axis, at the heights and barycentric weights it had at rest, so
	// the neck skin follows the head without its own muscles.
	std::vector<NeckLine> neckLines, neckRest;
	NeckLine neckAxis, neckAxisRest;
	std::vector<NeckVertex> neckVerts;
	std::vector<int> neckCount;

	const UserSet *FindUserItem(const char *name) const
	{
		for (const UserSet &u : userItems) if (u.name == name) return &u;
		return nullptr;
	}
	const BoneData *BoneOfType(unsigned type) const
	{
		for (const BoneData &b : bones) if ((b.flags & 0xffu) == type) return &b;
		return nullptr;
	}
	bool UpdateNeckAxis(NeckLine &axis) const
	{
		const BoneData *top = BoneOfType(3), *base = BoneOfType(4);
		if (!top || !base) return false;
		for (int k = 0; k < 3; ++k)
		{
			axis.org[k] = base->restWorld.m[3][k];
			axis.dir[k] = top->restWorld.m[3][k] - axis.org[k];
		}
		return true;
	}
	// heights on the three lines and barycentric weights of p (in the plane z = p.z)
	static void NeckCoords(const NeckLine *L[3], const float p[3], NeckVertex &nv)
	{
		float q[3][2];
		for (int k = 0; k < 3; ++k)
		{
			float t = (p[2] - L[k]->org[2]) / L[k]->dir[2];
			nv.t[k] = t;
			q[k][0] = t * L[k]->dir[0] + L[k]->org[0];
			q[k][1] = t * L[k]->dir[1] + L[k]->org[1];
		}
		float e1x = q[1][0] - q[0][0], e1y = q[1][1] - q[0][1];
		float e2x = q[2][0] - q[0][0], e2y = q[2][1] - q[0][1];
		float inv = 1.0f / (e2y * e1x - e2x * e1y);
		float dx = p[0] - q[0][0], dy = p[1] - q[0][1];
		float b1 = (dx * e2y - dy * e2x) * inv;
		float b2 = (dy * e1x - dx * e1y) * inv;
		nv.w[1] = b1; nv.w[2] = b2; nv.w[0] = (1.0f - b1) - b2;
	}
	void SetupNeck()
	{
		neckLines.clear(); neckRest.clear(); neckVerts.clear(); neckCount.clear();
		if (userItems.empty() || nVertices <= 0) return;
		for (BoneData &b : bones) b.UpdateWorld();
		std::vector<float> P((size_t)nVertices * 3, 0.0f);
		bool oldFill = fill;
		fill = true;
		Process(P.data(), 3);
		fill = oldFill;
		char name[64];
		for (int i = 0;; ++i)
		{
			snprintf(name, sizeof name, "Neck_Upper_%d", i);
			const UserSet *up = FindUserItem(name);
			if (!up) break;
			snprintf(name, sizeof name, "Neck_Lower_%d", i);
			const UserSet *lo = FindUserItem(name);
			if (!lo || up->indices.size() != 1 || lo->indices.size() != 1) { neckLines.clear(); return; }
			NeckLine L;
			L.upper = up->indices[0]; L.lower = lo->indices[0];
			if (L.upper < 0 || L.upper >= nVertices || L.lower < 0 || L.lower >= nVertices) { neckLines.clear(); return; }
			for (int k = 0; k < 3; ++k)
			{
				L.org[k] = P[L.lower * 3 + k];
				L.dir[k] = P[L.upper * 3 + k] - L.org[k];
			}
			neckLines.push_back(L);
		}
		const int n = (int)neckLines.size();
		if (n == 0 || !UpdateNeckAxis(neckAxis)) { neckLines.clear(); return; }
		neckRest = neckLines;
		neckAxisRest = neckAxis;
		std::vector<const UserSet *> zones(n);
		for (int i = 0; i < n; ++i)
		{
			snprintf(name, sizeof name, "Neck_Zone_%d", i);
			zones[i] = FindUserItem(name);
			if (!zones[i]) { neckLines.clear(); neckRest.clear(); return; }
		}
		neckCount.assign(nVertices, 0);
		for (int i = 0; i < n; ++i)
			for (int v : zones[i]->indices)
			{
				if (v < 0 || v >= nVertices) continue;
				++neckCount[v];
				NeckVertex nv;
				nv.v = v; nv.l0 = i; nv.l1 = (i + 1) % n;
				const NeckLine *L[3] = {&neckRest[nv.l0], &neckRest[nv.l1], &neckAxisRest};
				NeckCoords(L, &P[v * 3], nv);
				neckVerts.push_back(nv);
			}
		for (NeckVertex &nv : neckVerts)
			if (neckCount[nv.v] > 1)
				for (int k = 0; k < 3; ++k) nv.w[k] = nv.w[k] / (float)neckCount[nv.v];
	}
	void ProcessNeck(float *out, int step)
	{
		if (neckLines.empty()) return;
		if (neck2)
			for (NeckVertex &nv : neckVerts)
			{
				const NeckLine *L[3] = {&neckRest[nv.l0], &neckRest[nv.l1], &neckAxisRest};
				NeckCoords(L, out + (size_t)nv.v * step, nv);
				for (int k = 0; k < 3; ++k) nv.w[k] = nv.w[k] / (float)neckCount[nv.v];
			}
		for (NeckLine &L : neckLines)
		{
			const float *lo = out + (size_t)L.lower * step, *up = out + (size_t)L.upper * step;
			for (int k = 0; k < 3; ++k) { L.org[k] = lo[k]; L.dir[k] = up[k] - lo[k]; }
		}
		UpdateNeckAxis(neckAxis);
		for (const NeckVertex &nv : neckVerts)
		{
			float *o = out + (size_t)nv.v * step;
			o[0] = o[1] = o[2] = 0.0f;
		}
		for (const NeckVertex &nv : neckVerts)
		{
			float *o = out + (size_t)nv.v * step;
			const NeckLine *L[3] = {&neckLines[nv.l0], &neckLines[nv.l1], &neckAxis};
			for (int k = 0; k < 3; ++k)
				for (int c = 0; c < 3; ++c)
					o[c] = (L[k]->dir[c] * nv.t[k] + L[k]->org[c]) * nv.w[k] + o[c];
		}
	}

	void ClearAllMacroMuscles() override
	{
		std::fill(addSum.begin(), addSum.end(), 0.0f); std::fill(addWeight.begin(), addWeight.end(), 0.0f);
		std::fill(multSum.begin(), multSum.end(), 0.0f); std::fill(multWeight.begin(), multWeight.end(), 0.0f);
		std::fill(multBlend.begin(), multBlend.end(), 0.0f);
		if (collect)
			for (CollectedItem &c : collected) c.values.clear();
	}

	// --- macro muscles ---------------------------------------------------------------------------------
	// leaf record -> first animator channel (-1: this head has no such muscle/bone)
	std::map<const MMNode *, int> leafChannel;
	float multLevel = 0.0f;          // blend weight of the latest MultMacroMuscle, (e + 1) / 2
	std::vector<CollectedItem> collected;

	int ChannelFor(const MMNode *leaf) const
	{
		if (leaf->kind == 3)
		{
			for (size_t i = 0; i < muscles.size(); ++i)
				if (muscles[i].name == leaf->name) return muscles[i].channel;
		}
		else if (leaf->kind == 4)
		{
			for (size_t i = 0; i < bones.size(); ++i)
				if (bones[i].name == leaf->name) return bones[i].channel;
		}
		return -1;
	}
	template<class F> static void ForEachLeaf(const MMNode *n, F &&f, std::vector<const MMNode *> &seen)
	{
		const MMNode *t = n->target;
		if (std::find(seen.begin(), seen.end(), t) != seen.end()) return;
		seen.push_back(t);
		if (t->IsLeaf()) { f(t); return; }
		for (const MMNode *c : t->children) ForEachLeaf(c, f, seen);
	}
	void RegisterMacroMuscle(IMacroMuscle *mm) override
	{
		if (!mm) return;
		std::vector<const MMNode *> seen;
		ForEachLeaf(static_cast<MMNode *>(mm), [&](const MMNode *leaf) { leafChannel[leaf] = ChannelFor(leaf); }, seen);
	}
	void UnregisterMacroMuscle(IMacroMuscle *mm) override
	{
		if (!mm) return;
		std::vector<const MMNode *> seen;
		ForEachLeaf(static_cast<MMNode *>(mm), [&](const MMNode *leaf) { leafChannel.erase(leaf); }, seen);
	}
	void ClearAllRegistration() override { leafChannel.clear(); }

	void Accumulate(const MMNode *leaf, float v, bool mult)
	{
		if (leaf->kind == 5)
		{
			if (!collect) return;
			for (CollectedItem &c : collected)
				if (c.name == leaf->name) { c.values.push_back(v); return; }
			collected.push_back(CollectedItem{leaf->name, std::vector<float>(1, v)});
			return;
		}
		std::map<const MMNode *, int>::const_iterator it = leafChannel.find(leaf);
		if (it == leafChannel.end() || it->second < 0) return;
		int ch = it->second;
		if (leaf->kind == 4)
		{
			if (leaf->axis < 1 || leaf->axis > 3) return;
			ch += leaf->axis - 1;
		}
		if (ch < 0 || ch >= (int)addSum.size()) return;
		// each contribution counts with weight |v|: the channel ends up with sum(v|v|) / sum(|v|)
		float &sum = mult ? multSum[ch] : addSum[ch];
		float &weight = mult ? multWeight[ch] : addWeight[ch];
		if (0.0f < v) { sum = v * v + sum; weight = v + weight; }
		else { sum = sum - v * v; weight = weight - v; }
		if (mult && multBlend[ch] <= multLevel) multBlend[ch] = multLevel;
	}
	void Propagate(const MMNode *node, float v, bool mult, int depth)
	{
		const MMNode *t = node->target;
		if (t->IsLeaf()) { Accumulate(t, v, mult); return; }
		if (depth > 64) return;
		for (const MMNode *c : t->children)
		{
			if (c->muted & 1) continue;
			float cv = c->Response(v);
			if (c->target->IsLeaf()) Accumulate(c->target, cv, mult);
			else Propagate(c, cv, mult, depth + 1);
		}
	}
	void AddMacroMuscle(IMacroMuscle *mm, float e) override
	{
		if (!mm) return;
		if (e < -1.0f) e = -1.0f; else if (1.0f < e) e = 1.0f;
		Propagate(static_cast<MMNode *>(mm), e, false, 0);
	}
	void MultMacroMuscle(IMacroMuscle *mm, float e) override
	{
		multLevel = (e + 1.0f) * 0.5f;
		if (!mm) return;
		if (e < -1.0f) e = -1.0f; else if (1.0f < e) e = 1.0f;
		Propagate(static_cast<MMNode *>(mm), e, true, 0);
	}
	// resolve every channel: muscles take it as tension, bones as one of their three angles
	void ComputePhysics() override
	{
		const int nm = (int)muscles.size();
		for (int k = 0; k < (int)addSum.size(); ++k)
		{
			float a = 1e-4f <= addWeight[k] ? addSum[k] / addWeight[k] : 0.0f;
			float m = 1e-4f <= multWeight[k] ? multSum[k] / multWeight[k] : 0.0f;
			float v = (float)((double)m * multBlend[k] + (double)a * (1.0 - (double)multBlend[k]));
			if (k < nm) muscles[k].SetTension(v);
			else
			{
				int b = (k - nm) / 3;
				if (b < (int)bones.size()) bones[b].angle[(k - nm) % 3] = v;
			}
		}
		for (BoneData &b : bones)
		{
			EulerMatrix(b.angle[0], b.angle[1], b.angle[2], b.rot);
			b.UpdateLocal();
		}
	}
	void CollectUserItems(bool u) override { collect = u; }
	bool CollectUserItems() const override { return collect; }
	UserID UserItem(const char *name) override
	{
		if (!name) return -1;
		for (size_t i = 0; i < collected.size(); ++i)
			if (collected[i].name == name) return (UserID)i;
		return -1;
	}
	int UserValuesCount(UserID id) override { return id >= 0 && id < (int)collected.size() ? (int)collected[id].values.size() : 0; }
	float UserValue(UserID id, int i) override
	{
		if (id < 0 || id >= (int)collected.size() || i < 0 || i >= (int)collected[id].values.size()) return 0.0f;
		return collected[id].values[i];
	}
	void ClearUserItems() override { collected.clear(); }
	void ComputeBonesHierarchy() override {}
	bool HasNeck() const override { return !neckLines.empty(); }
	void NeckProcessing2(bool u) override { neck2 = u; }
	bool NeckProcessing2() const override { return neck2; }
	IAnimator *Clone() override
	{
		AnimatorT<IAnimator> *c = new AnimatorT<IAnimator>();
		c->muscles = muscles; c->bones = bones; c->verts = verts; c->unused = unused; c->userItems = userItems;
		c->nVertices = nVertices; c->recomputeWeights = recomputeWeights; c->fill = fill; c->collect = collect; c->neck2 = neck2;
		c->addSum = addSum; c->addWeight = addWeight; c->multSum = multSum; c->multWeight = multWeight; c->multBlend = multBlend;
		c->leafChannel = leafChannel; c->multLevel = multLevel;
		c->neckLines = neckLines; c->neckRest = neckRest; c->neckAxis = neckAxis; c->neckAxisRest = neckAxisRest;
		c->neckVerts = neckVerts; c->neckCount = neckCount;
		for (MuscleData &m : c->muscles) m.bone = nullptr;
		c->LinkBones();
		return c;
	}
	void Destroy() override { delete this; }
	virtual ~AnimatorT() {}
};
typedef AnimatorT<IAnimator> Animator;

// ---------------------------------------------------------------------------------------------------------
// The head space of Morph.txt (the text form of IMorphFile.dll's description). Sliders span a grid in percent;
// a HEAD line names the sculpted head at one grid point, a COMB line mixes heads at another:
//   SLIDER Age ...                                                  (labels after the name are editor text)
//   HEAD   Age=-25 Gender=100 African=-100 Asian=-100 Arab=-100 EuroM
//   COMB   Age=-25 Gender=100 African=100 Asian=100 Arab=100 AsianM=33 ArabM=33 AfricanM
// The last head of a COMB line takes what is left of 100. Those percentages stay percentages: TriangLib multiplies
// them by the corner weight without dividing (0x66a01595, 0x66a03850), so where a pure head corner and a COMB
// corner share a cell the COMB corner counts a hundred times more, until the sum is normalised at the end.
// Query (TriangLib 0x66a041d0, 0x66a04930): in each dimension take the nearest grid coordinates around the value;
// the 2^n corners of that cell get multilinear weights and each corner resolves to the point within 0.1 of it.
// TriangLib falls back to a simplex search through the nearest points when a corner has no point (0x66a07370). The
// shipped grid has none (3 ages x 2 genders x 8 race mixes = 48 points), so Parse refuses a grid with holes
// instead of guessing.
struct MorphSpace
{
	struct Point
	{
		std::vector<float> at;
		std::vector<std::pair<int, float>> heads;   // head index, weight
	};
	std::vector<std::string> sliders, headFiles;
	std::vector<Point> points;
	std::vector<std::vector<float>> coords;         // grid coordinates per dimension, ascending

	static std::vector<std::string> Tokens(const std::string &line)
	{
		std::vector<std::string> out;
		size_t i = 0;
		while (i < line.size())
		{
			while (i < line.size() && isspace((unsigned char)line[i])) ++i;
			size_t j = i;
			while (j < line.size() && !isspace((unsigned char)line[j])) ++j;
			if (j > i) out.push_back(line.substr(i, j - i));
			i = j;
		}
		return out;
	}
	int SliderIndex(const std::string &name) const
	{
		for (size_t i = 0; i < sliders.size(); ++i) if (sliders[i] == name) return (int)i;
		return -1;
	}
	int HeadIndex(const std::string &name) const
	{
		for (size_t i = 0; i < headFiles.size(); ++i) if (headFiles[i] == name) return (int)i;
		return -1;
	}
	// the slider values of a HEAD or COMB line; returns the index of the first token after them, or 0
	size_t ReadPosition(const std::vector<std::string> &t, Point &p) const
	{
		p.at.assign(sliders.size(), 0.0f);
		size_t n = 1;
		for (size_t got = 0; got < sliders.size(); ++got, ++n)
		{
			if (n >= t.size()) return 0;
			size_t eq = t[n].find('=');
			if (eq == std::string::npos) return 0;
			int s = SliderIndex(t[n].substr(0, eq));
			if (s < 0) return 0;
			p.at[s] = (float)atoi(t[n].c_str() + eq + 1);
		}
		return n;
	}
	bool Parse(const char *text, int size)
	{
		sliders.clear(); headFiles.clear(); points.clear(); coords.clear();
		std::vector<Point> combs;
		std::string all(text, (size_t)size);
		size_t pos = 0;
		while (pos < all.size())
		{
			size_t eol = all.find('\n', pos);
			if (eol == std::string::npos) eol = all.size();
			std::vector<std::string> t = Tokens(all.substr(pos, eol - pos));
			pos = eol + 1;
			if (t.empty()) continue;
			if (t[0] == "SLIDER")
			{
				if (t.size() < 2 || !points.empty()) return false;
				sliders.push_back(t[1]);
			}
			else if (t[0] == "HEAD")
			{
				Point p;
				size_t n = ReadPosition(t, p);
				if (n == 0 || n + 1 != t.size() || !combs.empty()) return false;
				p.heads.push_back(std::make_pair((int)headFiles.size(), 1.0f));
				headFiles.push_back(t[n]);
				points.push_back(p);
			}
			else if (t[0] == "COMB")
			{
				Point p;
				size_t n = ReadPosition(t, p);
				if (n == 0 || n >= t.size()) return false;
				int left = 100;
				for (; n < t.size(); ++n)
				{
					size_t eq = t[n].find('=');
					int percent = eq == std::string::npos ? left : atoi(t[n].c_str() + eq + 1);
					int h = HeadIndex(t[n].substr(0, eq));
					if (h < 0) return false;
					left -= percent;
					p.heads.push_back(std::make_pair(h, (float)percent));
				}
				combs.push_back(p);
			}
			else
				return false;
		}
		points.insert(points.end(), combs.begin(), combs.end());
		if (sliders.empty() || headFiles.empty() || sliders.size() > 16) return false;
		const size_t dims = sliders.size();
		coords.resize(dims);
		for (const Point &p : points)
			for (size_t d = 0; d < dims; ++d)
				if (std::find(coords[d].begin(), coords[d].end(), p.at[d]) == coords[d].end())
					coords[d].push_back(p.at[d]);
		size_t cells = 1;
		for (std::vector<float> &c : coords) { std::sort(c.begin(), c.end()); cells *= c.size(); }
		std::vector<float> corner(dims);
		std::vector<size_t> index(dims, 0);
		for (size_t i = 0; i < cells; ++i)
		{
			for (size_t d = 0; d < dims; ++d) corner[d] = coords[d][index[d]];
			if (!Find(corner.data())) return false;
			for (size_t d = 0; d < dims && ++index[d] == coords[d].size(); ++d) index[d] = 0;
		}
		return true;
	}
	const Point *Find(const float *at) const
	{
		const size_t dims = sliders.size();
		for (const Point &p : points)
		{
			double sum = 0.0;
			for (size_t d = 0; d < dims; ++d) sum += (double)(p.at[d] - at[d]) * (p.at[d] - at[d]);
			if (sum < 0.01) return &p;
		}
		return nullptr;
	}
	// raw weight of every head for a slider position; the caller normalises
	void Weights(const float *value, std::vector<float> &out) const
	{
		out.assign(headFiles.size(), 0.0f);
		const size_t dims = sliders.size();
		if (const Point *exact = Find(value))
		{
			for (const std::pair<int, float> &h : exact->heads) out[h.first] = h.second;
			return;
		}
		std::vector<float> lo(dims), hi(dims), t(dims), corner(dims);
		for (size_t d = 0; d < dims; ++d)
		{
			const std::vector<float> &c = coords[d];
			size_t i = 0;
			while (i + 2 < c.size() && c[i + 1] <= value[d]) ++i;
			lo[d] = c[i];
			hi[d] = c.size() > 1 ? c[i + 1] : c[i];
			t[d] = hi[d] > lo[d] ? (value[d] - lo[d]) / (hi[d] - lo[d]) : 0.0f;
		}
		for (size_t mask = 0; mask < ((size_t)1 << dims); ++mask)
		{
			float w = 1.0f;
			for (size_t d = 0; d < dims; ++d)
			{
				bool upper = (mask >> d) & 1;
				w = (upper ? t[d] : 1.0f - t[d]) * w;
				corner[d] = upper ? hi[d] : lo[d];
			}
			if (const Point *p = Find(corner.data()))
				for (const std::pair<int, float> &h : p->heads)
					out[h.first] = w * h.second + out[h.first];
		}
	}
};

// ---------------------------------------------------------------------------------------------------------
// ITransformer: the sculpted head (0x6600f600 + 0x660123e0). Morph.txt lists heads; each has two animators, %s_A.mld
// (the animation muscles and bones the game plays sequences on) and %s_M.mld (129 sculpting muscles over the
// same 419 vertices). The transformer keeps one blended copy of each:
//   ComputePhysics: the macro tree's Age, Gender, African, Asian and Arab leaves average into slider values; the
//     head space turns them into head weights; both copies become the weighted mean of their heads (muscle ends,
//     falloff keys, bone origins, vertices). The other leaves are tensions of the sculpting muscles.
//   Generate: the sculpting muscles deform the blended vertices. Those vertices become the rest pose of the output
//     animator, a copy of the animation half, so the morphed face still blinks and talks.
// Links.dat maps sculpting muscles to the animation muscle ends and bones they should drag along (0x66011bb0). In
// the shipped FaceGenHead.gdp every byte of that matrix is zero and its names predate the .mld files, so the
// animation rig follows the head blend only; the mapping is kept for fidelity with 0x66012300.
struct Transformer final : AnimatorT<ITransformer>
{
	struct Target { int kind, index; };          // 0 muscle start, 1 muscle end, 2 bone origin
	static const int kMaxSliderValues = 20;
	MorphSpace space;
	std::vector<int> headToUnique;
	std::vector<Animator *> animHeads, morphHeads;   // one per distinct head file
	std::vector<std::vector<float>> headVerts;
	Animator *curA = nullptr, *curM = nullptr;
	IAnimator *out = nullptr;
	std::vector<std::vector<Target>> links;       // per sculpting muscle
	std::vector<float> blended, morphed, headWeights, uniqueWeights, sliderValue;
	std::vector<int> sliderCount;
	std::vector<float> sliderSamples;             // kMaxSliderValues per slider
	std::map<const MMNode *, int> sliderLeaf;

	~Transformer() override { Unload(); }
	void Unload()
	{
		for (Animator *a : animHeads) delete a;
		for (Animator *a : morphHeads) delete a;
		animHeads.clear(); morphHeads.clear(); headVerts.clear(); headToUnique.clear();
		delete curA; delete curM;
		curA = curM = nullptr;
		links.clear();
		sliderLeaf.clear();
	}

	static Animator *LoadAnimator(ITransformerInput *input, const char *fileName)
	{
		int size = input->Size(fileName);
		if (size < 1) return nullptr;
		std::vector<char> data((size_t)size);
		if (!input->Get(fileName, data.data())) return nullptr;
		Animator *a = new Animator();
		if (!a->Load(data.data(), size)) { delete a; return nullptr; }
		return a;
	}
	static bool SameRig(const Animator &a, const Animator &b)
	{
		if (a.nVertices != b.nVertices || a.muscles.size() != b.muscles.size() || a.bones.size() != b.bones.size())
			return false;
		for (size_t i = 0; i < a.muscles.size(); ++i) if (a.muscles[i].name != b.muscles[i].name) return false;
		for (size_t i = 0; i < a.bones.size(); ++i) if (a.bones[i].name != b.bones[i].name) return false;
		return true;
	}
	// 0x6600fa50 and 0x660132d0
	bool Load(ITransformerInput *input) override
	{
		Unload();
		if (!input) return false;
		int size = input->Size("Morph.txt");
		if (size < 1) return false;
		std::vector<char> text((size_t)size);
		if (!input->Get("Morph.txt", text.data()) || !space.Parse(text.data(), size)) return false;

		std::vector<std::string> unique;
		for (const std::string &file : space.headFiles)
		{
			std::vector<std::string>::iterator it = std::find(unique.begin(), unique.end(), file);
			headToUnique.push_back((int)(it - unique.begin()));
			if (it != unique.end()) continue;
			unique.push_back(file);
			Animator *a = LoadAnimator(input, (file + "_A.mld").c_str());
			if (a) animHeads.push_back(a);
			Animator *m = LoadAnimator(input, (file + "_M.mld").c_str());
			if (m) morphHeads.push_back(m);
			if (!a || !m || a->nVertices != m->nVertices) { Unload(); return false; }
			if (!SameRig(*animHeads[0], *a) || !SameRig(*morphHeads[0], *m)) { Unload(); return false; }
			headVerts.push_back(std::vector<float>((size_t)m->nVertices * 3));
			m->FillUnused(true);
			m->Process(headVerts.back().data(), 3);
		}
		curA = static_cast<Animator *>(animHeads[0]->Clone());
		curM = static_cast<Animator *>(morphHeads[0]->Clone());
		if (!LoadLinks(input)) { Unload(); return false; }
		const size_t dims = space.sliders.size(), verts = (size_t)curM->nVertices;
		blended.assign(verts * 3, 0.0f);
		morphed.assign(verts * 3, 0.0f);
		sliderValue.assign(dims, 0.0f);
		sliderCount.assign(dims, 0);
		sliderSamples.assign(dims * kMaxSliderValues, 0.0f);
		uniqueWeights.assign(unique.size(), 0.0f);
		return true;
	}
	// 0x66013af0: [magic, nMorph, nRig][64-byte names * (nMorph + nRig)][nRig flag bytes * nMorph]
	bool LoadLinks(ITransformerInput *input)
	{
		links.assign(curM->muscles.size(), std::vector<Target>());
		int size = input->Size("Links.dat");
		if (size < 0) return false;                // no matrix: LifeStudio links everything; not in the shipped data
		std::vector<char> data((size_t)size);
		if (!input->Get("Links.dat", data.data())) return false;
		Reader r(data.data(), size);
		uint32_t magic = r.U();
		int nMorph = r.I(), nRig = r.I();
		if (r.bad || magic != 0x22D7118Eu || nMorph < 0 || nRig < 0) return false;
		if ((size_t)size < 12 + ((size_t)nMorph + nRig) * 64 + (size_t)nMorph * nRig) return false;
		const auto MuscleOf = [](const Animator &a, const std::string &n)
		{
			for (size_t i = 0; i < a.muscles.size(); ++i) if (a.muscles[i].name == n) return (int)i;
			return -1;
		};
		std::vector<int> row((size_t)nMorph), column((size_t)nRig);
		std::vector<bool> isBone((size_t)nRig, false);
		for (int i = 0; i < nMorph; ++i) row[i] = MuscleOf(*curM, r.FixedName(64));
		for (int i = 0; i < nRig; ++i)
		{
			std::string n = r.FixedName(64);
			column[i] = MuscleOf(*curA, n);
			if (column[i] >= 0) continue;
			for (size_t b = 0; b < curA->bones.size(); ++b)
				if (curA->bones[b].name == n) { column[i] = (int)b; isBone[i] = true; break; }
		}
		for (int i = 0; i < nMorph; ++i)
			for (int j = 0; j < nRig; ++j)
			{
				unsigned char flag = (unsigned char)*r.p++;
				if (!flag || row[i] < 0 || column[j] < 0) continue;
				std::vector<Target> &l = links[row[i]];
				if (isBone[j]) l.push_back(Target{2, column[j]});
				else
				{
					if (flag & 1) l.push_back(Target{0, column[j]});
					if (flag & 2) l.push_back(Target{1, column[j]});
				}
			}
		return true;
	}

	// 0x66010450: animator = weighted mean of its heads; the vertices are the blended head vertices
	static void Blend(Animator &a, const std::vector<Animator *> &heads, const std::vector<float> &w, const float *positions)
	{
		for (size_t i = 0; i < a.muscles.size(); ++i)
		{
			float A[3] = {0, 0, 0}, B[3] = {0, 0, 0}, x[5] = {0, 0, 0, 0, 0}, y[5] = {0, 0, 0, 0, 0};
			for (size_t h = 0; h < heads.size(); ++h)
			{
				const float f = w[h];
				if (f < 1e-4f) continue;
				const MuscleData &m = heads[h]->muscles[i];
				for (int k = 0; k < 3; ++k) { A[k] = f * m.A[k] + A[k]; B[k] = f * m.B[k] + B[k]; }
				for (int k = 0; k < 5; ++k) { x[k] = f * m.keyX[k] + x[k]; y[k] = f * m.keyY[k] + y[k]; }
			}
			MuscleData &m = a.muscles[i];
			for (int k = 0; k < 3; ++k) { m.A[k] = A[k]; m.B[k] = B[k]; }
			m.UpdateRest();
			m.SetSpline(x, y, 5);
		}
		for (size_t i = 0; i < a.bones.size(); ++i)
		{
			float origin[3] = {0, 0, 0};
			for (size_t h = 0; h < heads.size(); ++h)
			{
				const float f = w[h];
				if (f < 1e-4f) continue;
				for (int k = 0; k < 3; ++k) origin[k] = f * heads[h]->bones[i].rest.m[3][k] + origin[k];
			}
			MoveBone(a.bones[i], origin);
		}
		a.UpdateParameters(positions);
	}
	static void MoveBone(BoneData &b, const float origin[3])
	{
		for (int k = 0; k < 3; ++k) b.rest.m[3][k] = origin[k];
		RigidInverse(b.rest, b.restInv);
		b.UpdateLocal();
	}
	// 0x66010830 with the weights of 0x66010aa0/0x66010cc0
	void BlendHeads()
	{
		space.Weights(sliderValue.data(), headWeights);
		std::fill(uniqueWeights.begin(), uniqueWeights.end(), 0.0f);
		for (size_t h = 0; h < headWeights.size(); ++h)
			uniqueWeights[headToUnique[h]] = headWeights[h] + uniqueWeights[headToUnique[h]];
		float sum = 0.0f;
		for (float f : uniqueWeights) sum += f;
		if (1e-5f < sum) for (float &f : uniqueWeights) f = f / sum;
		else { std::fill(uniqueWeights.begin(), uniqueWeights.end(), 0.0f); uniqueWeights[0] = 1.0f; }
		std::fill(blended.begin(), blended.end(), 0.0f);
		for (size_t h = 0; h < uniqueWeights.size(); ++h)
		{
			const float f = uniqueWeights[h];
			if (f < 1e-4f) continue;
			const std::vector<float> &v = headVerts[h];
			for (size_t i = 0; i < blended.size(); ++i) blended[i] = f * v[i] + blended[i];
		}
		Blend(*curA, animHeads, uniqueWeights, blended.data());
		Blend(*curM, morphHeads, uniqueWeights, blended.data());
	}

	// a point of the animation rig, moved by the sculpting muscles linked to it (0x66011bb0 + 0x660120e0)
	void Follow(const float rest[3], int kind, int index, float result[3])
	{
		for (int k = 0; k < 3; ++k) result[k] = rest[k];
		std::vector<Influence> infl;
		for (size_t m = 0; m < links.size(); ++m)
			for (const Target &t : links[m])
				if (t.kind == kind && t.index == index)
					infl.push_back(Influence{(int)m, curM->muscles[m].Parameter(rest), 0.0f});
		if (infl.empty()) return;
		Vertex v;
		for (int k = 0; k < 3; ++k) v.rest[k] = rest[k];
		v.SetInfluences(std::move(infl));
		curM->UpdateWeights(v);
		curM->ProcessVertex(v, result);
	}
	// 0x66012300: the output animator takes the blended rig, stretched as the sculpting moved it, and the morphed
	// vertices as its rest pose. Falloff distances scale with their muscle's length.
	void Fit(Animator &o)
	{
		for (BoneData &b : curM->bones) b.UpdateWorld();
		const size_t nm = curA->muscles.size();
		for (size_t i = 0; i < nm; ++i)
		{
			const MuscleData &src = curA->muscles[i];
			MuscleData &dst = o.muscles[i];
			Follow(src.A, 0, (int)i, dst.A);
			dst.UpdateRest();
			Follow(src.B, 1, (int)i, dst.B);
			dst.UpdateRest();
			dst.SetTension(0.0f);
			float x[10], y[10];
			const float scale = dst.len / src.len;
			for (int k = 0; k < src.nKeys; ++k) { x[k] = scale * src.keyX[k]; y[k] = src.keyY[k]; }
			dst.SetSpline(x, y, src.nKeys);
		}
		for (size_t i = 0; i < curA->bones.size(); ++i)
		{
			float origin[3];
			Follow(curA->bones[i].rest.m[3], 2, (int)i, origin);
			MoveBone(o.bones[i], origin);
		}
		o.UpdateParameters(morphed.data());
		o.SetupNeck();
	}

	void Generate() override
	{
		if (!curM || !out) return;
		curM->FillUnused(true);
		curM->Process(morphed.data(), 3);
		Fit(*static_cast<Animator *>(out));
	}
	void OutputAnimator(IAnimator *a) override
	{
		out = a;
		if (!a || !curA) return;
		std::vector<char> buffer;
		curA->Serialize(buffer);
		a->Load(buffer.data(), (int)buffer.size());
	}
	IAnimator *OutputAnimator() const override { return out; }

	// the slider leaves of the macro tree, along the same edges Propagate walks
	void CollectSliders(const MMNode *node, float v, int depth)
	{
		const MMNode *t = node->target;
		if (t->IsLeaf())
		{
			std::map<const MMNode *, int>::const_iterator it = sliderLeaf.find(t);
			if (it != sliderLeaf.end() && sliderCount[it->second] < kMaxSliderValues)
				sliderSamples[(size_t)it->second * kMaxSliderValues + sliderCount[it->second]++] = v;
			return;
		}
		if (depth > 64) return;
		for (const MMNode *c : t->children)
		{
			if (c->muted & 1) continue;
			CollectSliders(c, c->Response(v), depth + 1);
		}
	}
	void ClearAllMacroMuscles() override
	{
		if (!curM) return;
		std::fill(sliderCount.begin(), sliderCount.end(), 0);
		curM->ClearAllMacroMuscles();
	}
	void AddMacroMuscle(IMacroMuscle *mm, float e) override
	{
		if (!curM || !mm) return;
		if (e < -1.0f) e = -1.0f; else if (1.0f < e) e = 1.0f;
		CollectSliders(static_cast<MMNode *>(mm), e, 0);
		curM->AddMacroMuscle(mm, e);
	}
	void MultMacroMuscle(IMacroMuscle *mm, float e) override
	{
		if (!curM || !mm) return;
		if (e < -1.0f) e = -1.0f; else if (1.0f < e) e = 1.0f;
		CollectSliders(static_cast<MMNode *>(mm), e, 0);
		curM->MultMacroMuscle(mm, e);
	}
	// 0x66012a30: a slider is the mean of what reached it, in percent
	void ComputePhysics() override
	{
		if (!curM) return;
		for (size_t s = 0; s < sliderValue.size(); ++s)
		{
			const int n = sliderCount[s];
			float sum = 0.0f;
			for (int i = 0; i < n; ++i) sum += sliderSamples[s * kMaxSliderValues + i];
			sliderValue[s] = n ? (float)(sum * 100.0f / n) : 0.0f;
		}
		BlendHeads();
		curM->ComputePhysics();
	}
	void RegisterMacroMuscle(IMacroMuscle *mm) override
	{
		if (!curM || !mm) return;
		std::vector<const MMNode *> seen;
		ForEachLeaf(static_cast<MMNode *>(mm), [&](const MMNode *leaf)
		{
			int s = leaf->kind == 3 ? space.SliderIndex(leaf->name) : -1;
			if (s >= 0) sliderLeaf[leaf] = s;
		}, seen);
		curM->RegisterMacroMuscle(mm);
	}
	void UnregisterMacroMuscle(IMacroMuscle *mm) override
	{
		if (!curM || !mm) return;
		std::vector<const MMNode *> seen;
		ForEachLeaf(static_cast<MMNode *>(mm), [&](const MMNode *leaf) { sliderLeaf.erase(leaf); }, seen);
		curM->UnregisterMacroMuscle(mm);
	}
	void ClearAllRegistration() override { sliderLeaf.clear(); if (curM) curM->ClearAllRegistration(); }

	// the rest of the interface is the sculpting animator's (vtable 0x660375e0)
	using AnimatorT<ITransformer>::Load;
	bool Load(const char *, int) override { return false; }
	int SaveBufferSize() override { return -1; }
	bool Save(char *) override { return false; }
	bool Process(float *v, int step) override { return curM && curM->Process(v, step); }
	int VerticesCount() const override { return curM ? curM->VerticesCount() : 0; }
	IMuscle *MuscleByName(const char *n) override { return curM ? curM->MuscleByName(n) : nullptr; }
	IMuscle *Muscle(int i) override { return curM ? curM->Muscle(i) : nullptr; }
	int MusclesCount() const override { return curM ? curM->MusclesCount() : 0; }
	IBone *BoneByName(const char *n) override { return curM ? curM->BoneByName(n) : nullptr; }
	IBone *Bone(int i) override { return curM ? curM->Bone(i) : nullptr; }
	IBone *BoneByType(unsigned long t, IBone *prev) override { return curM ? curM->BoneByType(t, prev) : nullptr; }
	int BonesCount() const override { return curM ? curM->BonesCount() : 0; }
	void FillUnused(bool f) override { if (curM) curM->FillUnused(f); }
	bool FillUnused() const override { return curM && curM->FillUnused(); }
	void CollectUserItems(bool u) override { if (curM) curM->CollectUserItems(u); }
	bool CollectUserItems() const override { return curM && curM->CollectUserItems(); }
	UserID UserItem(const char *n) override { return curM ? curM->UserItem(n) : -1; }
	int UserValuesCount(UserID id) override { return curM ? curM->UserValuesCount(id) : 0; }
	float UserValue(UserID id, int i) override { return curM ? curM->UserValue(id, i) : 0.0f; }
	void ClearUserItems() override { if (curM) curM->ClearUserItems(); }
};

// ---------------------------------------------------------------------------------------------------------
// GDP files are OLE compound documents: a storage per object ("800"), with one stream per data file. GDPFile.dll
// opens them through ole32; here the sectors are walked directly. Stream names compare without case, as in OLE.
struct CompoundFile
{
	struct Entry { std::string name; int type = 0; uint32_t left = 0, right = 0, child = 0, start = 0, size = 0; };
	std::vector<char> data;
	std::vector<uint32_t> fat, miniFat;
	std::vector<Entry> entries;
	std::vector<char> miniStream;
	std::map<std::string, const Entry *> streams;  // "object/file", lower case
	uint32_t sectorSize = 512, miniSize = 64, cutoff = 4096;
	static const uint32_t kEnd = 0xFFFFFFFCu;      // FREE, END, FAT and DIFAT marks all compare at or above this

	uint32_t U32(size_t at) const
	{
		if (at + 4 > data.size()) return 0xFFFFFFFFu;
		uint32_t v;
		memcpy(&v, &data[at], 4);
		return v;
	}
	const char *Sector(uint32_t n) const
	{
		size_t at = ((size_t)n + 1) * sectorSize;
		return at + sectorSize <= data.size() ? &data[at] : nullptr;
	}
	std::vector<char> Chain(uint32_t n, size_t limit) const
	{
		std::vector<char> out;
		for (size_t guard = 0; n < kEnd && n < fat.size() && guard <= fat.size() && out.size() < limit; ++guard)
		{
			const char *s = Sector(n);
			if (!s) break;
			out.insert(out.end(), s, s + sectorSize);
			n = fat[n];
		}
		return out;
	}
	static std::string Lower(std::string s)
	{
		for (char &c : s) c = (char)tolower((unsigned char)c);
		return s;
	}
	void Walk(uint32_t i, const std::string &path, int depth)
	{
		if (i >= entries.size() || depth > 256) return;
		const Entry &e = entries[i];
		Walk(e.left, path, depth + 1);
		if (e.type == 2) streams[path + Lower(e.name)] = &e;
		else if (e.type == 1) Walk(e.child, path + Lower(e.name) + "/", depth + 1);
		Walk(e.right, path, depth + 1);
	}
	bool Open(const char *fileName)
	{
		data = ReadWholeFile(fileName);
		static const unsigned char magic[8] = {0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1};
		if (data.size() < 512 || memcmp(data.data(), magic, 8) != 0) return false;
		uint16_t shift, miniShift;
		memcpy(&shift, &data[30], 2);
		memcpy(&miniShift, &data[32], 2);
		if (shift < 7 || shift > 16 || miniShift > shift) return false;
		sectorSize = 1u << shift;
		miniSize = 1u << miniShift;
		const uint32_t nFat = U32(44), directory = U32(48), miniFatStart = U32(60), nMiniFat = U32(64);
		cutoff = U32(56);
		std::vector<uint32_t> fatSectors;
		for (int i = 0; i < 109; ++i) fatSectors.push_back(U32(76 + (size_t)i * 4));
		uint32_t difat = U32(68), nDifat = U32(72);
		for (uint32_t i = 0; i < nDifat && difat < kEnd; ++i)
		{
			if (!Sector(difat)) return false;
			size_t at = ((size_t)difat + 1) * sectorSize;
			for (uint32_t k = 0; k + 1 < sectorSize / 4; ++k) fatSectors.push_back(U32(at + (size_t)k * 4));
			difat = U32(at + sectorSize - 4);
		}
		for (uint32_t i = 0; i < nFat && i < fatSectors.size(); ++i)
		{
			if (fatSectors[i] >= kEnd) break;
			const char *s = Sector(fatSectors[i]);
			if (!s) return false;
			size_t first = fat.size();
			fat.resize(first + sectorSize / 4);
			memcpy(&fat[first], s, sectorSize / 4 * 4);
		}
		std::vector<char> mf = Chain(miniFatStart, (size_t)nMiniFat * sectorSize);
		miniFat.resize(mf.size() / 4);
		if (!mf.empty()) memcpy(miniFat.data(), mf.data(), miniFat.size() * 4);
		std::vector<char> dir = Chain(directory, (size_t)-1);
		for (size_t at = 0; at + 128 <= dir.size(); at += 128)
		{
			const unsigned char *p = (const unsigned char *)&dir[at];
			Entry e;
			uint16_t nameBytes;
			memcpy(&nameBytes, p + 64, 2);
			for (int i = 0; i + 2 < nameBytes && i < 64; i += 2) e.name.push_back((char)p[i]);   // the names are ASCII
			e.type = p[66];
			memcpy(&e.left, p + 68, 4);
			memcpy(&e.right, p + 72, 4);
			memcpy(&e.child, p + 76, 4);
			memcpy(&e.start, p + 116, 4);
			memcpy(&e.size, p + 120, 4);
			entries.push_back(e);
		}
		if (entries.empty()) return false;
		miniStream = Chain(entries[0].start, entries[0].size);
		Walk(entries[0].child, "", 0);
		return true;
	}
	const Entry *Find(const std::string &path) const
	{
		std::map<std::string, const Entry *>::const_iterator it = streams.find(Lower(path));
		return it == streams.end() ? nullptr : it->second;
	}
	bool Read(const Entry &e, char *out) const
	{
		if (e.size >= cutoff)
		{
			std::vector<char> s = Chain(e.start, e.size);
			if (s.size() < e.size) return false;
			memcpy(out, s.data(), e.size);
			return true;
		}
		size_t done = 0;
		for (uint32_t n = e.start; n < kEnd && n < miniFat.size() && done < e.size; n = miniFat[n])
		{
			size_t at = (size_t)n * miniSize, take = std::min((size_t)miniSize, (size_t)e.size - done);
			if (at + take > miniStream.size()) return false;
			memcpy(out + done, &miniStream[at], take);
			done += take;
		}
		return done == e.size;
	}
};

// Only what the transformer reads is implemented. The engine takes topology from the "Heads" pack.
struct GdpObject final : IGDPObject
{
	const CompoundFile *file;
	std::string storage;
	GdpObject(const CompoundFile *f, const std::string &name) : file(f), storage(name + "/") {}
	int Size(const char *name) override
	{
		const CompoundFile::Entry *e = file->Find(storage + name);
		return e ? (int)e->size : -1;
	}
	bool Get(const char *name, char *buffer) override
	{
		const CompoundFile::Entry *e = file->Find(storage + name);
		return e && buffer && file->Read(*e, buffer);
	}
	bool IsTransformable() const override { return file->Find(storage + "Morph.txt") != nullptr; }   // GDPFile 0x65002d90
	int MaterialsCount() const override { return 0; }
	bool Material(int, ObjectMaterial &) const override { return false; }
	int TrianglesCount(int) const override { return 0; }
	const unsigned short *Triangulation(int) const override { return nullptr; }
	int VerticesCount() const override { return 0; }
	const float *UV() const override { return nullptr; }
	const float *UVNoChg() const override { return nullptr; }
	bool HasExtenedUVInfo() const override { return false; }
	int UVCount() const override { return 0; }
	int BaseTrianglesCount() const override { return 0; }
	const unsigned short *BaseTriangulation() const override { return nullptr; }
	const unsigned short *UV2VMap() const override { return nullptr; }
	int AdditionalNormalsDataSize() const override { return 0; }
	bool AdditionalNormalsData(char *) override { return false; }
	int PNGTextureSize(const char *) const override { return -1; }
	bool PNGTexture(const char *, char *) override { return false; }
	int DataListSize() const override { return 0; }
	const char *DataListItem(int) const override { return nullptr; }
	int DefaultAnimatorDataSize() const override { return -1; }
	bool DefaultAnimatorData(char *) override { return false; }
	int SubObjectsCount() const override { return 0; }
	const char *SubObjectName(int) const override { return nullptr; }
	const char *SubObjectType(int) const override { return nullptr; }
	IGDPObject *SubObject(int) override { return nullptr; }
	void Destroy() override { delete this; }
};

struct GdpFile final : IGDPFile
{
	CompoundFile file;
	std::vector<std::string> objects;
	bool Open(const char *name)
	{
		if (!file.Open(name)) return false;
		const CompoundFile::Entry *list = file.Find("Objects.txt");
		if (!list) return false;
		std::string text(list->size, '\0');
		if (!file.Read(*list, &text[0])) return false;
		objects = MorphSpace::Tokens(text);
		return !objects.empty();
	}
	int ObjectsCount() const override { return (int)objects.size(); }
	const char *ObjectName(int i) const override { return i >= 0 && i < (int)objects.size() ? objects[i].c_str() : nullptr; }
	IGDPObject *Object(int i) override
	{
		return i >= 0 && i < (int)objects.size() ? new GdpObject(&file, objects[i]) : nullptr;
	}
	void Destroy() override { delete this; }
};

// ---------------------------------------------------------------------------------------------------------
// Sequences ("MMSF", Sequences.res). Header [magic, version 1, bytesAfterHeader, lengthMs, tracks, blobBytes,
// 0, 0], an opaque editor blob, then tracks: [flags, bytes, clips, nameBytes, ...] + name, each followed by
// its clips: [type, flags, bytes, startMs, lengthMs, 0, 0, 0] + name + payload, where
//   type 1 (macro muscle):  [n][x * n][y * n]  expression in percent over normalised clip time
//   type 2 (sound):         file name
//   type 3 (phonemes):      [int][count] + count * ([int][int][name])
// Rendering at time t: for each enabled track (flags bit 0) the clip with the lowest start containing t;
// a macro clip sends spline((t - start) / length) / 100 to its macro muscle, through MultMacroMuscle
// when its flags carry 0x10 and AddMacroMuscle otherwise.
struct SeqClip
{
	int type = 0;
	uint32_t flags = 0, start = 0, length = 0;
	std::string name, sound;
	Spline curve;
	IMacroMuscle *mm = nullptr;
	bool Contains(uint32_t t) const { return start <= t && t < start + length; }
	float Expression(uint32_t t) const
	{
		float x = (float)((double)(uint32_t)(t - start) / (double)length);
		return (float)((double)(curve.n >= 3 ? curve.Eval(x) : 0.0f) * (double)0.01f);
	}
};
struct SeqTrack
{
	uint32_t flags = 0;
	std::string name;
	std::vector<SeqClip> clips;
	std::map<uint32_t, int> byStart;     // start -> clip index; a later clip with the same start replaces
	const SeqClip *At(uint32_t t) const
	{
		if (!(flags & 1)) return nullptr;
		for (std::map<uint32_t, int>::const_iterator it = byStart.begin(); it != byStart.end(); ++it)
			if (clips[it->second].Contains(t)) return &clips[it->second];
		return nullptr;
	}
};

struct Sequencer final : ISequencer
{
	IMMTree *tree = nullptr;
	uint32_t length = 0;
	std::vector<SeqTrack> tracks;

	static std::string IntName(Reader &r)
	{
		int n = r.I();
		if (n < 0 || !r.Need((size_t)n)) { r.bad = true; return std::string(); }
		std::string s((const char *)r.p, (size_t)n);
		r.p += n;
		return s;
	}
	bool Load(const char *buffer, int size) override
	{
		tracks.clear(); length = 0;
		Reader r(buffer, size);
		uint32_t h[8];
		for (int i = 0; i < 8; ++i) h[i] = r.U();
		if (r.bad || h[0] != 0x46534D4Du || h[1] != 1) return false;
		uint32_t nTracks = h[4];
		r.Skip(h[5]);
		std::vector<SeqTrack> loaded;
		for (uint32_t t = 0; t < nTracks && !r.bad; ++t)
		{
			SeqTrack tr;
			uint32_t th[8];
			for (int i = 0; i < 8; ++i) th[i] = r.U();
			tr.flags = th[0];
			tr.name = IntName(r);
			for (uint32_t c = 0; c < th[2] && !r.bad; ++c)
			{
				SeqClip cl;
				uint32_t ch[8];
				for (int i = 0; i < 8; ++i) ch[i] = r.U();
				cl.type = (int)ch[0]; cl.flags = ch[1]; cl.start = ch[3]; cl.length = ch[4];
				cl.name = IntName(r);
				if (cl.type == 1)
				{
					int n = r.I();
					if (n < 0 || !r.Need((size_t)n * 8)) return false;
					std::vector<float> x(n), y(n);
					for (int i = 0; i < n; ++i) x[i] = r.F();
					for (int i = 0; i < n; ++i) y[i] = r.F();
					cl.curve.Build(x.data(), y.data(), n);
				}
				else if (cl.type == 2)
					cl.sound = IntName(r);
				else if (cl.type == 3)
				{
					r.I();
					int k = r.I();
					for (int i = 0; i < k && !r.bad; ++i) { r.I(); r.I(); IntName(r); }
				}
				else
					return false;
				tr.clips.push_back(cl);
			}
			for (int i = 0; i < (int)tr.clips.size(); ++i)
				tr.byStart[tr.clips[i].start] = i;
			loaded.push_back(tr);
		}
		if (r.bad) return false;
		tracks.swap(loaded);
		length = h[3];
		Resolve();
		return true;
	}
	bool Load(const char *fileName) override
	{
		std::vector<char> d = ReadWholeFile(fileName);
		return !d.empty() && Load(d.data(), (int)d.size());
	}
	void Resolve()
	{
		for (SeqTrack &t : tracks)
			for (SeqClip &c : t.clips)
				c.mm = (tree && c.type == 1) ? tree->FindMacroMuscle(c.name.c_str()) : nullptr;
	}
	IMMTree *RegisterMMTree(IMMTree *t) override { IMMTree *old = tree; tree = t; Resolve(); return old; }
	int SequenceTime() const override { return (int)length; }
	int TracksCount() const override { return (int)tracks.size(); }

	int EnumerateMacroMuscles(MUSCLE_CB cb, void *user) override
	{
		if (!cb) return 0;
		for (SeqTrack &t : tracks)
			for (SeqClip &c : t.clips)
				if (c.type == 1 && c.mm)
					if (void *r = cb(this, c.mm, (int)c.flags, user)) return (int)(intptr_t)r;
		return 0;
	}
	int EnumerateMacroMuscles(int time, MUSCLE_EXPR_CB cb, void *user) override
	{
		if (!cb || (uint32_t)time >= length) return 0;
		for (size_t i = 0; i < tracks.size(); ++i)
			if (const SeqClip *c = tracks[i].At((uint32_t)time))
				if (c->type == 1 && c->mm)
					if (void *r = cb(this, c->mm, c->Expression((uint32_t)time), (int)i, (int)c->flags, user)) return (int)(intptr_t)r;
		return 0;
	}
	int EnumerateMacroMuscles(MUSCLE_NAME_CB cb, void *user) override
	{
		if (!cb) return 0;
		for (SeqTrack &t : tracks)
			for (SeqClip &c : t.clips)
				if (c.type == 1)
					if (void *r = cb(this, c.name.c_str(), (int)c.flags, user)) return (int)(intptr_t)r;
		return 0;
	}
	int EnumerateMacroMuscles(int time, MUSCLE_NAME_EXPR_CB cb, void *user) override
	{
		if (!cb || (uint32_t)time >= length) return 0;
		for (size_t i = 0; i < tracks.size(); ++i)
			if (const SeqClip *c = tracks[i].At((uint32_t)time))
				if (c->type == 1)
					if (void *r = cb(this, c->name.c_str(), c->Expression((uint32_t)time), (int)i, (int)c->flags, user)) return (int)(intptr_t)r;
		return 0;
	}
	int EnumerateSounds(SOUND_CB cb, void *user) override
	{
		if (!cb) return 0;
		for (SeqTrack &t : tracks)
			for (SeqClip &c : t.clips)
				if (c.type == 2)
					if (void *r = cb(this, c.sound.c_str(), (int)c.start, (int)c.flags, user)) return (int)(intptr_t)r;
		return 0;
	}
	int EnumerateSounds(int time, SOUND_TIME_CB cb, void *user) override
	{
		if (!cb) return 0;
		for (size_t i = 0; i < tracks.size(); ++i)
			if (const SeqClip *c = tracks[i].At((uint32_t)time))
				if (c->type == 2)
					if (void *r = cb(this, c->sound.c_str(), (int)c->start, time - (int)c->start, (int)i, (int)c->flags, user)) return (int)(intptr_t)r;
		return 0;
	}
	void RenderMacroMuscles(IAnimator *animator, int time) override
	{
		if (!animator || (uint32_t)time >= length) return;
		for (const SeqTrack &t : tracks)
			if (const SeqClip *c = t.At((uint32_t)time))
				if (c->type == 1 && c->mm)
				{
					float e = c->Expression((uint32_t)time);
					if (c->flags & 0x10) animator->MultMacroMuscle(c->mm, e);
					else animator->AddMacroMuscle(c->mm, e);
				}
	}
	void Destroy() override { delete this; }
};
} // namespace

void __stdcall Init() {}
IAnimator *__stdcall IAnimator::Create() { return new Animator(); }
ITransformer *__stdcall ITransformer::Create() { return new Transformer(); }
IMMTree *__stdcall IMMTree::Create() { return new Tree(); }
ISequencer *__stdcall ISequencer::Create() { return new Sequencer(); }
IGDPFile *__stdcall IGDPFile::Create(const char *name)
{
	GdpFile *f = new GdpFile();
	if (f->Open(name)) return f;
	delete f;
	return nullptr;
}
}

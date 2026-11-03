// facegen_test <FaceGenHead.gdp> <FaceGenHead.mmt>: drives the native ITransformer the way Main/LSHead.cpp does, with no
// game and no GPU, and checks what a slider must do. clang++ -std=c++17 -O2 -D__stdcall= -Ithird_party/lifestudio/include
// port/tools/lifestudio_oracle/facegen_test.cpp port/platform/src/lifestudio.cpp
#define LIFESTUDIOHEADAPI_EXPORTS_LIB
#include "LifeStudioHeadAPI.h"
#include "LifeStudioHeadAPIGDP.h"
#include "LifeStudioHeadAPIMMTS.h"
#include "LifeStudioHeadAPITransform.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <chrono>
#include <map>
#include <string>
#include <vector>
using namespace LifeStudioHeadAPI;
extern "C" const char *S2HostPath(const char *p, char *out, size_t n) { snprintf(out, n, "%s", p); for (char *c = out; *c; ++c) if (*c == '\\') *c = '/'; return out; }

struct Rig
{
	IMMTree *tree = nullptr; ITransformer *tr = nullptr; IAnimator *out = nullptr;
	bool Build(const char *gdp, const char *mmt)
	{
		tree = IMMTree::Create();
		if (!tree->Load(mmt)) return false;
		tr = ITransformer::Create(); out = IAnimator::Create();
		IGDPFile *f = IGDPFile::Create(gdp);
		if (!f) return false;
		IGDPObject *o = f->Object(0);
		bool ok = o && o->IsTransformable() && tr->Load(o);
		if (ok) { tr->OutputAnimator(out); tr->RegisterMacroMuscle(tree->RootMacroMuscle()); tr->CollectUserItems(true); }
		if (o) o->Destroy();
		f->Destroy();
		return ok;
	}
	std::vector<float> Shape(const std::map<std::string, float> &t)
	{
		tr->ClearAllMacroMuscles();
		for (auto &kv : t) if (IMacroMuscle *m = tree->FindMacroMuscle(kv.first.c_str())) tr->AddMacroMuscle(m, kv.second);
		tr->ComputePhysics();
		tr->Generate();
		std::vector<float> v((size_t)out->VerticesCount() * 3);
		out->FillUnused(true);
		out->ClearAllMacroMuscles();
		out->Process(v.data(), 3);
		return v;
	}
};
static void Stats(const char *name, const std::vector<float> &v)
{
	float lo[3] = {1e9f, 1e9f, 1e9f}, hi[3] = {-1e9f, -1e9f, -1e9f};
	int bad = 0;
	for (size_t i = 0; i < v.size(); i += 3)
		for (int k = 0; k < 3; ++k)
		{
			if (!isfinite(v[i + k])) { ++bad; continue; }
			if (v[i + k] < lo[k]) lo[k] = v[i + k];
			if (v[i + k] > hi[k]) hi[k] = v[i + k];
		}
	printf("%-26s x %7.3f..%7.3f y %7.3f..%7.3f z %8.3f..%7.3f nonfinite %d\n", name, lo[0], hi[0], lo[1], hi[1], lo[2], hi[2], bad);
}
static double MaxMove(const std::vector<float> &a, const std::vector<float> &b)
{
	double m = 0;
	for (size_t i = 0; i < a.size(); i += 3)
	{
		double d = sqrt((a[i] - b[i]) * (a[i] - b[i]) + (a[i + 1] - b[i + 1]) * (a[i + 1] - b[i + 1]) + (a[i + 2] - b[i + 2]) * (a[i + 2] - b[i + 2]));
		if (d > m) m = d;
	}
	return m;
}
int main(int argc, char **argv)
{
	if (argc < 3) return 2;
	auto t0 = std::chrono::steady_clock::now();
	Rig r;
	if (!r.Build(argv[1], argv[2])) { printf("rig failed\n"); return 1; }
	auto t1 = std::chrono::steady_clock::now();
	printf("rig ok: %d vertices, load %.1f ms\n", r.out->VerticesCount(), std::chrono::duration<double, std::milli>(t1 - t0).count());
	std::vector<float> base = r.Shape({});
	Stats("default", base);
	static const char *names[] = {"Age", "Gender", "Nationality", "Lips", "Chin", "Nose", "Brows", "Cheeks"};
	int fails = 0;
	for (const char *n : names)
		for (float e : {-1.0f, -0.5f, 0.5f, 1.0f})
		{
			std::vector<float> v = r.Shape({{n, e}});
			char label[64];
			snprintf(label, sizeof label, "%s %+.1f", n, e);
			Stats(label, v);
			double m = MaxMove(base, v);
			printf("    largest vertex move from default %.3f\n", m);
			if (!(m > 1e-3)) { printf("    FAIL: no change\n"); ++fails; }
		}
	// the bake: Save -> Load must reproduce the shape, and a second Save must be identical bytes
	std::map<std::string, float> custom = {{"Age", 0.4f}, {"Gender", -0.8f}, {"Nationality", 0.3f}, {"Nose", 0.7f}, {"Chin", -0.6f}, {"Lips", 0.3f}};
	std::vector<float> shaped = r.Shape(custom);
	int size = r.out->SaveBufferSize();
	std::vector<char> buffer((size_t)size);
	bool saved = r.out->Save(buffer.data());
	IAnimator *back = IAnimator::Create();
	bool loaded = back->Load(buffer.data(), size);
	std::vector<float> again((size_t)back->VerticesCount() * 3);
	back->FillUnused(true);
	back->Process(again.data(), 3);
	std::vector<char> second((size_t)back->SaveBufferSize());
	back->Save(second.data());
	double diff = MaxMove(shaped, again);
	printf("bake: %d bytes saved %d loaded %d, largest difference after reload %.6f, bytes identical %d\n", size, saved, loaded, diff,
	       second.size() == buffer.size() && memcmp(second.data(), buffer.data(), buffer.size()) == 0);
	if (!saved || !loaded || diff > 1e-3) { printf("FAIL: bake\n"); ++fails; }
	// the texture channels the face bake reads
	for (const char *item : {"European.0", "Arab.0", "African.0", "Asian.0", "OLD", "T01", "M01", "F01"})
	{
		UserID id = r.tr->UserItem(item);
		printf("channel %-11s id %d values %d first %.3f\n", item, id, r.tr->UserValuesCount(id), r.tr->UserValuesCount(id) ? r.tr->UserValue(id, 0) : 0.0f);
	}
	auto t2 = std::chrono::steady_clock::now();
	for (int i = 0; i < 100; ++i) r.Shape(custom);
	auto t3 = std::chrono::steady_clock::now();
	printf("one re-morph %.3f ms\n", std::chrono::duration<double, std::milli>(t3 - t2).count() / 100);
	if (argc > 3)
		for (const auto &sh : std::vector<std::pair<const char *, std::map<std::string, float>>>{{"default", {}}, {"custom", custom}, {"old", {{"Age", 1.f}}}, {"female", {{"Gender", -1.f}}}, {"nose", {{"Nose", -0.4f}}}, {"chin", {{"Chin", 1.f}}}})
		{
			std::vector<float> v = r.Shape(sh.second);
			FILE *o = fopen((std::string(argv[3]) + "/" + sh.first + ".f32").c_str(), "wb");
			fwrite(v.data(), 4, v.size(), o);
			fclose(o);
		}
	printf(fails ? "FAILED %d\n" : "all passed\n", fails);
	return fails != 0;
}

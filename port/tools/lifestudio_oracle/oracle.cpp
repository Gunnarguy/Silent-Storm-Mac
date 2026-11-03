// Test oracle (port/tools/lifestudio_oracle/run.sh): drives the real LifeStudioHeadAPI.dll under Wine and dumps
// reference vertices and internal state.
// Not part of the port. Commands (one per line on stdin):
//   load <file>            create animator, load buffer
//   tree <file>            load macro-muscle tree from file (IMMTree::Load(file))
//   reg                    RegisterMacroMuscle(tree root)
//   clear                  ClearAllMacroMuscles
//   add <name> <value>     AddMacroMuscle(FindMacroMuscle(name), value)
//   mult <name> <value>
//   phys                   ComputePhysics
//   seq <file>             load sequencer from buffer file, RegisterMMTree(tree)
//   render <time>          sequencer RenderMacroMuscles(animator,time)
//   fill <0|1>             FillUnused
//   out <file>             Process(stride 3) into NaN-filled buffer, write VerticesCount*3 floats
//   info                   print counts
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <string>
#include <vector>
typedef void *(__stdcall *CreateFn)();
typedef void *(__stdcall *OptFn)(void *, unsigned, unsigned);
static void **vt(void *o) { return *(void ***)o; }
template<class R, class... A> R call(void *o, int slot, A... a)
{
	typedef R(__thiscall *F)(void *, A...);
	return ((F)vt(o)[slot])(o, a...);
}
static float __stdcall Compute(void *ctrl, float x)
{
	struct Key { float x; float _; };
	int n = *(int *)ctrl; const Key *k = *(const Key **)((char *)ctrl + 4); const float *c = *(const float **)((char *)ctrl + 8);
	for (int i = 0; i < n - 1; ++i)
		if (k[i].x <= x && x <= k[i + 1].x) { const float *q = c + i * 4; float dl = x - k[i].x, dr = x - k[i + 1].x; return q[0] * dl + q[1] * dr + q[2] * dl * dl * dr + q[3] * dl * dr * dr; }
	return 0.0f;
}
static std::vector<char> readf(const char *p) { std::vector<char> v; FILE *f = fopen(p, "rb"); if (!f) return v; fseek(f, 0, 2); v.resize(ftell(f)); fseek(f, 0, 0); fread(v.data(), 1, v.size(), f); fclose(f); return v; }
int main(int argc, char **argv)
{
	HMODULE h = LoadLibraryA(argv[1]);
	if (!h) { printf("no dll %lu\n", GetLastError()); return 1; }
	OptFn opt = (OptFn)GetProcAddress(h, "?Create@IOptions@LifeStudioHeadAPI@@SGPAU12@PAXII@Z");
	CreateFn cAnim = (CreateFn)GetProcAddress(h, "?Create@IAnimator@LifeStudioHeadAPI@@SGPAU12@XZ");
	CreateFn cTree = (CreateFn)GetProcAddress(h, "?Create@IMMTree@LifeStudioHeadAPI@@SGPAU12@XZ");
	CreateFn cSeq = (CreateFn)GetProcAddress(h, "?Create@ISequencer@LifeStudioHeadAPI@@SGPAU12@XZ");
	static unsigned tmp;
	unsigned addr = (unsigned)(uintptr_t)&Compute;
	opt(&tmp, addr & 0x1EF4FFFFu, (addr >> 16) + 0x33E50000u);
	void *anim = 0, *tree = 0, *seq = 0;
	std::vector<std::vector<char>> keep;
	char line[4096];
	setvbuf(stdout, 0, _IONBF, 0);
	while (fgets(line, sizeof line, stdin))
	{
		char cmd[64] = {0}, a1[2048] = {0}; float f = 0;
		int n = sscanf(line, "%63s %2047s %f", cmd, a1, &f);
		if (n < 1) continue;
		std::string c = cmd;
		if (c == "load") { keep.push_back(readf(a1)); if (anim) call<void>(anim, 32); anim = cAnim(); bool ok = call<bool>(anim, 0, (const char *)keep.back().data(), (int)keep.back().size()); printf("load %d verts %d muscles %d bones %d\n", ok, call<int>(anim, 13), call<int>(anim, 5), call<int>(anim, 9)); }
		else if (c == "tree") { tree = cTree(); bool ok = call<bool>(tree, 1, (const char *)a1); printf("tree %d root %p\n", ok, call<void *>(tree, 2)); }
		else if (c == "reg") call<void>(anim, 18, call<void *>(tree, 2));
		else if (c == "clear") call<void>(anim, 14);
		else if (c == "add" || c == "mult") { void *mm = call<void *>(tree, 3, (const char *)a1); if (!mm) printf("no mm %s\n", a1); else call<void>(anim, c == "add" ? 15 : 16, mm, f); }
		else if (c == "phys") call<void>(anim, 17);
		else if (c == "seq") { keep.push_back(readf(a1)); seq = cSeq(); bool ok = call<bool>(seq, 0, (const char *)keep.back().data(), (int)keep.back().size()); call<void *>(seq, 2, tree); printf("seq %d time %d tracks %d\n", ok, call<int>(seq, 3), call<int>(seq, 4)); }
		else if (c == "render") call<void>(seq, 11, anim, atoi(a1));
		else if (c == "fill") call<void>(anim, 11, (bool)atoi(a1));
		else if (c == "out")
		{
			int nv = call<int>(anim, 13);
			std::vector<float> v(nv * 3 + 3, NAN);
			bool ok = call<bool>(anim, 12, v.data(), 3);
			FILE *o = fopen(a1, "wb"); fwrite(v.data(), 4, nv * 3, o); fclose(o);
			printf("out %d nv %d\n", ok, nv);
		}
		else if (c == "state")
		{
			// internal DLL state (packed 2003 layout): muscles @+0x10 stride 0x138, bones @+0x30 stride 0x22c
			char *A = (char *)anim; FILE *o = fopen(a1, "w");
			auto P = [&](int off) { return *(char **)(A + off); };
			auto I = [&](int off) { return *(int *)(A + off); };
			int nm = (int)((P(0x14) - P(0x10)) / 0x138), nb = (int)((P(0x34) - P(0x30)) / 0x22c), nc = I(0x95);
			for (int i = 0; i < nm; ++i) fprintf(o, "T %d %.9g\n", i, *(float *)(P(0x10) + i * 0x138 + 0x7c));
			for (int i = 0; i < nb; ++i) { char *b = P(0x30) + i * 0x22c; fprintf(o, "B %d %.9g %.9g %.9g", i, *(float *)(b + 0x20c), *(float *)(b + 0x210), *(float *)(b + 0x214)); for (int k = 0; k < 16; ++k) fprintf(o, " %.9g", *(float *)(b + 0x10c + 4 * k)); fprintf(o, "\n"); }
			for (int k = 0; k < nc; ++k) fprintf(o, "C %d %.9g %.9g %.9g %.9g %.9g\n", k, ((float *)P(0x89))[k], ((float *)P(0x8d))[k], ((float *)P(0x99))[k], ((float *)P(0x9d))[k], ((float *)P(0xa1))[k]);
			fprintf(o, "S %.9g\n", *(float *)(A + 0xa5));
			int nr = (int)((P(0xb1) - P(0xad)) / 8);
			for (int k = 0; k < nr; ++k) fprintf(o, "R %d %d %d\n", k, ((int *)P(0xad))[2 * k], ((int *)P(0xad))[2 * k + 1]);
			fclose(o); printf("state nm %d nb %d nc %d nr %d\n", nm, nb, nc, nr);
		}
		else if (c == "quit") break;
	}
	return 0;
}

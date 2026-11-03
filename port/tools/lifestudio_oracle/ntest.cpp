// native twin of oracle.cpp: same stdin commands, drives port/platform/src/lifestudio.cpp
#define LIFESTUDIOHEADAPI_EXPORTS_LIB
#include "LifeStudioHeadAPI.h"
#include "LifeStudioHeadAPIMMTS.h"
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string>
#include <vector>
using namespace LifeStudioHeadAPI;
#include <string.h>
extern "C" const char *S2HostPath(const char *p, char *out, size_t n) { snprintf(out, n, "%s", p); for (char *c = out; *c; ++c) if (*c == '\\') *c = '/'; return out; }
static std::vector<char> readf(const char *p) { std::vector<char> v; FILE *f = fopen(p, "rb"); if (!f) return v; fseek(f, 0, 2); v.resize(ftell(f)); fseek(f, 0, 0); fread(v.data(), 1, v.size(), f); fclose(f); return v; }
int main()
{
	IAnimator *anim = 0; IMMTree *tree = 0; ISequencer *seq = 0;
	std::vector<std::vector<char>> keep;
	char line[4096];
	while (fgets(line, sizeof line, stdin))
	{
		char cmd[64] = {0}, a1[2048] = {0}; float f = 0;
		if (sscanf(line, "%63s %2047s %f", cmd, a1, &f) < 1) continue;
		std::string c = cmd;
		if (c == "load") { keep.push_back(readf(a1)); if (anim) anim->Destroy(); anim = IAnimator::Create(); bool ok = anim->Load(keep.back().data(), (int)keep.back().size()); printf("load %d verts %d muscles %d bones %d\n", ok, anim->VerticesCount(), anim->MusclesCount(), anim->BonesCount()); }
		else if (c == "tree") { tree = IMMTree::Create(); bool ok = tree->Load((const char *)a1); printf("tree %d root %p\n", ok, (void *)tree->RootMacroMuscle()); }
		else if (c == "reg") anim->RegisterMacroMuscle(tree->RootMacroMuscle());
		else if (c == "clear") anim->ClearAllMacroMuscles();
		else if (c == "add" || c == "mult") { IMacroMuscle *mm = tree->FindMacroMuscle(a1); if (!mm) printf("no mm %s\n", a1); else if (c == "add") anim->AddMacroMuscle(mm, f); else anim->MultMacroMuscle(mm, f); }
		else if (c == "phys") anim->ComputePhysics();
		else if (c == "seq") { keep.push_back(readf(a1)); seq = ISequencer::Create(); bool ok = seq->Load(keep.back().data(), (int)keep.back().size()); seq->RegisterMMTree(tree); printf("seq %d time %d tracks %d\n", ok, seq->SequenceTime(), seq->TracksCount()); }
		else if (c == "render") seq->RenderMacroMuscles(anim, atoi(a1));
		else if (c == "fill") anim->FillUnused(atoi(a1) != 0);
		else if (c == "out") { int nv = anim->VerticesCount(); std::vector<float> v(nv * 3 + 3, NAN); bool ok = anim->Process(v.data(), 3); FILE *o = fopen(a1, "wb"); fwrite(v.data(), 4, nv * 3, o); fclose(o); printf("out %d nv %d\n", ok, nv); }
		else if (c == "quit") break;
	}
	return 0;
}

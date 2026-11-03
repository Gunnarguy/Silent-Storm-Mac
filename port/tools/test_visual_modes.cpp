#include "../platform/include/s2visuals.h"
#include <cassert>
#include <iostream>

int main()
{
	S2Settings enhanced;
	int i = 0;
	for (const auto &field : s2VisualInts) enhanced.*field.member = ++i + 3;
	for (const auto &field : s2VisualFloats) enhanced.*field.member = (++i) * 0.037f;
	S2Settings active = enhanced;
	active.masterVolume = 0.31f;
	active.scrollScale = 2.3f;
	active.physRate = 120;
	active.frameCap = 40;
	for (int round = 0; round < 100; ++round)
	{
		S2ApplyOriginalVisuals(active);
		assert(active.hdTextures == 0 && active.terrainDetail == 256);
		assert(active.ao == 0 && active.bloom == 0 && active.edr == 0);
		assert(active.contrast == 1 && active.saturation == 1 && active.sharpen == 0);
		assert(active.masterVolume == 0.31f && active.scrollScale == 2.3f);
		S2RestoreVisuals(active, enhanced);
		for (const auto &field : s2VisualInts) assert(active.*field.member == enhanced.*field.member);
		for (const auto &field : s2VisualFloats) assert(active.*field.member == enhanced.*field.member);
		assert(active.masterVolume == 0.31f && active.scrollScale == 2.3f);
		assert(active.physRate == 120 && active.frameCap == 40);
	}
	std::cout << "PASS: 100 original/enhanced round trips preserve custom visuals, audio, input, physics and frame pacing\n";
}

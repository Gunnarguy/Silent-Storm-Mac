#pragma once
#include "s2settings.h"

// Only image settings belong to a graphics comparison. Input, camera position,
// cheats, simulation, audio, pacing and accessibility preferences stay unchanged.
struct S2VisualInt { const char *name; int S2Settings::*member; int original; };
struct S2VisualFloat { const char *name; float S2Settings::*member; float original; };
static constexpr S2VisualInt s2VisualInts[] = {
	{"upscaler", &S2Settings::upscaler, 1}, {"fxaa", &S2Settings::fxaa, 0},
	{"ao", &S2Settings::ao, 0}, {"bloom", &S2Settings::bloom, 0},
	{"worldFxDebug", &S2Settings::worldFxDebug, 0}, {"edr", &S2Settings::edr, 0},
	{"hdTextures", &S2Settings::hdTextures, 0}, {"terrainDetail", &S2Settings::terrainDetail, 256},
	{"anisoOverride", &S2Settings::anisoOverride, 0},
};
static constexpr S2VisualFloat s2VisualFloats[] = {
	{"sharpen", &S2Settings::sharpen, 0}, {"brightness", &S2Settings::brightness, 0},
	{"contrast", &S2Settings::contrast, 1}, {"saturation", &S2Settings::saturation, 1},
	{"vibrance", &S2Settings::vibrance, 0}, {"temperature", &S2Settings::temperature, 0},
	{"tint", &S2Settings::tint, 0}, {"vignette", &S2Settings::vignette, 0},
	{"grain", &S2Settings::grain, 0}, {"haze", &S2Settings::haze, 0}, {"lodBias", &S2Settings::lodBias, 0},
};
struct S2VisualEngine { const char *name; float original; };
// High-quality options available in the shipped game, at a period 4:3 resolution.
// Original is not the lowest preset, nor the new renderer's enhancements.
static constexpr S2VisualEngine s2VisualEngine[] = {
	{"gfx_fastest", 0}, {"gfx_shadows", 1}, {"gfx_cl", 1}, {"gfx_fog", 2},
	{"gfx_specular", 1}, {"gfx_point_specular", 1}, {"gfx_blur_sun", 1},
	{"gfx_cl_blur", 1}, {"gfx_decals", 1}, {"gfx_cl_use_bump", 1},
	{"gfx_cl_use_bump_always", 1}, {"gfx_cl_use_precise_shadows", 1},
	{"gfx_cl_cube_resolution", 64}, {"gfx_cl_sky_textures", 2},
	{"gfx_depth_tex_resolution", 1024}, {"gfx_texture_mip", 0},
	{"gfx_register_resolution", 1}, {"gfx_anisotropic_filter", 1},
	{"gfx_texture_usedxt", 1}, {"gfx_terrain_565", 1}, {"gfx_16bit_textures", 0},
	{"gfx_fsaa", 0}, {"gfx_gamma", 1}, {"gfx_particles", 1}, {"game_showweathereffect", 1},
};
inline void S2ApplyOriginalVisuals(S2Settings &settings)
{
	for (const auto &field : s2VisualInts) settings.*field.member = field.original;
	for (const auto &field : s2VisualFloats) settings.*field.member = field.original;
}
inline void S2RestoreVisuals(S2Settings &settings, const S2Settings &saved)
{
	for (const auto &field : s2VisualInts) settings.*field.member = saved.*field.member;
	for (const auto &field : s2VisualFloats) settings.*field.member = saved.*field.member;
}

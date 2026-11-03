// settings_engine.cpp: the Settings window's door into the engine's variable and command registry (MiscDll/Commands).
// Kept in its own C++ file so the Objective-C++ window code never includes engine headers.
#include "s2platform.h"
#include <string>
#include <vector>
using std::string; using std::wstring; using std::vector;
#include "MiscDll/Commands.h"
#include "s2engine.h"
namespace NGScene { void SetHDTextureSources(bool enabled); unsigned TextureSourceGeneration(); }

static wstring Widen(const char *s) { wstring w; for (; s && *s; ++s) w += (wchar_t)(unsigned char)*s; return w; }

bool S2EngineHas(const char *name) { return NGlobal::IsRegistered(name); }
float S2EngineGet(const char *name, float def)
{
	static const NGlobal::CValue missing(-12345.0f);
	const NGlobal::CValue &v = NGlobal::GetVar(name, missing);
	return &v == &missing ? def : v.GetFloat();
}
std::string S2EngineGetString(const char *name)
{
	const wstring &w = NGlobal::GetVar(name).GetString();
	std::string s; for (wchar_t c : w) s += c < 128 ? (char)c : '?';
	return s;
}
void S2EngineSet(const char *name, float value) { NGlobal::SetVar(name, NGlobal::CValue(value)); }
void S2EngineSetString(const char *name, const char *value) { NGlobal::SetVar(name, NGlobal::CValue(Widen(value))); }
void S2EngineCommand(const char *command) { NGlobal::ProcessCommand(Widen(command)); }
void S2EngineSaveConfig() { NGlobal::SaveConfig(S2ConfigPath("config.cfg")); }
void S2ReloadTextureSources(bool enabled) { NGScene::SetHDTextureSources(enabled); }
unsigned S2TextureSourceGeneration() { return NGScene::TextureSourceGeneration(); }

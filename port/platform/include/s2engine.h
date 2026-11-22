// s2engine.h: engine variables and console commands, for platform code (settings_engine.cpp). Call on the game thread.
#pragma once
#include <string>

bool S2EngineHas(const char *name);                     // a live variable or command is registered under this name
float S2EngineGet(const char *name, float def = 0);
std::string S2EngineGetString(const char *name);
void S2EngineSet(const char *name, float value);
void S2EngineSetString(const char *name, const char *value);
void S2EngineCommand(const char *command);              // a console line, e.g. "gfx_recreate"
void S2EngineSaveConfig();                              // write cfg/config.cfg now
void S2EngineInputEvent(const char *name);              // fire a bind action by name, as the game's own on-screen buttons do (e.g. "hideinterface")

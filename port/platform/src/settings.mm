// settings.mm: the native Settings window (Silent Storm > Settings…, Cmd-,).
//
// Two kinds of option live here:
//  - the engine's own variables (gfx_*, sound_*, game_*, ui_*, cheat_*), set through its console registry. The
//    engine saves the ones it marks persistent in cfg/config.cfg; renderer-structure options (lighting caches,
//    shadow maps, resolution) restart the renderer half a second after the last change, like the in-game menu does.
//  - options the macOS port adds (upscaling, sharpening, FXAA, colour grading, frame pacing, overlays, audio master,
//    camera limits, persistent cheats), saved in the app's user defaults and read by the renderer every frame.
// Every change applies while the game runs behind the window; the game keeps rendering while Settings has focus.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include "s2settings.h"
#include "s2visuals.h"
#include "s2engine.h"
#include "s2platform.h"
#include <vector>
#include <string>
#include <cmath>
#include <atomic>
#include <algorithm>
#include <unistd.h>
#include <sys/stat.h>
#include <string.h>

S2Settings g_s2;
void S2ReloadTextureSources(bool enabled);
unsigned S2TextureSourceGeneration();
static NSWindow *GameWindow();
void S2RequestQuit();

// ---------------------------------------------------------------------------------------------------
// Mac-side values and their persistence
namespace {
struct MacField { const char *key; float *f; int *i; };
const std::vector<MacField> &MacFields()
{
	static const std::vector<MacField> f = {
		{ "upscaler", nullptr, &g_s2.upscaler }, { "sharpen", &g_s2.sharpen, nullptr }, { "fxaa", nullptr, &g_s2.fxaa },
		{ "brightness", &g_s2.brightness, nullptr }, { "contrast", &g_s2.contrast, nullptr }, { "saturation", &g_s2.saturation, nullptr },
		{ "vibrance", &g_s2.vibrance, nullptr }, { "temperature", &g_s2.temperature, nullptr }, { "tint", &g_s2.tint, nullptr },
		{ "vignette", &g_s2.vignette, nullptr }, { "grain", &g_s2.grain, nullptr },
		{ "ao", nullptr, &g_s2.ao }, { "aoStrength", &g_s2.aoStrength, nullptr }, { "aoRadius", &g_s2.aoRadius, nullptr },
		{ "bloom", nullptr, &g_s2.bloom }, { "bloomStrength", &g_s2.bloomStrength, nullptr }, { "bloomThreshold", &g_s2.bloomThreshold, nullptr },
		{ "haze", &g_s2.haze, nullptr }, { "worldFxDebug", nullptr, &g_s2.worldFxDebug },   // reset at launch
		{ "edr", nullptr, &g_s2.edr }, { "edrStrength", &g_s2.edrStrength, nullptr },
		{ "hdTextures", nullptr, &g_s2.hdTextures }, { "terrainDetail", nullptr, &g_s2.terrainDetail },
		{ "physRate", nullptr, &g_s2.physRate }, { "physIterations", nullptr, &g_s2.physIterations }, { "physJointLimits", nullptr, &g_s2.physJointLimits },
		{ "physFriction", &g_s2.physFriction, nullptr }, { "physStiffness", &g_s2.physStiffness, nullptr },
		{ "vsync", nullptr, &g_s2.vsync }, { "frameCap", nullptr, &g_s2.frameCap }, { "tripleBuffer", nullptr, &g_s2.tripleBuffer },
		{ "showFPS", nullptr, &g_s2.showFPS }, { "anisoOverride", nullptr, &g_s2.anisoOverride }, { "lodBias", &g_s2.lodBias, nullptr },
		{ "masterVolume", &g_s2.masterVolume, nullptr }, { "muteInBackground", nullptr, &g_s2.muteInBackground },
		{ "scrollScale", &g_s2.scrollScale, nullptr }, { "ctrlClickRight", nullptr, &g_s2.ctrlClickRight },
		{ "pauseInBackground", nullptr, &g_s2.pauseInBackground }, { "aiTurnSpeed", nullptr, &g_s2.aiTurnSpeed }, { "weaponCompare", nullptr, &g_s2.weaponCompare },
		{ "keepAwake", nullptr, &g_s2.keepAwake }, { "adaptPower", nullptr, &g_s2.adaptPower }, { "metalHUD", nullptr, &g_s2.metalHUD },
		{ "hdrFollowSystem", nullptr, &g_s2.hdrFollowSystem }, { "scrollPans", nullptr, &g_s2.scrollPans }, { "pinchZoom", nullptr, &g_s2.pinchZoom },
		{ "rotateGesture", nullptr, &g_s2.rotateGesture }, { "gestureSpeed", &g_s2.gestureSpeed, nullptr }, { "edgeScrollBand", nullptr, &g_s2.edgeScrollBand },
		{ "doubleClickMs", nullptr, &g_s2.doubleClickMs }, { "logLineSeconds", nullptr, &g_s2.logLineSeconds }, { "endTurnGuardMs", nullptr, &g_s2.endTurnGuardMs },
		{ "subtitleSeconds", nullptr, &g_s2.subtitleSeconds }, { "hitNumberSeconds", nullptr, &g_s2.hitNumberSeconds }, { "followSeconds", nullptr, &g_s2.followSeconds },
		{ "aiThinkMs", nullptr, &g_s2.aiThinkMs }, { "attractDemo", nullptr, &g_s2.attractDemo }, { "physSettle", &g_s2.physSettle, nullptr },
		{ "horPlus", nullptr, &g_s2.horPlus },
		{ "retailRules", nullptr, &g_s2.retailRules }, { "enemyHeadShots", nullptr, &g_s2.enemyHeadShots }, { "enemyPartialBursts", nullptr, &g_s2.enemyPartialBursts },
	};
	return f;
}

// Mission camera limits (console commands, applied when a map loads). Stock values are the shipped autoexec.cfg.
struct CameraCfg
{
	float fov = 35, minRod = 10, maxRod = 65, minPitch = -1.35f, maxPitch = -0.75f;
	int softLimits = 1;
	float zoomSpeed = 0.3f, pitchSpeed = 5, yawSpeed = 1.5f, scrollSpeed = 1.4f;
	// not in the shipped autoexec.cfg: the engine's constructor defaults (Main/Camera.h SLimits)
	float zoomAccel = 5, scrollAccel = 1.2f, yawAccel = 1, attenuation = 1, minHeight = 4;
} cam;
const CameraCfg kStockCamera;

// Cheats the user turned on stay on: re-applied whenever their variable is live (mission-scoped ones every mission).
struct Cheat { const char *var; NSString *title, *detail; bool mission; };
const std::vector<Cheat> &Cheats()
{
	static const std::vector<Cheat> c = {
		{ "godmode", @"God mode", @"Every soldier you command when it is switched on ignores all damage and critical wounds from attacks, and bullets pass straight through them. It is switched on again at the start of each mission; soldiers who join mid-mission are not covered until then. It is stored on each soldier, so a save made with it on keeps them invulnerable.", true },
		{ "cheat_ap", @"Unlimited action points", @"Your soldiers' action points are never used up: every action is affordable and costs nothing, turn after turn. It covers the soldiers you command when it is switched on, is switched on again at the start of each mission, and is stored on each soldier like God mode.", true },
		{ "seeall", @"Soldiers see everything", @"Each of your soldiers counts every unit on the map as seen, through walls, at any distance and when hidden, and knows every mine and trap. Because your squad then always sees an enemy, a fight that has gone to turns stays in turns until every enemy is down. Switched on again each mission; stored on each soldier.", true },
		{ "cheat_golden_shot", @"Any hit explodes the target", @"Any attack that reaches a person makes them burst apart on the spot, whatever the damage: enemies, civilians and your own soldiers alike. They drop what they carry and are removed from the map. It stays on in every mission until you switch it off.", false },
		{ "cheat_heads_off", @"Heads off", @"Every hit that lands on a living, conscious person takes the head off and kills, wherever it struck and whatever the damage. It works with Blood and Headshot decapitations switched off, and on your own soldiers. Panzerkleins are exempt.", false },
		{ "cheat_football", @"Football", @"Every hit on a body lying on the ground, dead or unconscious, shoves it along the line of the shot, including the shot that put it there. Normally only some weapons push bodies. With this on those weapons push at one third strength and all others at full strength. Panzerkleins and bodies being carried do not move.", false },
		{ "cheat_showall", @"Draw every unit in missions", @"In a mission, draws every unit on the map and plays their sounds, including enemies none of your soldiers can see. It is a display cheat only: what your soldiers themselves see, and so when turns begin, is unchanged. Despite its old name it does nothing on the chapter map.", false },
		{ "cheat_zoneautocomplete", @"Complete zones by moving onto them", @"On the chapter map, a zone is completed the moment your squad's marker moves onto it, including zones it only crosses on the way: the zone is marked as passed, its clues are found and its capture or destroy objectives are completed, with no mission played. This cannot be undone and is kept in saves made afterwards.", false },
		{ "cheat_slomo", @"Cinematic slow motion", @"When the automatic camera swings to a death or a large explosion, the game may drop to one third speed for up to 4 seconds. The first chance is about 1 in 2 and it shrinks as slow motions add up over the campaign. Needs 'Camera follows units' on. Off is the 2003 default.", false },
		{ "cheat_global_xcom", @"Globe view for the world map", @"Replaces the world map screen with an unfinished 3D globe left in the game files. You can spin and zoom the globe, but the screen has no way to choose a region, so the campaign cannot be continued from it. It is read each time the world map opens: switch it off and reopen the map to get the normal one.", false },
		{ "i_am_an_alien", @"Everyone gets the cloaked look", @"Every person in a mission is drawn with the sky-reflecting cloak material the game otherwise uses for a hidden soldier in a Panzerklein suit, and casts no shadow. Display only: nothing in the rules changes.", false },
		{ "game_noai", @"Freeze all computer-controlled units", @"Every computer-controlled side stops deciding: enemies, allies and civilians give no orders and do not react, and in turn-based play their turns end at once. Unlike the other cheats, the game saves this one in its own settings, so it stays on in later sessions until you switch it off.", false },
	};
	return c;
}
NSMutableDictionary<NSString*, NSNumber*> *cheatWanted;   // var -> 0/1, only for cheats the user touched

std::atomic<bool> s2appActive{ true };
std::atomic<bool> s2powerSaving{ false }, s2hdrSuppressed{ false };   // heat or Low Power Mode reductions on; macOS asked for HDR to be held back
bool recreatePending, cameraPending, cameraLimitsPending = true, savePending, physicsPending = true;
int physJointsApplied;   // the engine starts with the extra joint limits off; phaddrestrict toggles them
double recreateAt, saveAt;
int tickCount;
bool originalGraphics = false, initialOriginalPending = false, textureReloadPending = false;
int requestedGraphics = -1;
bool requestedMaximumFidelity = false;
NSDictionary<NSString*, NSNumber*> *enhancedMac;
NSDictionary<NSString*, NSNumber*> *enhancedEngine;
NSString *enhancedResolution;

NSString *Key(const char *k) { return [@"s2." stringByAppendingString:@(k)]; }

NSUserDefaults *SettingsDefaults()
{
	// Automated renderer checks use their own preference domain, never the player's.
	static NSUserDefaults *defaults = [] {
		const char *suite = getenv("S2_TEST_DEFAULTS_SUITE");
		return getenv("S2_HEADLESS") && suite ? [[NSUserDefaults alloc] initWithSuiteName:@(suite)] : NSUserDefaults.standardUserDefaults;
	}();
	return defaults;
}

void SaveMac()
{
	NSUserDefaults *d = SettingsDefaults();
	for (const MacField &m : MacFields()) [d setObject:@(m.f ? *m.f : (float)*m.i) forKey:Key(m.key)];
	[d setObject:@{ @"fov": @(cam.fov), @"minRod": @(cam.minRod), @"maxRod": @(cam.maxRod), @"minPitch": @(cam.minPitch), @"maxPitch": @(cam.maxPitch),
		@"soft": @(cam.softLimits), @"zoom": @(cam.zoomSpeed), @"pitch": @(cam.pitchSpeed), @"yaw": @(cam.yawSpeed), @"scroll": @(cam.scrollSpeed),
		@"zoomAccel": @(cam.zoomAccel), @"scrollAccel": @(cam.scrollAccel), @"yawAccel": @(cam.yawAccel), @"attenuation": @(cam.attenuation), @"minHeight": @(cam.minHeight) } forKey:@"s2.camera"];
	[d setObject:cheatWanted forKey:@"s2.cheats"];
	[d setBool:originalGraphics forKey:@"s2.originalGraphics"];
	if (enhancedMac) [d setObject:enhancedMac forKey:@"s2.enhancedMac"];
	if (enhancedEngine) [d setObject:enhancedEngine forKey:@"s2.enhancedEngine"];
	if (enhancedResolution) [d setObject:enhancedResolution forKey:@"s2.enhancedResolution"];
	++g_s2.generation;
}

void ScheduleRecreate() { recreatePending = true; recreateAt = CACurrentMediaTime() + 0.5; }
void ScheduleSave() { savePending = true; saveAt = CACurrentMediaTime() + 1.0; }

void ApplyPhysics()
{
	// fixed-step Verlet with interpolation (GAnimParticles.cpp): a shorter step is smoother and more stable.
	// Ground friction removes a share of each step's travel, so it is rescaled to keep the same loss per 50 ms.
	int rate = std::max(10, std::min(240, g_s2.physRate));
	float dt = 1.0f / rate;
	dt = std::max(0.004f, floorf(dt * 1000) / 1000);   // the engine keeps the step in whole milliseconds too
	float keep = 1 - std::max(0.0f, std::min(1.0f, g_s2.physFriction));
	float friction = 1 - powf(keep, dt / 0.05f);
	int it = std::max(1, std::min(40, g_s2.physIterations));
	char line[96];
	snprintf(line, sizeof line, "phtimestep %g", dt); S2EngineCommand(line);
	snprintf(line, sizeof line, "phfriction %g", friction); S2EngineCommand(line);
	// cycles each include a map collision query, so they stay at the original 5; iterations are cheap constraint passes
	snprintf(line, sizeof line, "phitercycles 5 %d", it); S2EngineCommand(line);
	snprintf(line, sizeof line, "phstiffness %g", std::max(0.1f, std::min(1.0f, g_s2.physStiffness))); S2EngineCommand(line);
	// the rest test: the second number is the stillness a body must reach to be frozen (the first is unused by the engine)
	snprintf(line, sizeof line, "phstoprule 0 %g", std::max(0.005f, std::min(0.5f, g_s2.physSettle))); S2EngineCommand(line);
	// the joint-limit switch changes array sizes used by ragdolls being simulated, so only flip it between missions
	if ((g_s2.physJointLimits != 0) != (physJointsApplied != 0) && !S2EngineHas("godmode"))
	{
		S2EngineCommand("phaddrestrict");
		physJointsApplied = g_s2.physJointLimits != 0;
	}
}

void ApplyCamera()
{
	char line[160];
	snprintf(line, sizeof line, "mission_camera_limits %g %g %g %g %g", cam.fov, cam.minRod, cam.maxRod, cam.minPitch, cam.maxPitch);
	S2EngineCommand(line);
	if (cam.softLimits)
	{
		// the stock soft range sits inside the hard one; the camera eases back into it after zooming past
		float minR = std::min(cam.maxRod, cam.minRod * 1.8f), maxR = std::max(minR, cam.maxRod * 0.77f);
		snprintf(line, sizeof line, "mission_camera_softlimits %g %g %g %g %g", cam.fov, minR, maxR, cam.minPitch - 0.05f, cam.maxPitch + 0.05f);
	}
	else snprintf(line, sizeof line, "mission_camera_softlimits %g %g %g %g %g", cam.fov, cam.minRod, cam.maxRod, cam.minPitch, cam.maxPitch);
	S2EngineCommand(line);
	snprintf(line, sizeof line, "mission_camera_zoom_speed %g", cam.zoomSpeed); S2EngineCommand(line);
	snprintf(line, sizeof line, "mission_camera_pitch_speed %g", cam.pitchSpeed); S2EngineCommand(line);
	snprintf(line, sizeof line, "mission_camera_yaw_speed %g", cam.yawSpeed); S2EngineCommand(line);
	snprintf(line, sizeof line, "mission_camera_scroll_speed %g", cam.scrollSpeed); S2EngineCommand(line);
	// each handler takes one number and stores it in the defaults a mission's camera is created from (Main/iMission.cpp)
	snprintf(line, sizeof line, "mission_camera_zoom_acceleration %g", cam.zoomAccel); S2EngineCommand(line);
	snprintf(line, sizeof line, "mission_camera_scroll_acceleration %g", cam.scrollAccel); S2EngineCommand(line);
	snprintf(line, sizeof line, "mission_camera_yaw_acceleration %g", cam.yawAccel); S2EngineCommand(line);
	snprintf(line, sizeof line, "mission_camera_attenuation %g", cam.attenuation); S2EngineCommand(line);
	snprintf(line, sizeof line, "mission_camera_minheight %g", cam.minHeight); S2EngineCommand(line);
}
} // namespace

void S2SettingsLoad()
{
	NSUserDefaults *d = SettingsDefaults();
	for (const MacField &m : MacFields())
	{
		NSNumber *v = [d objectForKey:Key(m.key)];
		if (![v isKindOfClass:NSNumber.class]) continue;
		if (m.f) *m.f = v.floatValue; else *m.i = v.intValue;
	}
	g_s2.worldFxDebug = 0;   // comparison views are for the current session only
	originalGraphics = [d boolForKey:@"s2.originalGraphics"];
	requestedMaximumFidelity = [d boolForKey:@"s2.pendingMaximumFidelity"];
	initialOriginalPending = originalGraphics;
	enhancedMac = [d dictionaryForKey:@"s2.enhancedMac"];
	enhancedEngine = [d dictionaryForKey:@"s2.enhancedEngine"];
	enhancedResolution = [d stringForKey:@"s2.enhancedResolution"];
	if (originalGraphics) S2ApplyOriginalVisuals(g_s2);
	NSDictionary *c = [d dictionaryForKey:@"s2.camera"];
	auto rd = [&](NSString *k, float &f) { if ([c[k] isKindOfClass:NSNumber.class]) f = [c[k] floatValue]; };
	rd(@"fov", cam.fov); rd(@"minRod", cam.minRod); rd(@"maxRod", cam.maxRod); rd(@"minPitch", cam.minPitch); rd(@"maxPitch", cam.maxPitch);
	rd(@"zoom", cam.zoomSpeed); rd(@"pitch", cam.pitchSpeed); rd(@"yaw", cam.yawSpeed); rd(@"scroll", cam.scrollSpeed);
	rd(@"zoomAccel", cam.zoomAccel); rd(@"scrollAccel", cam.scrollAccel); rd(@"yawAccel", cam.yawAccel); rd(@"attenuation", cam.attenuation); rd(@"minHeight", cam.minHeight);
	if ([c[@"soft"] isKindOfClass:NSNumber.class]) cam.softLimits = [c[@"soft"] intValue];
	cheatWanted = [NSMutableDictionary dictionary];
	NSDictionary *ch = [d dictionaryForKey:@"s2.cheats"];
	for (NSString *k in ch) if ([ch[k] isKindOfClass:NSNumber.class]) cheatWanted[k] = ch[k];
	[NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *) { s2appActive = true; }];
	if (@available(macOS 26.0, *))
	{
		// macOS 26: the system can ask apps to hold back HDR content (NSApplication.h, applicationShouldSuppressHighDynamicRangeContent)
		s2hdrSuppressed = NSApplication.sharedApplication.applicationShouldSuppressHighDynamicRangeContent;
		[NSNotificationCenter.defaultCenter addObserverForName:NSApplicationShouldBeginSuppressingHighDynamicRangeContentNotification object:nil queue:nil usingBlock:^(NSNotification *) { s2hdrSuppressed = true; ++g_s2.generation; }];
		[NSNotificationCenter.defaultCenter addObserverForName:NSApplicationShouldEndSuppressingHighDynamicRangeContentNotification object:nil queue:nil usingBlock:^(NSNotification *) { s2hdrSuppressed = false; ++g_s2.generation; }];
	}
	[NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification *) { s2appActive = false; }];
}

bool S2HDTexturesEnabled()
{
	return g_s2.hdTextures && S2HDTexturePackAvailable();
}

bool S2HDTexturePackAvailable()
{
	// only when the pack exists: an empty hd folder would cost a file probe per texture for nothing
	struct stat st;
	return stat("hd/Textures", &st) == 0;
}

int S2TerrainNearResolution()
{
	int r = g_s2.terrainDetail;
	return r >= 1024 ? 1024 : r >= 512 ? 512 : 256;
}

float S2AudioTargetGain()
{
	float v = std::max(0.0f, std::min(1.0f, g_s2.masterVolume));
	return g_s2.muteInBackground && !s2appActive ? 0.0f : v;
}
void S2SetAppActive(bool active) { s2appActive = active; }

// ---------------------------------------------------------------------------------------------------
// Power, display and gestures: the state behind the rows of the same names
static CAMetalLayer *s2gameLayer;
bool S2PowerSaving() { return s2powerSaving; }
bool S2HDRSuppressed() { return g_s2.hdrFollowSystem && s2hdrSuppressed; }
// Main/Camera.cpp multiplies the camera's angle by this every frame. The engine itself only knows 35 degrees (it writes that
// number back each frame), so the slider is applied as a ratio to it and the slow-motion zooms scale along.
float S2CameraFOVScale() { return std::max(20.0f, std::min(90.0f, cam.fov)) / 35.0f; }
int S2EdgeScrollBand() { return std::max(0, std::min(64, g_s2.edgeScrollBand)); }   // 0: no comparison at the edges can be true, edge scrolling is off
int S2DoubleClickMs()
{
	// 0 follows the speed chosen in System Settings (NSEvent.doubleClickInterval, seconds)
	if (g_s2.doubleClickMs <= 0) return std::max(150, std::min(5000, (int)lround(NSEvent.doubleClickInterval * 1000)));
	return std::max(150, std::min(2000, g_s2.doubleClickMs));
}
int S2LogLineMs() { return std::max(0, std::min(120, g_s2.logLineSeconds)) * 1000; }
int S2EndTurnGuardMs() { return std::max(0, std::min(2000, g_s2.endTurnGuardMs)); }
int S2SubtitleMs() { return std::max(1, std::min(30, g_s2.subtitleSeconds)) * 1000; }
int S2HitNumberMs() { return std::max(1, std::min(20, g_s2.hitNumberSeconds)) * 1000; }
int S2FollowUnitMs() { return g_s2.followSeconds <= 0 ? 3600000 : std::max(1, std::min(600, g_s2.followSeconds)) * 1000; }   // "no limit" is an hour
float S2AIThinkSeconds() { return std::max(5, std::min(50, g_s2.aiThinkMs)) / 1000.0f; }
bool S2AttractDemo() { return g_s2.attractDemo != 0; }
bool S2WidescreenHorPlus() { return g_s2.horPlus != 0; }   // Main/Camera.cpp reads it whenever a camera builds its projection
bool S2RetailRules() { return g_s2.retailRules != 0; }
int S2EnemyAim() { return g_s2.enemyHeadShots != 0; }
int S2EnemyPartialBursts() { return g_s2.enemyPartialBursts != 0; }
const S2Settings &S2EffectiveSettings()
{
	// the saved settings are never changed by heat or battery: the renderer is handed a reduced copy while it lasts
	static S2Settings e;
	e = g_s2;
	if (s2powerSaving) { e.ao = 0; e.bloom = 0; e.frameCap = e.frameCap > 0 ? std::min(e.frameCap, 30) : 30; }
	return e;
}
static struct { float panRight = 0, panUp = 0, yaw = 0; } s2gesture;
void S2AddTrackpadCamera(float panRight, float panUp, float yawRadians) { s2gesture.panRight += panRight; s2gesture.panUp += panUp; s2gesture.yaw += yawRadians; }
bool S2TakeTrackpadCamera(float *panRight, float *panUp, float *yawRadians)
{
	if (s2gesture.panRight == 0 && s2gesture.panUp == 0 && s2gesture.yaw == 0) return false;
	*panRight = s2gesture.panRight; *panUp = s2gesture.panUp; *yawRadians = s2gesture.yaw;
	s2gesture = {};
	return true;
}
// Twice a second from the tick: heat and battery, the display-sleep assertion, the Metal HUD.
extern int s2doubleClickMs;   // win32.cpp: what GetDoubleClickTime returns
static void S2PlatformTick()
{
	static unsigned n;
	if (n++ % 30) return;
	s2doubleClickMs = S2DoubleClickMs();
	NSProcessInfo *pi = NSProcessInfo.processInfo;
	bool save = g_s2.adaptPower && (pi.thermalState >= NSProcessInfoThermalStateSerious || pi.lowPowerModeEnabled);
	if (getenv("S2_FORCE_POWER_SAVING")) save = g_s2.adaptPower != 0;   // test hook: this Mac is neither hot nor in Low Power Mode during a check
	if (save != s2powerSaving) { s2powerSaving = save; fprintf(stderr, "[power] reductions %s\n", save ? "on" : "off"); ++g_s2.generation; }
	static id<NSObject> awake;
	bool want = g_s2.keepAwake && s2appActive && !getenv("S2_HEADLESS");
	if (want && !awake) awake = [pi beginActivityWithOptions:(NSActivityIdleDisplaySleepDisabled | NSActivityIdleSystemSleepDisabled) reason:@"Silent Storm is in front"];
	else if (!want && awake) { [pi endActivity:awake]; awake = nil; }
	static int hud = 0;   // the layer's own default is no HUD, so nothing is set until the player asks
	if (s2gameLayer && hud != (g_s2.metalHUD != 0))
	{
		hud = g_s2.metalHUD != 0;
		// keys and values from Apple's "Customizing the Metal Performance HUD" (read 2026-11-21): mode default / main / disabled
		s2gameLayer.developerHUDProperties = hud ? @{ @"mode": @"default", @"logging": @"default" } : @{ @"mode": @"disabled" };
		fprintf(stderr, "[hud] metal performance hud %s\n", hud ? "on" : "off");
	}
}

// ---------------------------------------------------------------------------------------------------
// FPS overlay: a text layer on top of the game's Metal layer
static CATextLayer *s2overlay;
static struct { double sum = 0, worst = 0; int frames = 0; double last = 0; std::vector<double> window; } s2fps;

void S2SettingsAttachOverlay(void *metalLayer)
{
	CALayer *host = (__bridge CALayer*)metalLayer;
	if ([host isKindOfClass:CAMetalLayer.class]) s2gameLayer = (CAMetalLayer*)host;
	s2overlay = [CATextLayer layer];
	s2overlay.font = (__bridge CFTypeRef)[NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold];
	s2overlay.fontSize = 13;
	s2overlay.foregroundColor = CGColorCreateGenericRGB(0.75, 1.0, 0.75, 1);
	s2overlay.backgroundColor = CGColorCreateGenericRGB(0, 0, 0, 0.55);
	s2overlay.cornerRadius = 6;
	s2overlay.contentsScale = NSScreen.mainScreen.backingScaleFactor;
	s2overlay.alignmentMode = kCAAlignmentLeft;
	s2overlay.hidden = YES;
	s2overlay.zPosition = 10;
	[host addSublayer:s2overlay];
}

void S2SettingsFrame(double ms, int srcW, int srcH, int outW, int outH, const char *scaler)
{
	if (!s2overlay || ms <= 0) return;
	if (!g_s2.showFPS) { if (!s2overlay.hidden) { [CATransaction begin]; [CATransaction setDisableActions:YES]; s2overlay.hidden = YES; [CATransaction commit]; } return; }
	s2fps.sum += ms; ++s2fps.frames; s2fps.worst = std::max(s2fps.worst, ms);
	s2fps.window.push_back(ms);
	double now = CACurrentMediaTime();
	if (now - s2fps.last < 0.5) return;
	s2fps.last = now;
	double mean = s2fps.sum / s2fps.frames;
	std::vector<double> w = s2fps.window;
	std::sort(w.begin(), w.end());
	double p99 = w[std::min(w.size() - 1, (size_t)(w.size() * 0.99))];
	NSString *text;
	if (g_s2.showFPS == 1)
		text = [NSString stringWithFormat:@" %.0f fps ", 1000.0 / mean];
	else
		text = [NSString stringWithFormat:@" %.0f fps   %.2f ms avg   %.1f ms 1%% low   %.1f ms worst \n %d×%d → %d×%d  %s%s%s ",
			1000.0 / mean, mean, p99, s2fps.worst, srcW, srcH, outW, outH, scaler,
			g_s2.fxaa ? " + FXAA" : "", g_s2.vsync ? "  VSync" : ""];
	extern float s2hdrHeadroom;
	if (g_s2.showFPS == 2 && s2hdrHeadroom > 0) text = [text stringByAppendingFormat:@" HDR %.1f× \n ", s2hdrHeadroom];
	s2fps.sum = 0; s2fps.frames = 0; s2fps.worst = 0; s2fps.window.clear();
	CALayer *host = s2overlay.superlayer;
	NSDictionary *attrs = @{ NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold] };
	NSSize sz = [text boundingRectWithSize:NSMakeSize(2000, 200) options:NSStringDrawingUsesLineFragmentOrigin attributes:attrs].size;
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	s2overlay.string = text;
	s2overlay.hidden = NO;
	CGFloat h = host.bounds.size.height;
	s2overlay.frame = CGRectMake(12, host.geometryFlipped ? 12 : h - sz.height - 16, ceil(sz.width) + 8, ceil(sz.height) + 4);
	[CATransaction commit];
}

// ---------------------------------------------------------------------------------------------------
// Rows
typedef NS_ENUM(int, S2Kind) { S2Switch, S2Slider, S2Popup };

@interface S2Row : NSObject
@property S2Kind kind;
@property (copy) float (^get)(void);
@property (copy) void (^set)(float);
@property (copy) NSString *(^format)(float);
@property (strong) NSControl *control;
@property (strong) NSTextField *valueLabel;
@property (strong) NSArray<NSNumber*> *values;   // popup item values
@property (copy) NSString *title, *tab;
- (void)changed:(id)sender;
- (void)refresh;
@end

@implementation S2Row
- (void)changed:(id)sender
{
	float v = 0;
	switch (self.kind)
	{
	case S2Switch: v = ((NSSwitch*)self.control).state == NSControlStateValueOn ? 1 : 0; break;
	case S2Slider: v = (float)((NSSlider*)self.control).doubleValue; break;
	case S2Popup: { NSInteger i = ((NSPopUpButton*)self.control).indexOfSelectedItem; if (i >= 0 && i < (NSInteger)self.values.count) v = self.values[i].floatValue; break; }
	}
	self.set(v);
	if (self.valueLabel && self.format) self.valueLabel.stringValue = self.format(v);
}
- (void)refresh
{
	float v = self.get();
	switch (self.kind)
	{
	case S2Switch: ((NSSwitch*)self.control).state = v != 0 ? NSControlStateValueOn : NSControlStateValueOff; break;
	case S2Slider: ((NSSlider*)self.control).doubleValue = v; break;
	case S2Popup:
	{
		NSInteger best = 0; float bd = INFINITY;
		for (NSUInteger i = 0; i < self.values.count; ++i) { float d = fabsf(self.values[i].floatValue - v); if (d < bd) { bd = d; best = (NSInteger)i; } }
		[(NSPopUpButton*)self.control selectItemAtIndex:best];
		break;
	}
	}
	if (self.valueLabel && self.format) self.valueLabel.stringValue = self.format(v);
}
@end

@interface S2ActionTarget : NSObject
@property (copy) void (^action)(void);
- (void)fire:(id)sender;
@end
@implementation S2ActionTarget
- (void)fire:(id)sender { self.action(); }
@end

// ---------------------------------------------------------------------------------------------------
// A page: a scrolling column of sections and rows
@interface S2Page : NSViewController
@property (strong) NSStackView *stack;
@property (strong) NSMutableArray *rows;
@end

@interface S2FlippedView : NSView
@end
@implementation S2FlippedView
- (BOOL)isFlipped { return YES; }
@end

static NSMutableArray *s2targets;   // keeps button targets alive
static NSMutableArray<S2Row*> *s2allRows;
static NSMutableArray<NSControl*> *s2visualControls;
static bool s2collectVisualControls;
static void CollectVisualControls(NSView *view)
{
	if ([view isKindOfClass:NSControl.class])
	{
		NSControl *control = (NSControl*)view;
		control.enabled = !S2OriginalGraphics();
		[s2visualControls addObject:control];
	}
	for (NSView *child in view.subviews) CollectVisualControls(child);
}

static const CGFloat kWidth = 760, kTextWidth = 400;

@implementation S2Page
- (void)loadView
{
	NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, 600)];
	scroll.hasVerticalScroller = YES;
	scroll.drawsBackground = NO;
	scroll.autohidesScrollers = YES;
	S2FlippedView *doc = [[S2FlippedView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, 600)];
	doc.translatesAutoresizingMaskIntoConstraints = NO;
	self.stack = [NSStackView stackViewWithViews:@[]];
	self.stack.orientation = NSUserInterfaceLayoutOrientationVertical;
	self.stack.alignment = NSLayoutAttributeLeading;
	self.stack.spacing = 10;
	self.stack.edgeInsets = NSEdgeInsetsMake(18, 24, 24, 24);
	self.stack.translatesAutoresizingMaskIntoConstraints = NO;
	[doc addSubview:self.stack];
	scroll.documentView = doc;
	[NSLayoutConstraint activateConstraints:@[
		[self.stack.leadingAnchor constraintEqualToAnchor:doc.leadingAnchor], [self.stack.trailingAnchor constraintEqualToAnchor:doc.trailingAnchor],
		[self.stack.topAnchor constraintEqualToAnchor:doc.topAnchor], [self.stack.bottomAnchor constraintEqualToAnchor:doc.bottomAnchor],
		[doc.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
		[scroll.widthAnchor constraintGreaterThanOrEqualToConstant:kWidth], [scroll.heightAnchor constraintGreaterThanOrEqualToConstant:560],
	]];
	self.view = scroll;
	self.rows = [NSMutableArray array];
}
- (void)viewWillAppear { [super viewWillAppear]; for (S2Row *r in self.rows) [r refresh]; }

- (void)section:(NSString *)title
{
	NSTextField *t = [NSTextField labelWithString:title.uppercaseString];
	t.font = [NSFont systemFontOfSize:11 weight:NSFontWeightBold];
	t.textColor = NSColor.secondaryLabelColor;
	if (self.stack.arrangedSubviews.count) [self.stack setCustomSpacing:22 afterView:self.stack.arrangedSubviews.lastObject];
	[self.stack addArrangedSubview:t];
	NSBox *line = [NSBox new]; line.boxType = NSBoxSeparator;
	line.translatesAutoresizingMaskIntoConstraints = NO;
	[self.stack addArrangedSubview:line];
	[line.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48].active = YES;
}

- (void)note:(NSString *)text
{
	NSTextField *t = [NSTextField wrappingLabelWithString:text];
	t.font = [NSFont systemFontOfSize:11];
	t.textColor = NSColor.secondaryLabelColor;
	t.preferredMaxLayoutWidth = kWidth - 48;
	[self.stack addArrangedSubview:t];
}

- (NSView *)rowWithTitle:(NSString *)title detail:(NSString *)detail control:(NSView *)control
{
	if (s2collectVisualControls) CollectVisualControls(control);
	NSTextField *tl = [NSTextField labelWithString:title];
	tl.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
	NSStackView *text = [NSStackView stackViewWithViews:@[ tl ]];
	text.orientation = NSUserInterfaceLayoutOrientationVertical;
	text.alignment = NSLayoutAttributeLeading;
	text.spacing = 2;
	// fixed text column: the control gets the rest, and descriptions wrap instead of clipping
	text.translatesAutoresizingMaskIntoConstraints = NO;
	[text.widthAnchor constraintEqualToConstant:kTextWidth].active = YES;
	if (detail.length)
	{
		NSTextField *dl = [NSTextField wrappingLabelWithString:detail];
		dl.font = [NSFont systemFontOfSize:11];
		dl.textColor = NSColor.secondaryLabelColor;
		dl.preferredMaxLayoutWidth = kTextWidth;
		[dl setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];
		[text addArrangedSubview:dl];
	}
	NSView *spacer = [NSView new];
	[spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
	NSStackView *row = [NSStackView stackViewWithViews:@[ text, spacer, control ]];
	row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	row.alignment = NSLayoutAttributeCenterY;
	row.translatesAutoresizingMaskIntoConstraints = NO;
	[self.stack addArrangedSubview:row];
	[row.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48].active = YES;
	return row;
}

- (S2Row *)add:(S2Row *)r title:(NSString *)title detail:(NSString *)detail view:(NSView *)view
{
	r.control.target = r; r.control.action = @selector(changed:);
	r.title = title; r.tab = self.title;
	[self rowWithTitle:title detail:detail control:view];
	[self.rows addObject:r];
	[s2allRows addObject:r];
	[r refresh];
	return r;
}

- (S2Row *)toggle:(NSString *)title detail:(NSString *)detail get:(float (^)(void))get set:(void (^)(float))set
{
	S2Row *r = [S2Row new]; r.kind = S2Switch; r.get = get; r.set = set;
	r.control = [NSSwitch new];
	return [self add:r title:title detail:detail view:r.control];
}

- (S2Row *)slider:(NSString *)title detail:(NSString *)detail min:(float)mn max:(float)mx format:(NSString *(^)(float))fmt get:(float (^)(void))get set:(void (^)(float))set
{
	S2Row *r = [S2Row new]; r.kind = S2Slider; r.get = get; r.set = set; r.format = fmt;
	NSSlider *s = [NSSlider sliderWithValue:get() minValue:mn maxValue:mx target:nil action:nil];
	s.continuous = YES;
	[s.widthAnchor constraintEqualToConstant:170].active = YES;
	r.control = s;
	r.valueLabel = [NSTextField labelWithString:@""];
	r.valueLabel.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
	r.valueLabel.alignment = NSTextAlignmentRight;
	[r.valueLabel.widthAnchor constraintEqualToConstant:64].active = YES;
	NSStackView *v = [NSStackView stackViewWithViews:@[ s, r.valueLabel ]];
	v.spacing = 8;
	return [self add:r title:title detail:detail view:v];
}

- (S2Row *)popup:(NSString *)title detail:(NSString *)detail items:(NSArray<NSString*> *)items values:(NSArray<NSNumber*> *)values get:(float (^)(void))get set:(void (^)(float))set
{
	S2Row *r = [S2Row new]; r.kind = S2Popup; r.get = get; r.set = set; r.values = values;
	NSPopUpButton *p = [NSPopUpButton new];
	[p addItemsWithTitles:items];
	[p.widthAnchor constraintGreaterThanOrEqualToConstant:180].active = YES;
	[p.widthAnchor constraintLessThanOrEqualToConstant:270].active = YES;
	r.control = p;
	return [self add:r title:title detail:detail view:p];
}

- (void)buttons:(NSArray<NSString*> *)titles title:(NSString *)title detail:(NSString *)detail actions:(NSArray *)actions
{
	NSMutableArray *bs = [NSMutableArray array];
	for (NSUInteger i = 0; i < titles.count; ++i)
	{
		S2ActionTarget *t = [S2ActionTarget new]; t.action = actions[i];
		[s2targets addObject:t];
		NSButton *b = [NSButton buttonWithTitle:titles[i] target:t action:@selector(fire:)];
		b.bezelStyle = NSBezelStyleRounded;
		[bs addObject:b];
	}
	NSStackView *v = [NSStackView stackViewWithViews:bs];
	v.spacing = 6;
	[self rowWithTitle:title detail:detail control:v];
}
@end

// ---------------------------------------------------------------------------------------------------
// Engine-variable shortcuts
namespace {
enum Apply { Live, Recreate, Camera };

void EngineChanged(Apply a)
{
	if (a == Recreate) ScheduleRecreate();
	if (a == Camera) cameraPending = true;
	ScheduleSave();
}
float (^EngGet(const char *var, float def))(void) { std::string v = var; return ^float { return S2EngineGet(v.c_str(), def); }; }
void (^EngSet(const char *var, Apply a))(float) { std::string v = var; return ^(float x) { S2EngineSet(v.c_str(), x); EngineChanged(a); }; }

void (^MacSetF(float *p))(float) { return ^(float x) { *p = x; SaveMac(); }; }
void (^MacSetI(int *p))(float) { return ^(float x) { *p = (int)lroundf(x); if (p == &g_s2.hdTextures || p == &g_s2.terrainDetail) textureReloadPending = true; SaveMac(); }; }
float (^MacGetF(float *p))(void) { return ^float { return *p; }; }
float (^MacGetI(int *p))(void) { return ^float { return (float)*p; }; }

NSString *(^Percent)(float) = ^NSString *(float v) { return [NSString stringWithFormat:@"%.0f%%", v * 100]; };
NSString *(^Signed)(float) = ^NSString *(float v) { return [NSString stringWithFormat:@"%+.2f", v]; };
NSString *(^Times)(float) = ^NSString *(float v) { return [NSString stringWithFormat:@"%.2f×", v]; };
NSString *(^Plain1)(float) = ^NSString *(float v) { return [NSString stringWithFormat:@"%.1f", v]; };
NSString *(^Plain2)(float) = ^NSString *(float v) { return [NSString stringWithFormat:@"%.2f", v]; };
NSString *(^Degrees)(float) = ^NSString *(float v) { return [NSString stringWithFormat:@"%.0f°", v]; };
NSString *(^PitchDeg)(float) = ^NSString *(float v) { return [NSString stringWithFormat:@"%.0f°", -v * 180 / M_PI]; };

struct Preset { const char *var; float v; };
void ApplyPreset(const std::vector<Preset> &p)
{
	for (const Preset &x : p) S2EngineSet(x.var, x.v);
	ScheduleRecreate(); ScheduleSave();
	for (S2Row *r in s2allRows) [r refresh];
}
const std::vector<Preset> kLow = {
	{ "gfx_fastest", 1 }, { "gfx_shadows", 0 }, { "gfx_cl", 0 }, { "gfx_fog", 1 }, { "gfx_specular", 0 }, { "gfx_point_specular", 0 },
	{ "gfx_blur_sun", 0 }, { "gfx_cl_blur", 0 }, { "gfx_decals", 0 }, { "gfx_cl_use_bump", 0 }, { "gfx_cl_use_bump_always", 0 },
	{ "gfx_cl_use_precise_shadows", 0 }, { "gfx_cl_cube_resolution", 16 }, { "gfx_cl_sky_textures", 0 }, { "gfx_depth_tex_resolution", 512 },
	{ "gfx_texture_mip", 1 }, { "gfx_register_resolution", 1 }, { "gfx_anisotropic_filter", 1 },
};
const std::vector<Preset> kMedium = {
	{ "gfx_fastest", 0 }, { "gfx_shadows", 1 }, { "gfx_cl", 1 }, { "gfx_fog", 1 }, { "gfx_specular", 1 }, { "gfx_point_specular", 0 },
	{ "gfx_blur_sun", 0 }, { "gfx_cl_blur", 1 }, { "gfx_decals", 1 }, { "gfx_cl_use_bump", 0 }, { "gfx_cl_use_bump_always", 0 },
	{ "gfx_cl_use_precise_shadows", 0 }, { "gfx_cl_cube_resolution", 32 }, { "gfx_cl_sky_textures", 1 }, { "gfx_depth_tex_resolution", 512 },
	{ "gfx_texture_mip", 0 }, { "gfx_register_resolution", 1 }, { "gfx_anisotropic_filter", 2 },
};
const std::vector<Preset> kHigh = {
	{ "gfx_fastest", 0 }, { "gfx_shadows", 1 }, { "gfx_cl", 1 }, { "gfx_fog", 2 }, { "gfx_specular", 1 }, { "gfx_point_specular", 1 },
	{ "gfx_blur_sun", 1 }, { "gfx_cl_blur", 1 }, { "gfx_decals", 1 }, { "gfx_cl_use_bump", 1 }, { "gfx_cl_use_bump_always", 1 },
	{ "gfx_cl_use_precise_shadows", 1 }, { "gfx_cl_cube_resolution", 64 }, { "gfx_cl_sky_textures", 2 }, { "gfx_depth_tex_resolution", 1024 },
	{ "gfx_texture_mip", 0 }, { "gfx_register_resolution", 1 }, { "gfx_anisotropic_filter", 2 },
};
const std::vector<Preset> kUltra = {
	{ "gfx_fastest", 0 }, { "gfx_shadows", 1 }, { "gfx_cl", 1 }, { "gfx_fog", 2 }, { "gfx_specular", 1 }, { "gfx_point_specular", 1 },
	{ "gfx_blur_sun", 1 }, { "gfx_cl_blur", 1 }, { "gfx_decals", 1 }, { "gfx_cl_use_bump", 1 }, { "gfx_cl_use_bump_always", 1 },
	{ "gfx_cl_use_precise_shadows", 1 }, { "gfx_cl_cube_resolution", 128 }, { "gfx_cl_sky_textures", 4 }, { "gfx_depth_tex_resolution", 1024 },
	{ "gfx_texture_mip", 0 }, { "gfx_register_resolution", 2 }, { "gfx_anisotropic_filter", 2 }, { "gfx_texture_usedxt", 1 },
	{ "gfx_terrain_565", 0 }, { "gfx_16bit_textures", 0 }, { "gfx_particles", 1 },
};
std::vector<Preset> Beyond() { std::vector<Preset> p = kUltra; p.push_back({ "gfx_cl_cube_resolution", 256 }); p.push_back({ "gfx_register_resolution", 4 }); p.push_back({ "gfx_depth_tex_resolution", 4096 }); return p; }

void ApplyMaximumFidelity();

void ApplyGraphicsMode(bool original, bool initial = false)
{
	if (original == originalGraphics && !initial) return;
	if (original && !originalGraphics)
	{
		NSMutableDictionary *mac = [NSMutableDictionary dictionary], *engine = [NSMutableDictionary dictionary];
		for (const auto &field : s2VisualInts) mac[@(field.name)] = @(g_s2.*field.member);
		for (const auto &field : s2VisualFloats) mac[@(field.name)] = @(g_s2.*field.member);
		for (const auto &field : s2VisualEngine) if (S2EngineHas(field.name)) engine[@(field.name)] = @(S2EngineGet(field.name, field.original));
		enhancedMac = mac; enhancedEngine = engine;
		enhancedResolution = @(S2EngineGetString("gfx_resolution").c_str());
	}
	if (original)
	{
		S2ApplyOriginalVisuals(g_s2);
		for (const auto &field : s2VisualEngine) if (S2EngineHas(field.name)) S2EngineSet(field.name, field.original);
		S2EngineSetString("gfx_resolution", "1024x768");
	}
	else
	{
		for (const auto &field : s2VisualInts) if ([enhancedMac[@(field.name)] isKindOfClass:NSNumber.class]) g_s2.*field.member = [enhancedMac[@(field.name)] intValue];
		for (const auto &field : s2VisualFloats) if ([enhancedMac[@(field.name)] isKindOfClass:NSNumber.class]) g_s2.*field.member = [enhancedMac[@(field.name)] floatValue];
		for (const auto &field : s2VisualEngine) if ([enhancedEngine[@(field.name)] isKindOfClass:NSNumber.class]) S2EngineSet(field.name, [enhancedEngine[@(field.name)] floatValue]);
		if (enhancedResolution.length) S2EngineSetString("gfx_resolution", enhancedResolution.UTF8String);
	}
	originalGraphics = original;
	textureReloadPending = true;
	recreatePending = true; recreateAt = 0; // one rebuild, not one per option
	SaveMac(); ScheduleSave();
	for (S2Row *row in s2allRows) [row refresh];
	for (NSControl *control in s2visualControls) control.enabled = !original;
	fprintf(stderr, "[graphics-mode] %s resolution=%s hd=%d terrain=%d\n", original ? "Original" : "Enhanced", S2EngineGetString("gfx_resolution").c_str(), g_s2.hdTextures, g_s2.terrainDetail);
}

void ResetMacOptions()
{
	// Leave the comparison baseline before resetting Mac-only options, so the
	// Original label can never describe a half-original, half-enhanced image.
	requestedGraphics = -1;
	initialOriginalPending = false;
	requestedMaximumFidelity = false;
	[SettingsDefaults() removeObjectForKey:@"s2.pendingMaximumFidelity"];
	if (originalGraphics) ApplyGraphicsMode(false);
	g_s2 = S2Settings(); cam = kStockCamera; [cheatWanted removeAllObjects];
	textureReloadPending = true; physicsPending = true; cameraLimitsPending = true;
	SaveMac();
	for (S2Row *row in s2allRows) [row refresh];
	for (NSControl *control in s2visualControls) control.enabled = YES;
}

void ApplyMaximumFidelity()
{
	requestedGraphics = -1; initialOriginalPending = false;
	if (originalGraphics) ApplyGraphicsMode(false);
	ApplyPreset(Beyond());
	// Twice the world pixels at the display's own resolution. Four times costs twice the frame time for edges that are
	// already smooth: measured 148 against 79 fps at 2560x1440, and 34 fps at the old Retina-sized target.
	S2EngineSet("gfx_register_resolution", 2);
	// Fidelity is resolution and sampling, not maximising artistic filter strength.
	// Keep the original palette, avoid negative-LOD shimmer and leave HUD FXAA off.
	g_s2.hdTextures = 1; g_s2.terrainDetail = 1024; g_s2.anisoOverride = 16;
	g_s2.upscaler = 1; g_s2.fxaa = 0; g_s2.lodBias = 0; g_s2.sharpen = 0.25f;
	g_s2.brightness = 0; g_s2.contrast = 1; g_s2.saturation = 1;
	g_s2.vibrance = g_s2.temperature = g_s2.tint = g_s2.grain = g_s2.vignette = g_s2.haze = 0;
	g_s2.ao = 1; g_s2.aoStrength = 0.85f; g_s2.aoRadius = 0.7f;
	g_s2.bloom = 1; g_s2.bloomStrength = 0.5f; g_s2.bloomThreshold = 0.8f;
	g_s2.edr = 1; g_s2.edrStrength = 0.6f; g_s2.worldFxDebug = 0;
	S2EngineSet("gfx_gamma", 1); S2EngineSet("gfx_fsaa", 0);
	NSScreen *screen = GameWindow().screen ?: NSScreen.mainScreen;   // the display the game is on, not the primary one
	int w = (int)lround(screen.frame.size.width * screen.backingScaleFactor);
	int h = (int)lround(screen.frame.size.height * screen.backingScaleFactor);
	// The engine advertises 8192-pixel targets; 2x area requires 1.41 times the width.
	double fit = std::min(1.0, 8192.0 / (std::max(w, h) * 1.42));
	w = std::max(800, (int)lround(w * fit)); h = std::max(600, (int)lround(h * fit));
	char resolution[64]; snprintf(resolution, sizeof resolution, "%dx%d", w, h);
	S2EngineSetString("gfx_resolution", resolution);
	textureReloadPending = true; recreatePending = true; recreateAt = 0;
	[SettingsDefaults() removeObjectForKey:@"s2.pendingMaximumFidelity"];
	SaveMac(); ScheduleSave();
	for (S2Row *row in s2allRows) [row refresh];
	fprintf(stderr, "[maximum-fidelity] resolution=%s worldArea=2 shadow=4096 lightCache=256 terrain=1024 aniso=16\n", resolution);
}
} // namespace

bool S2OriginalGraphics() { return requestedGraphics >= 0 ? requestedGraphics != 0 : originalGraphics; }
int S2AITurnSpeed() { return std::max(1, std::min(4, g_s2.aiTurnSpeed)); }
bool S2WeaponCompareOn() { return g_s2.weaponCompare != 0; }
void S2SetAITurnSpeed(int speed)
{
	g_s2.aiTurnSpeed = std::max(1, std::min(4, speed));
	SaveMac();
	for (S2Row *row in s2allRows) [row refresh];
	fprintf(stderr, "[turn-speed] %dx\n", g_s2.aiTurnSpeed);
}
void S2CycleAITurnSpeed()
{
	S2SetAITurnSpeed(S2AITurnSpeed() % 4 + 1);
	char text[96];
	snprintf(text, sizeof text, S2AITurnSpeed() == 1 ? "Enemy and ally turns: normal speed" : "Enemy and ally turns: %d× speed", S2AITurnSpeed());
	S2KeyHelpNotice(text);
}
void S2SetOriginalGraphics(bool original) { requestedGraphics = original ? 1 : 0; }
void S2ToggleGraphics() { S2SetOriginalGraphics(!S2OriginalGraphics()); }

// ---------------------------------------------------------------------------------------------------
// The window
@interface S2SettingsWindow : NSWindowController <NSWindowDelegate>
@end
static S2SettingsWindow *s2settings;
static NSWindow *GameWindow()
{
	for (NSWindow *x in NSApp.windows) if ([x.contentView.layer isKindOfClass:CAMetalLayer.class]) return x;
	return nil;
}

std::vector<S2Mode> S2DisplayModes()
{
	NSScreen *sc = NSScreen.mainScreen;
	int pw = (int)sc.frame.size.width, ph = (int)sc.frame.size.height;
	double scale = sc.backingScaleFactor;
	int nw = (int)lround(pw * scale), nh = (int)lround(ph * scale);
	std::vector<S2Mode> m;
	auto add = [&](int w, int h, const char *label) {
		for (const S2Mode &x : m) if (x.w == w && x.h == h) return;
		m.push_back({ w, h, label });
	};
	add(pw, ph, "display size");
	add((int)lround(pw * 1.25), (int)lround(ph * 1.25), "1.25× display");
	add((int)lround(pw * 1.5), (int)lround(ph * 1.5), "1.5× display");
	add(nw, nh, "native pixels");
	add(nw * 3 / 2, nh * 3 / 2, "supersampled 1.5×");
	const int std16x10[][2] = { { 1024, 640 }, { 1280, 800 }, { 1440, 900 }, { 1680, 1050 }, { 1920, 1200 }, { 2560, 1600 }, { 2880, 1800 } };
	for (auto &r : std16x10) if (r[0] <= nw && r[1] <= nh) add(r[0], r[1], "16:10");
	const int std16x9[][2] = { { 1280, 720 }, { 1600, 900 }, { 1920, 1080 }, { 2560, 1440 }, { 3840, 2160 } };
	for (auto &r : std16x9) if (r[0] <= nw && r[1] <= nh) add(r[0], r[1], "16:9");
	const int classic[][2] = { { 800, 600 }, { 1024, 768 }, { 1280, 960 }, { 1600, 1200 } };
	for (auto &r : classic) if (r[0] <= nw && r[1] <= nh) add(r[0], r[1], r[0] <= 1024 ? "4:3, some menu text clips" : "4:3");
	return m;
}

static NSArray<NSString*> *ResolutionTitles(std::vector<std::pair<int, int>> &out)
{
	NSMutableArray *t = [NSMutableArray array];
	for (const S2Mode &m : S2DisplayModes())
	{
		out.push_back({ m.w, m.h });
		[t addObject:[NSString stringWithFormat:@"%d × %d   %s", m.w, m.h, m.label]];
	}
	return t;
}

@implementation S2SettingsWindow
{
	std::vector<std::pair<int, int>> resolutions;
}

- (instancetype)init
{
	s2targets = [NSMutableArray array];
	s2allRows = [NSMutableArray array];
	s2visualControls = [NSMutableArray array];
	NSTabViewController *tabs = [NSTabViewController new];
	tabs.tabStyle = NSTabViewControllerTabStyleToolbar;
	auto page = [&](NSString *label, NSString *symbol) {
		S2Page *p = [S2Page new];
		p.title = label;
		(void)p.view;
		NSTabViewItem *it = [NSTabViewItem tabViewItemWithViewController:p];
		it.label = label;
		it.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:label];
		[tabs addTabViewItem:it];
		return p;
	};
	[self buildDisplay:page(@"Display", @"display")];
	[self buildGraphics:page(@"Graphics", @"cube.transparent")];
	[self buildImage:page(@"Image", @"camera.filters")];
	[self buildAudio:page(@"Audio", @"speaker.wave.2")];
	[self buildCamera:page(@"Camera & Input", @"camera.viewfinder")];
	[self buildGameplay:page(@"Gameplay", @"flag.2.crossed")];
	[self buildCheats:page(@"Cheats", @"wand.and.stars")];
	[self buildAdvanced:page(@"Advanced", @"wrench.and.screwdriver")];

	NSWindow *w = [NSWindow windowWithContentViewController:tabs];
	w.styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable;
	w.title = @"Silent Storm Settings";
	w.toolbarStyle = NSWindowToolbarStylePreference;
	// shown over the game, including its full-screen Space
	w.level = NSFloatingWindowLevel;
	w.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorMoveToActiveSpace;
	w.releasedWhenClosed = NO;
	[w setContentSize:NSMakeSize(kWidth, 640)];
	w.contentMinSize = NSMakeSize(kWidth, 420);
	w.frameAutosaveName = @"S2Settings";
	self = [super initWithWindow:w];
	w.delegate = self;
	return self;
}

- (void)windowDidBecomeKey:(NSNotification *)n { for (S2Row *r in s2allRows) [r refresh]; }

// ---- Display
- (void)buildDisplay:(S2Page *)p
{
	s2collectVisualControls = true;
	[p section:@"Screen"];
	[p note:@"The size of the picture and of the window it is shown in."];
	NSArray *titles = ResolutionTitles(resolutions);
	NSMutableArray *vals = [NSMutableArray array];
	for (size_t i = 0; i < resolutions.size(); ++i) [vals addObject:@(i)];
	__block std::vector<std::pair<int, int>> *res = &resolutions;
	[p popup:@"Game resolution" detail:@"How many pixels the whole picture is drawn with, interface included. More pixels look sharper but make the 2003 interface smaller, because it has a fixed pixel size; \"display size\" shows it as designed. A shape that differs from the window's gets black bars. The picture rebuilds half a second after you choose; the mission stays loaded."
		items:titles values:vals
		get:^float {
			int w = 0, h = 0; sscanf(S2EngineGetString("gfx_resolution").c_str(), "%dx%d", &w, &h);
			for (size_t i = 0; i < res->size(); ++i) if ((*res)[i].first == w && (*res)[i].second == h) return (float)i;
			return 0;
		}
		set:^(float v) {
			size_t i = (size_t)v; if (i >= res->size()) return;
			char s[32]; snprintf(s, sizeof s, "%dx%d", (*res)[i].first, (*res)[i].second);
			S2EngineSetString("gfx_resolution", s); EngineChanged(Recreate);
		}];
	[p toggle:@"Full screen" detail:@"Puts the game in macOS full screen, on its own Space, with no title bar. Off returns it to a window. The same as pressing Command-F or the green window button. The choice is saved, so the next launch starts the same way."
		get:^float { return (GameWindow().styleMask & NSWindowStyleMaskFullScreen) ? 1 : 0; }
		set:^(float v) {
			S2EngineSet("gfx_fullscreen", v); ScheduleSave();
			NSWindow *g = GameWindow();
			if (g && ((g.styleMask & NSWindowStyleMaskFullScreen) != 0) != (v != 0)) [g toggleFullScreen:nil];
		}];

	[p section:@"HDR"];
	[p note:@"Extra brightness for highlights, on displays that can show brighter than white."];
	[p toggle:@"HDR highlights" detail:@"On a display that can show brighter than normal white (MacBook Pro XDR, Pro Display XDR, an HDR monitor), the brightest parts of the 3D world, such as fire, muzzle flashes, lamps and sunlit pale surfaces, are shown brighter than white. The interface stays at normal white. On any other display, and with Shadows off, it changes nothing."
		get:MacGetI(&g_s2.edr) set:MacSetI(&g_s2.edr)];
	[p slider:@"HDR intensity" detail:@"How far above normal white the highlights may go. The display offers a changing amount of extra brightness, and the game counts at most 3 times normal white; this is the share of it the highlights use. At 60% with full headroom the brightest pixels reach 2.2 times white. 0% is the same as HDR highlights off." min:0 max:1 format:Percent get:MacGetF(&g_s2.edrStrength) set:MacSetF(&g_s2.edrStrength)];
	[p toggle:@"Follow the system's HDR limit" detail:@"macOS 26 and later can ask apps to hold back HDR content. On: while such a request lasts, the highlights drop to normal white, and they return when it ends. Off: the highlights stay bright regardless. No effect on earlier macOS versions or when HDR highlights is off."
		get:MacGetI(&g_s2.hdrFollowSystem) set:MacSetI(&g_s2.hdrFollowSystem)];

	[p section:@"Scaling"];
	[p note:@"How the game picture is fitted to the screen's pixels and cleaned up afterwards."];
	[p popup:@"Upscaler" detail:@"How the picture is enlarged when the game resolution is lower than the window's pixels. MetalFX: Apple's upscaler, which rebuilds edges so they stay crisp. Bilinear: a smooth blend, slightly soft. Nearest: every game pixel becomes a hard square. No effect when the game resolution matches or exceeds the window's pixels."
		items:@[ @"MetalFX (Apple's upscaler, rebuilds edges)", @"Bilinear (smooth blend, slightly soft)", @"Nearest (hard square pixels)" ] values:@[ @0, @1, @2 ]
		get:MacGetI(&g_s2.upscaler) set:MacSetI(&g_s2.upscaler)];
	[p slider:@"Sharpening" detail:@"Makes edges and fine detail in the finished picture crisper, interface and text included. It raises the contrast between each pixel and its four neighbours after the picture has been scaled. 0% is off; high values draw light or dark outlines along edges. Default 25%; the Original look uses 0%."
		min:0 max:1 format:Percent get:MacGetF(&g_s2.sharpen) set:MacSetF(&g_s2.sharpen)];
	[p popup:@"FXAA anti-aliasing" detail:@"Smooths the stair-step look of slanted edges by blending the pixels along them. Off: no smoothing. 3D world only: done before the interface is drawn, so text and panels keep their exact pixels. Whole image: also runs over the interface, which softens small text a little."
		items:@[ @"Off", @"3D world only", @"Whole image" ] values:@[ @0, @2, @1 ] get:MacGetI(&g_s2.fxaa) set:MacSetI(&g_s2.fxaa)];

	[p section:@"Frame pacing"];
	[p note:@"How often, and how evenly, new frames reach the display."];
	s2collectVisualControls = false;
	[p toggle:@"VSync" detail:@"Shows each new frame only when the display begins a refresh, so the picture never tears (a horizontal break across the image while the camera moves) and the frame rate cannot exceed the display's refresh rate. Off: frames appear the moment they are ready, which reacts slightly sooner to the mouse but can tear."
		get:MacGetI(&g_s2.vsync) set:MacSetI(&g_s2.vsync)];
	[p popup:@"Frame-rate limit" detail:@"The most frames the game draws each second. A lower limit makes the Mac work less: cooler, quieter, longer on battery. Unlimited draws as fast as VSync and the hardware allow. While \"Ease off when hot or in Low Power Mode\" is active the limit is 30 at most."
		items:@[ @"Unlimited", @"30 fps", @"40 fps", @"60 fps", @"90 fps", @"120 fps" ] values:@[ @0, @30, @40, @60, @90, @120 ]
		get:MacGetI(&g_s2.frameCap) set:MacSetI(&g_s2.frameCap)];
	[p toggle:@"Triple buffering" detail:@"How many frames may be prepared ahead of the display. On: three, which keeps the frame rate steadier when a frame takes long to draw. Off: two, so what you see is one frame fresher after you move the mouse, with a less even frame rate when the Mac is working hard."
		get:MacGetI(&g_s2.tripleBuffer) set:MacSetI(&g_s2.tripleBuffer)];
	[p popup:@"Performance overlay" detail:@"Shows a small readout in the top-left corner of the game, refreshed twice a second. Frame rate: frames per second. Detailed adds the average frame time, the frame time that 99% of frames beat (shown as \"1% low\"), the slowest frame, the game and output sizes, the scaling method and the HDR headroom in use."
		items:@[ @"Off", @"Frame rate only", @"Frame rate, frame times and scaling" ] values:@[ @0, @1, @2 ]
		get:MacGetI(&g_s2.showFPS) set:MacSetI(&g_s2.showFPS)];
	[p toggle:@"Keep running in the background" detail:@"Off (default): while another app is in front the game freezes. Nothing moves, an enemy turn waits, nothing is drawn and input is ignored. On: the game keeps playing and drawing behind other windows, so an enemy turn can finish while you do something else. Using this Settings window never freezes the game."
		get:^float { return g_s2.pauseInBackground ? 0 : 1; } set:^(float v) { g_s2.pauseInBackground = v ? 0 : 1; SaveMac(); }];

	[p section:@"Power"];
	[p note:@"What the game does about heat, battery and screen sleep."];
	[p toggle:@"Keep the display awake" detail:@"While the game is the front app, the screen does not dim or sleep and the Mac does not fall asleep from idleness. Enemy turns and videos can run for minutes without a key press or a click. Off: your normal energy settings apply. In the background the game never keeps the Mac awake."
		get:MacGetI(&g_s2.keepAwake) set:MacSetI(&g_s2.keepAwake)];
	[p toggle:@"Ease off when hot or in Low Power Mode" detail:@"When macOS reports that the Mac is running hot (thermal state serious or critical), or Low Power Mode is on, ambient occlusion and bloom switch off and the frame rate is held to 30 at most until that ends. Your saved settings are not changed and come back by themselves. Off (default): the game never reduces anything on its own."
		get:MacGetI(&g_s2.adaptPower) set:MacSetI(&g_s2.adaptPower)];
	[p toggle:@"Metal performance HUD" detail:@"Shows Apple's own performance display over the game: frame rate, a frame time graph and the time the graphics chip spends on each frame. It is a diagnostic tool, useful in a bug report, and separate from the Performance overlay above. Off hides it."
		get:MacGetI(&g_s2.metalHUD) set:MacSetI(&g_s2.metalHUD)];
}

// ---- Graphics
- (void)buildGraphics:(S2Page *)p
{
	[p section:@"Original / Enhanced"];
	[p note:@"One switch between the 2003 look and your own settings."];
	[p toggle:@"Enhanced graphics" detail:@"Off: the Original look. The game switches to 1024 × 768, the shipped textures, 2003-level lighting and neutral colour, with every added effect off, and the picture options in this window are locked. On: your own settings return as you left them. Same as F9, Command-G or the control over the game. The picture rebuilds; the mission stays loaded."
		get:^float { return S2OriginalGraphics() ? 0 : 1; } set:^(float value) { S2SetOriginalGraphics(value == 0); }];
	[p buttons:@[ @"Maximum fidelity" ] title:@"Highest detail"
		detail:@"This display's resolution, 2× world pixels, 4096 shadows, 256 light caches, HD textures, 1024 terrain and 16× filtering. Neutral color with restrained effects. Rebuilds the renderer; can substantially reduce frame rate."
		actions:@[ ^{ requestedMaximumFidelity = true; } ]];
	s2collectVisualControls = true;
	[p section:@"Quality presets"];
	[p buttons:@[ @"Low", @"Medium", @"High", @"Ultra", @"Beyond" ] title:@"Apply a preset"
		detail:@"Changes engine quality options. Beyond raises shadow and light-cache resolution. Maximum fidelity above also configures resolution, textures and image processing."
		actions:@[ ^{ ApplyPreset(kLow); }, ^{ ApplyPreset(kMedium); }, ^{ ApplyPreset(kHigh); }, ^{ ApplyPreset(kUltra); g_s2.anisoOverride = 16; SaveMac(); },
			^{ ApplyPreset(Beyond()); g_s2.anisoOverride = 16; g_s2.sharpen = std::max(g_s2.sharpen, 0.3f); g_s2.ao = 1; g_s2.bloom = 1; SaveMac(); for (S2Row *r in s2allRows) [r refresh]; } ]];
	[p note:@"Options marked ⟳ restart the renderer half a second after the last change (about a second, the screen blinks)."];

	[p section:@"Modern effects (the 3D world only; the interface stays sharp)"];
	[p note:@"Effects the 2003 game did not have. They change the 3D world before the interface is drawn over it, and they need Shadows on."];
	[p toggle:@"Ambient occlusion" detail:@"Darkens the places where surfaces meet and little open light arrives: the foot of walls, under stairs, around soldiers' feet, in corners. Objects look planted on the ground. The interface is untouched. Costs frame rate: on an M3 Pro one scene ran at 87 frames per second with it and 107 without. Needs Shadows on."
		get:MacGetI(&g_s2.ao) set:MacSetI(&g_s2.ao)];
	[p slider:@"Occlusion strength" detail:@"How dark those contact shadows get. 0 turns them off; 0.85× is the default; 2× makes deep corners almost black. A spot that is half enclosed is darkened by about 60% at the default and about 90% at 2×." min:0 max:2 format:Times get:MacGetF(&g_s2.aoStrength) set:MacSetF(&g_s2.aoStrength)];
	[p slider:@"Occlusion radius" detail:@"How far from a corner or an object the contact shadow spreads, in metres of the game world. Small values (0.2 m) darken only tight creases; large values (2.5 m) shade whole room corners and the ground around buildings. Default 0.7 m." min:0.2 max:2.5
		format:^NSString *(float v) { return [NSString stringWithFormat:@"%.1f m", v]; } get:MacGetF(&g_s2.aoRadius) set:MacSetF(&g_s2.aoRadius)];
	[p toggle:@"Bloom" detail:@"Adds a soft glow around the brightest things in the 3D world: fire, explosions, muzzle flashes, lamps, sunlit pale surfaces. Their light spreads into the pixels around them, as in a camera lens. Off: bright things keep hard edges, as in 2003. The interface is not affected. Needs Shadows on." get:MacGetI(&g_s2.bloom) set:MacSetI(&g_s2.bloom)];
	[p slider:@"Bloom strength" detail:@"How bright the added glow is. 0% adds none, the same as Bloom off. 50% is the default. At 150% fires, lamps and flashes flood their surroundings with light." min:0 max:1.5 format:Percent get:MacGetF(&g_s2.bloomStrength) set:MacSetF(&g_s2.bloomStrength)];
	[p slider:@"Bloom threshold" detail:@"How bright a pixel must be before it glows. At 80% (default) only near-white things glow: flames, flashes, lamps. Lower values make more of the picture glow, down to 40%, where mid-bright surfaces join in. The glow fades in gently, starting 25 points below the threshold." min:0.4 max:1 format:Percent get:MacGetF(&g_s2.bloomThreshold) set:MacSetF(&g_s2.bloomThreshold)];
	[p slider:@"Distance haze" detail:@"Fades the 3D world towards a light grey the farther it is from the camera, like air between you and distant buildings. 0% (default) is off. At 100%, things 50 m from the camera are about 40% grey and things 100 m away about 60%. The grey is the same on every map, night maps included. Needs Shadows on." min:0 max:1 format:Percent get:MacGetF(&g_s2.haze) set:MacSetF(&g_s2.haze)];
	[p popup:@"Effects comparison" detail:@"A temporary view for judging the three added effects above (ambient occlusion, bloom, haze). The second choice shows only the ambient occlusion shading, in grey. The third draws the left half of the 3D world without the three effects and the right half with them. It returns to Off each time the game starts."
		items:@[ @"Off", @"Contact shadows alone, in grey", @"Split screen: left without, right with" ] values:@[ @0, @1, @2 ] get:MacGetI(&g_s2.worldFxDebug) set:MacSetI(&g_s2.worldFxDebug)];

	[p section:@"Lighting and shadows"];
	[p note:@"The 2003 game's own lighting options. ⟳ marks an option that rebuilds the picture half a second after you change it."];
	[p toggle:@"Shadows and full lighting" detail:@"The shadows that soldiers, trees and buildings cast in sunlight or moonlight. It is also the game's main lighting switch. Off: the world gets plain flat lighting with no shadows, no light from lamps, fires or flashes on surfaces, no shine and no surface relief, and the added effects, HDR highlights and World render scale stop working." get:EngGet("gfx_shadows", 1) set:EngSet("gfx_shadows", Live)];
	[p popup:@"Lamp shadow detail ⟳" detail:@"How finely the game stores the shadows that walls and objects cast in the light of lamps, fires and other fixed lights. Every such light keeps its own small shadow map; higher numbers give cleaner, less blocky shadow edges around lamps. The 2003 game offered 32 to 128. The picture rebuilds after a change."
		items:@[ @"16 (coarsest)", @"32 (2003 low and medium)", @"64 (2003 high)", @"128 (2003 maximum)", @"256 (beyond the original)" ] values:@[ @16, @32, @64, @128, @256 ]
		get:EngGet("gfx_cl_cube_resolution", 16) set:EngSet("gfx_cl_cube_resolution", Recreate)];
	[p toggle:@"Refine lamp shadows when the camera rests ⟳" detail:@"On: while the camera stands still, the game redraws the shadows of each lamp and fire in turn at a finer size (256 pixels a side) and blends the result into the stored lighting, so their edges come out cleaner. Off: lamp shadows stay at the Lamp shadow detail size. The picture rebuilds after a change." get:EngGet("gfx_cl_use_precise_shadows", 1) set:EngSet("gfx_cl_use_precise_shadows", Recreate)];
	[p popup:@"Sky shading ⟳" detail:@"Darkens places the open sky cannot light: under roofs and balconies, beside walls, inside doorways. Off: every surface gets the same sky light, which looks flat. 1 to 4 set how many sky directions are tested at a time (3 each, so 3 to 12); more gives smoother shading sooner after the camera moves. The picture rebuilds after a change."
		items:@[ @"Off (flat sky light)", @"1 (3 directions)", @"2 (6 directions)", @"3 (9 directions)", @"4 (12 directions, 2003 maximum)" ] values:@[ @0, @1, @2, @3, @4 ]
		get:EngGet("gfx_cl_sky_textures", 0) set:EngSet("gfx_cl_sky_textures", Recreate)];
	[p popup:@"Sun shadow detail ⟳" detail:@"How sharp the shadows are that soldiers, trees and buildings cast in sunlight or moonlight. They are all drawn into one square picture of this many pixels a side, stretched over the visible map; more pixels give crisper, less blocky edges. The 2003 game offered 512 and 1024. The picture rebuilds after a change."
		items:@[ @"512 (2003 low and medium)", @"1024 (2003 maximum)", @"2048 (4× the pixels of 1024)", @"4096 (16× the pixels of 1024)" ] values:@[ @512, @1024, @2048, @4096 ]
		get:EngGet("gfx_depth_tex_resolution", 512) set:EngSet("gfx_depth_tex_resolution", Recreate)];
	[p popup:@"World render scale ⟳" detail:@"How many pixels the 3D world is drawn with; the interface is not affected. Above 1× the world is drawn larger and shrunk, smoothing edges and foliage. The number multiplies the pixel count: 4× is twice the width and height. Costly: on an M3 Pro at 3600 × 2338, 149 frames per second at 1× became 87 at 2×."
		items:@[ @"0.5× the pixels (fastest, softer)", @"1× (same as the game resolution)", @"2× the pixels (1.4× width and height)", @"3× the pixels (1.7× width and height)", @"4× the pixels (2× width and height)" ] values:@[ @0.5, @1, @2, @3, @4 ]
		get:EngGet("gfx_register_resolution", 1) set:EngSet("gfx_register_resolution", Recreate)];
	[p toggle:@"Smooth lighting updates" detail:@"Controls what happens to the stored lamp and sky lighting when the camera moves. On: the lighting already worked out is carried over to the new view, and improvements fade in over 12 frames. Off: every camera move throws it away, so shading under roofs and around lamps turns coarse, then snaps back when the camera rests." get:EngGet("gfx_cl_blur", 1) set:EngSet("gfx_cl_blur", Live)];
	[p toggle:@"Soft sun shadows" detail:@"Blurs the edges of the shadows cast in sunlight or moonlight, so they fade out softly. Off: shadow edges are hard and show the blocky steps of the Sun shadow detail setting. How wide the blur is comes from each map's own lighting." get:EngGet("gfx_blur_sun", 1) set:EngSet("gfx_blur_sun", Live)];
	[p toggle:@"Surface relief in lamp light ⟳" detail:@"Lets the light of lamps, fires and other fixed lights pick out the relief of surfaces that carry relief detail, so they look raised and grooved instead of flat. Off: that light falls flat on them. Sunlight shows relief either way. With the next option off, the relief appears only once the camera rests." get:EngGet("gfx_cl_use_bump", 1) set:EngSet("gfx_cl_use_bump", Recreate)];
	[p toggle:@"Keep relief while the camera moves ⟳" detail:@"On: surface relief in lamp light is also drawn in the quick lighting update that runs whenever the camera moves or a light changes. Off: relief is drawn only in the slower refinement after the camera rests, so lamp-lit walls look flat while you scroll, and never if lamp shadow refinement is off. Needs the option above." get:EngGet("gfx_cl_use_bump_always", 1) set:EngSet("gfx_cl_use_bump_always", Recreate)];
	[p toggle:@"Shine in sunlight" detail:@"The bright glints that sunlight or moonlight makes on materials the artists made glossy. Off: those surfaces look matt. Surfaces without a gloss setting are not changed." get:EngGet("gfx_specular", 1) set:EngSet("gfx_specular", Live)];
	[p toggle:@"Shine from flashes and explosions" detail:@"The same glints, made by the moving lights of effects such as explosions and gunfire flashes. Off: those lights still brighten surfaces but leave no shiny spots. Fixed lamps make no glints either way, unless Advanced > Stencil shadows is on." get:EngGet("gfx_point_specular", 1) set:EngSet("gfx_point_specular", Live)];

	[p section:@"World"];
	[p note:@"Fog, battle marks, tree crowns and weather."];
	[p popup:@"Fog" detail:@"The distance fog and low ground mist that some maps have. Off: none is drawn, so far ground stays clear. Still: fog and mist are drawn but do not move. Drifting: the mist also flows and thickens and thins over time, on maps whose mist is set to move." items:@[ @"Off", @"Still", @"Drifting" ] values:@[ @0, @1, @2 ]
		get:EngGet("gfx_fog", 0) set:EngSet("gfx_fog", Live)];
	[p toggle:@"Decals" detail:@"The marks that fighting leaves on the world: bullet holes, blast scorches, blood stains. Off: new marks are not drawn. Marks already on screen stay until the map is loaded again." get:EngGet("gfx_decals", 1) set:EngSet("gfx_decals", Live)];
	[p toggle:@"Tree crowns" detail:@"Shows the leafy crowns of trees. Off: trees are drawn without their crowns, so you can see the soldiers and ground beneath them. Only the drawing changes. Smoke, sparks, fire and debris are not affected by this switch. It is the 2003 game's own tree crown option." get:EngGet("gfx_particles", 1) set:EngSet("gfx_particles", Live)];
	[p toggle:@"Weather effects" detail:@"The falling rain and snow on maps that have that weather. Off: no drops or flakes are drawn. The duller rainy light stays, and nothing else about the weather changes." get:EngGet("game_showweathereffect", 1) set:EngSet("game_showweathereffect", Live)];

	[p section:@"Textures"];
	[p note:@"How sharp surfaces look, close up and far away."];
	[p toggle:@"HD textures" detail:@"Uses the sharper, upscaled copies of the world's textures (walls, ground, objects, soldiers) from the HD texture pack in the game folder. Off: the shipped 2003 textures. Interface art and fonts always keep their original pixels. Does nothing if no pack is installed. Applies within moments; the mission stays loaded."
		get:MacGetI(&g_s2.hdTextures) set:MacSetI(&g_s2.hdTextures)];
	[p popup:@"Ground detail" detail:@"How sharply the ground is drawn near the camera. The game paints each patch of ground (grass, dirt, roads and their blends) into one picture of this size. 256 is the 2003 size and looks blurred up close; 1024 has 16 times the pixels. Distant ground is not changed. No effect while Texture detail is below Full."
		items:@[ @"256 (original)", @"512 (4× the pixels)", @"1024 (16× the pixels)" ] values:@[ @256, @512, @1024 ] get:MacGetI(&g_s2.terrainDetail) set:MacSetI(&g_s2.terrainDetail)];
	[p popup:@"Texture detail ⟳" detail:@"The size at which the world's textures are loaded. Full: every texture at its stored size. Half and Quarter: each at half or a quarter of its width and height, which looks blurrier and uses less memory; the ground also drops to its low-detail version. Interface art is never reduced. The picture rebuilds after a change." items:@[ @"Full", @"Half (half the width and height)", @"Quarter (a quarter of the width and height)" ] values:@[ @0, @1, @2 ]
		get:EngGet("gfx_texture_mip", 0) set:EngSet("gfx_texture_mip", Recreate)];
	[p toggle:@"Texture compression ⟳" detail:@"On (default): textures load in the compressed form most of them were shipped in. Off: the game loads the uncompressed copies that are also in its files, which avoids faint blocky compression marks and takes 4 to 8 times the memory for those textures. Off also skips the HD texture pack for them, so leave this on with HD textures." get:EngGet("gfx_texture_usedxt", 1) set:EngSet("gfx_texture_usedxt", Recreate)];
	[p toggle:@"16-bit textures ⟳" detail:@"Stores uncompressed textures, the interface art and videos with 16 bits of colour per pixel instead of 32. Smooth colour gradients show visible steps. It was an option for 2003 graphics cards with little memory: leave it off. The picture rebuilds after a change." get:EngGet("gfx_16bit_textures", 0) set:EngSet("gfx_16bit_textures", Recreate)];
	[p popup:@"Anisotropic filtering" detail:@"Anisotropic filtering keeps ground and wall textures sharp when you see them at a shallow angle, instead of smearing them. This choice raises it to as much as 16×. At present it does not reach the world's textures while the game's own filter level is 2, which every preset except Low sets: the game then filters them at 2× itself."
		items:@[ @"No override (the game's own setting)", @"2×", @"4×", @"8×", @"16×" ] values:@[ @0, @2, @4, @8, @16 ]
		get:MacGetI(&g_s2.anisoOverride) set:MacSetI(&g_s2.anisoOverride)];
	[p slider:@"Distant texture sharpness" detail:@"Chooses whether distant textures use their sharper or their softer stored versions. Below 0 picks sharper ones, which adds detail and, when too low, makes distant ground sparkle as the camera moves. Above 0 picks softer ones. 0 is the 2003 behaviour. At present it has no effect on world textures while the game's own filter level is 2." min:-2 max:1 format:Signed
		get:MacGetF(&g_s2.lodBias) set:MacSetF(&g_s2.lodBias)];
	s2collectVisualControls = false;
}

// ---- Image
- (void)buildImage:(S2Page *)p
{
	s2collectVisualControls = true;
	[p section:@"Colour"];
	[p note:@"Corrections to the whole finished picture, interface included. They cost nothing measurable and apply at once."];
	[p slider:@"Gamma" detail:@"Brightens or darkens the middle tones of the whole picture, interface included, while black stays black and white stays white. Above 1.00 lifts shadows and dark areas; below 1.00 deepens them. 1.00 is neutral. This is the 2003 game's own gamma control, and it is applied last, after the sliders below." min:0.5 max:2 format:Plain2 get:EngGet("gfx_gamma", 1) set:EngSet("gfx_gamma", Live)];
	[p slider:@"Brightness" detail:@"Adds the same amount of light to every pixel of the picture, interface included, or removes it below 0. At +0.25 everything rises by a quarter of the full range, so black turns dark grey; at -0.25 everything falls by as much. 0 is neutral. Applied before Gamma." min:-0.25 max:0.25 format:Signed get:MacGetF(&g_s2.brightness) set:MacSetF(&g_s2.brightness)];
	[p slider:@"Contrast" detail:@"Widens or narrows the gap between dark and light around middle grey, over the whole picture. Above 1.00× darks get darker and lights lighter, and detail at both ends can be lost. Below 1.00× the picture turns flatter and greyer. 1.00× is neutral." min:0.5 max:1.5 format:Times get:MacGetF(&g_s2.contrast) set:MacSetF(&g_s2.contrast)];
	[p slider:@"Saturation" detail:@"How strong the colours are, over the whole picture. 100% leaves them as they are, 0% is black and white, and 200% doubles the distance of every colour from grey." min:0 max:2 format:Percent get:MacGetF(&g_s2.saturation) set:MacSetF(&g_s2.saturation)];
	[p slider:@"Vibrance" detail:@"Strengthens colour mostly where it is weak: dull, greyish areas gain the most and already vivid colours change little. Below 0 it does the opposite and mutes mainly the dull areas. 0 is neutral. Applied after Saturation." min:-1 max:1 format:Signed get:MacGetF(&g_s2.vibrance) set:MacSetF(&g_s2.vibrance)];
	[p slider:@"Temperature" detail:@"Shifts the whole picture towards warm or cool. At +1 red rises by 8% and blue falls by 8%, a warm amber cast. At -1 the reverse, a cool blue cast. 0 is neutral." min:-1 max:1 format:Signed get:MacGetF(&g_s2.temperature) set:MacSetF(&g_s2.temperature)];
	[p slider:@"Tint" detail:@"Shifts the whole picture between green and magenta. At +1 green falls by 6% and red and blue rise by 4%, a magenta cast. At -1 the reverse, a green cast. 0 is neutral. Useful for removing a cast that Temperature leaves." min:-1 max:1 format:Signed get:MacGetF(&g_s2.tint) set:MacSetF(&g_s2.tint)];
	[p section:@"Lens"];
	[p note:@"Camera-style finishing touches over the whole picture."];
	[p slider:@"Vignette" detail:@"Darkens the picture towards its edges and corners, like an old camera lens, interface included. The centre is untouched. At 100% the corners are almost black and the left and right edges about 65% darker. 0% is off." min:0 max:1 format:Percent get:MacGetF(&g_s2.vignette) set:MacSetF(&g_s2.vignette)];
	[p slider:@"Film grain" detail:@"Lays fine grey noise over the whole picture, different on every frame, like film stock. At 100% each pixel is made up to 4% lighter or darker. 0% is off." min:0 max:1 format:Percent get:MacGetF(&g_s2.grain) set:MacSetF(&g_s2.grain)];
	[p section:@"Looks"];
	auto look = [](float b, float c, float s, float vib, float t, float tn, float vig, float g) {
		return ^{ g_s2.brightness = b; g_s2.contrast = c; g_s2.saturation = s; g_s2.vibrance = vib; g_s2.temperature = t; g_s2.tint = tn; g_s2.vignette = vig; g_s2.grain = g;
			SaveMac(); for (S2Row *r in s2allRows) [r refresh]; };
	};
	[p buttons:@[ @"Original", @"Vivid", @"1944 newsreel", @"Cinematic", @"Night ops" ] title:@"Apply a look" detail:@"Each button sets the Colour and Lens sliders above to a ready-made combination, which you can then adjust. Original: everything neutral, the picture as the game draws it. Vivid: more contrast and stronger colours. 1944 newsreel: black and white, high contrast, heavy grain and dark corners. Cinematic: warm, slightly muted, with soft dark corners. Night ops: cold, green-tinted and muted."
		actions:@[ look(0, 1, 1, 0, 0, 0, 0, 0), look(0, 1.08f, 1.1f, 0.35f, 0.05f, 0, 0.1f, 0), look(0.02f, 1.2f, 0, 0, 0.15f, 0, 0.45f, 0.5f),
			look(-0.02f, 1.12f, 0.9f, 0.2f, 0.25f, 0.05f, 0.35f, 0.12f), look(-0.04f, 1.1f, 0.6f, 0, -0.6f, -0.1f, 0.3f, 0.08f) ]];
	s2collectVisualControls = false;
}

// ---- Audio
- (void)buildAudio:(S2Page *)p
{
	[p section:@"Volume"];
	[p note:@"Master multiplies the other two. Videos follow Effects only."];
	[p slider:@"Master" detail:@"The overall loudness of the game's sound: effects, voices and music together, on top of the two sliders below. 100% leaves them as set, 0% is silence. Videos are the exception: their sound follows the Effects slider only." min:0 max:1 format:Percent get:MacGetF(&g_s2.masterVolume) set:MacSetF(&g_s2.masterVolume)];
	[p slider:@"Effects" detail:@"The loudness of everything except music: gunfire, explosions, footsteps, soldiers' voices and all other sound effects, plus the sound of videos. Default 75%, as in 2003. A video takes the value it finds when it starts." min:0 max:1 format:Percent get:EngGet("sound_sfxvolume", 0.75f) set:EngSet("sound_sfxvolume", Live)];
	[p slider:@"Music" detail:@"The loudness of the music, both the calm tracks and the combat tracks. Default 75%, as in 2003. At 0% the game does not start music at all, so after you raise it again the music returns when the next track begins." min:0 max:1 format:Percent get:EngGet("sound_musicvolume", 0.75f) set:EngSet("sound_musicvolume", Live)];
	[p toggle:@"Mute in the background" detail:@"Silences the game's effects, voices and music while another app is in front, and brings them back when you return. Off: the game stays audible behind other apps, which matters mostly when Keep running in the background is on." get:MacGetI(&g_s2.muteInBackground) set:MacSetI(&g_s2.muteInBackground)];
	[p section:@"Voices"];
	[p note:@"What your soldiers say when they take orders, and whether you see it written."];
	[p toggle:@"Character responses" detail:@"Your soldiers answer aloud when they take an order or react to something, and the face at the bottom left turns to speak the line. Off: no spoken replies and no talking face. The written line still appears if Response subtitles is on." get:EngGet("ui_charresponses", 1) set:EngSet("ui_charresponses", Live)];
	[p toggle:@"Response subtitles" detail:@"Shows each spoken reply as text on screen: the soldier's name, then the words. It works with or without the voices. Off: replies are heard but not written." get:EngGet("ui_charresponsessubtitles", 1) set:EngSet("ui_charresponsessubtitles", Live)];
	[p popup:@"Subtitle time" detail:@"The shortest time the words of a soldier's spoken reply stay on screen. A long line stays until the voice finishes; this only stops short lines vanishing too fast to read. The original is 3 seconds."
		items:@[ @"3 seconds (original)", @"5 seconds", @"8 seconds" ] values:@[ @3, @5, @8 ] get:MacGetI(&g_s2.subtitleSeconds) set:MacSetI(&g_s2.subtitleSeconds)];
}

// ---- Camera and input
- (void)buildCamera:(S2Page *)p
{
	auto camSet = [](float *f) { return ^(float v) { *f = v; SaveMac(); cameraLimitsPending = true; }; };
	auto camGet = [](float *f) { return ^float { return *f; }; };
	[p section:@"Mission camera"];
	[p note:@"The limits and speeds of the camera inside a mission. Except for Field of view, they are fixed when a mission starts: a change shows in the next mission you start, and a saved game keeps the camera it was saved with."];
	[p buttons:@[ @"2003", @"Wider", @"Unlocked" ] title:@"Camera presets" detail:@"2003: the original camera, 35° field of view, zoom 10 to 65 metres, tilt 43° to 77° below the horizon, every speed back to its 2003 value. Wider: 40°, zoom 7 to 90, tilt 32° to 83°. Unlocked: 45°, zoom 4 to 160, tilt 7° to 89°, and the zoom no longer eases back from its limits. The zoom and tilt limits apply from the next mission you start."
		actions:@[ ^{ cam = kStockCamera; SaveMac(); cameraLimitsPending = true; for (S2Row *r in s2allRows) [r refresh]; },
			^{ cam.fov = 40; cam.minRod = 7; cam.maxRod = 90; cam.minPitch = -1.45f; cam.maxPitch = -0.55f; SaveMac(); cameraLimitsPending = true; for (S2Row *r in s2allRows) [r refresh]; },
			^{ cam.fov = 45; cam.minRod = 4; cam.maxRod = 160; cam.minPitch = -1.55f; cam.maxPitch = -0.12f; cam.softLimits = 0; SaveMac(); cameraLimitsPending = true; for (S2Row *r in s2allRows) [r refresh]; } ]];
	[p slider:@"Field of view" detail:@"How wide an angle the mission camera sees, in degrees. Wider shows more of the map at once and stretches shapes near the screen edges; narrower flattens the view like a long lens. The 2003 game is fixed at 35°. Takes effect at once, in the current mission too. Slow-motion camera moves keep their proportions." min:20 max:75 format:Degrees get:camGet(&cam.fov) set:camSet(&cam.fov)];
	[p toggle:@"Wider view on wide screens (Hor+)" detail:@"Off (default): the 2003 camera. At a game resolution wider than 4:3 it keeps the width of the view and shows less at the top and bottom. On: the mission camera keeps the height of view it has at 4:3 and shows more at the sides, 20% more at 16:10 and 33% more at 16:9. Field of view above then means the view at 4:3. Menu backdrops and the 3D figures in the interface do not change. Takes effect at once, also during a mission."
		get:MacGetI(&g_s2.horPlus) set:MacSetI(&g_s2.horPlus)];
	[p slider:@"Closest zoom" detail:@"The nearest the camera can come to the spot on the ground it looks at, in metres. 2003: 10. While 'Ease back from the limits' is on you can push in this close, but the camera then settles at 1.8 times this distance (18 in 2003). It never sinks lower than 4 metres above the ground. Applies from the next mission you start." min:2 max:30 format:Plain1 get:camGet(&cam.minRod) set:camSet(&cam.minRod)];
	[p slider:@"Farthest zoom" detail:@"The farthest the camera can pull back from the spot it looks at, in metres. 2003: 65. While 'Ease back from the limits' is on you can pull out this far, but the camera then settles at 77% of it (50 in 2003). Panning and turning speed up as you zoom out. Applies from the next mission you start." min:30 max:200 format:Plain1 get:camGet(&cam.maxRod) set:camSet(&cam.maxRod)];
	[p slider:@"Steepest angle" detail:@"How steeply the camera may look down, as an angle below the horizon: 90° is straight down. 2003: 77°. Tilting down stops at this angle. Applies from the next mission you start." min:-1.57f max:-0.8f format:PitchDeg get:camGet(&cam.minPitch) set:camSet(&cam.minPitch)];
	[p slider:@"Flattest angle" detail:@"How far the camera may tilt up towards the horizon, as an angle below it: 0° would be level with the ground. 2003: 43°. Smaller numbers give a flatter, more distant view. The camera stays at least 4 metres above the ground, so close in it is lifted and the view steepens again. Applies from the next mission you start." min:-1.0f max:-0.05f format:PitchDeg get:camGet(&cam.maxPitch) set:camSet(&cam.maxPitch)];
	[p toggle:@"Zoom eases back from its limits" detail:@"On, as in 2003: zooming has a resting range inside the two zoom limits. Past it the zoom slows, and when you let go the camera glides back to 1.8 times the closest zoom or 77% of the farthest (18 and 50 in 2003). Off: the camera stays wherever you leave it between the limits. Applies from the next mission you start."
		get:^float { return (float)cam.softLimits; } set:^(float v) { cam.softLimits = v != 0; SaveMac(); cameraLimitsPending = true; }];
	[p slider:@"Zoom speed" detail:@"How far one zoom input moves the camera. At 0.30, the 2003 value, a wheel notch moves it 8% of the resting zoom range, about 2.6 metres with the 2003 limits; other values scale that in proportion. The zoom keys (Page Up, Page Down, ⌘= and ⌘-) scale the same way. Applies from the next mission you start." min:0.05f max:1.5f format:Plain2 get:camGet(&cam.zoomSpeed) set:camSet(&cam.zoomSpeed)];
	[p slider:@"Tilt speed" detail:@"Multiplies how fast the camera tilts up and down when you drag up or down with the right mouse button held, or hold Control and press the Up or Down arrow. 2003: 5. Range 1 to 15. Applies from the next mission you start." min:1 max:15 format:Plain1 get:camGet(&cam.pitchSpeed) set:camSet(&cam.pitchSpeed)];
	[p slider:@"Rotation speed" detail:@"Multiplies how fast the camera turns around the spot it looks at when you drag sideways with the right mouse button held, or hold Control and press the Left or Right arrow. 2003: 1.5. Range 0.3 to 5. Turning is up to twice as fast when zoomed out. The trackpad twist gesture is not affected. Applies from the next mission you start." min:0.3f max:5 format:Plain2 get:camGet(&cam.yawSpeed) set:camSet(&cam.yawSpeed)];
	[p slider:@"Map panning speed" detail:@"Multiplies how fast the view slides across the map with the arrow keys, a middle-button drag, or the pointer at a screen edge (4 metres a second at 1.0). 2003: 1.4. Range 0.3 to 5. Panning is up to 2.2 times faster when zoomed out. Two-finger trackpad panning is not affected. Applies from the next mission you start." min:0.3f max:5 format:Plain2 get:camGet(&cam.scrollSpeed) set:camSet(&cam.scrollSpeed)];
	[p slider:@"Zoom speed-up when far" detail:@"How much faster the zoom keys move the camera the farther it is from the ground. 0 moves the same step at every distance. The original is 5. The scroll wheel and pinch are not affected: they move a fixed share of the zoom range." min:0 max:10 format:Plain1 get:camGet(&cam.zoomAccel) set:camSet(&cam.zoomAccel)];
	[p slider:@"Pan speed-up when zoomed out" detail:@"Panning gets faster as the camera pulls back: at the farthest zoom it is 1 plus this value times as fast as at the closest. 0 pans at one speed everywhere. The original is 1.2." min:0 max:4 format:Plain2 get:camGet(&cam.scrollAccel) set:camSet(&cam.scrollAccel)];
	[p slider:@"Turn speed-up when zoomed out" detail:@"Rotating gets faster as the camera pulls back, up to 1 plus this value times at the farthest zoom. 0 turns at one speed everywhere. The original is 1." min:0 max:4 format:Plain2 get:camGet(&cam.yawAccel) set:camSet(&cam.yawAccel)];
	[p slider:@"Camera glide" detail:@"How quickly the camera catches up with where you moved it. Below 1× it eases in slowly and smoothly; above 1× it snaps there. The original is 1×. Scripted camera moves in cutscenes use the same value." min:0.25f max:4 format:Times get:camGet(&cam.attenuation) set:camSet(&cam.attenuation)];
	[p slider:@"Lowest camera height" detail:@"How close to the ground or a floor the camera may come before it is pushed back up, in metres. Lower lets you look along the ground; below about 2 the camera can end up inside a slope. The original is 4." min:1 max:10 format:Plain1 get:camGet(&cam.minHeight) set:camSet(&cam.minHeight)];
	[p toggle:@"Camera follows the action" detail:@"On, as in 2003: during other sides' turns the view switches to an automatic camera that frames whoever is acting, and at any time it swings to shots, deaths and explosions. Moving the camera yourself takes control back. Off: the camera only moves when you move it, except in scripted cutscenes." get:EngGet("ui_followcamera", 1) set:EngSet("ui_followcamera", Live)];
	[p popup:@"Follow a unit for at most" detail:@"With Camera follows units on, the camera lets go of a moving unit after this long, so a long walk does not hold the view. The original is 10 seconds. Takes effect the next time the camera starts following."
		items:@[ @"5 seconds", @"10 seconds (original)", @"20 seconds", @"No limit" ] values:@[ @5, @10, @20, @0 ] get:MacGetI(&g_s2.followSeconds) set:MacSetI(&g_s2.followSeconds)];

	[p section:@"Mouse and trackpad"];
	[p note:@"How the mouse, the keys and the trackpad drive the camera. These take effect at once."];
	[p slider:@"Camera sensitivity" detail:@"Multiplies how fast the camera turns, tilts and zooms from the mouse (right-drag), the keyboard, the wheel and the pinch gesture. 1.00× is the 2003 default; the 2003 options offered 0.30× to 3.00×. It works on top of the tilt, rotation and zoom speeds above. The trackpad twist gesture is not affected." min:0.1f max:3 format:Times get:EngGet("game_camerasensivity", 1) set:EngSet("game_camerasensivity", Camera)];
	[p slider:@"Panning sensitivity" detail:@"Multiplies how fast the map pans with the arrow keys and with a middle-button drag (or Control with a right-drag). 1.00× is the 2003 default; the 2003 options offered 0.30× to 3.00×. Panning at the screen edge and two-finger trackpad panning are not affected." min:0.1f max:3 format:Times get:EngGet("game_scrollsensivity", 1) set:EngSet("game_scrollsensivity", Camera)];
	[p slider:@"Drag-select threshold" detail:@"How far the pointer must travel with the button held before a click turns into a selection box. The distance is 20 pixels of the game's resolution times this number, so higher needs a longer drag: 1.00× (the 2003 default) is 20 pixels, 0.10× is 2, 3.00× is 60. Set too low, a slightly shaky click starts a box and gives no order." min:0.1f max:3 format:Times get:EngGet("game_selectionsensivity", 1) set:EngSet("game_selectionsensivity", Camera)];
	[p slider:@"Wheel and trackpad zoom" detail:@"Multiplies zoom input from the mouse wheel, two-finger scrolling and pinching before the game receives it. At 1.00× one wheel notch, or about 30 points of finger travel, is one zoom step. A single frame never zooms more than 1.5 steps. The zoom keys are not affected, nor is two-finger scrolling when it is set to pan." min:0.25f max:4 format:Times get:MacGetF(&g_s2.scrollScale) set:MacSetF(&g_s2.scrollScale)];
	[p toggle:@"Invert rotation" detail:@"Reverses which way the camera turns when you drag sideways with the right mouse button held, or press Control with the Left or Right arrow. Off is the 2003 default. The trackpad twist gesture is not reversed." get:EngGet("game_invertturnx", 0) set:EngSet("game_invertturnx", Camera)];
	[p toggle:@"Invert tilt" detail:@"Reverses which way the camera tilts when you drag up or down with the right mouse button held, or press Control with the Up or Down arrow. Off is the 2003 default." get:EngGet("game_invertturny", 0) set:EngSet("game_invertturny", Camera)];
	[p toggle:@"Invert forward and back panning" detail:@"Reverses panning up and down the screen: the Up and Down arrows and an up or down drag with the middle button. Off is the 2003 default. Panning at the screen edge and two-finger trackpad panning are not reversed." get:EngGet("game_invertscrollx", 0) set:EngSet("game_invertscrollx", Camera)];
	[p toggle:@"Invert left and right panning" detail:@"Reverses panning left and right: the Left and Right arrows and a sideways drag with the middle button. Off is the 2003 default. Panning at the screen edge and two-finger trackpad panning are not reversed." get:EngGet("game_invertscrolly", 0) set:EngSet("game_invertscrolly", Camera)];
	[p toggle:@"Control-click is a right click" detail:@"On (default): holding Control and clicking sends a right click to the game, for a trackpad or mouse with one button. Control stays held, so a Control-drag pans the map (the game's Control with right-drag) and does not turn the camera. Off: the game gets an ordinary left click with Control held. A real right button is not affected." get:MacGetI(&g_s2.ctrlClickRight) set:MacSetI(&g_s2.ctrlClickRight)];
	[p popup:@"Two-finger scrolling" detail:@"What sliding two fingers on a trackpad does. Zooms the camera (default): sliding up and down zooms. Pans the map: the ground moves with your fingers, and zooming is left to the pinch gesture and the zoom keys. A wheel mouse always zooms."
		items:@[ @"Zooms the camera", @"Pans the map" ] values:@[ @0, @1 ] get:MacGetI(&g_s2.scrollPans) set:MacSetI(&g_s2.scrollPans)];
	[p toggle:@"Pinch to zoom" detail:@"On (default): spreading two fingers on the trackpad zooms in and pinching them zooms out. Doubling the spread equals five wheel notches. 'Wheel and trackpad zoom', 'Zoom speed' and 'Camera sensitivity' all scale it. Off: the pinch gesture does nothing." get:MacGetI(&g_s2.pinchZoom) set:MacSetI(&g_s2.pinchZoom)];
	[p toggle:@"Twist to turn the camera" detail:@"On (default): turning two fingers on the trackpad turns the camera around the spot it looks at by the same angle, times 'Gesture speed'. Rotation speed, Camera sensitivity and Invert rotation do not apply to it. Off: the twist gesture does nothing." get:MacGetI(&g_s2.rotateGesture) set:MacSetI(&g_s2.rotateGesture)];
	[p slider:@"Pan and twist gesture speed" detail:@"Multiplies two-finger panning (when 'Two-finger scrolling' is set to pan) and the twist gesture. At 1.00×, the default, the ground moves exactly with your fingers and the camera turns by the angle you twist. Range 0.25× to 4×. Zooming is not affected." min:0.25f max:4 format:Times get:MacGetF(&g_s2.gestureSpeed) set:MacSetF(&g_s2.gestureSpeed)];
	[p popup:@"Screen-edge scrolling width" detail:@"How close the pointer must be to an edge of the game view for the map to slide that way, in pixels of the game's resolution. The 2003 game used 4, which is hard to hit in a window. The same width applies to all four edges."
		items:@[ @"Off (keys, drag or trackpad only)", @"4 pixels (2003)", @"8 pixels", @"16 pixels", @"32 pixels" ] values:@[ @0, @4, @8, @16, @32 ] get:MacGetI(&g_s2.edgeScrollBand) set:MacSetI(&g_s2.edgeScrollBand)];
	[p popup:@"Double-click speed" detail:@"The longest gap between two clicks that still counts as a double-click, which the game uses to make a soldier run and to open containers. Follow macOS uses the speed set in System Settings. Takes effect on the next screen that opens."
		items:@[ @"Follow macOS", @"0.3 seconds", @"0.5 seconds (original)", @"0.8 seconds" ] values:@[ @0, @300, @500, @800 ] get:MacGetI(&g_s2.doubleClickMs) set:MacSetI(&g_s2.doubleClickMs)];
	[p toggle:@"System cursor" detail:@"On: macOS draws the game's pointer, using the game's own pointer shapes, so it keeps up with the mouse even when the frame rate is low. Off (the 2003 default): the game paints the pointer itself, once per frame. The hit chance and action point text beside the pointer is painted by the game either way." get:EngGet("ui_hwcursor", 0) set:EngSet("ui_hwcursor", Live)];
}

// ---- Gameplay
- (void)buildGameplay:(S2Page *)p
{
	[p section:@"Turns and movement"];
	[p note:@"When play switches between real time and turns, and how move orders are given."];
	[p popup:@"Speed of enemy and ally turns" detail:@"In turn-based play, makes every turn that is not yours pass 2, 3 or 4 times faster: movement, shots and the camera all run on the faster clock. The game still works through the same steps, so nothing in the rules is skipped. Your own turns, real-time play and cutscenes stay at normal speed. F2 or ⌘T cycles it."
		items:@[ @"Normal speed (2003)", @"2× speed", @"3× speed", @"4× speed" ] values:@[ @1, @2, @3, @4 ]
		get:^float { return (float)S2AITurnSpeed(); } set:^(float v) { S2SetAITurnSpeed((int)v); }];
	[p toggle:@"Always turn-based" detail:@"On: missions run in turns from the start and never return to real time, even with no enemy in sight. The base stays real time. Off, the 2003 default: play returns to real time after a round in which nobody who can fight sees an enemy and no side lost sight of one. Switched on mid-mission, it takes hold the next time turns begin." get:EngGet("game_forceturnbased", 0) set:EngSet("game_forceturnbased", Live)];
	[p toggle:@"Start turns as soon as you spot an enemy" detail:@"On: in real time, the moment one of your soldiers sees a hostile, play switches to turns and your squad moves first, even if the enemy has not noticed you. Off, the 2003 default: real time goes on until an enemy sees one of your soldiers (turns begin about 2.5 seconds later, enemy first) or someone wins an interrupt when both sides see each other." get:EngGet("game_tbs_on_enemy_spot", 0) set:EngSet("game_tbs_on_enemy_spot", Live)];
	[p toggle:@"Camera shake on explosions" detail:@"On: when a grenade, mine or rocket explodes, the camera shakes up and down for a second and a half, harder for bigger blasts. Off, the 2003 default: no shake. Despite its old name, this option has nothing to do with turn-based play." get:EngGet("game_eq_on_grenades", 0) set:EngSet("game_eq_on_grenades", Live)];
	[p popup:@"End-turn guard" detail:@"After the turn comes back to you, the End turn key and button are ignored for this long, so a key still held from the last turn cannot skip your new one. The original is 2 seconds. With None, holding Enter ends the new turn at once."
		items:@[ @"2 seconds (original)", @"1 second", @"0.5 seconds", @"None" ] values:@[ @2000, @1000, @500, @0 ] get:MacGetI(&g_s2.endTurnGuardMs) set:MacSetI(&g_s2.endTurnGuardMs)];
	[p toggle:@"Show route and selection in real time" detail:@"On, the 2003 default: in real time the route of a selected soldier is drawn on the ground. Off: in real time neither the route nor the highlight on your selected soldiers is drawn. In turn-based play the route and its action point numbers always show." get:EngGet("game_pathinrealtime", 1) set:EngSet("game_pathinrealtime", Live)];
	[p toggle:@"Double-click to move in real time" detail:@"Off, the 2003 default: in real time one click sends the selected soldiers off at once and a double-click makes them run. On: one click only plots the route and a double-click sets them moving at their normal pace, the way orders work in turn-based play; a double-click no longer makes them run. Turn-based play is not changed." get:EngGet("game_dblclkmoveinrealtime", 0) set:EngSet("game_dblclkmoveinrealtime", Live)];
	[p popup:@"Selection highlight" detail:@"How the game marks your selected soldiers and whatever the pointer is over: soldiers, enemies, bodies and objects. Glowing outline: a coloured edge, green for your squad and red for enemies. Colour tint: the whole figure is washed with colour, white for your squad. No highlight: nothing is marked. A change shows on the next thing you select or point at." items:@[ @"Glowing outline (2003)", @"Colour tint", @"No highlight" ] values:@[ @0, @1, @2 ]
		get:EngGet("game_selectionmode", 0) set:EngSet("game_selectionmode", Live)];
	[p section:@"Rules and enemies"];
	[p note:@"The game's rules follow a fan reconstruction that repairs some bugs of the 2003 game on purpose, and that restored how the 2003 enemies fight. These three choices let you undo either. They act from the next calculation, also in the middle of a mission, and saved games are the same in every combination."];
	[p popup:@"Rules" detail:@"Corrected: a melee attack, a knife throw, readying a weapon, turning on the spot and a medical treatment always cost at least 1 action point, a negative cost never hands points back, and eight perks do what their descriptions say: the ones for aiming after moving, readying a weapon, burst recoil, critical damage taken, lockpicking, melee, night camouflage and throwing range. Retail 2003: the original arithmetic, including those bugs, so a very skilled soldier can get some of those actions for free and those perks work as they did in 2003."
		items:@[ @"Corrected (default)", @"Retail 2003" ] values:@[ @0, @1 ]
		get:MacGetI(&g_s2.retailRules) set:MacSetI(&g_s2.retailRules)];
	[p toggle:@"Enemies aim for the head" detail:@"On, the 2003 behaviour: a computer-controlled soldier that has more than a 50% chance to hit aims at your soldier's head when more than 5% of it is exposed, which does more damage and can kill outright. Off: they always fire at the body, as builds of this port before the November 2026 merge did, and firefights are more forgiving."
		get:MacGetI(&g_s2.enemyHeadShots) set:MacSetI(&g_s2.enemyHeadShots)];
	[p toggle:@"Enemies fire partial bursts" detail:@"On, the 2003 behaviour: a computer-controlled soldier without enough action points for a whole burst fires the bullets it can afford. Off: it fires a whole burst or none, as builds before the November 2026 merge did, so enemies low on action points shoot at you less."
		get:MacGetI(&g_s2.enemyPartialBursts) set:MacSetI(&g_s2.enemyPartialBursts)];
	[p section:@"Saves"];
	[p toggle:@"Autosave before each mission" detail:@"On, the 2003 default: the game saves to the slot 'AutoSave(Begin mission)' on the chapter map just before a mission loads. Off: that save is skipped. The 'AutoSave(End mission)' save, made when you confirm leaving a zone, is written either way." get:EngGet("game_autosaves", 1) set:EngSet("game_autosaves", Live)];

	{
		// each profile is a folder inside the game's save folder (Main/iSaveManager.cpp); the engine reads the variable at every save and load
		NSMutableArray<NSString*> *profiles = [NSMutableArray array];
		NSString *saveDir = [@(S2GameDirectory()) stringByAppendingPathComponent:@"save"];
		for (NSString *n in [[NSFileManager.defaultManager contentsOfDirectoryAtPath:saveDir error:nil] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)])
		{
			BOOL dir = NO;
			if (![n hasPrefix:@"."] && [NSFileManager.defaultManager fileExistsAtPath:[saveDir stringByAppendingPathComponent:n] isDirectory:&dir] && dir) [profiles addObject:n];
		}
		if (profiles.count == 0) [profiles addObject:@"default"];
		NSMutableArray *profileValues = [NSMutableArray array];
		for (NSUInteger i = 0; i < profiles.count; ++i) [profileValues addObject:@(i)];
		[p popup:@"Save profile" detail:@"Which set of saved games the save and load screens show. Each profile is a folder inside the game's save folder, and switching moves and deletes nothing. To make another profile, add a folder there and reopen this window."
			items:profiles values:profileValues
			get:^float {
				NSString *cur = @(S2EngineGetString("game_profile").c_str());
				NSUInteger i = [profiles indexOfObjectPassingTest:^BOOL(NSString *s, NSUInteger, BOOL *) { return [s caseInsensitiveCompare:cur] == NSOrderedSame; }];
				return i == NSNotFound ? 0 : (float)i;
			}
			set:^(float v) { NSUInteger i = (NSUInteger)v; if (i < profiles.count) { S2EngineSetString("game_profile", [profiles[i] UTF8String]); ScheduleSave(); } }];
	}
	[p section:@"Interface"];
	[p note:@"What the game shows on screen during play."];
	[p toggle:@"Hint screens and hint markers" detail:@"On, the 2003 default: missions can pause to show their hint screens, and each one shown gives its experience reward to the whole squad; markers also float over hint items you have found on the map. Off: the screens are skipped along with their experience, and the markers are hidden. Tutorial missions show their hints either way." get:EngGet("ui_showhints", 1) set:EngSet("ui_showhints", Live)];
	[p toggle:@"Tooltips" detail:@"On, the 2003 default: resting the pointer on a button, an inventory item or another part of the interface shows its description box. Off: no description boxes appear anywhere, which also removes the weapon comparison below." get:EngGet("ui_showtooltips", 1) set:EngSet("ui_showtooltips", Live)];
	[p toggle:@"Compare guns in tooltips" detail:@"Adds a block to a gun's tooltip comparing it with the gun the soldier holds: damage, range, snap shot cost, the skills each uses and ammunition carried. It also works out the best damage per action point at ranges 10, 25 and 45 with the game's own hit formula, and says Better, Worse or About the same. Hold Shift for seven more stats. Needs Tooltips on."
		get:MacGetI(&g_s2.weaponCompare) set:MacSetI(&g_s2.weaponCompare)];
	[p slider:@"Tooltip delay" detail:@"How long the pointer must rest on something before its tooltip appears. 1.0 second is the 2003 default. The slider runs from 0 (at once) to 3 seconds." min:0 max:0.3f format:^NSString *(float v) { return [NSString stringWithFormat:@"%.1f s", v * 10]; }
		get:EngGet("ui_tooltipdelay", 0.1f) set:EngSet("ui_tooltipdelay", Live)];
	[p toggle:@"Enemy, sound and trap markers" detail:@"On, the 2003 default: a marker floats over every enemy your side can see, bright if a selected soldier sees him and dimmed if only someone else does, and becomes an arrow at the screen edge when he is off screen. Ear markers show enemies heard but not seen, and markers show known mines and traps. Off: all of these are hidden. Clue markers stay." get:EngGet("ui_showicons", 1) set:EngSet("ui_showicons", Live)];
	[p toggle:@"Keep messages in the developer console" detail:@"Controls only whether the game's messages are also kept in the developer console's history. The message lines that appear on screen during a mission are shown whether this is on or off. On is the 2003 default." get:EngGet("ui_messages", 1) set:EngSet("ui_messages", Live)];
	[p popup:@"Combat message time" detail:@"How long each line of the combat log (hits, misses, damage, who spotted whom) stays on screen in a mission before it fades. The original is 8 seconds. Off hides the log."
		items:@[ @"Off", @"4 seconds", @"8 seconds (original)", @"15 seconds", @"30 seconds" ] values:@[ @0, @4, @8, @15, @30 ] get:MacGetI(&g_s2.logLineSeconds) set:MacSetI(&g_s2.logLineSeconds)];
	[p popup:@"Damage number time" detail:@"How long the number that floats up from a unit when it is hit stays visible. The original is 2 seconds; longer is easier to read during fast enemy turns."
		items:@[ @"2 seconds (original)", @"3 seconds", @"5 seconds" ] values:@[ @2, @3, @5 ] get:MacGetI(&g_s2.hitNumberSeconds) set:MacSetI(&g_s2.hitNumberSeconds)];
	[p buttons:@[ @"Hide / show" ] title:@"Hide the interface" detail:@"In a mission, removes every panel, icon and message from the view, for a clean screenshot. Press the button again to bring them back. The game has this action but ships no key for it."
		actions:@[ ^{ S2EngineInputEvent("hideinterface"); } ]];
	[p toggle:@"Demo battle on the main menu" detail:@"After two minutes without input on the main menu, the game starts a battle between computer squads and plays it until you press a key. Off: the menu stays as it is."
		get:MacGetI(&g_s2.attractDemo) set:MacSetI(&g_s2.attractDemo)];
	[p toggle:@"Skip all videos" detail:@"On: every video the game would play is skipped. That is the logos and intro at launch, and also the victory video, the defeat video and any video a mission plays. Off, the 2003 default: they play." get:EngGet("game_skipvideo", 0) set:EngSet("game_skipvideo", Live)];

	[p section:@"Physics (bodies falling, being thrown by blasts, dragged)"];
	[p note:@"How dead and unconscious bodies fall, are thrown and are carried. Looks only, except that a body may come to rest in a slightly different place."];
	auto physSet = [](int *v) { return ^(float x) { *v = (int)lroundf(x); SaveMac(); physicsPending = true; }; };
	auto physSetF = [](float *v) { return ^(float x) { *v = x; SaveMac(); physicsPending = true; }; };
	[p buttons:@[ @"Original", @"Smooth", @"Cinematic" ] title:@"Physics presets"
		detail:@"Original: 20 steps a second, 5 correction passes, no extra knee limits. Smooth: 60 steps, 10 passes. Cinematic: 120 steps, 16 passes and the extra knee limits, which switch on once no mission is loaded. All three set joint stiffness to 100%."
		actions:@[ ^{ g_s2.physRate = 20; g_s2.physIterations = 5; g_s2.physJointLimits = 0; g_s2.physFriction = 0.6f; g_s2.physStiffness = 1; SaveMac(); physicsPending = true; for (S2Row *r in s2allRows) [r refresh]; },
			^{ g_s2.physRate = 60; g_s2.physIterations = 10; g_s2.physJointLimits = 0; g_s2.physFriction = 0.6f; g_s2.physStiffness = 1; SaveMac(); physicsPending = true; for (S2Row *r in s2allRows) [r refresh]; },
			^{ g_s2.physRate = 120; g_s2.physIterations = 16; g_s2.physJointLimits = 1; g_s2.physFriction = 0.6f; g_s2.physStiffness = 1; SaveMac(); physicsPending = true; for (S2Row *r in s2allRows) [r refresh]; } ]];
	[p popup:@"Body simulation rate" detail:@"How many times a second the game recalculates a body that is falling, thrown by a blast or being carried. The 2003 game used 20 and blended the frames in between. At higher rates each body part moves less between collision checks, so motion is smoother and steadier; a body may come to rest in a slightly different place. Thrown and dropped items are not affected."
		items:@[ @"20 per second (2003)", @"30", @"60", @"120", @"240" ] values:@[ @20, @30, @60, @120, @240 ]
		get:MacGetI(&g_s2.physRate) set:physSet(&g_s2.physRate)];
	[p popup:@"Joint correction passes" detail:@"How many times, in each of the five collision rounds of a step, the game pulls a body's bones back to their proper lengths and joint angles. The 2003 game used 5. More passes leave limbs less stretched and joints less bent out of shape."
		items:@[ @"5 (2003)", @"10", @"16", @"24" ] values:@[ @5, @10, @16, @24 ]
		get:MacGetI(&g_s2.physIterations) set:physSet(&g_s2.physIterations)];
	[p toggle:@"Extra knee limits" detail:@"On: adds four knee limits the developers left switched off, so a knee can no longer straighten past 162 degrees or fold flat, and legs stop bending the wrong way. Off is the 2003 behaviour. Elbows are not changed. The switch is applied only while no mission is loaded, and it affects bodies that fall after that."
		get:MacGetI(&g_s2.physJointLimits) set:physSet(&g_s2.physJointLimits)];
	[p slider:@"Joint stiffness" detail:@"How firmly each correction pass pulls a body's bones back to their lengths and joint limits. 100%: the full correction every pass. Lower values apply only that share each pass, so bodies stretch and flop more. This window's default is 100%; the game's own built-in value is 90%." min:0.3 max:1 format:Percent get:MacGetF(&g_s2.physStiffness) set:physSetF(&g_s2.physStiffness)];

	[p slider:@"Bodies come to rest" detail:@"How still a fallen body must be before the simulation freezes it in place. Lower keeps bodies moving longer, so they settle more naturally; higher freezes them sooner, sometimes mid-slide. The original is 0.06." min:0.01f max:0.2f format:Plain2 get:MacGetF(&g_s2.physSettle) set:physSetF(&g_s2.physSettle)];
	[p section:@"Violence"];
	[p note:@"Blood and gore. Decapitation also decides whether a head hit kills."];
	[p toggle:@"Blood" detail:@"On, the 2003 default: hits on people throw a spray of blood and leave blood stains on the ground and walls. Off: no spray, existing stains vanish at once, heads no longer come off, and a body can no longer be torn apart by a single massive blow. Damage and wounds are otherwise unchanged." get:EngGet("cheat_blood", 1) set:EngSet("cheat_blood", Live)];
	[p toggle:@"Headshot decapitations" detail:@"On, the 2003 default: a hit to the head that causes a critical wound and leaves the target at zero health or less takes the head off, and the target dies outright. This applies to your own soldiers too. Off: heads stay on and the hit is settled by the normal rules for death and unconsciousness. Needs Blood on." get:EngGet("cheat_allow_headshot", 1) set:EngSet("cheat_allow_headshot", Live)];
}

// ---- Cheats
- (void)buildCheats:(S2Page *)p
{
	[p note:@"The developers' own cheats, still in the game. A cheat you switch on stays on until you switch it off. The squad cheats are stored on your soldiers, saves included, and are switched on again at the start of every mission."];
	[p section:@"Squad"];
	[p note:@"Stored on your soldiers, saves included, and switched on again at the start of every mission."];
	for (const Cheat &c : Cheats())
	{
		if (!c.mission && !strcmp(c.var, "cheat_golden_shot")) { [p section:@"World"]; [p note:@"Apply to the whole game, in every mission, until switched off."]; }
		std::string var = c.var;
		[p toggle:c.title detail:c.detail
			get:^float { NSNumber *n = cheatWanted[@(var.c_str())]; return n ? n.floatValue : (S2EngineHas(var.c_str()) ? (S2EngineGet(var.c_str()) > 0 ? 1 : 0) : 0); }
			set:^(float v) { cheatWanted[@(var.c_str())] = @(v); SaveMac(); if (S2EngineHas(var.c_str())) S2EngineSet(var.c_str(), v); }];
	}
	[p section:@"Instant"];
	[p note:@"One-off actions. They cannot be undone."];
	[p buttons:@[ @"Level 5", @"Level 10", @"Level 20" ] title:@"Set squad level" detail:@"Sets every soldier you command to exactly that level, raising or lowering them: experience is set to the level's threshold, every skill to its cap for that experience, and perk points are added for the levels gained. Works only inside a mission and cannot be undone."
		actions:@[ ^{ S2EngineCommand("setxplevel 5"); }, ^{ S2EngineCommand("setxplevel 10"); }, ^{ S2EngineCommand("setxplevel 20"); } ]];
	[p buttons:@[ @"Unlock" ] title:@"Developer console" detail:@"Unlocks the game's command console for this session: the key below Esc then opens it. Type help there for the list of commands. It locks again when the game quits."
		actions:@[ ^{ S2EngineCommand("wirbelwind"); } ]];
	[p buttons:@[ @"End mission" ] title:@"End the mission now" detail:@"Leaves the current mission at once, as if the squad had walked off the map: the mission counts as left, not as won. Does nothing outside a mission."
		actions:@[ ^{ if (S2EngineHas("surrender")) S2EngineCommand("surrender"); } ]];
}

// ---- Advanced
- (void)buildAdvanced:(S2Page *)p
{
	[p section:@"Renderer"];
	[p note:@"Fallback drawing methods from 2003. Leave them alone unless you are testing."];
	[p popup:@"Skip drawing hidden objects" detail:@"Whether the game works out which parts of the scene are fully hidden behind others and leaves them undrawn. It should change the frame rate, not the picture. Off: everything in view is drawn. Only while still: hidden parts are skipped once the camera stops. Also while moving: the check keeps running every second frame as the camera moves; this is the game's built-in default." items:@[ @"Off: draw everything", @"Only while the camera is still", @"Also while the camera moves" ] values:@[ @0, @1, @2 ]
		get:EngGet("gfx_hsr", 2) set:EngSet("gfx_hsr", Live)];
	[p toggle:@"Fastest mode ⟳" detail:@"On: the game draws with its simplest lighting, whatever the Graphics pane says: no shadows, no cached lighting from lamps, fires and explosions, and no sky lighting. It was meant for the weakest 2003 graphics cards. Off is normal. The renderer restarts by itself half a second after you change this." get:EngGet("gfx_fastest", 0) set:EngSet("gfx_fastest", Recreate)];
	[p toggle:@"Stencil shadows" detail:@"On: light from lamps and fires is also drawn directly, one light at a time, with hard-edged shadows cut by shadow volumes. Off, the 2003 default: the game does not draw them this way. The 2003 game shipped with it off and it has not been looked at on the Mac renderer, so expect faults." get:EngGet("gfx_stencil_shadows", 0) set:EngSet("gfx_stencil_shadows", Live)];
	[p toggle:@"Pixel shaders off ⟳" detail:@"On: the game is told the graphics card has no pixel shaders and uses the simpler drawing method it kept for older 2003 cards, with plainer lighting. Off is normal. The renderer restarts by itself half a second after you change this." get:EngGet("gfx_nopixelshaders", 0) set:EngSet("gfx_nopixelshaders", Recreate)];
	[p toggle:@"Occlusion-query culling" detail:@"Asks the graphics chip which lights' areas are completely hidden behind walls and skips drawing them. It can raise the frame rate on dense maps. Its effect on this renderer has not been measured: turn it off if lighting pops in late."
		get:EngGet("gfx_hw_hsr", 0) set:EngSet("gfx_hw_hsr", Live)];
	[p buttons:@[ @"Restart renderer" ] title:@"Restart the renderer" detail:@"Rebuilds the game's whole drawing setup now: the picture goes black for a moment and every texture and off-screen image is created again. Options marked ⟳ do this by themselves; use the button if the picture looks wrong after changing several at once."
		actions:@[ ^{ S2EngineCommand("gfx_recreate"); } ]];

	[p section:@"Files"];
	[p note:@"Where the game keeps its files, and its log."];
	[p buttons:@[ @"Show in Finder" ] title:@"Game folder" detail:[NSString stringWithFormat:@"%s. The copy of the game's data this app plays from: saved games (save), screenshots, the key bindings and settings files (cfg), and any mods.", S2GameDirectory()]
		actions:@[ ^{ [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:@(S2GameDirectory())]]; } ]];
	[p buttons:@[ @"Clear" ] title:@"Shader cache" detail:@"The game keeps its compiled drawing programs on disk so that later launches start without stutter. Clear deletes them; they are rebuilt in the background the next time the game starts, with a few short hitches the first time each effect appears. Use it only if graphics look wrong after an update."
		actions:@[ ^{
			NSString *c = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"org.silentstorm.mac"];
			[NSFileManager.defaultManager removeItemAtPath:c error:nil];
		} ]];
	[p toggle:@"Console log file" detail:@"On: every line the game writes to its console, including game messages and script errors, is also written to the file Console.txt in the game folder, with formatting codes removed. The file is started afresh the first time a line is written after each launch. Off is the 2003 default." get:EngGet("console_writelog", 0) set:EngSet("console_writelog", Live)];
	[p toggle:@"Script log" detail:@"Prints every call a mission script makes, and any wrong arguments, to the developer console. For people writing or debugging mods; it slows scripted scenes."
		get:EngGet("lua_showlog", 0) set:EngSet("lua_showlog", Live)];
	[p buttons:@[ @"Take", @"Show in Finder" ] title:@"Screenshot" detail:@"Saves the game picture as a BMP file in the screenshots folder inside the game folder. This window is not in the picture."
		actions:@[ ^{ S2EngineInputEvent("screenshot"); },
			^{ NSString *d = [@(S2GameDirectory()) stringByAppendingPathComponent:@"screenshots"];
			   [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
			   [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:d]]; } ]];
	[p section:@"Simulation"];
	[p popup:@"Computer thinking time per step" detail:@"How many milliseconds the computer may spend planning in each step of the game world. More lets enemy and ally turns start sooner, and makes each frame in which it plans longer by the same amount. The original is 10. Takes effect when the next mission loads."
		items:@[ @"10 ms (original)", @"20 ms", @"40 ms" ] values:@[ @10, @20, @40 ] get:MacGetI(&g_s2.aiThinkMs) set:MacSetI(&g_s2.aiThinkMs)];

	[p section:@"Reset"];
	[p buttons:@[ @"Reset Mac options" ] title:@"Defaults" detail:@"Puts every option this window added (image, pacing, camera, audio master, cheats) back to its default."
		actions:@[ ^{ ResetMacOptions(); } ]];
}

- (void)windowWillClose:(NSNotification *)n
{
	// focus back to the game
	[GameWindow() makeKeyAndOrderFront:nil];
}
@end

// ---------------------------------------------------------------------------------------------------
void S2SettingsShow()
{
	if (!s2settings) s2settings = [S2SettingsWindow new];
	[s2settings showWindow:nil];
	[s2settings.window makeKeyAndOrderFront:nil];
}

bool S2SettingsWindowIsKey() { return s2settings && s2settings.window.isKeyWindow; }

// test hook: "row <n> alt" moves a row through the path a click takes and "row <n> restore" puts it back. Each reports
// what the row read before and after, so a control that stores nothing shows up. The window itself is never shown.
static void S2ExerciseRow(int index, const char *action)
{
	if (!s2settings) s2settings = [S2SettingsWindow new];
	FILE *out = fopen("_s2out.txt", "ab");
	if (!out) return;
	if (index < 0) { fprintf(out, "rows count=%lu\n", (unsigned long)s2allRows.count); fclose(out); return; }
	if (index >= (int)s2allRows.count) { fclose(out); return; }
	static NSMutableDictionary<NSNumber*, NSNumber*> *saved;
	if (!saved) saved = [NSMutableDictionary dictionary];
	S2Row *r = s2allRows[index];
	float before = r.get(), target = before;
	// never from a test: this row takes over a display, and a hidden process has nothing to show on it
	bool refuse = [r.title isEqualToString:@"Full screen"];
	if (!strcmp(action, "info") || refuse)
	{
		fprintf(out, "row index=%d action=%s kind=%d enabled=%d before=%g target=%g after=%g tab=%s title=%s\n", index, refuse ? "refused" : action, (int)r.kind, r.control.enabled ? 1 : 0, before, before, before,
			[r.tab stringByReplacingOccurrencesOfString:@" " withString:@"_"].UTF8String, [r.title stringByReplacingOccurrencesOfString:@" " withString:@"_"].UTF8String);
		fclose(out);
		return;
	}
	if (!strcmp(action, "alt"))
	{
		saved[@(index)] = @(before);
		if (r.kind == S2Switch) target = before != 0 ? 0 : 1;
		else if (r.kind == S2Slider)
		{
			NSSlider *slider = (NSSlider*)r.control;
			double mn = slider.minValue, mx = slider.maxValue;
			target = (float)(before > (mn + mx) / 2 ? mn + (mx - mn) * 0.1 : mx - (mx - mn) * 0.1);
		}
		else for (NSUInteger i = 0; i < r.values.count; ++i)
			if (fabsf(r.values[i].floatValue - before) < 1e-4f) { target = r.values[(i + 1) % r.values.count].floatValue; break; }
	}
	else if (saved[@(index)]) target = saved[@(index)].floatValue;
	if (r.kind == S2Switch) ((NSSwitch*)r.control).state = target != 0 ? NSControlStateValueOn : NSControlStateValueOff;
	else if (r.kind == S2Slider) ((NSSlider*)r.control).doubleValue = target;
	else
	{
		NSInteger best = 0; float distance = INFINITY;
		for (NSUInteger i = 0; i < r.values.count; ++i) { float d = fabsf(r.values[i].floatValue - target); if (d < distance) { distance = d; best = (NSInteger)i; } }
		[(NSPopUpButton*)r.control selectItemAtIndex:best];
	}
	[r changed:r.control];
	fprintf(out, "row index=%d action=%s kind=%d enabled=%d before=%g target=%g after=%g tab=%s title=%s\n", index, action, (int)r.kind, r.control.enabled ? 1 : 0, before, target, r.get(),
		[r.tab stringByReplacingOccurrencesOfString:@" " withString:@"_"].UTF8String, [r.title stringByReplacingOccurrencesOfString:@" " withString:@"_"].UTF8String);
	fclose(out);
}

void S2SettingsTick()
{
	++tickCount;
	S2PlatformTick();
	if (tickCount > 2 && S2EngineHas("gfx_resolution"))
	{
		if (requestedMaximumFidelity) { requestedMaximumFidelity = false; ApplyMaximumFidelity(); }
		if (requestedGraphics >= 0) { int mode = requestedGraphics; requestedGraphics = -1; ApplyGraphicsMode(mode != 0, initialOriginalPending); initialOriginalPending = false; }
		else if (initialOriginalPending) { initialOriginalPending = false; ApplyGraphicsMode(true, true); }
	}
	// test hook: "_settings.req" in the game folder opens the window (behind other apps when S2_NO_ACTIVATE is set)
	// and writes its window number to "_settings.win" for screencapture -l
	if (tickCount % 15 == 0 && access("_settings.req", F_OK) == 0)
	{
		char tab[64] = {};
		if (FILE *f = fopen("_settings.req", "rb")) { if (!fgets(tab, sizeof tab, f)) tab[0] = 0; fclose(f); }
		unlink("_settings.req");
		if (!s2settings) s2settings = [S2SettingsWindow new];
		if (getenv("S2_NO_ACTIVATE")) [s2settings.window orderFront:nil]; else S2SettingsShow();
		NSTabViewController *tabs = (NSTabViewController*)s2settings.window.contentViewController;
		int t = atoi(tab);
		if (t >= 0 && t < (int)tabs.tabViewItems.count) tabs.selectedTabViewItemIndex = t;
		if (FILE *f = fopen("_settings.win", "wb")) { fprintf(f, "%ld %ld\n", (long)s2settings.window.windowNumber, (long)GameWindow().windowNumber); fclose(f); }
	}
	// test hook: "_s2cmd.txt" lines are "mac <option> <value>" (a field of S2Settings, by its saved name),
	// "cmd <console line>" or "get <variable>" (appends its state to "_s2out.txt"); the file is removed once read
	if (tickCount % 15 == 7 && access("_s2cmd.txt", F_OK) == 0)
	{
		if (FILE *f = fopen("_s2cmd.txt", "rb"))
		{
			char line[256];
			while (fgets(line, sizeof line, f))
			{
				line[strcspn(line, "\r\n")] = 0;
				fprintf(stderr, "[s2cmd] %s\n", line);   // trace for the hidden-run driver (a lost command is then visible)
				char key[64], rowAction[16]; float v; int rowIndex;
				if (sscanf(line, "mac %63s %f", key, &v) == 2)
				{
					for (const MacField &m : MacFields()) if (!strcmp(m.key, key)) { if (m.f) *m.f = v; else *m.i = (int)lroundf(v); }
					SaveMac();
				}
				else if (sscanf(line, "row %d %15s", &rowIndex, rowAction) == 2) S2ExerciseRow(rowIndex, rowAction);
				else if (int kw = 0, kh = 0; sscanf(line, "keyhelp %d %d", &kw, &kh) == 2) S2KeyHelpWriteImage("_keyhelp.png", kw, kh);
				else if (sscanf(line, "graphics %63s", key) == 1)
				{
					if (!strncmp(key, "selector-", 9)) S2GraphicsSelectorTest(key + 9);
						else if (!strcmp(key, "status"))
					{
						if (FILE *out = fopen("_s2out.txt", "ab"))
						{
							fprintf(out, "graphics mode=%s resolution=%s hd=%d terrain=%d ao=%d bloom=%d edr=%d sharpen=%g saturation=%g generation=%u mission=%d\n", originalGraphics ? "Original" : "Enhanced", S2EngineGetString("gfx_resolution").c_str(), g_s2.hdTextures, g_s2.terrainDetail, g_s2.ao, g_s2.bloom, g_s2.edr, g_s2.sharpen, g_s2.saturation, S2TextureSourceGeneration(), S2EngineHas("godmode"));
							fclose(out);
						}
					}
					else if (!strcmp(key, "original")) S2SetOriginalGraphics(true);
					else if (!strcmp(key, "enhanced")) S2SetOriginalGraphics(false);
					else if (!strcmp(key, "toggle")) S2ToggleGraphics();
					else if (!strcmp(key, "reset")) ResetMacOptions();
					else if (!strcmp(key, "maximum")) requestedMaximumFidelity = true;
				}
				else if (sscanf(line, "cheat %63s %f", key, &v) == 2)
				{
					// the same path as the Cheats tab, so a cheat set from the hub persists and shows in Settings
					cheatWanted[@(key)] = @(v); SaveMac();
					if (S2EngineHas(key)) S2EngineSet(key, v);
				}
				else if (sscanf(line, "turnspeed %f", &v) == 1) S2SetAITurnSpeed((int)v);
				else if (!strcmp(line, "hubstate"))
				{
					NSMutableArray *list = [NSMutableArray array];
					for (const Cheat &c : Cheats())
					{
						NSNumber *n = cheatWanted[@(c.var)];
						bool on = n ? n.floatValue > 0 : (S2EngineHas(c.var) && S2EngineGet(c.var) > 0);
						[list addObject:@{ @"var": @(c.var), @"title": c.title, @"detail": c.detail, @"mission": @(c.mission), @"on": @(on) }];
					}
					NSData *json = [NSJSONSerialization dataWithJSONObject:@{ @"graphics": originalGraphics ? @"Original" : @"Enhanced", @"turnSpeed": @(S2AITurnSpeed()), @"cheats": list } options:0 error:nil];
					[json writeToFile:@"_hubstate.json" atomically:YES];
				}
				else if (!strcmp(line, "quit")) S2RequestQuit();
				else if (!strncmp(line, "cmd ", 4)) S2EngineCommand(line + 4);
				else if (sscanf(line, "get %63s", key) == 1)
					if (FILE *o = fopen("_s2out.txt", "ab")) { fprintf(o, "%s live=%d value=%g str=%s\n", key, S2EngineHas(key) ? 1 : 0, S2EngineGet(key, -1), S2EngineGetString(key).c_str()); fclose(o); }
			}
			fclose(f);
		}
		unlink("_s2cmd.txt");
		for (S2Row *r in s2allRows) [r refresh];
	}
	double now = CACurrentMediaTime();
	if (textureReloadPending) { textureReloadPending = false; S2ReloadTextureSources(S2HDTexturesEnabled()); }
	if (recreatePending && now >= recreateAt) { recreatePending = false; S2EngineCommand("gfx_recreate"); }
	if (cameraPending) { cameraPending = false; S2EngineCommand("camera_update"); }
	if (cameraLimitsPending && tickCount > 2 && S2EngineHas("mission_camera_limits")) { cameraLimitsPending = false; ApplyCamera(); }
	if (tickCount > 2 && S2EngineHas("phtimestep") && (physicsPending || (tickCount % 120 == 0 && (g_s2.physJointLimits != 0) != (physJointsApplied != 0))))
	{
		physicsPending = false; ApplyPhysics();
	}
	if (tickCount % 30 == 0 && cheatWanted.count)
	{
		for (NSString *k in cheatWanted)
		{
			const char *var = k.UTF8String;
			if (!S2EngineHas(var)) continue;
			float want = cheatWanted[k].floatValue, have = S2EngineGet(var) > 0 ? 1 : 0;
			if (want != have) S2EngineSet(var, want);
		}
	}
	if (savePending && now >= saveAt) { savePending = false; S2EngineSaveConfig(); }
}

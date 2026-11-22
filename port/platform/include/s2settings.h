// s2settings.h: Mac-side options the macOS port adds on top of the engine's own variables. The Settings window
// (settings.mm) owns and saves them; the renderer, mixer and window read them every frame, so changes are live.
#pragma once
#include <stdint.h>
#include <vector>

struct S2Settings
{
	// image
	int upscaler = 0;            // 0 MetalFX spatial, 1 bilinear, 2 nearest (sharp pixels)
	float sharpen = 0.25f;       // contrast-adaptive sharpening, 0..1
	int fxaa = 0;                // FXAA: 0 off, 1 the whole game image before upscaling, 2 the 3D world only (interface stays sharp)
	float brightness = 0;        // -0.25..0.25, added
	float contrast = 1;          // 0.5..1.5
	float saturation = 1;        // 0..2
	float vibrance = 0;          // -1..1, saturation weighted towards dull colours
	float temperature = 0;       // -1 (cool) .. 1 (warm)
	float tint = 0;              // -1 (green) .. 1 (magenta)
	float vignette = 0;          // 0..1
	float grain = 0;             // 0..1
	// world effects (3D scene only, before the interface is drawn)
	int ao = 1;                  // ambient occlusion
	float aoStrength = 0.85f;    // 0..2
	float aoRadius = 0.7f;       // world units (metres)
	int bloom = 1;
	float bloomStrength = 0.5f;  // 0..1.5
	float bloomThreshold = 0.8f; // 0..1, scene luminance where glow starts
	float haze = 0;              // 0..1, distance haze towards the horizon colour
	int worldFxDebug = 0;        // 1 shows the occlusion buffer, 2 split screen
	// HDR: highlights of the 3D world above SDR white on displays with EDR headroom (XDR, HDR monitors)
	int edr = 1;
	float edrStrength = 0.6f;    // 0..1 of the display's current headroom
	// HD texture pack (hd/Textures/<id> in the game folder, built by port/tools/texpack); read at launch
	int hdTextures = 1;
	int terrainDetail = 1024;    // near terrain bake resolution; 256 is the original
	// ragdoll physics (NAnimation particle skeletons; the engine's ph* console commands)
	int physRate = 20;           // simulation steps per second; 20 is the original
	int physIterations = 5;      // constraint solver iterations per collision cycle (5 cycles); 5 is the original
	int physJointLimits = 0;     // the 4 extra joint-angle limits the developers left switched off
	float physFriction = 0.6f;   // ground friction per 50 ms, as in the original
	float physStiffness = 1.0f;  // constraint stiffness, 1 is rigid
	// timing
	int vsync = 1;
	int frameCap = 0;            // frames per second, 0 = none
	int tripleBuffer = 1;        // 3 drawables in flight (smoother) or 2 (lower latency)
	int showFPS = 0;             // 0 off, 1 fps, 2 detailed
	// textures
	int anisoOverride = 16;      // 0 = as the game asks, else 2..16 on every mipmapped texture
	float lodBias = 0;           // -2..2, negative is sharper
	// sound
	float masterVolume = 1;      // 0..1, on top of the game's SFX and music volumes
	int muteInBackground = 1;
	// input
	float scrollScale = 1;       // trackpad and wheel zoom multiplier
	int ctrlClickRight = 1;      // control-click acts as a right click
	// background
	int pauseInBackground = 1;   // the engine's own inactive throttle (40 ms sleep per frame)
	// gameplay
	int aiTurnSpeed = 1;         // 1..4: enemy and ally turns in turn-based play run this many times faster (iMission.cpp)
	int weaponCompare = 1;       // a gun's tooltip compares it with the one in the soldier's hands (iCommonUI.cpp)
	// power and display
	int keepAwake = 1;           // hold the display awake while the game is the front app (enemy turns and videos have no input)
	int adaptPower = 0;          // on a hot Mac or in Low Power Mode: no ambient occlusion or bloom, frame rate capped at 30
	int metalHUD = 0;            // Apple's Metal performance HUD on the game layer
	int hdrFollowSystem = 1;     // drop HDR highlights while macOS asks apps to suppress HDR (macOS 26 and later)
	// trackpad gestures and edge scrolling
	int scrollPans = 0;          // two-finger scrolling pans the map; 0 = it zooms (a wheel mouse always zooms)
	int pinchZoom = 1;           // pinch zooms
	int rotateGesture = 1;       // a two-finger twist turns the camera
	float gestureSpeed = 1;      // multiplier on the pan and the twist
	int edgeScrollBand = 4;      // pixels at each screen edge that scroll the map; 4 is the original, 0 switches edge scrolling off
	int doubleClickMs = 500;     // longest gap between the two clicks of a double-click; 500 is the port's original, 0 follows macOS
	// timings the original fixed in code (each read where the engine used the constant)
	int logLineSeconds = 8;      // mission combat log: seconds a line stays; 8 is the original, 0 hides the log (Main/iLogPanel.cpp)
	int endTurnGuardMs = 2000;   // End turn is ignored this long after the turn comes back to the player (Main/iMission.cpp)
	int subtitleSeconds = 3;     // shortest time the words of a spoken reply stay on screen (Main/iDesktopWindow.cpp)
	int hitNumberSeconds = 2;    // how long a floating damage number rises and fades (Main/iMissionUI.cpp)
	int followSeconds = 10;      // the camera follows a unit at most this long; 0 = no limit (Main/Camera.cpp)
	int aiThinkMs = 10;          // computer planning time per world step, milliseconds (Main/aiJob.cpp)
	int attractDemo = 1;         // the main menu starts a demo battle after two idle minutes (Main/iMainMenu.cpp)
	float physSettle = 0.06f;    // how readily a falling body is declared at rest (console phstoprule); 0.06 is the original
	// rules and enemy behaviour (read at the moment each calculation runs)
	int horPlus = 0;             // Hor+: wider than 4:3, the mission camera keeps its 4:3 height of view and widens (Main/Camera.cpp); 0 is the original
	int retailRules = 0;         // 0 corrected, 1 retail 2003: the reconstruction's rule fixes are off (S2RetailRules; Main/RPG*.cpp and others)
	int enemyHeadShots = 1;      // 1 retail: AI units choose a head shot above 50% to hit (Main/aiActions.cpp); 0 always the body
	int enemyPartialBursts = 1;  // 1 retail: AI units fire the affordable part of a burst (Main/aiWeapon.cpp); 0 a whole burst or none

	uint32_t generation = 0;     // bumped on every change
};
extern S2Settings g_s2;

// Settings window and per-frame hooks (settings.mm)
void S2SettingsLoad();                       // read saved values; call before the engine starts
void S2SettingsShow();                       // open the window (Cmd-,)
bool S2OriginalGraphics();                   // selected graphics mode, including a queued change
void S2SetOriginalGraphics(bool original);   // switch on the engine thread at the next message pump
void S2ToggleGraphics();
void S2GraphicsSelectorTest(const char *action);   // macwindow.mm test hook: "state", "original" or "enhanced"
bool S2HDTexturePackAvailable();
bool S2SettingsWindowIsKey();                // the Settings window has focus; the game keeps running behind it
void S2SettingsTick();                       // once per frame from the message pump: applies queued engine changes
void S2SettingsFrame(double ms, int srcW, int srcH, int outW, int outH, const char *scaler);   // from Present, for the FPS overlay
void S2SettingsAttachOverlay(void *metalLayer);
// keyhelp.mm: the F1 keyboard sheet and the F9 / Cmd-G graphics switch with its notice
void S2KeyHelpAttach(void *metalLayer);
void S2KeyHelpTick();
void S2KeyHelpToggle();
bool S2KeyHelpKey(unsigned short keyCode, bool down);
void S2ToggleGraphicsWithNotice();
void S2KeyHelpWriteImage(const char *path, int w, int h);
void S2KeyHelpNotice(const char *text);
int S2AITurnSpeed();
const S2Settings &S2EffectiveSettings();     // g_s2 with the heat and battery reductions applied; the renderer reads this
bool S2PowerSaving();                        // the reductions are active right now
bool S2HDRSuppressed();                      // macOS asked apps to hold back HDR and the player follows that
float S2CameraFOVScale();                    // Main/Camera.cpp: the Field of view setting as a ratio to the engine's fixed 35 degrees
int S2EdgeScrollBand();                      // Main/iMissionUI.cpp: pixels at each edge that scroll the map
int S2DoubleClickMs();                       // win32.cpp GetDoubleClickTime
int S2LogLineMs();                           // Main/iLogPanel.cpp: 0 hides the combat log
int S2EndTurnGuardMs();                      // Main/iMission.cpp
int S2SubtitleMs();                          // Main/iDesktopWindow.cpp
int S2HitNumberMs();                         // Main/iMissionUI.cpp
int S2FollowUnitMs();                        // Main/Camera.cpp
float S2AIThinkSeconds();                    // Main/aiJob.cpp
bool S2AttractDemo();                        // Main/iMainMenu.cpp
bool S2WidescreenHorPlus();                  // Main/Camera.cpp: the Hor+ mission camera is switched on
bool S2RetailRules();                        // engine rule code: true = the 2003 arithmetic instead of the corrected one
int S2EnemyAim();                            // Main/aiActions.cpp: 1 = AI units may choose a head shot (retail)
int S2EnemyPartialBursts();                  // Main/aiWeapon.cpp: 1 = AI units may fire part of a burst (retail)
void S2AddTrackpadCamera(float panRight, float panUp, float yawRadians);     // macwindow.mm: gestures, pan in viewport heights
bool S2TakeTrackpadCamera(float *panRight, float *panUp, float *yawRadians); // Main/Camera.cpp: gestures since the last call
void S2SetAITurnSpeed(int speed);
void S2CycleAITurnSpeed();
float S2AudioTargetGain();                   // master volume, 0 while muted in the background (audio thread safe)
void S2WorldEffects(const float *clipToWorld, const float *worldToClip, const float *screenRect);   // engine hook: register 0 + register depth hold the finished 3D world; screenRect = where it lands (x1 y1 x2 y2, back-buffer pixels)
void S2SetAppActive(bool active);            // from the window delegate

// Display sizes offered to the engine (the adapter's mode list) and in the Settings window, from the main screen
struct S2Mode { int w, h; const char *label; };
std::vector<S2Mode> S2DisplayModes();

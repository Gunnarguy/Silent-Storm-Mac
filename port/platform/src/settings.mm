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
	};
	return f;
}

// Mission camera limits (console commands, applied when a map loads). Stock values are the shipped autoexec.cfg.
struct CameraCfg
{
	float fov = 35, minRod = 10, maxRod = 65, minPitch = -1.35f, maxPitch = -0.75f;
	int softLimits = 1;
	float zoomSpeed = 0.3f, pitchSpeed = 5, yawSpeed = 1.5f, scrollSpeed = 1.4f;
} cam;
const CameraCfg kStockCamera;

// Cheats the user turned on stay on: re-applied whenever their variable is live (mission-scoped ones every mission).
struct Cheat { const char *var; NSString *title, *detail; bool mission; };
const std::vector<Cheat> &Cheats()
{
	static const std::vector<Cheat> c = {
		{ "godmode", @"God mode", @"Your squad takes no damage. Mission cheat; turned on again at the start of every mission.", true },
		{ "cheat_ap", @"Unlimited action points", @"Your soldiers never run out of AP in turn-based mode. Mission cheat.", true },
		{ "seeall", @"See everything", @"Reveals every unit on the map, through walls and fog of war. Mission cheat.", true },
		{ "teleport", @"Teleport", @"Ordered moves arrive instantly. Mission cheat.", true },
		{ "cheat_golden_shot", @"Golden shot", @"Any hit makes the target explode.", false },
		{ "cheat_heads_off", @"Heads off", @"Every landed hit beheads (needs blood and headshots on).", false },
		{ "cheat_football", @"Football", @"Corpses always get kicked across the floor when hit.", false },
		{ "cheat_showall", @"Show all on the chapter map", @"Every zone and encounter is shown.", false },
		{ "cheat_zoneautocomplete", @"Zone auto-complete", @"Clicking a zone on the chapter map completes it.", false },
		{ "cheat_slomo", @"Cinematic slow motion", @"Random slow-motion camera on dramatic shots.", false },
		{ "cheat_global_xcom", @"X-COM global map", @"The alternative global map interface left in the game files.", false },
		{ "i_am_an_alien", @"Everyone is a Panzerklein", @"Every soldier is drawn in the Panzerklein style.", false },
		{ "game_noai", @"Freeze enemy AI", @"Enemies stop thinking. Saved by the engine; remember to turn it off.", false },
	};
	return c;
}
NSMutableDictionary<NSString*, NSNumber*> *cheatWanted;   // var -> 0/1, only for cheats the user touched

std::atomic<bool> s2appActive{ true };
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
		@"soft": @(cam.softLimits), @"zoom": @(cam.zoomSpeed), @"pitch": @(cam.pitchSpeed), @"yaw": @(cam.yawSpeed), @"scroll": @(cam.scrollSpeed) } forKey:@"s2.camera"];
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
	if ([c[@"soft"] isKindOfClass:NSNumber.class]) cam.softLimits = [c[@"soft"] intValue];
	cheatWanted = [NSMutableDictionary dictionary];
	NSDictionary *ch = [d dictionaryForKey:@"s2.cheats"];
	for (NSString *k in ch) if ([ch[k] isKindOfClass:NSNumber.class]) cheatWanted[k] = ch[k];
	[NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *) { s2appActive = true; }];
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
// FPS overlay: a text layer on top of the game's Metal layer
static CATextLayer *s2overlay;
static struct { double sum = 0, worst = 0; int frames = 0; double last = 0; std::vector<double> window; } s2fps;

void S2SettingsAttachOverlay(void *metalLayer)
{
	CALayer *host = (__bridge CALayer*)metalLayer;
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
	NSArray *titles = ResolutionTitles(resolutions);
	NSMutableArray *vals = [NSMutableArray array];
	for (size_t i = 0; i < resolutions.size(); ++i) [vals addObject:@(i)];
	__block std::vector<std::pair<int, int>> *res = &resolutions;
	[p popup:@"Game resolution" detail:@"What the game renders. The 2003 interface is drawn in pixels: higher is sharper with a smaller interface. Display size keeps it at its designed scale; supersampling renders above the screen and scales down. 16:9 and 4:3 are letterboxed. Restarts the renderer."
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
	[p toggle:@"Full screen" detail:@"Its own Space, like any Mac app (also Cmd-F or the green button)."
		get:^float { return (GameWindow().styleMask & NSWindowStyleMaskFullScreen) ? 1 : 0; }
		set:^(float v) {
			S2EngineSet("gfx_fullscreen", v); ScheduleSave();
			NSWindow *g = GameWindow();
			if (g && ((g.styleMask & NSWindowStyleMaskFullScreen) != 0) != (v != 0)) [g toggleFullScreen:nil];
		}];

	[p section:@"HDR"];
	[p toggle:@"HDR highlights" detail:@"On displays that can go brighter than white (MacBook Pro XDR, Pro Display XDR, HDR monitors): fire, muzzle flashes, lamps and sunlight in the 3D world use the extra brightness. The interface stays at normal white."
		get:MacGetI(&g_s2.edr) set:MacSetI(&g_s2.edr)];
	[p slider:@"HDR intensity" detail:@"Share of the display's current headroom the highlights may use." min:0 max:1 format:Percent get:MacGetF(&g_s2.edrStrength) set:MacSetF(&g_s2.edrStrength)];

	[p section:@"Scaling"];
	[p popup:@"Upscaler" detail:@"How the game image is scaled to the screen's pixels when it is smaller. MetalFX reconstructs edges; nearest keeps hard pixels."
		items:@[ @"MetalFX (Apple, recommended)", @"Bilinear", @"Nearest (sharp pixels)" ] values:@[ @0, @1, @2 ]
		get:MacGetI(&g_s2.upscaler) set:MacSetI(&g_s2.upscaler)];
	[p slider:@"Sharpening" detail:@"Raises local contrast after scaling. High values can create halos; it does not recover missing source artwork."
		min:0 max:1 format:Percent get:MacGetF(&g_s2.sharpen) set:MacSetF(&g_s2.sharpen)];
	[p toggle:@"FXAA anti-aliasing" detail:@"Smooths jagged edges on the game image. Softens interface text slightly."
		get:MacGetI(&g_s2.fxaa) set:MacSetI(&g_s2.fxaa)];

	[p section:@"Frame pacing"];
	s2collectVisualControls = false;
	[p toggle:@"VSync" detail:@"Waits for the display refresh: no tearing. Off gives the lowest latency."
		get:MacGetI(&g_s2.vsync) set:MacSetI(&g_s2.vsync)];
	[p popup:@"Frame-rate limit" detail:@"Caps frames per second to save power and heat on battery."
		items:@[ @"Unlimited", @"30 fps", @"40 fps", @"60 fps", @"90 fps", @"120 fps" ] values:@[ @0, @30, @40, @60, @90, @120 ]
		get:MacGetI(&g_s2.frameCap) set:MacSetI(&g_s2.frameCap)];
	[p toggle:@"Triple buffering" detail:@"Three frames in flight: steadier frame times. Off: one frame less latency."
		get:MacGetI(&g_s2.tripleBuffer) set:MacSetI(&g_s2.tripleBuffer)];
	[p popup:@"Performance overlay" detail:@"Frame rate in the top-left corner; detailed adds frame times, the 1% low and the scaling path."
		items:@[ @"Off", @"Frame rate", @"Detailed" ] values:@[ @0, @1, @2 ]
		get:MacGetI(&g_s2.showFPS) set:MacSetI(&g_s2.showFPS)];
	[p toggle:@"Keep running in the background" detail:@"Off (default): the game pauses and idles while another app is in front."
		get:^float { return g_s2.pauseInBackground ? 0 : 1; } set:^(float v) { g_s2.pauseInBackground = v ? 0 : 1; SaveMac(); }];
}

// ---- Graphics
- (void)buildGraphics:(S2Page *)p
{
	[p section:@"Original / Enhanced"];
	[p toggle:@"Enhanced graphics" detail:@"Off: original textures, 1024×768, classic terrain, lighting and color. On: restores your enhanced setup. You can also click Original / Enhanced over the game or press ⇧⌘G. The image briefly rebuilds; your mission stays loaded."
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
	[p toggle:@"Ambient occlusion" detail:@"Soft contact shadows where surfaces meet: under stairs, around feet, in corners. Rebuilt in world space from the scene's depth."
		get:MacGetI(&g_s2.ao) set:MacSetI(&g_s2.ao)];
	[p slider:@"Occlusion strength" detail:@"How dark the contact shadows get. 0 removes them; 1× is the designed strength." min:0 max:2 format:Times get:MacGetF(&g_s2.aoStrength) set:MacSetF(&g_s2.aoStrength)];
	[p slider:@"Occlusion radius" detail:@"How far the shadowing reaches, in metres." min:0.2 max:2.5
		format:^NSString *(float v) { return [NSString stringWithFormat:@"%.1f m", v]; } get:MacGetF(&g_s2.aoRadius) set:MacSetF(&g_s2.aoRadius)];
	[p toggle:@"Bloom" detail:@"Fire, muzzle flashes, lamps and the sun glow into the air around them." get:MacGetI(&g_s2.bloom) set:MacSetI(&g_s2.bloom)];
	[p slider:@"Bloom strength" detail:@"How much glow bright things spread into the air. 0 adds none." min:0 max:1.5 format:Percent get:MacGetF(&g_s2.bloomStrength) set:MacSetF(&g_s2.bloomStrength)];
	[p slider:@"Bloom threshold" detail:@"How bright something must be before it glows." min:0.4 max:1 format:Percent get:MacGetF(&g_s2.bloomThreshold) set:MacSetF(&g_s2.bloomThreshold)];
	[p slider:@"Distance haze" detail:@"Atmospheric depth: far buildings fade into the air." min:0 max:1 format:Percent get:MacGetF(&g_s2.haze) set:MacSetF(&g_s2.haze)];
	[p popup:@"Effects comparison" detail:@"Compares only the added world effects. For the full original look, use Original / Enhanced above."
		items:@[ @"Off", @"Occlusion only", @"Split screen" ] values:@[ @0, @1, @2 ] get:MacGetI(&g_s2.worldFxDebug) set:MacSetI(&g_s2.worldFxDebug)];

	[p section:@"Lighting and shadows"];
	[p toggle:@"Shadows" detail:@"Dynamic shadows from the sun and lights." get:EngGet("gfx_shadows", 1) set:EngSet("gfx_shadows", Live)];
	[p toggle:@"Cached lighting ⟳" detail:@"Per-object light caches: soft, accurate light from lamps, fire and explosions." get:EngGet("gfx_cl", 1) set:EngSet("gfx_cl", Recreate)];
	[p popup:@"Light cache resolution ⟳" detail:@"Resolution of each light cache cube. Higher is smoother shadows from point lights."
		items:@[ @"16", @"32", @"64", @"128", @"256 (beyond the original)" ] values:@[ @16, @32, @64, @128, @256 ]
		get:EngGet("gfx_cl_cube_resolution", 16) set:EngSet("gfx_cl_cube_resolution", Recreate)];
	[p toggle:@"Precise point-light shadows ⟳" detail:@"An extra high-resolution cube for the nearest light." get:EngGet("gfx_cl_use_precise_shadows", 1) set:EngSet("gfx_cl_use_precise_shadows", Recreate)];
	[p popup:@"Sky light samples ⟳" detail:@"Ambient light from the sky. 0 turns ambient occlusion from the sky off."
		items:@[ @"Off", @"1", @"2", @"3", @"4" ] values:@[ @0, @1, @2, @3, @4 ]
		get:EngGet("gfx_cl_sky_textures", 0) set:EngSet("gfx_cl_sky_textures", Recreate)];
	[p popup:@"Sun shadow map ⟳" detail:@"Resolution of the sun's shadow map. The original game stops at 1024; 2048 and 4096 give crisper shadow edges."
		items:@[ @"512", @"1024", @"2048", @"4096 (beyond the original)" ] values:@[ @512, @1024, @2048, @4096 ]
		get:EngGet("gfx_depth_tex_resolution", 512) set:EngSet("gfx_depth_tex_resolution", Recreate)];
	[p popup:@"World render scale ⟳" detail:@"The 3D world renders off screen, separately from the interface. Above 1× it is supersampled: 4× renders the world at twice the width and height and scales it down, the cleanest anti-aliasing there is, while the interface keeps its size."
		items:@[ @"0.5× (fastest)", @"1×", @"2× (Ultra)", @"3×", @"4× (Beyond, 2×2 supersampling)" ] values:@[ @0.5, @1, @2, @3, @4 ]
		get:EngGet("gfx_register_resolution", 1) set:EngSet("gfx_register_resolution", Recreate)];
	[p toggle:@"Soft lighting" detail:@"Blurs the cached lighting to remove stair-stepping." get:EngGet("gfx_cl_blur", 1) set:EngSet("gfx_cl_blur", Live)];
	[p toggle:@"Soft sun shadows" detail:@"Blurs the sun's shadow edges." get:EngGet("gfx_blur_sun", 1) set:EngSet("gfx_blur_sun", Live)];
	[p toggle:@"Bump-mapped lighting ⟳" detail:@"Surface relief in the cached lighting." get:EngGet("gfx_cl_use_bump", 1) set:EngSet("gfx_cl_use_bump", Recreate)];
	[p toggle:@"Bump mapping on everything ⟳" detail:@"Relief on every surface, not only near lights." get:EngGet("gfx_cl_use_bump_always", 1) set:EngSet("gfx_cl_use_bump_always", Recreate)];
	[p toggle:@"Specular highlights" detail:@"Shine from the sun on metal, wet and glossy surfaces." get:EngGet("gfx_specular", 1) set:EngSet("gfx_specular", Live)];
	[p toggle:@"Point-light highlights" detail:@"Shine from lamps and fire." get:EngGet("gfx_point_specular", 1) set:EngSet("gfx_point_specular", Live)];

	[p section:@"World"];
	[p popup:@"Fog" detail:@"Dynamic fog is computed per pixel and moves with the weather." items:@[ @"Off", @"Per vertex", @"Dynamic" ] values:@[ @0, @1, @2 ]
		get:EngGet("gfx_fog", 0) set:EngSet("gfx_fog", Live)];
	[p toggle:@"Decals" detail:@"Bullet holes, scorch marks and blood on surfaces." get:EngGet("gfx_decals", 1) set:EngSet("gfx_decals", Live)];
	[p toggle:@"Particles" detail:@"Smoke, sparks, dust and debris." get:EngGet("gfx_particles", 1) set:EngSet("gfx_particles", Live)];
	[p toggle:@"Weather effects" detail:@"Rain and snow." get:EngGet("game_showweathereffect", 1) set:EngSet("game_showweathereffect", Live)];

	[p section:@"Textures"];
	[p toggle:@"HD textures" detail:@"Model and world textures upscaled with Real-ESRGAN (built once on this Mac). Interface art keeps its original pixels. Loaded textures and terrain refresh while the mission stays open."
		get:MacGetI(&g_s2.hdTextures) set:MacSetI(&g_s2.hdTextures)];
	[p popup:@"Terrain detail" detail:@"Resolution the ground is baked at near the camera. The original 256 blurs the ground tiles; 1024 shows them at full source detail. Applies as the ground is re-baked (move the camera, or load a map)."
		items:@[ @"256 (original)", @"512", @"1024" ] values:@[ @256, @512, @1024 ] get:MacGetI(&g_s2.terrainDetail) set:MacSetI(&g_s2.terrainDetail)];
	[p popup:@"Texture detail ⟳" detail:@"Full uses every texture at its original size." items:@[ @"Full", @"Half", @"Quarter" ] values:@[ @0, @1, @2 ]
		get:EngGet("gfx_texture_mip", 0) set:EngSet("gfx_texture_mip", Recreate)];
	[p toggle:@"Texture compression ⟳" detail:@"The game's original DXT compressed textures. Off decompresses them (more memory, no visible gain on most)." get:EngGet("gfx_texture_usedxt", 1) set:EngSet("gfx_texture_usedxt", Recreate)];
	[p toggle:@"16-bit textures ⟳" detail:@"Lower colour depth. Off for quality." get:EngGet("gfx_16bit_textures", 0) set:EngSet("gfx_16bit_textures", Recreate)];
	[p popup:@"Anisotropic filtering" detail:@"Keeps oblique surfaces sharper. Overrides filtered, mipmapped reads; point-sampled textures are preserved. Performance depends on the scene."
		items:@[ @"As the game sets it", @"2×", @"4×", @"8×", @"16×" ] values:@[ @0, @2, @4, @8, @16 ]
		get:MacGetI(&g_s2.anisoOverride) set:MacSetI(&g_s2.anisoOverride)];
	[p slider:@"Texture sharpness (LOD bias)" detail:@"Negative picks sharper mip levels; too low shimmers." min:-2 max:1 format:Signed
		get:MacGetF(&g_s2.lodBias) set:MacSetF(&g_s2.lodBias)];
	s2collectVisualControls = false;
}

// ---- Image
- (void)buildImage:(S2Page *)p
{
	s2collectVisualControls = true;
	[p section:@"Colour"];
	[p slider:@"Gamma" detail:@"The game's own gamma ramp." min:0.5 max:2 format:Plain2 get:EngGet("gfx_gamma", 1) set:EngSet("gfx_gamma", Live)];
	[p slider:@"Brightness" detail:@"Lifts or lowers every pixel by the same amount, after the game's own gamma." min:-0.25 max:0.25 format:Signed get:MacGetF(&g_s2.brightness) set:MacSetF(&g_s2.brightness)];
	[p slider:@"Contrast" detail:@"Pushes darks and lights apart around mid grey. 1× leaves the picture as it is." min:0.5 max:1.5 format:Times get:MacGetF(&g_s2.contrast) set:MacSetF(&g_s2.contrast)];
	[p slider:@"Saturation" detail:@"0 is black and white." min:0 max:2 format:Percent get:MacGetF(&g_s2.saturation) set:MacSetF(&g_s2.saturation)];
	[p slider:@"Vibrance" detail:@"Saturates dull colours more than vivid ones; skin stays natural." min:-1 max:1 format:Signed get:MacGetF(&g_s2.vibrance) set:MacSetF(&g_s2.vibrance)];
	[p slider:@"Temperature" detail:@"Cool blue to warm amber." min:-1 max:1 format:Signed get:MacGetF(&g_s2.temperature) set:MacSetF(&g_s2.temperature)];
	[p slider:@"Tint" detail:@"Green to magenta." min:-1 max:1 format:Signed get:MacGetF(&g_s2.tint) set:MacSetF(&g_s2.tint)];
	[p section:@"Lens"];
	[p slider:@"Vignette" detail:@"Darkens the corners." min:0 max:1 format:Percent get:MacGetF(&g_s2.vignette) set:MacSetF(&g_s2.vignette)];
	[p slider:@"Film grain" detail:@"Fine random noise over the picture, different every frame, like film stock." min:0 max:1 format:Percent get:MacGetF(&g_s2.grain) set:MacSetF(&g_s2.grain)];
	[p section:@"Looks"];
	auto look = [](float b, float c, float s, float vib, float t, float tn, float vig, float g) {
		return ^{ g_s2.brightness = b; g_s2.contrast = c; g_s2.saturation = s; g_s2.vibrance = vib; g_s2.temperature = t; g_s2.tint = tn; g_s2.vignette = vig; g_s2.grain = g;
			SaveMac(); for (S2Row *r in s2allRows) [r refresh]; };
	};
	[p buttons:@[ @"Original", @"Vivid", @"1944 newsreel", @"Cinematic", @"Night ops" ] title:@"Apply a look" detail:@"Starting points for the sliders above."
		actions:@[ look(0, 1, 1, 0, 0, 0, 0, 0), look(0, 1.08f, 1.1f, 0.35f, 0.05f, 0, 0.1f, 0), look(0.02f, 1.2f, 0, 0, 0.15f, 0, 0.45f, 0.5f),
			look(-0.02f, 1.12f, 0.9f, 0.2f, 0.25f, 0.05f, 0.35f, 0.12f), look(-0.04f, 1.1f, 0.6f, 0, -0.6f, -0.1f, 0.3f, 0.08f) ]];
	s2collectVisualControls = false;
}

// ---- Audio
- (void)buildAudio:(S2Page *)p
{
	[p section:@"Volume"];
	[p slider:@"Master" detail:@"Everything the game plays." min:0 max:1 format:Percent get:MacGetF(&g_s2.masterVolume) set:MacSetF(&g_s2.masterVolume)];
	[p slider:@"Effects" detail:@"Weapons, footsteps, voices and ambience." min:0 max:1 format:Percent get:EngGet("sound_sfxvolume", 0.75f) set:EngSet("sound_sfxvolume", Live)];
	[p slider:@"Music" detail:@"The game's own music volume. 0 is silent." min:0 max:1 format:Percent get:EngGet("sound_musicvolume", 0.75f) set:EngSet("sound_musicvolume", Live)];
	[p toggle:@"Mute in the background" detail:@"Silence while another app is in front." get:MacGetI(&g_s2.muteInBackground) set:MacSetI(&g_s2.muteInBackground)];
	[p section:@"Voices"];
	[p toggle:@"Character responses" detail:@"Soldiers answer orders out loud." get:EngGet("ui_charresponses", 1) set:EngSet("ui_charresponses", Live)];
	[p toggle:@"Response subtitles" detail:@"Prints the words of a soldier's spoken reply on screen." get:EngGet("ui_charresponsessubtitles", 1) set:EngSet("ui_charresponsessubtitles", Live)];
}

// ---- Camera and input
- (void)buildCamera:(S2Page *)p
{
	auto camSet = [](float *f) { return ^(float v) { *f = v; SaveMac(); cameraLimitsPending = true; }; };
	auto camGet = [](float *f) { return ^float { return *f; }; };
	[p section:@"Mission camera"];
	[p note:@"These apply when a map loads: start or load a mission to see them."];
	[p buttons:@[ @"Stock", @"Wider", @"Unlocked" ] title:@"Camera presets" detail:@"Unlocked zooms far out, close in and almost to the horizon."
		actions:@[ ^{ cam = kStockCamera; SaveMac(); cameraLimitsPending = true; for (S2Row *r in s2allRows) [r refresh]; },
			^{ cam.fov = 40; cam.minRod = 7; cam.maxRod = 90; cam.minPitch = -1.45f; cam.maxPitch = -0.55f; SaveMac(); cameraLimitsPending = true; for (S2Row *r in s2allRows) [r refresh]; },
			^{ cam.fov = 45; cam.minRod = 4; cam.maxRod = 160; cam.minPitch = -1.55f; cam.maxPitch = -0.12f; cam.softLimits = 0; SaveMac(); cameraLimitsPending = true; for (S2Row *r in s2allRows) [r refresh]; } ]];
	[p slider:@"Field of view" detail:@"How wide the mission camera sees, in degrees. Wider shows more of the map and bends the edges more. The game's default is 35°." min:20 max:75 format:Degrees get:camGet(&cam.fov) set:camSet(&cam.fov)];
	[p slider:@"Closest zoom" detail:@"Distance from the camera to the point it looks at." min:2 max:30 format:Plain1 get:camGet(&cam.minRod) set:camSet(&cam.minRod)];
	[p slider:@"Farthest zoom" detail:@"How far the camera can pull back from the point it looks at. Higher fits more of the map on screen." min:30 max:200 format:Plain1 get:camGet(&cam.maxRod) set:camSet(&cam.maxRod)];
	[p slider:@"Steepest angle" detail:@"Degrees below the horizon when looking straight down." min:-1.57f max:-0.8f format:PitchDeg get:camGet(&cam.minPitch) set:camSet(&cam.minPitch)];
	[p slider:@"Flattest angle" detail:@"Lower values let the camera look towards the horizon." min:-1.0f max:-0.05f format:PitchDeg get:camGet(&cam.maxPitch) set:camSet(&cam.maxPitch)];
	[p toggle:@"Ease back from the limits" detail:@"The stock camera springs back inside a softer range after zooming to the edge."
		get:^float { return (float)cam.softLimits; } set:^(float v) { cam.softLimits = v != 0; SaveMac(); cameraLimitsPending = true; }];
	[p slider:@"Zoom speed" detail:@"How far one wheel notch, two-finger swipe or zoom key moves the camera." min:0.05f max:1.5f format:Plain2 get:camGet(&cam.zoomSpeed) set:camSet(&cam.zoomSpeed)];
	[p slider:@"Tilt speed" detail:@"How fast the camera tilts up and down (Control with the arrow keys, or a right-drag)." min:1 max:15 format:Plain1 get:camGet(&cam.pitchSpeed) set:camSet(&cam.pitchSpeed)];
	[p slider:@"Rotation speed" detail:@"How fast the camera turns around the point it looks at (Control with the arrow keys, or a right-drag)." min:0.3f max:5 format:Plain2 get:camGet(&cam.yawSpeed) set:camSet(&cam.yawSpeed)];
	[p slider:@"Scroll speed" detail:@"Panning with the keys or the screen edge." min:0.3f max:5 format:Plain2 get:camGet(&cam.scrollSpeed) set:camSet(&cam.scrollSpeed)];
	[p toggle:@"Camera follows units" detail:@"Tracks the acting soldier or enemy." get:EngGet("ui_followcamera", 1) set:EngSet("ui_followcamera", Live)];

	[p section:@"Mouse and trackpad"];
	[p slider:@"Camera sensitivity" detail:@"How fast the camera rotates, tilts and zooms, with the mouse and the keys." min:0.1f max:3 format:Times get:EngGet("game_camerasensivity", 1) set:EngSet("game_camerasensivity", Camera)];
	[p slider:@"Scroll sensitivity" detail:@"How fast the camera pans with the arrow keys and middle-drag." min:0.1f max:3 format:Times get:EngGet("game_scrollsensivity", 1) set:EngSet("game_scrollsensivity", Camera)];
	[p slider:@"Selection sensitivity" detail:@"How far the mouse moves before a click becomes a drag-select." min:0.1f max:3 format:Times get:EngGet("game_selectionsensivity", 1) set:EngSet("game_selectionsensivity", Camera)];
	[p slider:@"Wheel and trackpad zoom" detail:@"Multiplier on scroll-wheel and two-finger scrolling." min:0.25f max:4 format:Times get:MacGetF(&g_s2.scrollScale) set:MacSetF(&g_s2.scrollScale)];
	[p toggle:@"Invert rotation" detail:@"Reverses which way the camera turns when you rotate it." get:EngGet("game_invertturnx", 0) set:EngSet("game_invertturnx", Camera)];
	[p toggle:@"Invert tilt" detail:@"Reverses which way the camera tilts." get:EngGet("game_invertturny", 0) set:EngSet("game_invertturny", Camera)];
	[p toggle:@"Invert forward and back panning" detail:@"Reverses panning up and down the map. (The game stores this as its horizontal invert: the original wired the two the other way round.)" get:EngGet("game_invertscrollx", 0) set:EngSet("game_invertscrollx", Camera)];
	[p toggle:@"Invert left and right panning" detail:@"Reverses panning sideways. (Stored as the game's vertical invert, for the same reason.)" get:EngGet("game_invertscrolly", 0) set:EngSet("game_invertscrolly", Camera)];
	[p toggle:@"Control-click is a right click" detail:@"For one-button trackpads." get:MacGetI(&g_s2.ctrlClickRight) set:MacSetI(&g_s2.ctrlClickRight)];
	[p toggle:@"System cursor" detail:@"The game's cursor drawn by macOS instead of the game. Lower latency." get:EngGet("ui_hwcursor", 0) set:EngSet("ui_hwcursor", Live)];
}

// ---- Gameplay
- (void)buildGameplay:(S2Page *)p
{
	[p section:@"Turns and movement"];
	[p popup:@"Enemy and ally turns" detail:@"Plays the other sides' turns faster. They decide and move exactly as at 1×: the world runs the same steps, more of them a second. Your turns and real time stay at normal speed. F2 in the game cycles it."
		items:@[ @"1× (original)", @"2×", @"3×", @"4×" ] values:@[ @1, @2, @3, @4 ]
		get:^float { return (float)S2AITurnSpeed(); } set:^(float v) { S2SetAITurnSpeed((int)v); }];
	[p toggle:@"Always turn-based" detail:@"Every encounter in turn-based mode, also when no enemy is in sight." get:EngGet("game_forceturnbased", 0) set:EngSet("game_forceturnbased", Live)];
	[p toggle:@"Turn-based when an enemy is spotted" detail:@"Normally turns start only once you and an enemy see each other. On: they start the moment you see one, before it has seen you." get:EngGet("game_tbs_on_enemy_spot", 0) set:EngSet("game_tbs_on_enemy_spot", Live)];
	[p toggle:@"Turn-based on grenades" detail:@"Switch to turns when a grenade is thrown." get:EngGet("game_eq_on_grenades", 0) set:EngSet("game_eq_on_grenades", Live)];
	[p toggle:@"Show the path in real time" detail:@"Draws the route before you order a move outside turns." get:EngGet("game_pathinrealtime", 1) set:EngSet("game_pathinrealtime", Live)];
	[p toggle:@"Double-click to move in real time" detail:@"Off: in real time a click sends the soldier straight away and a double-click makes them run. On: a click only plans the route and a double-click walks it." get:EngGet("game_dblclkmoveinrealtime", 0) set:EngSet("game_dblclkmoveinrealtime", Live)];
	[p popup:@"Selection highlight" detail:@"How selected soldiers, enemies and objects are marked. Original: the game's highlight and colours. Tint: a flat colour wash over the unit, with a second palette. None: no highlight at all." items:@[ @"Original", @"Tint", @"None" ] values:@[ @0, @1, @2 ]
		get:EngGet("game_selectionmode", 0) set:EngSet("game_selectionmode", Live)];
	[p toggle:@"Autosaves" detail:@"Saves automatically when a mission begins and ends (the AutoSave slots). Off: nothing is saved unless you save." get:EngGet("game_autosaves", 1) set:EngSet("game_autosaves", Live)];

	[p section:@"Interface"];
	[p toggle:@"Hints" detail:@"The lightbulb icons that explain a game rule the first time it comes up." get:EngGet("ui_showhints", 1) set:EngSet("ui_showhints", Live)];
	[p toggle:@"Tooltips" detail:@"Text that appears when the pointer rests on a button, item or soldier." get:EngGet("ui_showtooltips", 1) set:EngSet("ui_showtooltips", Live)];
	[p toggle:@"Compare weapons on hover" detail:@"A gun's tooltip shows it against the one in that soldier's hands: every stat, the skills each gun uses and the ammo carried, then the game's own hit chance for that soldier (skills, perks, wounds, pose, familiarity, weather) at ranges 10, 25 and 45 in snap, aimed and burst fire, as damage per AP. Cover and target size are left out. Hold Shift for every stat."
		get:MacGetI(&g_s2.weaponCompare) set:MacSetI(&g_s2.weaponCompare)];
	[p slider:@"Tooltip delay" detail:@"How long the pointer must rest before a tooltip appears." min:0 max:0.3f format:^NSString *(float v) { return [NSString stringWithFormat:@"%.1f s", v * 10]; }
		get:EngGet("ui_tooltipdelay", 0.1f) set:EngSet("ui_tooltipdelay", Live)];
	[p toggle:@"Status icons" detail:@"Icons over soldiers' heads." get:EngGet("ui_showicons", 1) set:EngSet("ui_showicons", Live)];
	[p toggle:@"Message log" detail:@"Combat messages on screen." get:EngGet("ui_messages", 1) set:EngSet("ui_messages", Live)];
	[p toggle:@"Skip intro videos" detail:@"Straight to the main menu at launch." get:EngGet("game_skipvideo", 0) set:EngSet("game_skipvideo", Live)];

	[p section:@"Physics (bodies falling, being thrown by blasts, dragged)"];
	auto physSet = [](int *v) { return ^(float x) { *v = (int)lroundf(x); SaveMac(); physicsPending = true; }; };
	auto physSetF = [](float *v) { return ^(float x) { *v = x; SaveMac(); physicsPending = true; }; };
	[p buttons:@[ @"Original", @"Smooth", @"Cinematic" ] title:@"Physics presets"
		detail:@"Original is the 2003 simulation (20 steps a second). Smooth runs it at 60 with twice the solver work. Cinematic runs at 120 with joint limits on: no rubber limbs, bodies settle naturally."
		actions:@[ ^{ g_s2.physRate = 20; g_s2.physIterations = 5; g_s2.physJointLimits = 0; g_s2.physFriction = 0.6f; g_s2.physStiffness = 1; SaveMac(); physicsPending = true; for (S2Row *r in s2allRows) [r refresh]; },
			^{ g_s2.physRate = 60; g_s2.physIterations = 10; g_s2.physJointLimits = 0; g_s2.physFriction = 0.6f; g_s2.physStiffness = 1; SaveMac(); physicsPending = true; for (S2Row *r in s2allRows) [r refresh]; },
			^{ g_s2.physRate = 120; g_s2.physIterations = 16; g_s2.physJointLimits = 1; g_s2.physFriction = 0.6f; g_s2.physStiffness = 1; SaveMac(); physicsPending = true; for (S2Row *r in s2allRows) [r refresh]; } ]];
	[p popup:@"Simulation rate" detail:@"Steps per second. Higher is smoother motion and fewer limbs through walls; the cost is tiny on Apple silicon."
		items:@[ @"20 (original)", @"30", @"60", @"120", @"240" ] values:@[ @20, @30, @60, @120, @240 ]
		get:MacGetI(&g_s2.physRate) set:physSet(&g_s2.physRate)];
	[p popup:@"Solver iterations" detail:@"How many times each step enforces the skeleton's joints. More keeps bodies from stretching."
		items:@[ @"5 (original)", @"10", @"16", @"24" ] values:@[ @5, @10, @16, @24 ]
		get:MacGetI(&g_s2.physIterations) set:physSet(&g_s2.physIterations)];
	[p toggle:@"Extra joint limits" detail:@"Four more joint-angle limits the developers left off (knees and elbows stop bending backwards). Switches on between missions."
		get:MacGetI(&g_s2.physJointLimits) set:physSet(&g_s2.physJointLimits)];
	[p slider:@"Ground friction" detail:@"How quickly bodies stop sliding. 60% is the original." min:0.2 max:0.95 format:Percent get:MacGetF(&g_s2.physFriction) set:physSetF(&g_s2.physFriction)];
	[p slider:@"Skeleton stiffness" detail:@"Below 100% bodies go softer and floppier." min:0.3 max:1 format:Percent get:MacGetF(&g_s2.physStiffness) set:physSetF(&g_s2.physStiffness)];

	[p section:@"Violence"];
	[p toggle:@"Blood" detail:@"Blood from hits and wounds. Headshot decapitations need it." get:EngGet("cheat_blood", 1) set:EngSet("cheat_blood", Live)];
	[p toggle:@"Headshot decapitations" detail:@"Critical head hits behead (needs blood)." get:EngGet("cheat_allow_headshot", 1) set:EngSet("cheat_allow_headshot", Live)];
}

// ---- Cheats
- (void)buildCheats:(S2Page *)p
{
	[p note:@"The developers' own cheats, still in the game. Each one you turn on stays on: mission cheats switch on again when the next mission starts. Saved games keep no record of them."];
	[p section:@"Squad"];
	for (const Cheat &c : Cheats())
	{
		if (!c.mission && !strcmp(c.var, "cheat_golden_shot")) [p section:@"World"];
		std::string var = c.var;
		[p toggle:c.title detail:c.detail
			get:^float { NSNumber *n = cheatWanted[@(var.c_str())]; return n ? n.floatValue : (S2EngineHas(var.c_str()) ? (S2EngineGet(var.c_str()) > 0 ? 1 : 0) : 0); }
			set:^(float v) { cheatWanted[@(var.c_str())] = @(v); SaveMac(); if (S2EngineHas(var.c_str())) S2EngineSet(var.c_str(), v); }];
	}
	[p section:@"Instant"];
	[p buttons:@[ @"Level 5", @"Level 10", @"Level 20" ] title:@"Set squad level" detail:@"Sets every soldier in your squad to that experience level (in a mission)."
		actions:@[ ^{ S2EngineCommand("setxplevel 5"); }, ^{ S2EngineCommand("setxplevel 10"); }, ^{ S2EngineCommand("setxplevel 20"); } ]];
	[p buttons:@[ @"Unlock" ] title:@"Developer console" detail:@"Unlocks the in-game console (the key below Esc). Type help for every command."
		actions:@[ ^{ S2EngineCommand("wirbelwind"); } ]];
}

// ---- Advanced
- (void)buildAdvanced:(S2Page *)p
{
	[p section:@"Renderer"];
	[p popup:@"Hidden-surface removal" detail:@"Skips drawing what walls hide. Dynamic is the game's default." items:@[ @"Off", @"Fast", @"Dynamic" ] values:@[ @0, @1, @2 ]
		get:EngGet("gfx_hsr", 2) set:EngSet("gfx_hsr", Live)];
	[p toggle:@"Fastest mode ⟳" detail:@"The game's lowest path: no shadows or cached lighting." get:EngGet("gfx_fastest", 0) set:EngSet("gfx_fastest", Recreate)];
	[p toggle:@"Stencil shadows" detail:@"An unfinished alternative shadow path left in the engine. Expect artefacts." get:EngGet("gfx_stencil_shadows", 0) set:EngSet("gfx_stencil_shadows", Live)];
	[p toggle:@"Pixel shaders off ⟳" detail:@"The DirectX 7-class fixed-function path, as on 2003 cards without shaders." get:EngGet("gfx_nopixelshaders", 0) set:EngSet("gfx_nopixelshaders", Recreate)];
	[p buttons:@[ @"Restart renderer" ] title:@"Restart the renderer" detail:@"Rebuilds the device and every render target now."
		actions:@[ ^{ S2EngineCommand("gfx_recreate"); } ]];

	[p section:@"Files"];
	[p buttons:@[ @"Show in Finder" ] title:@"Game folder" detail:@(S2GameDirectory())
		actions:@[ ^{ [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:@(S2GameDirectory())]]; } ]];
	[p buttons:@[ @"Clear" ] title:@"Shader cache" detail:@"Compiled Metal pipelines, rebuilt in the background on the next launch."
		actions:@[ ^{
			NSString *c = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"org.silentstorm.mac"];
			[NSFileManager.defaultManager removeItemAtPath:c error:nil];
		} ]];
	[p toggle:@"Console log file" detail:@"Writes the console to a log in the game folder." get:EngGet("console_writelog", 0) set:EngSet("console_writelog", Live)];

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

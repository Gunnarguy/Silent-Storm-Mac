// In-game keyboard sheet (F1 or Cmd-/), the one-key Original / Enhanced switch (F9 or Cmd-G) and the turn speed (F2).
//
// The sheet is read from the game's own bind file each time it opens (cfg/input.cfg), so an
// edited bind shows as it is. F1 and F9 are bound to nothing in the game's shipped file (checked 2026-11-02: the
// function keys used are F5 to F8 and F10; F2 is free too), so taking them changes no game control. The sheet is drawn by AppKit into an
// image on a layer above the game's Metal layer, the way the FPS overlay sits there; the game's frame is not touched.
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <QuartzCore/QuartzCore.h>
#include <algorithm>
#include <map>
#include <string>
#include <vector>

const char *S2ConfigPath(const char *base);
bool S2OriginalGraphics();
void S2ToggleGraphics();
void S2CycleAITurnSpeed();

namespace
{
CALayer *s2helpHost;
CALayer *s2help;
CATextLayer *s2notice;
CGSize s2helpLastHost;

std::string Trim(const std::string &s)
{
	size_t a = s.find_first_not_of(" \t\r"), b = s.find_last_not_of(" \t\r");
	return a == std::string::npos ? std::string() : s.substr(a, b - a + 1);
}

// command (without +, - or !) -> each binding as its list of key names
std::map<std::string, std::vector<std::vector<std::string>>> ReadBinds()
{
	std::map<std::string, std::vector<std::vector<std::string>>> binds;
	std::string path = S2ConfigPath("input.cfg");
	std::replace(path.begin(), path.end(), '\\', '/');
	if (path.rfind("./", 0) == 0) path = path.substr(2);
	FILE *f = fopen(path.c_str(), "rb");
	if (!f) return binds;
	char line[512];
	std::string section;
	while (fgets(line, sizeof line, f))
	{
		std::string s = Trim(line);
		if (s.rfind("bindsection", 0) == 0) { section = Trim(s.substr(11)); continue; }
		if (s.rfind("bind ", 0) != 0 || section == "mapeditor" || section == "dummy") continue;
		s = Trim(s.substr(5));
		size_t q = s.find('\'');
		if (q == std::string::npos) continue;
		std::string command = Trim(s.substr(0, q));
		while (!command.empty() && (command[0] == '+' || command[0] == '-' || command[0] == '!')) command.erase(0, 1);
		std::vector<std::string> keys;
		for (size_t p = q; (p = s.find('\'', p)) != std::string::npos;)
		{
			size_t e = s.find('\'', p + 1);
			if (e == std::string::npos) break;
			keys.push_back(s.substr(p + 1, e - p - 1));
			p = e + 1;
		}
		if (!keys.empty()) binds[command].push_back(keys);
	}
	fclose(f);
	return binds;
}

// what a MacBook keyboard uses for a key it does not have, as macwindow.mm's laptop table gives it
std::string LaptopName(const std::string &k)
{
	static const std::map<std::string, std::string> laptop = {
		{ "NUM_1", "⌘1" }, { "NUM_2", "⌘2" }, { "NUM_3", "⌘3" }, { "NUM_4", "⌘4" }, { "NUM_5", "⌘5" }, { "NUM_6", "⌘6" },
		{ "NUM_7", "⌘7" }, { "NUM_8", "⌘8" }, { "NUM_9", "⌘9" }, { "NUM_PLUS", "⌘↑" }, { "NUM_MINUS", "⌘↓" }, { "HOME", "⌘←" },
		{ "PG_UP", "⌘=" }, { "PG_DOWN", "⌘−" }, { "F5", "⌘S" }, { "F6", "⌘⇧S" }, { "F7", "⌘O" }, { "F8", "⌘L" }, { "PAUSE", "⌘P" },
		{ "F10", "fn F10" }, { "SYSRQ", "F13" }, { "SCROLL", "F14" },
	};
	auto i = laptop.find(k);
	return i == laptop.end() ? std::string() : i->second;
}

std::string KeyName(const std::string &k)
{
	static const std::map<std::string, std::string> names = {
		{ "LSHIFT", "⇧" }, { "RSHIFT", "⇧" }, { "LCTRL", "⌃" }, { "RCTRL", "⌃" }, { "LALT", "⌥" }, { "RALT", "⌥" },
		{ "UP", "↑" }, { "DOWN", "↓" }, { "LEFT", "←" }, { "RIGHT", "→" }, { "PG_UP", "Page Up" }, { "PG_DOWN", "Page Down" },
		{ "SPACE", "Space" }, { "ENTER", "Return" }, { "ESC", "Esc" }, { "TAB", "Tab" }, { "HOME", "Home" }, { "DELETE", "Delete" },
		{ "SCROLL", "Scroll Lock" }, { "SYSRQ", "Print Screen" }, { "PAUSE", "Pause" }, { "NUM_PLUS", "Num +" }, { "NUM_MINUS", "Num −" },
		{ "MOUSE_BUTTON0", "Click" }, { "`", "` (backtick)" }, { "MOUSE_BUTTON1", "Right-click" }, { "MOUSE_BUTTON2", "Middle-click" }, { "MOUSE_AXIS_Z", "Wheel" },
	};
	auto i = names.find(k);
	if (i != names.end()) return i->second;
	if (k.rfind("NUM_", 0) == 0) return "Num " + k.substr(4);
	return k;
}

// one binding as the player reads it: modifiers first, a button held with mouse movement is a drag
std::string Chord(const std::vector<std::string> &keys)
{
	bool axis = false;
	for (const std::string &k : keys) if (k == "MOUSE_AXIS_X" || k == "MOUSE_AXIS_Y") axis = true;
	std::string mods, rest, buttons;
	for (const std::string &k : keys)
	{
		if (k == "MOUSE_AXIS_X" || k == "MOUSE_AXIS_Y") continue;
		if (axis && (k == "MOUSE_BUTTON0" || k == "MOUSE_BUTTON1" || k == "MOUSE_BUTTON2"))
		{
			buttons += (buttons.empty() ? "" : "+") + std::string(k == "MOUSE_BUTTON0" ? "Left" : k == "MOUSE_BUTTON1" ? "Right" : "Middle");
			continue;
		}
		std::string n = KeyName(k);
		if (n == "⇧" || n == "⌃" || n == "⌥") mods += n;
		else rest += (rest.empty() ? "" : " ") + n;
	}
	if (!buttons.empty()) rest += (rest.empty() ? "" : " ") + buttons + "-drag";
	// a single key the laptop lacks: its Command pair first, the original after it
	if (keys.size() == 1 && !LaptopName(keys[0]).empty())
		return LaptopName(keys[0]).rfind("fn ", 0) == 0 ? LaptopName(keys[0]) : LaptopName(keys[0]) + " (" + KeyName(keys[0]) + ")";
	if (rest.empty()) return axis ? "" : mods;   // a bare mouse axis is the pointer itself, not a shortcut
	return mods + rest;
}

std::string KeysFor(const std::map<std::string, std::vector<std::vector<std::string>>> &binds, std::initializer_list<const char *> commands)
{
	std::vector<std::string> out;
	for (const char *c : commands)
	{
		auto i = binds.find(c);
		if (i == binds.end()) continue;
		for (const auto &b : i->second)
		{
			std::string chord = Chord(b);
			if (!chord.empty() && std::find(out.begin(), out.end(), chord) == out.end()) out.push_back(chord);
		}
	}
	for (const char *mod : { "", "⇧", "⌃", "⌥" })
	{
		std::vector<std::string> arrows;
		for (const char *a : { "↑", "↓", "←", "→" }) arrows.push_back(std::string(mod) + a);
		bool all = std::all_of(arrows.begin(), arrows.end(), [&](const std::string &a) { return std::find(out.begin(), out.end(), a) != out.end(); });
		if (!all) continue;
		auto at = std::find(out.begin(), out.end(), arrows[0]);
		*at = std::string(mod) + "Arrow keys";
		for (size_t i = 1; i < arrows.size(); ++i) out.erase(std::find(out.begin(), out.end(), arrows[i]));
	}
	std::string s;
	for (const std::string &k : out) s += (s.empty() ? "" : ", ") + k;
	return s;
}

struct Row { std::string label, keys; };
struct Group { std::string title; std::vector<Row> rows; };

std::vector<Group> BuildGroups()
{
	auto b = ReadBinds();
	auto row = [&](std::vector<Row> &rows, const char *label, std::initializer_list<const char *> commands)
	{
		std::string k = KeysFor(b, commands);
		if (!k.empty()) rows.push_back({ label, k });
	};
	std::vector<Group> g(7);
	g[0].title = "Squad";
	row(g[0].rows, "Select soldier 1 to 7", { "hero_1" });
	if (!g[0].rows.empty()) g[0].rows.back().keys = "1 to 7";
	row(g[0].rows, "Next soldier", { "hero_next" });
	row(g[0].rows, "Previous soldier", { "hero_prev" });
	row(g[0].rows, "Select the whole squad", { "select_all_units" });
	row(g[0].rows, "Centre on the soldier", { "focus_unit" });
	row(g[0].rows, "Next visible enemy", { "nextenemy" });
	row(g[0].rows, "Show items on the ground", { "showitems", "alt" });
	g[1].title = "Orders";
	row(g[1].rows, "Move", { "move" });
	row(g[1].rows, "Attack, use, first aid, mine", { "attack", "firstaid", "usetool", "setmine", "dropcorpse" });
	row(g[1].rows, "Turn in place", { "unit_rotate" });
	row(g[1].rows, "Hide", { "hide" });
	row(g[1].rows, "Reload", { "weapon_reload" });
	row(g[1].rows, "Next hand slot", { "slot_next" });
	row(g[1].rows, "Run", { "pose_run" });
	row(g[1].rows, "Stand", { "pose_normal" });
	row(g[1].rows, "Crouch", { "pose_crouch" });
	row(g[1].rows, "Prone", { "pose_crawl" });
	row(g[1].rows, "Strafe", { "pose_strafe" });
	g[2].title = "Shooting";
	row(g[2].rows, "Snap shot", { "weapon_snapshot" });
	row(g[2].rows, "Aimed shot", { "weapon_aimedshot" });
	row(g[2].rows, "Careful shot", { "weapon_carefulshot" });
	row(g[2].rows, "Short burst", { "weapon_shortburst" });
	row(g[2].rows, "Long burst", { "weapon_longburst" });
	row(g[2].rows, "Snipe shot", { "weapon_snipeshot" });
	row(g[2].rows, "Previous / next fire mode", { "weapon_prevmode", "weapon_nextmode" });
	row(g[2].rows, "Aim: head", { "hitlocation_head" });
	row(g[2].rows, "Aim: body", { "hitlocation_body" });
	row(g[2].rows, "Aim: arms", { "hitlocation_larm", "hitlocation_rarm" });
	row(g[2].rows, "Aim: legs", { "hitlocation_lleg", "hitlocation_rleg" });
	g[3].title = "Turns and panels";
	row(g[3].rows, "Start / end turn", { "startofturn", "endofturn" });
	row(g[3].rows, "Next (dialogue, script)", { "next", "skipScriptPart" });
	row(g[3].rows, "Skip the cutscene", { "skipScript" });
	row(g[3].rows, "Inventory", { "inventory" });
	row(g[3].rows, "Character", { "character" });
	row(g[3].rows, "Objectives", { "objectives" });
	row(g[3].rows, "Journal / clues", { "clues" });
	row(g[3].rows, "Pause", { "pause" });
	g[4].title = "Camera";
	row(g[4].rows, "Move", { "camera_forward", "camera_strafe" });
	row(g[4].rows, "Rotate and tilt", { "camera_rotate", "camera_pitch" });
	row(g[4].rows, "Zoom", { "camera_zoom" });
	row(g[4].rows, "Floor up / down", { "next_floor", "prev_floor" });
	row(g[4].rows, "Cut floor", { "floor_slider" });
	g[5].title = "Game";
	row(g[5].rows, "Quick save", { "save" });
	row(g[5].rows, "Quick load", { "load" });
	row(g[5].rows, "Save menu", { "savemenu" });
	row(g[5].rows, "Load menu", { "loadmenu", "loadgame" });
	row(g[5].rows, "Game menu", { "gamemenu" });
	row(g[5].rows, "Console", { "console" });
	row(g[5].rows, "Screenshot", { "screenshot" });
	row(g[5].rows, "Particles on / off", { "switch_particles" });
	g[6].title = "Mac";
	g[6].rows = {
		{ "This sheet", "F1, ⌘/" },
		{ "Original / Enhanced", "F9, ⌘G" },
		{ "Enemy and ally turn speed", "F2, ⌘T" },
		{ "Settings", "⌘," },
		{ "Full screen", "⌘F" },
		{ "Right-click", "⌃Click" },
		{ "Zoom on a trackpad", "Two fingers" },
		{ "Quit", "⌘Q" },
	};
	g.erase(std::remove_if(g.begin(), g.end(), [](const Group &x) { return x.rows.empty(); }), g.end());
	return g;
}

NSAttributedString *Column(const std::vector<Group> &groups, size_t first, size_t last, CGFloat font, CGFloat labelWidth)
{
	NSMutableParagraphStyle *para = [NSMutableParagraphStyle new];
	para.tabStops = @[ [[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft location:labelWidth options:@{}] ];
	para.lineSpacing = font * 0.18;
	NSMutableParagraphStyle *head = [para mutableCopy];
	head.paragraphSpacingBefore = font * 0.7;
	NSDictionary *title = @{ NSFontAttributeName: [NSFont systemFontOfSize:font * 0.85 weight:NSFontWeightBold],
		NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.96 green:0.74 blue:0.36 alpha:1], NSParagraphStyleAttributeName: head,
		NSKernAttributeName: @(font * 0.06) };
	NSDictionary *label = @{ NSFontAttributeName: [NSFont systemFontOfSize:font], NSForegroundColorAttributeName: [NSColor colorWithWhite:0.86 alpha:1],
		NSParagraphStyleAttributeName: para };
	NSDictionary *keys = @{ NSFontAttributeName: [NSFont systemFontOfSize:font weight:NSFontWeightSemibold], NSForegroundColorAttributeName: NSColor.whiteColor,
		NSParagraphStyleAttributeName: para };
	NSMutableAttributedString *s = [NSMutableAttributedString new];
	for (size_t i = first; i < last; ++i)
	{
		NSString *t = [[NSString stringWithUTF8String:groups[i].title.c_str()] uppercaseString];
		[s appendAttributedString:[[NSAttributedString alloc] initWithString:[(s.length ? @"\n" : @"") stringByAppendingString:t] attributes:title]];
		for (const Row &r : groups[i].rows)
		{
			[s appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"\n%s\t", r.label.c_str()] attributes:label]];
			[s appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithUTF8String:r.keys.c_str()] attributes:keys]];
		}
	}
	return s;
}

size_t RowCount(const Group &g) { return g.rows.size() + 2; }

// The sheet as an image of at most maxSize points, in three columns balanced by row count.
NSBitmapImageRep *RenderSheet(CGSize maxSize, CGFloat scale, size_t *rowsOut)
{
	std::vector<Group> groups = BuildGroups();
	size_t total = 0;
	for (const Group &g : groups) total += RowCount(g);
	if (rowsOut) { *rowsOut = 0; for (const Group &g : groups) *rowsOut += g.rows.size(); }
	// split points: fill each column to a third of the rows, groups never split
	(void)total;
	std::vector<size_t> starts = { 0, groups.size() };
	size_t best = SIZE_MAX;
	for (size_t a = 1; a + 1 < groups.size(); ++a)
		for (size_t b = a + 1; b < groups.size(); ++b)
		{
			size_t c1 = 0, c2 = 0, c3 = 0;
			for (size_t i = 0; i < groups.size(); ++i) (i < a ? c1 : i < b ? c2 : c3) += RowCount(groups[i]);
			size_t tallest = std::max(c1, std::max(c2, c3));
			if (tallest < best) { best = tallest; starts = { 0, a, b, groups.size() }; }
		}
	const char *game = "Silent Storm";
	NSString *subtitle = [NSString stringWithFormat:@"%s · read from %s · ⌘ keys stand in for keys a MacBook lacks · F1, ⌘/ or Esc closes", game,
		"cfg/input.cfg"];
	for (CGFloat font = 15; font >= 8; font -= 0.5)
	{
		const CGFloat labelWidth = font * 14.2, pad = font * 1.6, gap = font * 2.2;
		std::vector<NSAttributedString *> cols;
		CGFloat width = 0, height = 0;
		for (size_t c = 0; c + 1 < starts.size(); ++c)
		{
			NSAttributedString *col = Column(groups, starts[c], starts[c + 1], font, labelWidth);
			NSSize sz = [col boundingRectWithSize:NSMakeSize(4000, 4000) options:NSStringDrawingUsesLineFragmentOrigin].size;
			cols.push_back(col);
			width += ceil(sz.width) + (c ? gap : 0);
			height = std::max(height, ceil(sz.height));
		}
		NSDictionary *titleAttrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:font * 1.45 weight:NSFontWeightBold], NSForegroundColorAttributeName: NSColor.whiteColor };
		NSDictionary *subAttrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:font * 0.85], NSForegroundColorAttributeName: [NSColor colorWithWhite:0.62 alpha:1] };
		NSSize tsz = [@"Keyboard shortcuts" sizeWithAttributes:titleAttrs], ssz = [subtitle sizeWithAttributes:subAttrs];
		const CGFloat header = tsz.height + ssz.height + font * 0.4;
		width = std::max(width, std::max(tsz.width, ssz.width)) + pad * 2;
		height += header + pad * 2;
		if ((width > maxSize.width || height > maxSize.height) && font > 8) continue;
		NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr pixelsWide:(NSInteger)ceil(width * scale) pixelsHigh:(NSInteger)ceil(height * scale)
			bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
		rep.size = NSMakeSize(width, height);
		[NSGraphicsContext saveGraphicsState];
		NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
		NSBezierPath *box = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0.5, 0.5, width - 1, height - 1) xRadius:font * 0.9 yRadius:font * 0.9];
		[[NSColor colorWithSRGBRed:0.06 green:0.07 blue:0.08 alpha:0.9] setFill];
		[box fill];
		[[NSColor colorWithWhite:1 alpha:0.14] setStroke];
		[box stroke];
		[@"Keyboard shortcuts" drawAtPoint:NSMakePoint(pad, height - pad - tsz.height) withAttributes:titleAttrs];
		[subtitle drawAtPoint:NSMakePoint(pad, height - pad - tsz.height - ssz.height) withAttributes:subAttrs];
		CGFloat x = pad;
		for (NSAttributedString *col : cols)
		{
			NSSize sz = [col boundingRectWithSize:NSMakeSize(4000, 4000) options:NSStringDrawingUsesLineFragmentOrigin].size;
			[col drawWithRect:NSMakeRect(x, height - pad - header - ceil(sz.height), ceil(sz.width), ceil(sz.height)) options:NSStringDrawingUsesLineFragmentOrigin];
			x += ceil(sz.width) + gap;
		}
		[NSGraphicsContext restoreGraphicsState];
		return rep;
	}
	return nil;
}

CGFloat HostScale() { return s2helpHost.contentsScale > 0 ? s2helpHost.contentsScale : NSScreen.mainScreen.backingScaleFactor; }

void PlaceSheet()
{
	if (!s2help || s2help.hidden) return;
	CGSize host = s2helpHost.bounds.size;
	NSBitmapImageRep *rep = RenderSheet(CGSizeMake(host.width * 0.94, host.height * 0.9), HostScale(), nullptr);
	if (!rep) return;
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	s2help.contents = (__bridge id)rep.CGImage;
	s2help.contentsScale = HostScale();
	s2help.frame = CGRectMake(floor((host.width - rep.size.width) / 2), floor((host.height - rep.size.height) / 2), rep.size.width, rep.size.height);
	[CATransaction commit];
	s2helpLastHost = host;
}
} // namespace

void S2KeyHelpAttach(void *metalLayer)
{
	s2helpHost = (__bridge CALayer *)metalLayer;
	s2help = [CALayer layer];
	s2help.hidden = YES;
	s2help.zPosition = 30;
	[s2helpHost addSublayer:s2help];
	s2notice = [CATextLayer layer];
	s2notice.font = (__bridge CFTypeRef)[NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
	s2notice.fontSize = 15;
	s2notice.alignmentMode = kCAAlignmentCenter;
	s2notice.foregroundColor = CGColorCreateGenericRGB(1, 1, 1, 1);
	s2notice.backgroundColor = CGColorCreateGenericRGB(0.06, 0.07, 0.08, 0.86);
	s2notice.cornerRadius = 8;
	s2notice.contentsScale = HostScale();
	s2notice.opacity = 0;
	s2notice.zPosition = 31;
	[s2helpHost addSublayer:s2notice];
}

bool S2KeyHelpVisible() { return s2help && !s2help.hidden; }

void S2KeyHelpToggle()
{
	if (!s2help) return;
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	s2help.hidden = !s2help.hidden;
	[CATransaction commit];
	PlaceSheet();
	fprintf(stderr, "[keyhelp] %s\n", s2help.hidden ? "closed" : "open");
}

// called every frame: keeps the sheet centred and fitted when the window changes size
void S2KeyHelpTick()
{
	if (S2KeyHelpVisible() && !CGSizeEqualToSize(s2helpHost.bounds.size, s2helpLastHost)) PlaceSheet();
}

// A two-second line at the top of the game window
void S2KeyHelpNotice(const char *utf8)
{
	if (!s2notice) return;
	NSString *text = [NSString stringWithFormat:@"  %@  ", [NSString stringWithUTF8String:utf8]];
	NSSize sz = [text sizeWithAttributes:@{ NSFontAttributeName: [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold] }];
	CGSize host = s2helpHost.bounds.size;
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	s2notice.string = text;
	CGFloat w = ceil(sz.width) + 16, h = ceil(sz.height) + 12;
	s2notice.frame = CGRectMake(floor((host.width - w) / 2), s2helpHost.geometryFlipped ? 56 : host.height - h - 56, w, h);
	[s2notice removeAllAnimations];
	s2notice.opacity = 0;
	[CATransaction commit];
	CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
	fade.values = @[ @1, @1, @0 ];
	fade.keyTimes = @[ @0, @0.75, @1 ];
	fade.duration = 2.0;
	[s2notice addAnimation:fade forKey:@"notice"];
}

// Switches Original / Enhanced and says which one is coming, since the change takes a moment to appear
void S2ToggleGraphicsWithNotice()
{
	S2ToggleGraphics();
	fprintf(stderr, "[keyhelp] graphics switch: %s\n", S2OriginalGraphics() ? "original" : "enhanced");
	S2KeyHelpNotice(S2OriginalGraphics() ? "Original graphics: the 2003 look" : "Enhanced graphics");
}

// F1 and F9 belong to the Mac layer; Esc closes an open sheet. Returns true when the key was used here.
bool S2KeyHelpKey(unsigned short keyCode, bool down)
{
	if (keyCode == kVK_F1) { if (down) S2KeyHelpToggle(); return true; }
	if (keyCode == kVK_F9) { if (down) S2ToggleGraphicsWithNotice(); return true; }
	if (keyCode == kVK_F2) { if (down) S2CycleAITurnSpeed(); return true; }
	if (keyCode == kVK_Escape && S2KeyHelpVisible()) { if (down) S2KeyHelpToggle(); return true; }
	return false;
}

// test hook: writes the sheet as it would draw on a window of w x h points, and its row count
void S2KeyHelpWriteImage(const char *path, int w, int h)
{
	size_t rows = 0;
	NSBitmapImageRep *rep = RenderSheet(CGSizeMake(w * 0.94, h * 0.9), 2, &rows);
	NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
	[png writeToFile:[NSString stringWithUTF8String:path] atomically:YES];
	fprintf(stderr, "[keyhelp] wrote %s: %d rows, %.0f x %.0f points, for a %d x %d window\n", path, (int)rows, rep.size.width, rep.size.height, w, h);
}

// macwindow.mm: the game window, event loop, cursor, clipboard and DirectInput 8 for macOS.
// Replaces Game/WinFrame.cpp (NWinFrame) and feeds DirectInput's buffered keyboard/mouse data from AppKit,
// so the engine's input code (Input/Input.cpp) runs unchanged.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <Carbon/Carbon.h>   // kVK_* key codes, UCKeyTranslate
#import <GameController/GameController.h>
#include <map>
#include "s2win32.h"
#include "s2win32ui.h"
#include "s2com.h"
#include "win/dinput.h"
#include "s2platform.h"
#include "s2settings.h"
#include "s2engine.h"
typedef long long int64;   // Misc/Tools.h: typedef __int64 int64
#include "Game/WinFrame.h"
#include <vector>
#include <deque>
#include <string>
#include <mutex>
#include "s2mousemotion.h"

using namespace NWinFrame;

// ---------------------------------------------------------------------------------------------------
// key tables: macOS virtual key code -> DirectInput scan code and Windows virtual key
struct S2KeyMap { unsigned short mac; BYTE dik; BYTE vk; };
static const S2KeyMap s2Keys[] = {
	{ kVK_Escape, DIK_ESCAPE, VK_ESCAPE }, { kVK_ANSI_1, DIK_1, '1' }, { kVK_ANSI_2, DIK_2, '2' }, { kVK_ANSI_3, DIK_3, '3' },
	{ kVK_ANSI_4, DIK_4, '4' }, { kVK_ANSI_5, DIK_5, '5' }, { kVK_ANSI_6, DIK_6, '6' }, { kVK_ANSI_7, DIK_7, '7' },
	{ kVK_ANSI_8, DIK_8, '8' }, { kVK_ANSI_9, DIK_9, '9' }, { kVK_ANSI_0, DIK_0, '0' }, { kVK_ANSI_Minus, DIK_MINUS, 0xBD },
	{ kVK_ANSI_Equal, DIK_EQUALS, 0xBB }, { kVK_Delete, DIK_BACK, VK_BACK }, { kVK_Tab, DIK_TAB, VK_TAB },
	{ kVK_ANSI_Q, DIK_Q, 'Q' }, { kVK_ANSI_W, DIK_W, 'W' }, { kVK_ANSI_E, DIK_E, 'E' }, { kVK_ANSI_R, DIK_R, 'R' },
	{ kVK_ANSI_T, DIK_T, 'T' }, { kVK_ANSI_Y, DIK_Y, 'Y' }, { kVK_ANSI_U, DIK_U, 'U' }, { kVK_ANSI_I, DIK_I, 'I' },
	{ kVK_ANSI_O, DIK_O, 'O' }, { kVK_ANSI_P, DIK_P, 'P' }, { kVK_ANSI_LeftBracket, DIK_LBRACKET, 0xDB },
	{ kVK_ANSI_RightBracket, DIK_RBRACKET, 0xDD }, { kVK_Return, DIK_RETURN, VK_RETURN }, { kVK_Control, DIK_LCONTROL, VK_CONTROL },
	{ kVK_ANSI_A, DIK_A, 'A' }, { kVK_ANSI_S, DIK_S, 'S' }, { kVK_ANSI_D, DIK_D, 'D' }, { kVK_ANSI_F, DIK_F, 'F' },
	{ kVK_ANSI_G, DIK_G, 'G' }, { kVK_ANSI_H, DIK_H, 'H' }, { kVK_ANSI_J, DIK_J, 'J' }, { kVK_ANSI_K, DIK_K, 'K' },
	{ kVK_ANSI_L, DIK_L, 'L' }, { kVK_ANSI_Semicolon, DIK_SEMICOLON, 0xBA }, { kVK_ANSI_Quote, DIK_APOSTROPHE, 0xDE },
	{ kVK_ANSI_Grave, DIK_GRAVE, 0xC0 }, { kVK_Shift, DIK_LSHIFT, VK_SHIFT }, { kVK_ANSI_Backslash, DIK_BACKSLASH, 0xDC },
	{ kVK_ANSI_Z, DIK_Z, 'Z' }, { kVK_ANSI_X, DIK_X, 'X' }, { kVK_ANSI_C, DIK_C, 'C' }, { kVK_ANSI_V, DIK_V, 'V' },
	{ kVK_ANSI_B, DIK_B, 'B' }, { kVK_ANSI_N, DIK_N, 'N' }, { kVK_ANSI_M, DIK_M, 'M' }, { kVK_ANSI_Comma, DIK_COMMA, 0xBC },
	{ kVK_ANSI_Period, DIK_PERIOD, 0xBE }, { kVK_ANSI_Slash, DIK_SLASH, 0xBF }, { kVK_RightShift, DIK_RSHIFT, VK_SHIFT },
	{ kVK_ANSI_KeypadMultiply, DIK_MULTIPLY, VK_MULTIPLY }, { kVK_Option, DIK_LMENU, VK_MENU }, { kVK_Space, DIK_SPACE, VK_SPACE },
	{ kVK_CapsLock, DIK_CAPITAL, VK_CAPITAL }, { kVK_F1, DIK_F1, VK_F1 }, { kVK_F2, DIK_F2, VK_F1 + 1 }, { kVK_F3, DIK_F3, VK_F1 + 2 },
	{ kVK_F4, DIK_F4, VK_F1 + 3 }, { kVK_F5, DIK_F5, VK_F1 + 4 }, { kVK_F6, DIK_F6, VK_F1 + 5 }, { kVK_F7, DIK_F7, VK_F1 + 6 },
	{ kVK_F8, DIK_F8, VK_F1 + 7 }, { kVK_F9, DIK_F9, VK_F1 + 8 }, { kVK_F10, DIK_F10, VK_F1 + 9 }, { kVK_ANSI_KeypadClear, DIK_NUMLOCK, VK_NUMLOCK },
	{ kVK_ANSI_Keypad7, DIK_NUMPAD7, VK_NUMPAD0 + 7 }, { kVK_ANSI_Keypad8, DIK_NUMPAD8, VK_NUMPAD0 + 8 }, { kVK_ANSI_Keypad9, DIK_NUMPAD9, VK_NUMPAD0 + 9 },
	{ kVK_ANSI_KeypadMinus, DIK_SUBTRACT, VK_SUBTRACT }, { kVK_ANSI_Keypad4, DIK_NUMPAD4, VK_NUMPAD0 + 4 }, { kVK_ANSI_Keypad5, DIK_NUMPAD5, VK_NUMPAD0 + 5 },
	{ kVK_ANSI_Keypad6, DIK_NUMPAD6, VK_NUMPAD0 + 6 }, { kVK_ANSI_KeypadPlus, DIK_ADD, VK_ADD }, { kVK_ANSI_Keypad1, DIK_NUMPAD1, VK_NUMPAD0 + 1 },
	{ kVK_ANSI_Keypad2, DIK_NUMPAD2, VK_NUMPAD0 + 2 }, { kVK_ANSI_Keypad3, DIK_NUMPAD3, VK_NUMPAD0 + 3 }, { kVK_ANSI_Keypad0, DIK_NUMPAD0, VK_NUMPAD0 },
	{ kVK_ANSI_KeypadDecimal, DIK_DECIMAL, VK_DECIMAL }, { kVK_F11, DIK_F11, VK_F1 + 10 }, { kVK_F12, DIK_F12, VK_F12 },
	{ kVK_F13, DIK_SYSRQ, VK_SNAPSHOT },   // Mac keyboards have no Print Screen; F13 takes the screenshot binding
	{ kVK_F14, DIK_SCROLL, VK_SCROLL },    // and F14 the Scroll Lock (show fps) binding
	{ kVK_F15, DIK_PAUSE, VK_PAUSE },
	{ kVK_ANSI_KeypadEnter, DIK_NUMPADENTER, VK_RETURN }, { kVK_RightControl, DIK_RCONTROL, VK_CONTROL }, { kVK_ANSI_KeypadDivide, DIK_DIVIDE, VK_DIVIDE },
	{ kVK_RightOption, DIK_RMENU, VK_MENU }, { kVK_Home, DIK_HOME, VK_HOME }, { kVK_UpArrow, DIK_UP, VK_UP }, { kVK_PageUp, DIK_PRIOR, VK_PRIOR },
	{ kVK_LeftArrow, DIK_LEFT, VK_LEFT }, { kVK_RightArrow, DIK_RIGHT, VK_RIGHT }, { kVK_End, DIK_END, VK_END }, { kVK_DownArrow, DIK_DOWN, VK_DOWN },
	{ kVK_PageDown, DIK_NEXT, VK_NEXT }, { kVK_Help, DIK_INSERT, VK_INSERT }, { kVK_ForwardDelete, DIK_DELETE, VK_DELETE },
	{ kVK_Command, DIK_LWIN, VK_LWIN }, { kVK_RightCommand, DIK_RWIN, VK_RWIN }, { kVK_ANSI_KeypadEquals, DIK_NUMPADEQUALS, 0 },
};
static const S2KeyMap *S2FindMac(unsigned short code) { for (const S2KeyMap &k : s2Keys) if (k.mac == code) return &k; return nullptr; }

// Laptop shortcuts: Command plus a key stands for a key a MacBook does not have, or has only behind fn. The game never sees
// Command (it is in no table above), so these reach it as the plain original key and need no change to its bind file;
// the original keys work as before. keyhelp.mm shows the same pairs on the F1 sheet.
struct S2LaptopKey { unsigned short mac; bool shift; unsigned short as; };
static const S2LaptopKey s2LaptopKeys[] = {
	{ kVK_ANSI_1, false, kVK_ANSI_Keypad1 }, { kVK_ANSI_2, false, kVK_ANSI_Keypad2 }, { kVK_ANSI_3, false, kVK_ANSI_Keypad3 },
	{ kVK_ANSI_4, false, kVK_ANSI_Keypad4 }, { kVK_ANSI_5, false, kVK_ANSI_Keypad5 }, { kVK_ANSI_6, false, kVK_ANSI_Keypad6 },
	{ kVK_ANSI_7, false, kVK_ANSI_Keypad7 }, { kVK_ANSI_8, false, kVK_ANSI_Keypad8 }, { kVK_ANSI_9, false, kVK_ANSI_Keypad9 },
	{ kVK_UpArrow, false, kVK_ANSI_KeypadPlus }, { kVK_DownArrow, false, kVK_ANSI_KeypadMinus },   // floor up and down
	{ kVK_LeftArrow, false, kVK_Home },                                                          // centre on the soldier
	{ kVK_ANSI_Equal, false, kVK_PageUp }, { kVK_ANSI_Minus, false, kVK_PageDown },                // zoom in and out
	{ kVK_ANSI_S, true, kVK_F6 }, { kVK_ANSI_S, false, kVK_F5 }, { kVK_ANSI_L, false, kVK_F8 },    // save menu, quick save, quick load
	{ kVK_ANSI_O, false, kVK_F7 }, { kVK_ANSI_P, false, kVK_F15 },                                 // load menu, pause
};
static const S2LaptopKey *S2FindLaptopKey(NSEvent *e)
{
	if (!(e.modifierFlags & NSEventModifierFlagCommand)) return nullptr;
	bool shift = (e.modifierFlags & NSEventModifierFlagShift) != 0;
	for (const S2LaptopKey &k : s2LaptopKeys) if (k.mac == e.keyCode && k.shift == shift) return &k;
	return nullptr;
}
static std::map<unsigned short, unsigned short> s2laptopHeld;
// iCommonUI.cpp: Shift held while a gun's tooltip shows lists every stat in its comparison (S2_COMPARE_ALL for tests)
bool S2WeaponCompareAll() { static const bool bTest = getenv("S2_COMPARE_ALL") != nullptr; return bTest || (NSEvent.modifierFlags & NSEventModifierFlagShift) != 0; }   // the physical key -> the key the game was given
static const S2KeyMap *S2FindVK(UINT vk) { for (const S2KeyMap &k : s2Keys) if (k.vk == vk) return &k; return nullptr; }

// ---------------------------------------------------------------------------------------------------
// shared input state
struct S2DIEvent { DWORD ofs, data, time, seq; };
static struct S2Input
{
	std::mutex m;
	BYTE keys[256] = {};          // DirectInput keyboard state, 0x80 = down
	BYTE vkDown[256] = {};        // Windows virtual-key state
	LONG mouseAbs[3] = {};        // accumulated mouse axes (DirectInput absolute axis mode)
	BYTE mouseButtons[8] = {};
	std::deque<S2DIEvent> keyEvents, mouseEvents;
	DWORD seq = 0;
} s2in;
static S2MouseMotion s2motion;

static bool s2testCursor;          // scripted input owns the pointer position until real mouse movement
static POINT s2testCursorClient;

static void S2PushKey(BYTE dik, bool down)
{
	std::lock_guard<std::mutex> l(s2in.m);
	if (((s2in.keys[dik] & 0x80) != 0) == down) return;
	s2in.keys[dik] = down ? 0x80 : 0;
	s2in.keyEvents.push_back({ dik, (DWORD)(down ? 0x80 : 0), GetTickCount(), ++s2in.seq });
	if (s2in.keyEvents.size() > 1024) s2in.keyEvents.pop_front();
}
static void S2PushMouseAxis(int axis, LONG delta)
{
	if (!delta) return;
	std::lock_guard<std::mutex> l(s2in.m);
	s2in.mouseAbs[axis] += delta;
	s2in.mouseEvents.push_back({ (DWORD)(axis * 4), (DWORD)s2in.mouseAbs[axis], GetTickCount(), ++s2in.seq });
	if (s2in.mouseEvents.size() > 1024) s2in.mouseEvents.pop_front();
}
static void S2PushMouseButton(int b, bool down)
{
	std::lock_guard<std::mutex> l(s2in.m);
	if (((s2in.mouseButtons[b] & 0x80) != 0) == down) return;
	s2in.mouseButtons[b] = down ? 0x80 : 0;
	s2in.mouseEvents.push_back({ (DWORD)(12 + b), (DWORD)(down ? 0x80 : 0), GetTickCount(), ++s2in.seq });
}

// ---------------------------------------------------------------------------------------------------
// window state
struct S2Window
{
	NSWindow *window = nil;
	NSView *view = nil;
	CAMetalLayer *layer = nil;
	int clientW = 100, clientH = 100;   // client size in game pixels (the back buffer)
	bool sized = false;                 // the first mode has set the window's size
	DWORD style = 0, exStyle = 0;
	LONG_PTR userData = 0;
	bool visible = false;
};
static S2Window *s2main;
static volatile bool s2exit, s2active = true;
static HCURSOR s2cursor;
static bool s2cursorShown = true;
static bool s2cursorReleased = false;  // Escape/focus loss restores the system pointer until the next click
static NSCursor *S2CurrentNSCursor();   // the engine's cursor, or a blank one while the engine hides it
void S2RequestQuit();
static std::mutex s2msgLock;
static std::deque<SWindowsMsg> s2msgs;

static void S2AddMsg(SWindowsMsg::EMsg msg, int x, int y, DWORD flags)
{
	SWindowsMsg m = {};
	NHPTimer::GetTime(&m.time);
	m.msg = msg; m.x = x; m.y = y; m.dwFlags = flags;
	std::lock_guard<std::mutex> l(s2msgLock);
	s2msgs.push_back(m);
}

static void S2ReleaseInput();

// view point (bottom-left origin, points) -> client pixel (top-left origin, back-buffer pixels)
static NSPoint S2ToClient(S2Window *w, NSPoint p)
{
	NSSize sz = w->view.bounds.size;
	double x, y, cw, ch;
	S2ContentRect(sz.width, sz.height, w->clientW, w->clientH, &x, &y, &cw, &ch);
	double fy = sz.height - p.y;   // top-left origin
	return NSMakePoint((p.x - x) * w->clientW / std::max(1.0, cw), (fy - y) * w->clientH / std::max(1.0, ch));
}

static void S2ReleaseInput()
{
	for (int i = 0; i < 256; ++i) if (s2in.keys[i]) S2PushKey((BYTE)i, false);
	for (const S2KeyMap &key : s2Keys)
		if (key.vk && s2in.vkDown[key.vk]) S2AddMsg(SWindowsMsg::KEY_UP, key.vk, 1, key.dik);
	memset(s2in.vkDown, 0, sizeof s2in.vkDown);
	NSPoint p = s2main ? S2ToClient(s2main, [s2main->view convertPoint:[s2main->window mouseLocationOutsideOfEventStream] fromView:nil]) : NSZeroPoint;
	for (int i = 0; i < 8; ++i)
	{
		if (!s2in.mouseButtons[i]) continue;
		S2PushMouseButton(i, false);
		if (i < 2) S2AddMsg(i ? SWindowsMsg::RB_UP : SWindowsMsg::LB_UP, (int)p.x, (int)p.y, 0);
	}
	s2motion.reset();
	s2cursorReleased = true;
	[NSCursor.arrowCursor set];
}

// Answers the first click even when the game window is not focused, for example straight after using Settings.
@interface S2GraphicsSelector : NSSegmentedControl
@end
@implementation S2GraphicsSelector
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
@end

@interface S2GameView : NSView
@property (strong) NSSegmentedControl *graphicsSelector;
@end
@implementation S2GameView
- (instancetype)initWithFrame:(NSRect)frame
{
	self = [super initWithFrame:frame];
	if (self)
	{
		self.graphicsSelector = [S2GraphicsSelector segmentedControlWithLabels:@[@"Original", @"Enhanced"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(s2GraphicsChanged:)];
		self.graphicsSelector.selectedSegment = S2OriginalGraphics() ? 0 : 1;
		// always the dark look: over this game's dark frames the system's light look draws "Original" black on black
		self.graphicsSelector.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
		self.graphicsSelector.toolTip = @"Switch between the original 2003 look and your enhanced graphics (F9 or ⌘G). Your mission stays loaded. F1 shows every key.";
		[self.graphicsSelector setAccessibilityLabel:@"Original or enhanced graphics"];
		self.graphicsSelector.wantsLayer = YES;
		[self addSubview:self.graphicsSelector];
		[self s2LayoutGraphicsSelector];
	}
	return self;
}
- (void)s2LayoutGraphicsSelector
{
	[self.graphicsSelector sizeToFit];
	NSSize size = self.graphicsSelector.frame.size;
	self.graphicsSelector.frame = NSMakeRect(std::max(8.0, self.bounds.size.width - size.width - 12), self.bounds.size.height - size.height - 12, size.width, size.height);
}
- (void)s2GraphicsChanged:(NSSegmentedControl *)sender
{
	S2SetOriginalGraphics(sender.selectedSegment == 0);
	[self.window makeFirstResponder:self];
}
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)canBecomeKeyView { return YES; }
- (BOOL)wantsUpdateLayer { return YES; }
- (CALayer *)makeBackingLayer
{
	CAMetalLayer *l = [CAMetalLayer layer];
	l.device = MTLCreateSystemDefaultDevice();
	l.pixelFormat = MTLPixelFormatBGRA8Unorm;
	l.framebufferOnly = NO;   // screenshots read the drawable back
	l.contentsScale = 1.0;
	l.magnificationFilter = kCAFilterLinear;
	l.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
	return l;
}
- (void)s2UpdateDrawable
{
	CAMetalLayer *l = (CAMetalLayer*)self.layer;
	CGFloat scale = self.window ? self.window.backingScaleFactor : NSScreen.mainScreen.backingScaleFactor;
	l.contentsScale = scale;
	NSSize sz = self.bounds.size;
	if (sz.width > 0 && sz.height > 0) l.drawableSize = CGSizeMake(sz.width * scale, sz.height * scale);
}
- (void)setFrameSize:(NSSize)s { [super setFrameSize:s]; [self s2UpdateDrawable]; [self s2LayoutGraphicsSelector]; }
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; [self s2UpdateDrawable]; }
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; [self s2UpdateDrawable]; }
- (void)updateTrackingAreas
{
	for (NSTrackingArea *a in self.trackingAreas) [self removeTrackingArea:a];
	[self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect | NSTrackingCursorUpdate | NSTrackingMouseEnteredAndExited owner:self userInfo:nil]];
	[super updateTrackingAreas];
}
// the pointer is hidden by showing a blank cursor over the game view only, so the Settings window and the menu bar
// always keep a visible pointer
- (void)cursorUpdate:(NSEvent *)e { [S2CurrentNSCursor() set]; }
- (void)mouseExited:(NSEvent *)e { [NSCursor.arrowCursor set]; }
- (void)s2mouse:(NSEvent *)e msg:(SWindowsMsg::EMsg)msg
{
	NSPoint p = S2ToClient(s2main, [self convertPoint:e.locationInWindow fromView:nil]);
	S2AddMsg(msg, (int)p.x, (int)p.y, 0);
}
- (void)s2delta:(NSEvent *)e
{
	if (!self.window.isKeyWindow || !NSApp.isActive) return;
	// Camera sensitivity follows physical AppKit motion, independent of render
	// resolution, Retina scale, window size and MetalFX quality.
	S2PushMouseAxis(0, (LONG)s2motion.add(0, e.deltaX));
	S2PushMouseAxis(1, (LONG)s2motion.add(1, e.deltaY));
}
- (void)mouseMoved:(NSEvent *)e { s2testCursor = false; [self s2delta:e]; [self s2mouse:e msg:SWindowsMsg::MOUSE_MOVE]; }
- (void)mouseDragged:(NSEvent *)e { [self mouseMoved:e]; }
- (void)rightMouseDragged:(NSEvent *)e { [self mouseMoved:e]; }
- (void)otherMouseDragged:(NSEvent *)e { [self mouseMoved:e]; }
- (void)mouseDown:(NSEvent *)e
{
	s2cursorReleased = false;
	s2motion.reset();
	[S2CurrentNSCursor() set];
	// ctrl-click is the macOS right click; keep it for one-button trackpads
	if (g_s2.ctrlClickRight && (e.modifierFlags & NSEventModifierFlagControl)) { [self rightMouseDown:e]; return; }
	S2PushMouseButton(0, true); [self s2mouse:e msg:SWindowsMsg::LB_DOWN];
}
- (void)mouseUp:(NSEvent *)e
{
	if (s2in.mouseButtons[1] && !s2in.mouseButtons[0]) { [self rightMouseUp:e]; return; }
	S2PushMouseButton(0, false); [self s2mouse:e msg:SWindowsMsg::LB_UP];
}
- (void)rightMouseDown:(NSEvent *)e { s2cursorReleased = false; s2motion.reset(); [S2CurrentNSCursor() set]; S2PushMouseButton(1, true); [self s2mouse:e msg:SWindowsMsg::RB_DOWN]; }
- (void)rightMouseUp:(NSEvent *)e { S2PushMouseButton(1, false); [self s2mouse:e msg:SWindowsMsg::RB_UP]; }
- (void)otherMouseDown:(NSEvent *)e { s2cursorReleased = false; s2motion.reset(); [S2CurrentNSCursor() set]; if (e.buttonNumber < 8) S2PushMouseButton((int)e.buttonNumber, true); }
- (void)otherMouseUp:(NSEvent *)e { if (e.buttonNumber < 8) S2PushMouseButton((int)e.buttonNumber, false); }
- (void)scrollWheel:(NSEvent *)e
{
	// macOS keeps sending scroll events after the fingers lift; they zoomed on by themselves long after the gesture
	if (e.momentumPhase != NSEventPhaseNone) return;
	// one wheel notch is 120 units on Windows; precise trackpad deltas are scaled to match
	double d = (e.hasPreciseScrollingDeltas ? e.scrollingDeltaY * 4.0 : e.scrollingDeltaY * 120.0) * g_s2.scrollScale;
	S2PushMouseAxis(2, (LONG)s2motion.add(2, d));
}
- (void)s2key:(NSEvent *)e down:(bool)down
{
	const S2KeyMap *k = S2FindMac(e.keyCode);
	if (!k) return;
	S2PushKey(k->dik, down);
	if (k->vk) s2in.vkDown[k->vk] = down ? 0x80 : 0;
	if (k->vk) S2AddMsg(down ? SWindowsMsg::KEY_DOWN : SWindowsMsg::KEY_UP, k->vk, e.isARepeat ? 1 : 1, k->dik | (e.isARepeat ? 0x4000 : 0));
	if (down && !(e.modifierFlags & NSEventModifierFlagCommand))
	{
		NSString *chars = e.characters;
		for (NSUInteger i = 0; i < chars.length; ++i)
		{
			unichar c = [chars characterAtIndex:i];
			if (c >= 0xF700 && c <= 0xF8FF) continue;   // function-key private-use codes
			if (c == 0x7F) c = 8;                        // Delete key sends DEL; Windows sends backspace
			if (c == 3) c = 13;                          // keypad Enter
			S2AddMsg(SWindowsMsg::CHAR, c, 1, k->dik);
		}
	}
}
- (void)s2laptopKey:(unsigned short)code down:(bool)down
{
	const S2KeyMap *k = S2FindMac(code);
	if (!k) return;
	if (down && getenv("S2_HEADLESS")) fprintf(stderr, "[laptop-key] game key %u\n", (unsigned)k->dik);
	S2PushKey(k->dik, down);
	if (k->vk) s2in.vkDown[k->vk] = down ? 0x80 : 0;
	if (k->vk) S2AddMsg(down ? SWindowsMsg::KEY_DOWN : SWindowsMsg::KEY_UP, k->vk, 1, k->dik);
}
- (void)keyDown:(NSEvent *)e
{
	if (e.modifierFlags & NSEventModifierFlagCommand)
	{
		if ([e.charactersIgnoringModifiers isEqualToString:@"t"]) { if (!e.isARepeat) S2CycleAITurnSpeed(); return; }
		if (const S2LaptopKey *k = S2FindLaptopKey(e))
		{
			if (!e.isARepeat) { s2laptopHeld[e.keyCode] = k->as; [self s2laptopKey:k->as down:true]; }
			return;
		}
	}
	if ((e.modifierFlags & NSEventModifierFlagCommand) && [e.charactersIgnoringModifiers isEqualToString:@"q"]) { S2RequestQuit(); return; }
	if ((e.modifierFlags & NSEventModifierFlagCommand) && [e.charactersIgnoringModifiers isEqualToString:@"f"]) { [self.window toggleFullScreen:nil]; return; }
	if (S2KeyHelpKey(e.keyCode, true)) return;
	if (e.keyCode == kVK_Escape) S2ReleaseInput();
	[self s2key:e down:true];
}
- (void)keyUp:(NSEvent *)e
{
	auto held = s2laptopHeld.find(e.keyCode);   // released after Command, the key still ends what it started
	if (held != s2laptopHeld.end()) { [self s2laptopKey:held->second down:false]; s2laptopHeld.erase(held); return; }
	if (!S2KeyHelpKey(e.keyCode, false)) [self s2key:e down:false];
}
- (void)flagsChanged:(NSEvent *)e
{
	const S2KeyMap *k = S2FindMac(e.keyCode);
	if (!k) return;
	NSEventModifierFlags f = e.modifierFlags;
	bool down;
	switch (e.keyCode)
	{
	case kVK_Shift: case kVK_RightShift: down = (f & NSEventModifierFlagShift) != 0; break;
	case kVK_Control: case kVK_RightControl: down = (f & NSEventModifierFlagControl) != 0; break;
	case kVK_Option: case kVK_RightOption: down = (f & NSEventModifierFlagOption) != 0; break;
	case kVK_Command: case kVK_RightCommand: down = (f & NSEventModifierFlagCommand) != 0; break;
	case kVK_CapsLock: down = (f & NSEventModifierFlagCapsLock) != 0; break;
	default: return;
	}
	S2PushKey(k->dik, down);
	if (k->vk) { s2in.vkDown[k->vk] = down ? 0x80 : 0; S2AddMsg(down ? SWindowsMsg::KEY_DOWN : SWindowsMsg::KEY_UP, k->vk, 1, k->dik); }
}
@end

@interface S2WindowDelegate : NSObject <NSWindowDelegate>
@end
@implementation S2WindowDelegate
- (BOOL)windowShouldClose:(NSWindow *)w { S2RequestQuit(); return NO; }
// keep the engine's gfx_fullscreen in step with the green button and Cmd-F, so a renderer restart keeps the mode
- (void)windowDidEnterFullScreen:(NSNotification *)n { if (S2EngineHas("gfx_fullscreen")) S2EngineSet("gfx_fullscreen", 1); }
- (void)windowDidExitFullScreen:(NSNotification *)n { if (S2EngineHas("gfx_fullscreen")) S2EngineSet("gfx_fullscreen", 0); }
- (void)windowDidBecomeKey:(NSNotification *)n { s2active = true; }
- (void)windowDidResignKey:(NSNotification *)n
{
	s2active = false;
	S2ReleaseInput();
}
@end
static S2WindowDelegate *s2delegate;

// ---------------------------------------------------------------------------------------------------
// NWinFrame
bool NWinFrame::GetMessage(SWindowsMsg *pRes)
{
	std::lock_guard<std::mutex> l(s2msgLock);
	if (!s2msgs.empty()) { *pRes = s2msgs.front(); s2msgs.pop_front(); return true; }
	pRes->msg = SWindowsMsg::TIME;
	NHPTimer::GetTime(&pRes->time);
	return false;
}
// the game keeps running while its Settings window has focus (changes show live), or always when the user turned
// off pausing in the background
bool NWinFrame::IsAppActive() { return s2active || S2SettingsWindowIsKey() || !g_s2.pauseInBackground; }
bool NWinFrame::IsExit() { return s2exit; }
void NWinFrame::Exit() { S2RequestQuit(); }
HWND NWinFrame::GetWnd() { return (HWND)s2main; }
void NWinFrame::SetCursor(HCURSOR c) { if (s2cursor != c) { s2cursor = c; ::SetCursor(c); } }
void NWinFrame::ShowCursor(bool show)
{
	if (s2cursorShown == show) return;
	s2cursorShown = show;
	NSPoint p = s2main ? [s2main->window mouseLocationOutsideOfEventStream] : NSZeroPoint;
	if (s2main && s2main->window.isVisible && NSPointInRect(p, s2main->view.frame)) [S2CurrentNSCursor() set];
}
void S2RequestQuit() { S2ReleaseInput(); s2exit = true; }
// Test input: lines in "_input.txt" (game folder) are replayed as real input, one step per frame.
//   move X Y | click X Y | rclick X Y | down X Y | up X Y   (client pixels)
//   key NAME | keydown NAME | keyup NAME                   (NAME: esc enter space f1..f12 a..z 0..9 up down left right tab grave)
//   wait N                                                 (frames)
static std::deque<std::string> s2script;
static int s2scriptWait;
static int S2DikByName(const std::string &n)
{
	static const struct { const char *n; int d; } t[] = { { "esc", DIK_ESCAPE }, { "enter", DIK_RETURN }, { "space", DIK_SPACE }, { "tab", DIK_TAB }, { "grave", DIK_GRAVE },
		{ "up", DIK_UP }, { "down", DIK_DOWN }, { "left", DIK_LEFT }, { "right", DIK_RIGHT }, { "backspace", DIK_BACK }, { "lshift", DIK_LSHIFT }, { "lctrl", DIK_LCONTROL },
		{ "f1", DIK_F1 }, { "f2", DIK_F2 }, { "f3", DIK_F3 }, { "f4", DIK_F4 }, { "f5", DIK_F5 }, { "f6", DIK_F6 }, { "f7", DIK_F7 }, { "f8", DIK_F8 }, { "f9", DIK_F9 }, { "f10", DIK_F10 },
		{ "a", DIK_A }, { "b", DIK_B }, { "c", DIK_C }, { "d", DIK_D }, { "e", DIK_E }, { "f", DIK_F }, { "g", DIK_G }, { "h", DIK_H }, { "i", DIK_I }, { "j", DIK_J }, { "k", DIK_K },
		{ "l", DIK_L }, { "m", DIK_M }, { "n", DIK_N }, { "o", DIK_O }, { "p", DIK_P }, { "q", DIK_Q }, { "r", DIK_R }, { "s", DIK_S }, { "t", DIK_T }, { "u", DIK_U }, { "v", DIK_V },
		{ "w", DIK_W }, { "x", DIK_X }, { "y", DIK_Y }, { "z", DIK_Z }, { "1", DIK_1 }, { "2", DIK_2 }, { "3", DIK_3 }, { "4", DIK_4 }, { "5", DIK_5 }, { "0", DIK_0 } };
	for (auto &e : t) if (n == e.n) return e.d;
	return -1;
}
static void S2RunTestInput()
{
	// a plain access() first: this runs every frame in the player's build too
	if (access("_input.txt", F_OK) == 0) if (FILE *f = ::fopen("_input.txt", "rb"))
	{
		char line[256];
		while (fgets(line, sizeof line, f)) { std::string l(line); while (!l.empty() && (l.back() == '\n' || l.back() == '\r')) l.pop_back(); if (!l.empty()) s2script.push_back(l); }
		fclose(f); unlink("_input.txt");
	}
	if (s2scriptWait > 0) { --s2scriptWait; return; }
	if (s2script.empty()) return;
	std::string l = s2script.front(); s2script.pop_front();
	char cmd[32] = {}, arg[64] = {}; int x = 0, y = 0;
	sscanf(l.c_str(), "%31s", cmd);
	std::string c = cmd;
	if (c == "wait") { sscanf(l.c_str(), "%*s %d", &s2scriptWait); return; }
	// a real AppKit key event through the view's own keyDown/keyUp, for the Mac-layer keys (F1, F9, Esc)
	if (c == "mackey")
	{
		sscanf(l.c_str(), "%*s %63s", arg);
		// "cmd+", "shift+" prefixes, then f1, f2, f9, esc, a digit, a letter, up, down, left, =, -
		NSEventModifierFlags mods = 0;
		const char *key = arg;
		for (;;)
		{
			if (!strncmp(key, "cmd+", 4)) { mods |= NSEventModifierFlagCommand; key += 4; }
			else if (!strncmp(key, "shift+", 6)) { mods |= NSEventModifierFlagShift; key += 6; }
			else break;
		}
		static const struct { const char *name; unsigned short code; } names[] = {
			{ "f1", kVK_F1 }, { "f2", kVK_F2 }, { "f9", kVK_F9 }, { "esc", kVK_Escape }, { "up", kVK_UpArrow }, { "down", kVK_DownArrow },
			{ "left", kVK_LeftArrow }, { "=", kVK_ANSI_Equal }, { "-", kVK_ANSI_Minus }, { "s", kVK_ANSI_S }, { "l", kVK_ANSI_L },
			{ "o", kVK_ANSI_O }, { "p", kVK_ANSI_P }, { "t", kVK_ANSI_T }, { "1", kVK_ANSI_1 }, { "3", kVK_ANSI_3 }, { "4", kVK_ANSI_4 },
			{ "5", kVK_ANSI_5 }, { "6", kVK_ANSI_6 }, { "8", kVK_ANSI_8 } };
		unsigned short code = 0xFFFF;
		for (const auto &n : names) if (!strcmp(key, n.name)) code = n.code;
		if (code == 0xFFFF || !s2main) return;
		NSString *chars = strlen(key) == 1 ? [NSString stringWithUTF8String:key] : @"";
		for (NSEventType type : { NSEventTypeKeyDown, NSEventTypeKeyUp })
		{
			NSEvent *e = [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:mods timestamp:0 windowNumber:s2main->window.windowNumber context:nil
				characters:chars charactersIgnoringModifiers:chars isARepeat:NO keyCode:code];
			if (type == NSEventTypeKeyDown) [s2main->view keyDown:e]; else [s2main->view keyUp:e];
		}
		return;
	}
	if (c == "wheel") { sscanf(l.c_str(), "%*s %d", &x); S2PushMouseAxis(2, x); return; }   // raw wheel units, 120 is one notch
	if (c == "key" || c == "keydown" || c == "keyup")
	{
		sscanf(l.c_str(), "%*s %63s", arg);
		int d = S2DikByName(arg); if (d < 0) return;
		const S2KeyMap *k = nullptr; for (const S2KeyMap &m : s2Keys) if (m.dik == d) { k = &m; break; }
		if (c != "keyup") { S2PushKey((BYTE)d, true); if (k && k->vk) { s2in.vkDown[k->vk] = 0x80; S2AddMsg(SWindowsMsg::KEY_DOWN, k->vk, 1, d); } }
		if (c != "keydown") { S2PushKey((BYTE)d, false); if (k && k->vk) { s2in.vkDown[k->vk] = 0; S2AddMsg(SWindowsMsg::KEY_UP, k->vk, 1, d); } }
		if (c == "key" && strlen(arg) == 1) S2AddMsg(SWindowsMsg::CHAR, arg[0], 1, d);
		return;
	}
	sscanf(l.c_str(), "%*s %d %d", &x, &y);
	static int lastX, lastY;
	S2PushMouseAxis(0, x - lastX); S2PushMouseAxis(1, y - lastY); lastX = x; lastY = y;
	S2AddMsg(SWindowsMsg::MOUSE_MOVE, x, y, 0);
	s2testCursor = true; s2testCursorClient = { x, y };
	if (c == "click" || c == "down") { S2PushMouseButton(0, true); S2AddMsg(SWindowsMsg::LB_DOWN, x, y, 0); }
	if (c == "click" || c == "up") { S2PushMouseButton(0, false); S2AddMsg(SWindowsMsg::LB_UP, x, y, 0); }
	if (c == "rclick") { S2PushMouseButton(1, true); S2AddMsg(SWindowsMsg::RB_DOWN, x, y, 0); S2PushMouseButton(1, false); S2AddMsg(SWindowsMsg::RB_UP, x, y, 0); }
}

// test hook: reports the Original / Enhanced control and clicks a segment by sending real AppKit events to this
// window only, so hit testing and tracking run as for a person's click without touching the system pointer
void S2GraphicsSelectorTest(const char *action)
{
	S2GameView *view = (S2GameView*)s2main->view;
	NSSegmentedControl *control = view.graphicsSelector;
	NSWindow *window = view.window;
	if (!strcmp(action, "original") || !strcmp(action, "enhanced"))
	{
		int segment = !strcmp(action, "enhanced") ? 1 : 0;
		NSPoint p = [view convertPoint:NSMakePoint(NSMinX(control.frame) + control.frame.size.width * (segment + 0.5) / 2, NSMidY(control.frame)) toView:nil];
		NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
		NSEvent *(^click)(NSEventType) = ^NSEvent *(NSEventType type)
		{
			return [NSEvent mouseEventWithType:type location:p modifierFlags:0 timestamp:now windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
		};
		[NSApp postEvent:click(NSEventTypeLeftMouseUp) atStart:NO];
		[NSApp sendEvent:click(NSEventTypeLeftMouseDown)];
	}
	if (FILE *out = fopen("_s2out.txt", "ab"))
	{
		NSRect screen = [window convertRectToScreen:[view convertRect:control.frame toView:nil]];
		NSPoint center = [view convertPoint:NSMakePoint(NSMidX(control.frame), NSMidY(control.frame)) toView:nil];
		NSView *hit = [window.contentView.superview hitTest:center];
		fprintf(out, "selector action=%s hitControl=%d hitClass=%s selected=%ld hidden=%d alpha=%g layer=%d key=%d visible=%d window=%g,%g,%g,%g control=%g,%g,%g,%g\n",
			action, hit && [hit isDescendantOf:control] ? 1 : 0, NSStringFromClass(hit.class).UTF8String, (long)control.selectedSegment, control.hiddenOrHasHiddenAncestor ? 1 : 0, control.alphaValue,
			control.layer.superlayer == view.layer ? 1 : 0, window.isKeyWindow ? 1 : 0, window.isVisible ? 1 : 0,
			window.frame.origin.x, window.frame.origin.y, window.frame.size.width, window.frame.size.height, screen.origin.x, screen.origin.y, screen.size.width, screen.size.height);
		fclose(out);
	}
}

void NWinFrame::PumpMessages()
{
	S2RunTestInput();
	@autoreleasepool
	{
		NSEvent *e;
		while ((e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:nil inMode:NSDefaultRunLoopMode dequeue:YES]))
			[NSApp sendEvent:e];
		[NSApp updateWindows];
		S2SettingsTick();
		S2KeyHelpTick();
		((S2GameView*)s2main->view).graphicsSelector.selectedSegment = S2OriginalGraphics() ? 0 : 1;
	}
}
bool NWinFrame::InitApplication(HINSTANCE, const char *pszAppName, const char *pszWndName)
{
	@autoreleasepool
	{
		S2Window *w = new S2Window();
		NSRect r = NSMakeRect(0, 0, 1280, 800);
		w->window = [[NSWindow alloc] initWithContentRect:r styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
		w->window.title = [NSString stringWithUTF8String:pszAppName ? pszAppName : "Silent Storm"];
		w->window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
		w->window.contentAspectRatio = NSMakeSize(16, 10);
		w->window.releasedWhenClosed = NO;
		w->view = [[S2GameView alloc] initWithFrame:r];
		w->view.wantsLayer = YES;
		w->layer = (CAMetalLayer*)w->view.layer;
		S2SettingsAttachOverlay((__bridge void*)w->layer);
		S2KeyHelpAttach((__bridge void*)w->layer);
		w->window.contentView = w->view;
		s2delegate = [S2WindowDelegate new];
		w->window.delegate = s2delegate;
		[w->window center];
		[w->window makeFirstResponder:w->view];
		w->window.acceptsMouseMovedEvents = YES;
		if (getenv("S2_HEADLESS"))
		{
			// automated test runs: the window is never shown; frames are checked through the capture hook
		}
		else if ((getenv("S2_NO_ACTIVATE") || getenv("S2_HEADLESS")))
		{
			// test runs: open behind the user's windows and never take keyboard focus
			[w->window orderBack:nil];
		}
		else
		{
			[w->window makeKeyAndOrderFront:nil];
			[NSApp activate];
		}
		w->visible = true;
		s2main = w;
	}
	return true;
}

// ---------------------------------------------------------------------------------------------------
// Win32 window functions used by Gfx.cpp and Cursor.cpp (operate on the single game window)
static S2Window *S2W(HWND h) { return h ? (S2Window*)h : s2main; }
void *S2GetMetalLayer(HWND h) { S2Window *w = S2W(h); return w ? (__bridge void*)w->layer : nullptr; }
void S2SetBackBufferSize(HWND h, int width, int height)
{
	S2Window *w = S2W(h); if (!w) return;
	w->clientW = width; w->clientH = height;
	if (width > 0 && height > 0) w->window.contentAspectRatio = NSMakeSize(width, height);
	[(S2GameView*)w->view s2UpdateDrawable];
}
WINBOOL SetWindowPos(HWND h, HWND, int, int, int cx, int cy, UINT flags)
{
	S2Window *w = S2W(h); if (!w) return FALSE;
	if (!(flags & SWP_NOSIZE) && cx > 0 && cy > 0)
	{
		S2SetBackBufferSize(h, cx, cy);
		// Only the first mode sizes the window. The engine calls this on every renderer rebuild, so anything later
		// (Original / Enhanced, a ⟳ option) would otherwise shrink and re-centre it, moving the control just clicked.
		// The image is letterboxed into whatever size the window has (S2ContentRect).
		if (!w->sized && !(w->window.styleMask & NSWindowStyleMaskFullScreen))
		{
			// fit the requested size on screen, keeping its aspect ratio
			NSRect vis = w->window.screen.visibleFrame;
			double scale = std::min(1.0, std::min((vis.size.width - 40) / cx, (vis.size.height - 60) / cy));
			[w->window setContentSize:NSMakeSize(floor(cx * scale), floor(cy * scale))];
			[w->window center];
			w->sized = true;
		}
	}
	if ((flags & SWP_SHOWWINDOW) && !(getenv("S2_NO_ACTIVATE") || getenv("S2_HEADLESS"))) [w->window makeKeyAndOrderFront:nil];
	return TRUE;
}
WINBOOL MoveWindow(HWND h, int x, int y, int cx, int cy, BOOL) { return SetWindowPos(h, 0, x, y, cx, cy, 0); }
WINBOOL GetClientRect(HWND h, RECT *r) { S2Window *w = S2W(h); if (!w || !r) return FALSE; r->left = r->top = 0; r->right = w->clientW; r->bottom = w->clientH; return TRUE; }
WINBOOL GetWindowRect(HWND h, RECT *r) { return GetClientRect(h, r); }
WINBOOL AdjustWindowRect(RECT *, DWORD, BOOL) { return TRUE; }
WINBOOL AdjustWindowRectEx(RECT *, DWORD, BOOL, DWORD) { return TRUE; }
WINBOOL IsWindowVisible(HWND h) { S2Window *w = S2W(h); return w && w->window.visible; }
WINBOOL IsWindow(HWND h) { return S2W(h) != nullptr; }
WINBOOL IsIconic(HWND h) { S2Window *w = S2W(h); return w && w->window.miniaturized; }
WINBOOL ShowWindow(HWND h, int cmd)
{
	S2Window *w = S2W(h); if (!w) return FALSE;
	if (cmd == SW_HIDE) [w->window orderOut:nil];
	else if (cmd == SW_MINIMIZE) [w->window miniaturize:nil];
	else if (!(getenv("S2_NO_ACTIVATE") || getenv("S2_HEADLESS"))) { if (w->window.miniaturized) [w->window deminiaturize:nil]; [w->window makeKeyAndOrderFront:nil]; }
	return TRUE;
}
WINBOOL UpdateWindow(HWND) { return TRUE; }
WINBOOL InvalidateRect(HWND, const RECT *, BOOL) { return TRUE; }
HWND GetForegroundWindow() { return s2active ? (HWND)s2main : nullptr; }
WINBOOL SetForegroundWindow(HWND h) { S2Window *w = S2W(h); if (w && !(getenv("S2_NO_ACTIVATE") || getenv("S2_HEADLESS"))) { [NSApp activate]; [w->window makeKeyAndOrderFront:nil]; } return TRUE; }
HWND SetFocus(HWND h) { return h; }
HWND GetFocus() { return (HWND)s2main; }
HWND GetActiveWindow() { return s2active ? (HWND)s2main : nullptr; }
HWND GetParent(HWND) { return nullptr; }
WINBOOL SetWindowText(HWND h, LPCSTR t) { S2Window *w = S2W(h); if (w && t) w->window.title = [NSString stringWithUTF8String:t]; return TRUE; }
LONG_PTR SetWindowLongPtr(HWND h, int idx, LONG_PTR v) { S2Window *w = S2W(h); if (!w) return 0; LONG_PTR o; if (idx == GWL_STYLE) { o = w->style; w->style = (DWORD)v; } else if (idx == GWL_EXSTYLE) { o = w->exStyle; w->exStyle = (DWORD)v; } else { o = w->userData; w->userData = v; } return o; }
LONG_PTR GetWindowLongPtr(HWND h, int idx) { S2Window *w = S2W(h); if (!w) return 0; return idx == GWL_STYLE ? w->style : idx == GWL_EXSTYLE ? w->exStyle : w->userData; }
LONG SetWindowLong(HWND h, int idx, LONG v) { return (LONG)SetWindowLongPtr(h, idx, v); }
LONG GetWindowLong(HWND h, int idx) { return (LONG)GetWindowLongPtr(h, idx); }
int GetSystemMetrics(int idx)
{
	NSRect f = NSScreen.mainScreen.frame; CGFloat s = NSScreen.mainScreen.backingScaleFactor;
	return idx == SM_CXSCREEN ? (int)(f.size.width * s) : idx == SM_CYSCREEN ? (int)(f.size.height * s) : 0;
}
HDC GetDC(HWND) { return (HDC)(intptr_t)1; }
int ReleaseDC(HWND, HDC) { return 1; }
HDC BeginPaint(HWND, PAINTSTRUCT *ps) { memset(ps, 0, sizeof *ps); return (HDC)(intptr_t)1; }
WINBOOL EndPaint(HWND, const PAINTSTRUCT *) { return TRUE; }

// client pixel <-> global screen pixel (top-left origin) for cursor placement
static NSPoint S2ClientToScreenPoints(S2Window *w, double x, double y)
{
	NSSize sz = w->view.bounds.size;
	double cx, cy, cw, ch;
	S2ContentRect(sz.width, sz.height, w->clientW, w->clientH, &cx, &cy, &cw, &ch);
	NSPoint inView = NSMakePoint(cx + x * cw / std::max(1, w->clientW), sz.height - (cy + y * ch / std::max(1, w->clientH)));
	NSPoint inWin = [w->view convertPoint:inView toView:nil];
	return [w->window convertPointToScreen:inWin];
}
WINBOOL ClientToScreen(HWND h, POINT *p)
{
	S2Window *w = S2W(h); if (!w || !p) return FALSE;
	NSPoint s = S2ClientToScreenPoints(w, p->x, p->y);
	CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
	p->x = (LONG)lround(s.x); p->y = (LONG)lround(top - s.y);
	return TRUE;
}
WINBOOL ScreenToClient(HWND h, POINT *p)
{
	S2Window *w = S2W(h); if (!w || !p) return FALSE;
	CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
	NSPoint s = NSMakePoint(p->x, top - p->y);
	NSPoint inWin = [w->window convertPointFromScreen:s];
	NSPoint inView = [w->view convertPoint:inWin fromView:nil];
	NSPoint c = S2ToClient(w, inView);
	p->x = (LONG)lround(c.x); p->y = (LONG)lround(c.y);
	return TRUE;
}
WINBOOL GetCursorPos(POINT *p)
{
	if (s2testCursor && s2main) { *p = s2testCursorClient; return ClientToScreen((HWND)s2main, p); }
	NSPoint m = NSEvent.mouseLocation;
	CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
	p->x = (LONG)lround(m.x); p->y = (LONG)lround(top - m.y);
	return TRUE;
}
WINBOOL SetCursorPos(int x, int y)
{
	// The Windows engine calls this every frame during camera drag to pin its
	// cursor. Its virtual cursor already stays fixed; moving the macOS pointer
	// creates synthetic motion and can trap the user's pointer. Never warp it.
	return TRUE;
}
WINBOOL ClipCursor(const RECT *r)
{
	// Windows confines the pointer to the window during play; macOS keeps it free but the game's own
	// cursor is clamped by the engine, so edge scrolling still works
	return TRUE;
}
HWND SetCapture(HWND h) { return h; }
WINBOOL ReleaseCapture() { return TRUE; }

// ---------------------------------------------------------------------------------------------------
// cursors: Windows .cur files (ICO container, 32-bit or palettised DIB) become NSCursors
struct S2Cursor { NSCursor *cursor; };
static NSCursor *S2LoadCur(const char *file)
{
	char path[1024]; S2HostPath(file, path, sizeof path);
	NSData *d = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
	if (d.length < 22) return nil;
	const BYTE *b = (const BYTE*)d.bytes;
	WORD type = *(const WORD*)(b + 2), count = *(const WORD*)(b + 4);
	if ((type != 2 && type != 1) || count == 0) return nil;
	const BYTE *e = b + 6;
	int hotX = *(const WORD*)(e + 4), hotY = *(const WORD*)(e + 6);
	DWORD size = *(const DWORD*)(e + 8), off = *(const DWORD*)(e + 12);
	if (off + size > d.length) return nil;
	NSData *img = [NSData dataWithBytes:b + off length:size];
	NSImage *image = nil;
	if (size > 8 && memcmp(b + off, "\x89PNG", 4) == 0) image = [[NSImage alloc] initWithData:img];
	else
	{
		// DIB: BITMAPINFOHEADER, height is doubled (XOR + AND masks)
		const BITMAPINFOHEADER *bi = (const BITMAPINFOHEADER*)(b + off);
		int w = bi->biWidth, h = bi->biHeight / 2, bpp = bi->biBitCount;
		const BYTE *pal = b + off + bi->biSize;
		int palCount = bpp <= 8 ? (bi->biClrUsed ? (int)bi->biClrUsed : 1 << bpp) : 0;
		const BYTE *xorBits = pal + palCount * 4;
		int xorStride = ((w * bpp + 31) / 32) * 4, andStride = ((w + 31) / 32) * 4;
		const BYTE *andBits = xorBits + xorStride * h;
		NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nil pixelsWide:w pixelsHigh:h bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:w * 4 bitsPerPixel:32];
		BYTE *dst = rep.bitmapData;
		bool anyAlpha = false;
		if (bpp == 32) for (int y = 0; y < h && !anyAlpha; ++y) for (int x = 0; x < w; ++x) if (xorBits[y * xorStride + x * 4 + 3]) { anyAlpha = true; break; }
		for (int y = 0; y < h; ++y)
		{
			const BYTE *xr = xorBits + (h - 1 - y) * xorStride, *ar = andBits + (h - 1 - y) * andStride;
			for (int x = 0; x < w; ++x)
			{
				BYTE r, g, bl, a;
				bool masked = (ar[x >> 3] >> (7 - (x & 7))) & 1;
				if (bpp == 32) { bl = xr[x * 4]; g = xr[x * 4 + 1]; r = xr[x * 4 + 2]; a = anyAlpha ? xr[x * 4 + 3] : (masked ? 0 : 255); }
				else if (bpp == 24) { bl = xr[x * 3]; g = xr[x * 3 + 1]; r = xr[x * 3 + 2]; a = masked ? 0 : 255; }
				else
				{
					int idx = bpp == 8 ? xr[x] : bpp == 4 ? (xr[x >> 1] >> ((x & 1) ? 0 : 4)) & 15 : (xr[x >> 3] >> (7 - (x & 7))) & 1;
					bl = pal[idx * 4]; g = pal[idx * 4 + 1]; r = pal[idx * 4 + 2]; a = masked ? 0 : 255;
				}
				BYTE *o = dst + (y * w + x) * 4; o[0] = r; o[1] = g; o[2] = bl; o[3] = a;
			}
		}
		image = [[NSImage alloc] initWithSize:NSMakeSize(w, h)];
		[image addRepresentation:rep];
	}
	if (!image) return nil;
	return [[NSCursor alloc] initWithImage:image hotSpot:NSMakePoint(hotX, hotY)];
}
HCURSOR LoadCursorFromFileA(LPCSTR file)
{
	NSCursor *c = S2LoadCur(file);
	if (!c) return nullptr;
	S2Cursor *h = new S2Cursor(); h->cursor = c; return (HCURSOR)h;
}
HCURSOR LoadCursor(HINSTANCE, LPCSTR) { static S2Cursor arrow = { NSCursor.arrowCursor }; return (HCURSOR)&arrow; }
WINBOOL DestroyCursor(HCURSOR c) { if (c) delete (S2Cursor*)c; return TRUE; }
HCURSOR SetCursor(HCURSOR c)
{
	static HCURSOR prev; HCURSOR old = prev; prev = c;
	if (c) [S2CurrentNSCursor() set];
	return old;
}
static NSCursor *S2CurrentNSCursor()
{
	if (s2cursorReleased || !s2main || !s2main->window.isKeyWindow || !NSApp.isActive) return NSCursor.arrowCursor;
	if (!NSPointInRect([s2main->window mouseLocationOutsideOfEventStream], s2main->view.frame)) return NSCursor.arrowCursor;
	NSPoint point = [s2main->view convertPoint:[s2main->window mouseLocationOutsideOfEventStream] fromView:nil];
	if (NSPointInRect(point, ((S2GameView*)s2main->view).graphicsSelector.frame)) return NSCursor.arrowCursor;
	static NSCursor *blank;
	if (!blank)
	{
		NSImage *im = [NSImage imageWithSize:NSMakeSize(8, 8) flipped:NO drawingHandler:^BOOL(NSRect) { return YES; }];
		blank = [[NSCursor alloc] initWithImage:im hotSpot:NSZeroPoint];
	}
	if (!s2cursorShown) return blank;
	return s2cursor ? ((S2Cursor*)s2cursor)->cursor : NSCursor.arrowCursor;
}
int ShowCursor(WINBOOL show) { NWinFrame::ShowCursor(show != 0); return show ? 0 : -1; }

// ---------------------------------------------------------------------------------------------------
// keyboard queries
SHORT GetAsyncKeyState(int vk) { return (vk >= 0 && vk < 256 && s2in.vkDown[vk]) ? (SHORT)0x8000 : 0; }
SHORT GetKeyState(int vk) { return GetAsyncKeyState(vk); }
WINBOOL GetKeyboardState(BYTE *keys) { memcpy(keys, s2in.vkDown, 256); return TRUE; }
UINT MapVirtualKeyEx(UINT code, UINT type, HKL)
{
	if (type == MAPVK_VK_TO_VSC) { const S2KeyMap *k = S2FindVK(code); return k ? k->dik : 0; }
	if (type == MAPVK_VSC_TO_VK) { for (const S2KeyMap &k : s2Keys) if (k.dik == code) return k.vk; return 0; }
	if (type == MAPVK_VK_TO_CHAR) { WORD c = 0; BYTE none[256] = {}; return ToAsciiEx(code, 0, none, &c, 0, nullptr) == 1 ? c : 0; }
	return 0;
}
UINT MapVirtualKey(UINT code, UINT type) { return MapVirtualKeyEx(code, type, nullptr); }
// translate a virtual key through the current macOS keyboard layout
int ToUnicodeEx(UINT vk, UINT, const BYTE *keys, WCHAR *out, int n, UINT, HKL)
{
	const S2KeyMap *k = S2FindVK(vk); if (!k || n < 1) return 0;
	TISInputSourceRef src = TISCopyCurrentKeyboardLayoutInputSource();
	CFDataRef data = src ? (CFDataRef)TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) : nullptr;
	int res = 0;
	if (data)
	{
		UInt32 mods = 0;
		if (keys && (keys[VK_SHIFT] & 0x80)) mods |= shiftKey >> 8;
		if (keys && (keys[VK_CAPITAL] & 0x01)) mods |= alphaLock >> 8;
		if (keys && (keys[VK_MENU] & 0x80)) mods |= optionKey >> 8;
		UInt32 dead = 0; UniChar buf[4]; UniCharCount len = 0;
		if (UCKeyTranslate((const UCKeyboardLayout*)CFDataGetBytePtr(data), k->mac, kUCKeyActionDown, mods, LMGetKbdType(), kUCKeyTranslateNoDeadKeysBit, &dead, 4, &len, buf) == noErr && len > 0)
		{ out[0] = buf[0]; res = 1; }
	}
	if (src) CFRelease(src);
	return res;
}
int ToAsciiEx(UINT vk, UINT scan, const BYTE *keys, WORD *out, UINT flags, HKL kl)
{
	WCHAR c; int r = ToUnicodeEx(vk, scan, keys, &c, 1, flags, kl);
	if (r == 1 && out) *out = (WORD)c;
	return r;
}

// ---------------------------------------------------------------------------------------------------
// clipboard (CF_UNICODETEXT only, which is what the text fields paste)
static std::vector<WCHAR> s2clip;
WINBOOL OpenClipboard(HWND) { return TRUE; }
WINBOOL CloseClipboard() { return TRUE; }
WINBOOL IsClipboardFormatAvailable(UINT fmt) { return (fmt == CF_UNICODETEXT || fmt == CF_TEXT) && [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString] != nil; }
HANDLE GetClipboardData(UINT fmt)
{
	NSString *s = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
	if (!s || fmt != CF_UNICODETEXT) return nullptr;
	s2clip.assign(s.length + 1, 0);
	for (NSUInteger i = 0; i < s.length; ++i) s2clip[i] = [s characterAtIndex:i];
	return s2clip.data();
}
void *GlobalLock(HGLOBAL h) { return h; }
WINBOOL GlobalUnlock(HGLOBAL) { return TRUE; }

int MessageBox(HWND, LPCSTR text, LPCSTR caption, UINT type)
{
	fprintf(stderr, "[MessageBox] %s: %s\n", caption ? caption : "", text ? text : "");
	if (!NSThread.isMainThread) return IDYES;
	@autoreleasepool
	{
		NSAlert *a = [NSAlert new];
		a.messageText = [NSString stringWithUTF8String:caption ? caption : "Silent Storm"];
		a.informativeText = [NSString stringWithUTF8String:text ? text : ""];
		if (type & MB_YESNO) { [a addButtonWithTitle:@"Yes"]; [a addButtonWithTitle:@"No"]; return [a runModal] == NSAlertFirstButtonReturn ? IDYES : 7; }
		[a runModal];
	}
	return 1;
}

// ---------------------------------------------------------------------------------------------------
// DirectInput 8: keyboard and mouse devices backed by the event state above
const DIDATAFORMAT c_dfDIKeyboard = { sizeof(DIDATAFORMAT), sizeof(DIOBJECTDATAFORMAT), DIDF_RELAXIS, 256, 256, nullptr };
const DIDATAFORMAT c_dfDIMouse2 = { sizeof(DIDATAFORMAT), sizeof(DIOBJECTDATAFORMAT), DIDF_RELAXIS, sizeof(DIMOUSESTATE2), 11, nullptr };
const DIDATAFORMAT c_dfDIMouse = { sizeof(DIDATAFORMAT), sizeof(DIOBJECTDATAFORMAT), DIDF_RELAXIS, sizeof(DIMOUSESTATE), 7, nullptr };

namespace {
struct S2DIDevice : IDirectInputDevice8A
{
	ULONG refs = 1;
	bool keyboard;
	DWORD bufferSize = 0;
	DWORD axisMode = DIPROPAXISMODE_ABS;
	explicit S2DIDevice(bool kb) : keyboard(kb) {}
	HRESULT QueryInterface(REFIID, void **ppv) override { *ppv = this; AddRef(); return S_OK; }
	ULONG AddRef() override { return ++refs; }
	ULONG Release() override { ULONG r = --refs; if (!r) delete this; return r; }
	HRESULT GetCapabilities(LPDIDEVCAPS caps) override
	{
		if (!caps) return E_POINTER;
		DWORD sz = caps->dwSize; memset(caps, 0, sz); caps->dwSize = sz;
		caps->dwFlags = DIDC_ATTACHED;
		caps->dwDevType = keyboard ? (DI8DEVTYPE_KEYBOARD | (DI8DEVTYPEKEYBOARD_PCENH << 8)) : (DI8DEVTYPE_MOUSE | (DI8DEVTYPEMOUSE_UNKNOWN << 8));
		caps->dwAxes = keyboard ? 0 : 3; caps->dwButtons = keyboard ? 128 : 8;
		return S_OK;
	}
	HRESULT EnumObjects(LPDIENUMDEVICEOBJECTSCALLBACKA, LPVOID, DWORD) override { return S_OK; }
	HRESULT GetProperty(REFGUID prop, LPDIPROPHEADER h) override
	{
		if (&prop == &DIPROP_GRANULARITY && h) { ((DIPROPDWORD*)h)->dwData = 1; return S_OK; }
		if (h && h->dwSize >= sizeof(DIPROPDWORD)) ((DIPROPDWORD*)h)->dwData = 1;
		return S_OK;
	}
	HRESULT SetProperty(REFGUID prop, LPCDIPROPHEADER h) override
	{
		if (&prop == &DIPROP_BUFFERSIZE) bufferSize = ((const DIPROPDWORD*)h)->dwData;
		else if (&prop == &DIPROP_AXISMODE) axisMode = ((const DIPROPDWORD*)h)->dwData;
		return S_OK;
	}
	HRESULT Acquire() override { return S_OK; }
	HRESULT Unacquire() override { return S_OK; }
	HRESULT GetDeviceState(DWORD size, LPVOID data) override
	{
		std::lock_guard<std::mutex> l(s2in.m);
		if (keyboard) { memcpy(data, s2in.keys, std::min<DWORD>(size, 256)); return S_OK; }
		DIMOUSESTATE2 st = {};
		st.lX = s2in.mouseAbs[0]; st.lY = s2in.mouseAbs[1]; st.lZ = s2in.mouseAbs[2];
		memcpy(st.rgbButtons, s2in.mouseButtons, 8);
		memcpy(data, &st, std::min<DWORD>(size, sizeof st));
		return S_OK;
	}
	HRESULT GetDeviceData(DWORD objSize, LPDIDEVICEOBJECTDATA out, LPDWORD inOut, DWORD flags) override
	{
		std::lock_guard<std::mutex> l(s2in.m);
		std::deque<S2DIEvent> &q = keyboard ? s2in.keyEvents : s2in.mouseEvents;
		DWORD n = std::min<DWORD>(*inOut, (DWORD)q.size());
		for (DWORD i = 0; i < n; ++i)
		{
			DIDEVICEOBJECTDATA *d = (DIDEVICEOBJECTDATA*)((BYTE*)out + i * objSize);
			memset(d, 0, objSize);
			d->dwOfs = q[i].ofs; d->dwData = q[i].data; d->dwTimeStamp = q[i].time; d->dwSequence = q[i].seq;
		}
		if (!(flags & DIGDD_PEEK)) q.erase(q.begin(), q.begin() + n);
		*inOut = n;
		return S_OK;
	}
	HRESULT SetDataFormat(LPCDIDATAFORMAT) override { return S_OK; }
	HRESULT SetEventNotification(HANDLE) override { return S_OK; }
	HRESULT SetCooperativeLevel(HWND, DWORD) override { return S_OK; }
	HRESULT GetObjectInfo(LPDIDEVICEOBJECTINSTANCEA, DWORD, DWORD) override { return E_NOTIMPL; }
	HRESULT GetDeviceInfo(LPDIDEVICEINSTANCEA info) override
	{
		if (!info) return E_POINTER;
		DWORD sz = info->dwSize; memset(info, 0, sz); info->dwSize = sz;
		info->guidInstance = keyboard ? GUID_SysKeyboard : GUID_SysMouse; info->guidProduct = info->guidInstance;
		info->dwDevType = keyboard ? (DI8DEVTYPE_KEYBOARD | (DI8DEVTYPEKEYBOARD_PCENH << 8)) : (DI8DEVTYPE_MOUSE | (DI8DEVTYPEMOUSE_UNKNOWN << 8));
		strcpy(info->tszInstanceName, keyboard ? "Keyboard" : "Mouse"); strcpy(info->tszProductName, info->tszInstanceName);
		return S_OK;
	}
	HRESULT RunControlPanel(HWND, DWORD) override { return S_OK; }
	HRESULT Initialize(HINSTANCE, DWORD, REFGUID) override { return S_OK; }
	HRESULT CreateEffect(REFGUID, LPCDIEFFECT, LPDIRECTINPUTEFFECT *, LPUNKNOWN) override { return E_NOTIMPL; }
	HRESULT EnumEffects(LPDIENUMEFFECTSCALLBACKA, LPVOID, DWORD) override { return S_OK; }
	HRESULT GetEffectInfo(LPDIEFFECTINFOA, REFGUID) override { return E_NOTIMPL; }
	HRESULT GetForceFeedbackState(LPDWORD) override { return E_NOTIMPL; }
	HRESULT SendForceFeedbackCommand(DWORD) override { return E_NOTIMPL; }
	HRESULT EnumCreatedEffectObjects(LPDIENUMCREATEDEFFECTOBJECTSCALLBACK, LPVOID, DWORD) override { return S_OK; }
	HRESULT Escape(LPDIEFFESCAPE) override { return E_NOTIMPL; }
	HRESULT Poll() override { return S_OK; }
	HRESULT SendDeviceData(DWORD, LPCDIDEVICEOBJECTDATA, LPDWORD, DWORD) override { return E_NOTIMPL; }
	HRESULT EnumEffectsInFile(LPCSTR, LPDIENUMEFFECTSINFILECALLBACK, LPVOID, DWORD) override { return S_OK; }
	HRESULT WriteEffectToFile(LPCSTR, DWORD, LPDIFILEEFFECT, DWORD) override { return E_NOTIMPL; }
	HRESULT BuildActionMap(LPDIACTIONFORMATA, LPCSTR, DWORD) override { return E_NOTIMPL; }
	HRESULT SetActionMap(LPDIACTIONFORMATA, LPCSTR, DWORD) override { return E_NOTIMPL; }
	HRESULT GetImageInfo(LPDIDEVICEIMAGEINFOHEADERA) override { return E_NOTIMPL; }
};

struct S2DirectInput : IDirectInput8A
{
	ULONG refs = 1;
	HRESULT QueryInterface(REFIID, void **ppv) override { *ppv = this; AddRef(); return S_OK; }
	ULONG AddRef() override { return ++refs; }
	ULONG Release() override { ULONG r = --refs; if (!r) delete this; return r; }
	HRESULT CreateDevice(REFGUID g, LPDIRECTINPUTDEVICE8A *dev, LPUNKNOWN) override
	{
		if (g == GUID_SysKeyboard) { *dev = new S2DIDevice(true); return S_OK; }
		if (g == GUID_SysMouse) { *dev = new S2DIDevice(false); return S_OK; }
		return E_FAIL;
	}
	HRESULT EnumDevices(DWORD, LPDIENUMDEVICESCALLBACKA, LPVOID, DWORD) override { return S_OK; }
	HRESULT GetDeviceStatus(REFGUID) override { return S_OK; }
	HRESULT RunControlPanel(HWND, DWORD) override { return S_OK; }
	HRESULT Initialize(HINSTANCE, DWORD) override { return S_OK; }
	HRESULT FindDevice(REFGUID, LPCSTR, LPGUID) override { return E_FAIL; }
	HRESULT EnumDevicesBySemantics(LPCSTR, LPDIACTIONFORMATA, LPDIENUMDEVICESBYSEMANTICSCBA, LPVOID, DWORD) override { return S_OK; }
	HRESULT ConfigureDevices(LPDICONFIGUREDEVICESCALLBACK, LPDICONFIGUREDEVICESPARAMSA, DWORD, LPVOID) override { return E_NOTIMPL; }
};
} // namespace

extern "C" HRESULT DirectInput8Create(HINSTANCE, DWORD, REFIID, LPVOID *out, LPUNKNOWN)
{
	*out = new S2DirectInput();
	return S_OK;
}

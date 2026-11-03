// splash_mac.mm: NSplash::CSplashScreen for macOS. The game window opens quickly enough on Apple silicon
// that the loading splash is not shown; the class keeps the engine's interface.
#include "s2win32.h"
#include "s2win32ui.h"
#include "Main/StdAfx.h"
#include "Main/SplashScreenDialog.h"
namespace NSplash {
CSplashScreen::SBitmap::SBitmap() : hBitmap(0), hPalette(0) { memset(&bitmapInfo, 0, sizeof bitmapInfo); }
bool CSplashScreen::SBitmap::Load(const string &) { return false; }
bool CSplashScreen::SBitmap::Draw(HDC *) { return false; }
CSplashScreen::CSplashScreen(const string &prefix) : szWndClassName(prefix), hWnd(0) {}
bool CSplashScreen::Create(const string &image, bool) { szImageFileName = image; return true; }
void CSplashScreen::Destroy() { hWnd = 0; }
bool CSplashScreen::IsWindow() const { return false; }
bool CSplashScreen::ShowWindow(int) { return true; }
bool CSplashScreen::UpdateWindow() { return true; }
}

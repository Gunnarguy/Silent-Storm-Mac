// s2platform.h: entry points shared between the macOS platform pieces (window, Metal device, app).
#pragma once
#include "s2win32.h"
#include <algorithm>

void *S2GetMetalLayer(HWND hWnd);                       // CAMetalLayer* backing the game window
void S2SetBackBufferSize(HWND hWnd, int width, int height);
const char *S2GameDirectory();                          // folder holding game.db and res/
const char *S2ConfigPath(const char *base);             // "autoexec.cfg" -> ".\cfg\autoexec.cfg"

// where the game image sits inside a view of the given size: aspect-preserving fit (letterbox / pillarbox)
inline void S2ContentRect(double viewW, double viewH, double gameW, double gameH, double *x, double *y, double *w, double *h)
{
	double s = (gameW > 0 && gameH > 0) ? std::min(viewW / gameW, viewH / gameH) : 1;
	*w = gameW * s; *h = gameH * s; *x = (viewW - *w) * 0.5; *y = (viewH - *h) * 0.5;
}

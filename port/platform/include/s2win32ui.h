// s2win32ui.h: window, message and keyboard names the engine uses. On macOS the window is an
// NSWindow owned by port/platform/src; these functions are implemented there.
#pragma once
#include "s2win32.h"

#define FIELD_OFFSET(t, f) ((LONG)offsetof(t, f))

// virtual keys
#define VK_LBUTTON 0x01
#define VK_RBUTTON 0x02
#define VK_MBUTTON 0x04
#define VK_BACK 0x08
#define VK_TAB 0x09
#define VK_RETURN 0x0D
#define VK_SHIFT 0x10
#define VK_CONTROL 0x11
#define VK_MENU 0x12
#define VK_PAUSE 0x13
#define VK_CAPITAL 0x14
#define VK_ESCAPE 0x1B
#define VK_SPACE 0x20
#define VK_PRIOR 0x21
#define VK_NEXT 0x22
#define VK_END 0x23
#define VK_HOME 0x24
#define VK_LEFT 0x25
#define VK_UP 0x26
#define VK_RIGHT 0x27
#define VK_DOWN 0x28
#define VK_SNAPSHOT 0x2C
#define VK_INSERT 0x2D
#define VK_DELETE 0x2E
#define VK_LWIN 0x5B
#define VK_RWIN 0x5C
#define VK_NUMPAD0 0x60
#define VK_MULTIPLY 0x6A
#define VK_ADD 0x6B
#define VK_SUBTRACT 0x6D
#define VK_DECIMAL 0x6E
#define VK_DIVIDE 0x6F
#define VK_F1 0x70
#define VK_F12 0x7B
#define VK_NUMLOCK 0x90
#define VK_SCROLL 0x91
#define VK_LSHIFT 0xA0
#define VK_RSHIFT 0xA1
#define VK_LCONTROL 0xA2
#define VK_RCONTROL 0xA3
#define VK_LMENU 0xA4
#define VK_RMENU 0xA5
#define MAPVK_VK_TO_VSC 0
#define MAPVK_VSC_TO_VK 1
#define MAPVK_VK_TO_CHAR 2

// messages
#define WM_NULL 0x0000
#define WM_CREATE 0x0001
#define WM_DESTROY 0x0002
#define WM_MOVE 0x0003
#define WM_SIZE 0x0005
#define WM_ACTIVATE 0x0006
#define WM_SETFOCUS 0x0007
#define WM_KILLFOCUS 0x0008
#define WM_PAINT 0x000F
#define WM_CLOSE 0x0010
#define WM_QUIT 0x0012
#define WM_ERASEBKGND 0x0014
#define WM_ACTIVATEAPP 0x001C
#define WM_SETCURSOR 0x0020
#define WM_GETMINMAXINFO 0x0024
#define WM_NCHITTEST 0x0084
#define WM_KEYDOWN 0x0100
#define WM_KEYUP 0x0101
#define WM_CHAR 0x0102
#define WM_SYSKEYDOWN 0x0104
#define WM_SYSKEYUP 0x0105
#define WM_SYSCHAR 0x0106
#define WM_INITDIALOG 0x0110
#define WM_COMMAND 0x0111
#define WM_SYSCOMMAND 0x0112
#define WM_TIMER 0x0113
#define WM_ENTERIDLE 0x0121
#define WM_MOUSEMOVE 0x0200
#define WM_LBUTTONDOWN 0x0201
#define WM_LBUTTONUP 0x0202
#define WM_LBUTTONDBLCLK 0x0203
#define WM_RBUTTONDOWN 0x0204
#define WM_RBUTTONUP 0x0205
#define WM_RBUTTONDBLCLK 0x0206
#define WM_MBUTTONDOWN 0x0207
#define WM_MBUTTONUP 0x0208
#define WM_MOUSEWHEEL 0x020A
#define WM_POWERBROADCAST 0x0218
#define WM_ENTERSIZEMOVE 0x0231
#define WM_EXITSIZEMOVE 0x0232
#define WM_USER 0x0400
#define WA_INACTIVE 0
#define WA_ACTIVE 1
#define SC_SCREENSAVE 0xF140
#define SC_MONITORPOWER 0xF170
#define SC_KEYMENU 0xF100
#define HTCLIENT 1
#define PBT_APMQUERYSUSPEND 0x0000
#define BROADCAST_QUERY_DENY 0x424D5144
#define PM_NOREMOVE 0x0000
#define PM_REMOVE 0x0001

// window styles and commands
#define WS_OVERLAPPED 0x00000000L
#define WS_POPUP 0x80000000L
#define WS_VISIBLE 0x10000000L
#define WS_CAPTION 0x00C00000L
#define WS_SYSMENU 0x00080000L
#define WS_THICKFRAME 0x00040000L
#define WS_MINIMIZEBOX 0x00020000L
#define WS_MAXIMIZEBOX 0x00010000L
#define WS_OVERLAPPEDWINDOW (WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX)
#define WS_EX_TOPMOST 0x00000008L
#define WS_EX_TOOLWINDOW 0x00000080L
#define WS_EX_APPWINDOW 0x00040000L
#define CS_VREDRAW 0x0001
#define CS_HREDRAW 0x0002
#define CS_DBLCLKS 0x0008
#define CS_OWNDC 0x0020
#define SW_HIDE 0
#define SW_SHOWNORMAL 1
#define SW_SHOW 5
#define SW_MINIMIZE 6
#define SW_RESTORE 9
#define SWP_NOSIZE 0x0001
#define SWP_NOMOVE 0x0002
#define SWP_NOZORDER 0x0004
#define SWP_SHOWWINDOW 0x0040
#define HWND_TOP ((HWND)0)
#define HWND_TOPMOST ((HWND)-1)
#define HWND_NOTOPMOST ((HWND)-2)
#define GWL_STYLE (-16)
#define GWL_EXSTYLE (-20)
#define GWL_USERDATA (-21)
#define GWLP_USERDATA (-21)
#define SM_CXSCREEN 0
#define SM_CYSCREEN 1
#define COLOR_WINDOW 5
#define IDC_ARROW MAKEINTRESOURCE(32512)
#define IDI_APPLICATION MAKEINTRESOURCE(32512)
#define MK_LBUTTON 0x0001
#define MK_RBUTTON 0x0002
#define CF_TEXT 1
#define CF_UNICODETEXT 13
#define GMEM_MOVEABLE 0x0002

typedef LRESULT (*WNDPROC)(HWND, UINT, WPARAM, LPARAM);
typedef struct tagMSG { HWND hwnd; UINT message; WPARAM wParam; LPARAM lParam; DWORD time; POINT pt; } MSG, *LPMSG;
typedef struct tagWNDCLASS { UINT style; WNDPROC lpfnWndProc; int cbClsExtra, cbWndExtra; HINSTANCE hInstance; HICON hIcon; HCURSOR hCursor; HBRUSH hbrBackground; LPCSTR lpszMenuName, lpszClassName; } WNDCLASS, WNDCLASSA;
typedef struct tagWNDCLASSEXA { UINT cbSize, style; WNDPROC lpfnWndProc; int cbClsExtra, cbWndExtra; HINSTANCE hInstance; HICON hIcon; HCURSOR hCursor; HBRUSH hbrBackground; LPCSTR lpszMenuName, lpszClassName; HICON hIconSm; } WNDCLASSEXA, WNDCLASSEX;
typedef struct tagMINMAXINFO { POINT ptReserved, ptMaxSize, ptMaxPosition, ptMinTrackSize, ptMaxTrackSize; } MINMAXINFO;
typedef struct tagPAINTSTRUCT { HDC hdc; WINBOOL fErase; RECT rcPaint; WINBOOL fRestore, fIncUpdate; BYTE rgbReserved[32]; } PAINTSTRUCT;

extern "C" {
// keyboard
SHORT GetAsyncKeyState(int vk);
SHORT GetKeyState(int vk);
WINBOOL GetKeyboardState(BYTE *keys);
int ToAsciiEx(UINT vk, UINT scan, const BYTE *keys, WORD *out, UINT flags, HKL kl);
int ToUnicodeEx(UINT vk, UINT scan, const BYTE *keys, WCHAR *out, int n, UINT flags, HKL kl);
UINT MapVirtualKeyEx(UINT code, UINT type, HKL kl);
UINT MapVirtualKey(UINT code, UINT type);
// messages and windows
WINBOOL PeekMessage(MSG *m, HWND w, UINT fmin, UINT fmax, UINT remove);
WINBOOL GetMessage(MSG *m, HWND w, UINT fmin, UINT fmax);
WINBOOL TranslateMessage(const MSG *m);
LRESULT DispatchMessage(const MSG *m);
WINBOOL PostMessage(HWND w, UINT msg, WPARAM wp, LPARAM lp);
LRESULT SendMessage(HWND w, UINT msg, WPARAM wp, LPARAM lp);
void PostQuitMessage(int code);
LRESULT DefWindowProc(HWND w, UINT msg, WPARAM wp, LPARAM lp);
ATOM RegisterClass(const WNDCLASS *wc);
ATOM RegisterClassEx(const WNDCLASSEXA *wc);
WINBOOL UnregisterClass(LPCSTR name, HINSTANCE inst);
HWND CreateWindowEx(DWORD exStyle, LPCSTR cls, LPCSTR title, DWORD style, int x, int y, int w, int h, HWND parent, HMENU menu, HINSTANCE inst, void *param);
HWND CreateWindow(LPCSTR cls, LPCSTR title, DWORD style, int x, int y, int w, int h, HWND parent, HMENU menu, HINSTANCE inst, void *param);
WINBOOL DestroyWindow(HWND w);
WINBOOL ShowWindow(HWND w, int cmd);
WINBOOL UpdateWindow(HWND w);
WINBOOL SetWindowPos(HWND w, HWND after, int x, int y, int cx, int cy, UINT flags);
WINBOOL MoveWindow(HWND w, int x, int y, int cx, int cy, WINBOOL repaint);
WINBOOL GetClientRect(HWND w, RECT *r);
WINBOOL GetWindowRect(HWND w, RECT *r);
WINBOOL AdjustWindowRect(RECT *r, DWORD style, WINBOOL menu);
WINBOOL AdjustWindowRectEx(RECT *r, DWORD style, WINBOOL menu, DWORD exStyle);
WINBOOL ClientToScreen(HWND w, POINT *p);
WINBOOL ScreenToClient(HWND w, POINT *p);
WINBOOL SetWindowText(HWND w, LPCSTR text);
HWND GetForegroundWindow();
WINBOOL SetForegroundWindow(HWND w);
HWND SetFocus(HWND w);
HWND GetFocus();
HWND GetActiveWindow();
HWND GetParent(HWND w);
WINBOOL IsWindow(HWND w);
WINBOOL IsIconic(HWND w);
WINBOOL IsWindowVisible(HWND w);
LONG_PTR SetWindowLongPtr(HWND w, int idx, LONG_PTR v);
LONG_PTR GetWindowLongPtr(HWND w, int idx);
LONG SetWindowLong(HWND w, int idx, LONG v);
LONG GetWindowLong(HWND w, int idx);
int GetSystemMetrics(int idx);
WINBOOL InvalidateRect(HWND w, const RECT *r, WINBOOL erase);
HDC BeginPaint(HWND w, PAINTSTRUCT *ps);
WINBOOL EndPaint(HWND w, const PAINTSTRUCT *ps);
HDC GetDC(HWND w);
int ReleaseDC(HWND w, HDC dc);
// cursor
HCURSOR LoadCursor(HINSTANCE inst, LPCSTR name);
HCURSOR LoadCursorFromFileA(LPCSTR file);
HCURSOR SetCursor(HCURSOR c);
WINBOOL DestroyCursor(HCURSOR c);
int ShowCursor(WINBOOL show);
WINBOOL SetCursorPos(int x, int y);
WINBOOL GetCursorPos(POINT *p);
WINBOOL ClipCursor(const RECT *r);
HWND SetCapture(HWND w);
WINBOOL ReleaseCapture();
// clipboard
WINBOOL OpenClipboard(HWND w);
WINBOOL CloseClipboard();
HANDLE GetClipboardData(UINT fmt);
WINBOOL IsClipboardFormatAvailable(UINT fmt);
void *GlobalLock(HGLOBAL h);
WINBOOL GlobalUnlock(HGLOBAL h);
}
#define CreateWindowExA CreateWindowEx
#define CreateWindowA CreateWindow
#define RegisterClassA RegisterClass
#define RegisterClassExA RegisterClassEx
#define DefWindowProcA DefWindowProc
#define PeekMessageA PeekMessage
#define GetMessageA GetMessage
#define DispatchMessageA DispatchMessage
#define PostMessageA PostMessage
#define SendMessageA SendMessage
#define SetWindowTextA SetWindowText
#define LoadCursorA LoadCursor
#define MapVirtualKeyExA MapVirtualKeyEx
#define MapVirtualKeyA MapVirtualKey
#define SetWindowLongA SetWindowLong
#define GetWindowLongA GetWindowLong

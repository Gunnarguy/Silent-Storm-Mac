// s2win32.h: the subset of the Win32 API that the Silent Storm engine uses, implemented natively for macOS.
// Types follow the Windows LLP64 model where layout matters (DWORD and LONG are 32-bit even though
// macOS 'long' is 64-bit). Functions that need state live in port/platform/src/win32.cpp.
#pragma once
#include <stdint.h>
#include <stdarg.h>
#include <alloca.h>
#include <cmath>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <wchar.h>
#include <math.h>
#include <ctype.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
#include <pthread.h>
#include <atomic>
#include <cstdlib>
#include <cwchar>
// The engine has a global 'CRandomGenerator random', which collides with POSIX random(); rename it engine-wide.
#define random S2RandomGenerator

#define S2_PLATFORM_MACOS 1

// ---- basic types ---------------------------------------------------------------------------------
typedef uint32_t DWORD;
typedef uint16_t WORD;
typedef uint8_t BYTE;
typedef int32_t WINBOOL;
// Objective-C has its own 1-byte BOOL; Windows APIs here are declared with the 4-byte WINBOOL so both agree
#ifndef __OBJC__
typedef WINBOOL BOOL;
#endif
typedef int32_t LONG;
typedef uint32_t ULONG;
typedef int32_t INT;
typedef uint32_t UINT;
typedef int16_t SHORT;
typedef uint16_t USHORT;
typedef char CHAR;
typedef unsigned char UCHAR;
typedef wchar_t WCHAR;
typedef float FLOAT;
typedef void VOID;
typedef int64_t LONGLONG;
typedef uint64_t ULONGLONG;
typedef uint64_t DWORD64;
typedef intptr_t INT_PTR;
typedef uintptr_t UINT_PTR;
typedef intptr_t LONG_PTR;
typedef uintptr_t ULONG_PTR;
typedef uintptr_t DWORD_PTR;
typedef size_t SIZE_T;
typedef int32_t HRESULT;
typedef intptr_t LRESULT;
typedef uintptr_t WPARAM;
typedef intptr_t LPARAM;
typedef WORD ATOM;
typedef DWORD COLORREF;
typedef BYTE *LPBYTE, *PBYTE;
typedef DWORD *LPDWORD, *PDWORD;
typedef WORD *LPWORD;
typedef LONG *LPLONG, *PLONG;
typedef WINBOOL *LPBOOL;
typedef void *LPVOID, *PVOID;
typedef const void *LPCVOID;
typedef char *LPSTR, *PSTR;
typedef const char *LPCSTR, *PCSTR;
typedef wchar_t *LPWSTR;
typedef const wchar_t *LPCWSTR;
typedef char TCHAR;
typedef const char *LPCTSTR;
typedef char *LPTSTR;
#ifndef __int64
#define __int64 long long
#endif
#ifndef __int32
#define __int32 int
#endif
#ifndef __int16
#define __int16 short
#endif
#ifndef __int8
#define __int8 char
#endif

#define S2_DECLARE_HANDLE(n) struct n##__ { int unused; }; typedef struct n##__ *n
typedef void *HANDLE;
S2_DECLARE_HANDLE(HWND);
S2_DECLARE_HANDLE(HINSTANCE);
S2_DECLARE_HANDLE(HDC);
S2_DECLARE_HANDLE(HBITMAP);
S2_DECLARE_HANDLE(HBRUSH);
S2_DECLARE_HANDLE(HCURSOR);
S2_DECLARE_HANDLE(HICON);
S2_DECLARE_HANDLE(HMENU);
S2_DECLARE_HANDLE(HPALETTE);
S2_DECLARE_HANDLE(HFONT);
S2_DECLARE_HANDLE(HKL);
S2_DECLARE_HANDLE(HKEY);
S2_DECLARE_HANDLE(HGLRC);
S2_DECLARE_HANDLE(HMONITOR);
typedef HINSTANCE HMODULE;
typedef void *HGDIOBJ;
typedef HANDLE HGLOBAL;

#ifndef TRUE
#define TRUE 1
#endif
#ifndef FALSE
#define FALSE 0
#endif
#define CONST const
#define WINAPI
#define APIENTRY
#define CALLBACK
#define WINBASEAPI
#define PASCAL
#define FAR
#define NEAR
#define IN
#define OUT
#define OPTIONAL
#ifndef __stdcall
#define __stdcall
#endif
#ifndef __cdecl
#define __cdecl
#endif
#ifndef __fastcall
#define __fastcall
#endif
#ifndef _cdecl
#define _cdecl
#endif
#define __forceinline inline __attribute__((always_inline))
#define MAX_PATH 260
#define _MAX_PATH 260
#define INFINITE 0xFFFFFFFFu
#define WAIT_OBJECT_0 0u
#define WAIT_TIMEOUT 258u
#define WAIT_FAILED 0xFFFFFFFFu
#define INVALID_HANDLE_VALUE ((HANDLE)(intptr_t)-1)
#define INVALID_FILE_SIZE ((DWORD)0xFFFFFFFF)
#define INVALID_FILE_ATTRIBUTES ((DWORD)-1)

// ---- HRESULT ------------------------------------------------------------------------------------
#define S_OK ((HRESULT)0)
#define S_FALSE ((HRESULT)1)
#define E_FAIL ((HRESULT)0x80004005)
#define E_NOTIMPL ((HRESULT)0x80004001)
#define E_OUTOFMEMORY ((HRESULT)0x8007000E)
#define E_INVALIDARG ((HRESULT)0x80070057)
#define E_NOINTERFACE ((HRESULT)0x80004002)
#define E_POINTER ((HRESULT)0x80004003)
#define SUCCEEDED(hr) (((HRESULT)(hr)) >= 0)
#define FAILED(hr) (((HRESULT)(hr)) < 0)
#define MAKE_HRESULT(sev, fac, code) ((HRESULT)(((unsigned long)(sev) << 31) | ((unsigned long)(fac) << 16) | ((unsigned long)(code))))

// ---- small structs ------------------------------------------------------------------------------
typedef struct tagRECT { LONG left, top, right, bottom; } RECT, *LPRECT, *PRECT;
typedef const RECT *LPCRECT;
typedef struct tagPOINT { LONG x, y; } POINT, *LPPOINT, *PPOINT;
typedef struct tagSIZE { LONG cx, cy; } SIZE, *LPSIZE;
typedef struct _FILETIME { DWORD dwLowDateTime, dwHighDateTime; } FILETIME, *LPFILETIME;
typedef struct _SYSTEMTIME { WORD wYear, wMonth, wDayOfWeek, wDay, wHour, wMinute, wSecond, wMilliseconds; } SYSTEMTIME, *LPSYSTEMTIME;
typedef union _LARGE_INTEGER { struct { DWORD LowPart; LONG HighPart; }; struct { DWORD LowPart; LONG HighPart; } u; LONGLONG QuadPart; } LARGE_INTEGER, *PLARGE_INTEGER;
typedef union _ULARGE_INTEGER { struct { DWORD LowPart; DWORD HighPart; }; ULONGLONG QuadPart; } ULARGE_INTEGER;
typedef struct _GUID { uint32_t Data1; uint16_t Data2; uint16_t Data3; uint8_t Data4[8]; } GUID, IID, CLSID;
typedef const GUID &REFGUID;
typedef const IID &REFIID;
typedef const CLSID &REFCLSID;
typedef struct tagRGBQUAD { BYTE rgbBlue, rgbGreen, rgbRed, rgbReserved; } RGBQUAD;
#pragma pack(push, 2)
typedef struct tagBITMAPFILEHEADER { WORD bfType; DWORD bfSize; WORD bfReserved1, bfReserved2; DWORD bfOffBits; } BITMAPFILEHEADER;
#pragma pack(pop)
typedef struct tagBITMAPINFOHEADER { DWORD biSize; LONG biWidth, biHeight; WORD biPlanes, biBitCount; DWORD biCompression, biSizeImage; LONG biXPelsPerMeter, biYPelsPerMeter; DWORD biClrUsed, biClrImportant; } BITMAPINFOHEADER;
typedef struct tagBITMAPINFO { BITMAPINFOHEADER bmiHeader; RGBQUAD bmiColors[1]; } BITMAPINFO;
typedef struct tagBITMAP { LONG bmType, bmWidth, bmHeight, bmWidthBytes; WORD bmPlanes, bmBitsPixel; LPVOID bmBits; } BITMAP;
typedef struct tagPALETTEENTRY { BYTE peRed, peGreen, peBlue, peFlags; } PALETTEENTRY;
typedef struct tagLOGPALETTE { WORD palVersion, palNumEntries; PALETTEENTRY palPalEntry[1]; } LOGPALETTE;
#define BI_RGB 0
typedef struct _MEMORYSTATUS { DWORD dwLength, dwMemoryLoad; SIZE_T dwTotalPhys, dwAvailPhys, dwTotalPageFile, dwAvailPageFile, dwTotalVirtual, dwAvailVirtual; } MEMORYSTATUS, *LPMEMORYSTATUS;

// ---- macros -------------------------------------------------------------------------------------
#define ZeroMemory(p, n) memset((p), 0, (n))
#define FillMemory(p, n, v) memset((p), (v), (n))
#define CopyMemory(d, s, n) memcpy((d), (s), (n))
#define MoveMemory(d, s, n) memmove((d), (s), (n))
#define LOWORD(l) ((WORD)(((DWORD_PTR)(l)) & 0xffff))
#define HIWORD(l) ((WORD)((((DWORD_PTR)(l)) >> 16) & 0xffff))
#define LOBYTE(w) ((BYTE)(((DWORD_PTR)(w)) & 0xff))
#define HIBYTE(w) ((BYTE)((((DWORD_PTR)(w)) >> 8) & 0xff))
#define MAKELONG(a, b) ((LONG)(((WORD)(((DWORD_PTR)(a)) & 0xffff)) | ((DWORD)((WORD)(((DWORD_PTR)(b)) & 0xffff))) << 16))
#define MAKEWORD(a, b) ((WORD)(((BYTE)(((DWORD_PTR)(a)) & 0xff)) | ((WORD)((BYTE)(((DWORD_PTR)(b)) & 0xff))) << 8))
#define MAKEINTRESOURCE(i) ((LPSTR)((ULONG_PTR)((WORD)(i))))
#define MAKEINTRESOURCEA MAKEINTRESOURCE
#define RGB(r, g, b) ((COLORREF)(((BYTE)(r) | ((WORD)((BYTE)(g)) << 8)) | (((DWORD)(BYTE)(b)) << 16)))
#define GetRValue(c) ((BYTE)(c))
#define GetGValue(c) ((BYTE)(((WORD)(c)) >> 8))
#define GetBValue(c) ((BYTE)((c) >> 16))
#define UNREFERENCED_PARAMETER(p) (void)(p)
#define _countof(a) (sizeof(a) / sizeof((a)[0]))
#define __assume(x) ((void)0)
#define _alloca alloca
#define LOCALE_USER_DEFAULT 0x400
#define LOCALE_IDATE 0x21
#define MB_OK 0
#define MB_ICONERROR 0x10
#define MB_ICONSTOP 0x10
#define MB_YESNO 4
#define IDYES 6
#define CP_ACP 0
#define CP_UTF8 65001

// ---- CRT name differences -----------------------------------------------------------------------
#define _stricmp strcasecmp
#define stricmp strcasecmp
#define _strnicmp strncasecmp
#define strnicmp strncasecmp
#define _wcsicmp wcscasecmp
#define _snprintf snprintf
#define _vsnprintf vsnprintf
#define _snwprintf swprintf
#define _strdup strdup
#define _unlink unlink
#define _access access
#define _getcwd getcwd
#define _chdir chdir
#define _finite(x) std::isfinite(x)
#define _isnan(x) std::isnan(x)
#define _hypot hypot
#define _stat stat
#define _fstat fstat
#define _copysign copysign
#define _MAX_DRIVE 3
#define _MAX_DIR 256
#define _MAX_FNAME 256
#define _MAX_EXT 256
inline int sprintf_s(char *buf, size_t n, const char *fmt, ...) { va_list a; va_start(a, fmt); int r = vsnprintf(buf, n, fmt, a); va_end(a); return r; }
template<size_t N> inline int sprintf_s(char (&buf)[N], const char *fmt, ...) { va_list a; va_start(a, fmt); int r = vsnprintf(buf, N, fmt, a); va_end(a); return r; }
inline char *_strlwr(char *s) { for (char *p = s; *p; ++p) *p = (char)tolower((unsigned char)*p); return s; }
inline char *_strupr(char *s) { for (char *p = s; *p; ++p) *p = (char)toupper((unsigned char)*p); return s; }
#define strlwr _strlwr
#define strupr _strupr
inline char *_itoa(int v, char *buf, int radix) { if (radix == 16) sprintf(buf, "%x", v); else sprintf(buf, "%d", v); return buf; }
#define itoa _itoa
inline char *_ltoa(long v, char *buf, int radix) { return _itoa((int)v, buf, radix); }
inline wchar_t *_itow(int v, wchar_t *buf, int radix) { char t[34]; _itoa(v, t, radix); size_t i = 0; for (; t[i]; ++i) buf[i] = (wchar_t)t[i]; buf[i] = 0; return buf; }
inline long _wtol(const wchar_t *s) { return wcstol(s, nullptr, 10); }
inline int _wtoi(const wchar_t *s) { return (int)wcstol(s, nullptr, 10); }
inline double _wtof(const wchar_t *s) { return wcstod(s, nullptr); }
inline int64_t _atoi64(const char *s) { return strtoll(s, nullptr, 10); }
inline uint64_t __rdtsc() { uint64_t v; __asm__ volatile("mrs %0, cntvct_el0" : "=r"(v)); return v; }

// Windows wide printf: no buffer size, and %s / %c mean wide string / wide char (POSIX spells those %ls / %lc).
int S2vswprintf(wchar_t *buf, const wchar_t *fmt, va_list va);
inline int swprintf(wchar_t *buf, const wchar_t *fmt, ...) { va_list a; va_start(a, fmt); int r = S2vswprintf(buf, fmt, a); va_end(a); return r; }
inline int vswprintf(wchar_t *buf, const wchar_t *fmt, va_list va) { return S2vswprintf(buf, fmt, va); }
#define _vsnwprintf(b, n, f, v) vswprintf(b, n, f, v)

extern "C" {
// ---- time ---------------------------------------------------------------------------------------
DWORD GetTickCount();
DWORD timeGetTime();
WINBOOL QueryPerformanceCounter(LARGE_INTEGER *p);
WINBOOL QueryPerformanceFrequency(LARGE_INTEGER *p);
void Sleep(DWORD ms);
void GetLocalTime(SYSTEMTIME *t);
void GetSystemTime(SYSTEMTIME *t);
WINBOOL FileTimeToSystemTime(const FILETIME *f, SYSTEMTIME *t);
WINBOOL FileTimeToLocalFileTime(const FILETIME *f, FILETIME *l);
WINBOOL SystemTimeToFileTime(const SYSTEMTIME *t, FILETIME *f);
LONG CompareFileTime(const FILETIME *a, const FILETIME *b);
DWORD GetDoubleClickTime();

// ---- synchronisation ----------------------------------------------------------------------------
struct CRITICAL_SECTION { pthread_mutex_t m; };
typedef CRITICAL_SECTION *LPCRITICAL_SECTION;
void InitializeCriticalSection(CRITICAL_SECTION *cs);
void DeleteCriticalSection(CRITICAL_SECTION *cs);
void EnterCriticalSection(CRITICAL_SECTION *cs);
void LeaveCriticalSection(CRITICAL_SECTION *cs);
WINBOOL TryEnterCriticalSection(CRITICAL_SECTION *cs);
#ifndef __OBJC__
HANDLE CreateEvent(void *sa, WINBOOL manualReset, WINBOOL initialState, LPCSTR name);
#define CreateEventA CreateEvent
#endif
WINBOOL SetEvent(HANDLE h);
WINBOOL ResetEvent(HANDLE h);
DWORD WaitForSingleObject(HANDLE h, DWORD ms);
DWORD WaitForMultipleObjects(DWORD n, const HANDLE *h, WINBOOL all, DWORD ms);
WINBOOL CloseHandle(HANDLE h);
typedef DWORD (*LPTHREAD_START_ROUTINE)(void *);
HANDLE CreateThread(void *sa, SIZE_T stack, LPTHREAD_START_ROUTINE fn, void *arg, DWORD flags, DWORD *id);
DWORD GetCurrentThreadId();
WINBOOL SetThreadPriority(HANDLE h, int prio);
#ifndef __OBJC__
HANDLE GetCurrentThread();
#endif
#ifndef __OBJC__
HANDLE GetCurrentProcess();
#endif
#define THREAD_PRIORITY_NORMAL 0
#define THREAD_PRIORITY_LOWEST -2
#define THREAD_PRIORITY_BELOW_NORMAL -1
#define THREAD_PRIORITY_ABOVE_NORMAL 1
#define THREAD_PRIORITY_HIGHEST 2
#define THREAD_PRIORITY_IDLE -15
inline LONG InterlockedIncrement(volatile LONG *p) { return __atomic_add_fetch(p, 1, __ATOMIC_SEQ_CST); }
inline LONG InterlockedDecrement(volatile LONG *p) { return __atomic_sub_fetch(p, 1, __ATOMIC_SEQ_CST); }
inline LONG InterlockedExchange(volatile LONG *p, LONG v) { return __atomic_exchange_n(p, v, __ATOMIC_SEQ_CST); }
inline LONG InterlockedExchangeAdd(volatile LONG *p, LONG v) { return __atomic_fetch_add(p, v, __ATOMIC_SEQ_CST); }
inline LONG InterlockedCompareExchange(volatile LONG *p, LONG x, LONG c) { __atomic_compare_exchange_n(p, &c, x, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); return c; }

// ---- files (paths may use '\'; they are converted and matched case-insensitively) ---------------
#define GENERIC_READ 0x80000000u
#define GENERIC_WRITE 0x40000000u
#define FILE_SHARE_READ 1
#define FILE_SHARE_WRITE 2
#define CREATE_NEW 1
#define CREATE_ALWAYS 2
#define OPEN_EXISTING 3
#define OPEN_ALWAYS 4
#define TRUNCATE_EXISTING 5
#define FILE_ATTRIBUTE_READONLY 0x1
#define FILE_ATTRIBUTE_HIDDEN 0x2
#define FILE_ATTRIBUTE_SYSTEM 0x4
#define FILE_ATTRIBUTE_DIRECTORY 0x10
#define FILE_ATTRIBUTE_ARCHIVE 0x20
#define FILE_ATTRIBUTE_NORMAL 0x80
#define FILE_FLAG_SEQUENTIAL_SCAN 0x08000000
#define FILE_FLAG_RANDOM_ACCESS 0x10000000
#define FILE_BEGIN 0
#define FILE_CURRENT 1
#define FILE_END 2
#define _A_SUBDIR 0x10
#define _A_HIDDEN 0x02
#define _A_SYSTEM 0x04
#define _A_RDONLY 0x01
#define _A_NORMAL 0x00
#define _A_ARCH 0x20
typedef struct _WIN32_FIND_DATAA { DWORD dwFileAttributes; FILETIME ftCreationTime, ftLastAccessTime, ftLastWriteTime; DWORD nFileSizeHigh, nFileSizeLow, dwReserved0, dwReserved1; CHAR cFileName[MAX_PATH]; CHAR cAlternateFileName[14]; } WIN32_FIND_DATAA, WIN32_FIND_DATA, *LPWIN32_FIND_DATA;
struct _finddata_t { unsigned attrib; int64_t time_create, time_access, time_write; uint32_t size; char name[MAX_PATH]; };
const char *S2HostPath(const char *winPath, char *out, size_t outSize); // '\' -> '/', case-insensitive resolve
FILE *S2fopen(const char *path, const char *mode);
#define fopen S2fopen
HANDLE CreateFile(LPCSTR name, DWORD access, DWORD share, void *sa, DWORD disposition, DWORD flags, HANDLE tmpl);
#define CreateFileA CreateFile
WINBOOL ReadFile(HANDLE h, void *buf, DWORD n, DWORD *read, void *ov);
WINBOOL WriteFile(HANDLE h, const void *buf, DWORD n, DWORD *written, void *ov);
DWORD SetFilePointer(HANDLE h, LONG dist, LONG *distHigh, DWORD method);
DWORD GetFileSize(HANDLE h, DWORD *high);
WINBOOL GetFileTime(HANDLE h, FILETIME *c, FILETIME *a, FILETIME *w);
WINBOOL FlushFileBuffers(HANDLE h);
WINBOOL DeleteFile(LPCSTR name);
#define DeleteFileA DeleteFile
WINBOOL CreateDirectory(LPCSTR name, void *sa);
#define CreateDirectoryA CreateDirectory
WINBOOL RemoveDirectory(LPCSTR name);
#define RemoveDirectoryA RemoveDirectory
WINBOOL MoveFile(LPCSTR from, LPCSTR to);
#define MoveFileA MoveFile
WINBOOL CopyFile(LPCSTR from, LPCSTR to, WINBOOL failIfExists);
#define CopyFileA CopyFile
DWORD GetFileAttributes(LPCSTR name);
#define GetFileAttributesA GetFileAttributes
WINBOOL SetFileAttributes(LPCSTR name, DWORD attr);
#define SetFileAttributesA SetFileAttributes
DWORD GetCurrentDirectory(DWORD n, LPSTR buf);
#define GetCurrentDirectoryA GetCurrentDirectory
WINBOOL SetCurrentDirectory(LPCSTR dir);
#define SetCurrentDirectoryA SetCurrentDirectory
DWORD GetModuleFileName(HMODULE m, LPSTR buf, DWORD n);
#define GetModuleFileNameA GetModuleFileName
HANDLE FindFirstFile(LPCSTR pattern, WIN32_FIND_DATA *fd);
#define FindFirstFileA FindFirstFile
WINBOOL FindNextFile(HANDLE h, WIN32_FIND_DATA *fd);
#define FindNextFileA FindNextFile
WINBOOL FindClose(HANDLE h);
intptr_t _findfirst(const char *pattern, struct _finddata_t *fd);
int _findnext(intptr_t h, struct _finddata_t *fd);
int _findclose(intptr_t h);
int _mkdir(const char *path);
int _rmdir(const char *path);
#define mkdir_win _mkdir
void _splitpath(const char *path, char *drive, char *dir, char *fname, char *ext);
void _makepath(char *path, const char *drive, const char *dir, const char *fname, const char *ext);
char *_fullpath(char *abs, const char *rel, size_t n);

// ---- process, memory, misc ----------------------------------------------------------------------
void OutputDebugString(LPCSTR s);
#define OutputDebugStringA OutputDebugString
WINBOOL IsDebuggerPresent();
WINBOOL IsBadReadPtr(const void *p, UINT_PTR n);
WINBOOL IsBadWritePtr(void *p, UINT_PTR n);
HMODULE GetModuleHandle(LPCSTR name);
#define GetModuleHandleA GetModuleHandle
HMODULE LoadLibrary(LPCSTR name);
#define LoadLibraryA LoadLibrary
WINBOOL FreeLibrary(HMODULE m);
void *GetProcAddress(HMODULE m, LPCSTR name);
void GlobalMemoryStatus(MEMORYSTATUS *ms);
DWORD GetLastError();
void SetLastError(DWORD e);
int MessageBox(HWND w, LPCSTR text, LPCSTR caption, UINT type);
#define MessageBoxA MessageBox
int WideCharToMultiByte(UINT cp, DWORD flags, LPCWSTR w, int wn, LPSTR s, int sn, LPCSTR def, WINBOOL *used);
int MultiByteToWideChar(UINT cp, DWORD flags, LPCSTR s, int sn, LPWSTR w, int wn);
int GetLocaleInfo(DWORD locale, DWORD type, LPSTR buf, int n);
#define GetLocaleInfoA GetLocaleInfo
UINT GetACP();
HKL GetKeyboardLayout(DWORD thread);
void ExitProcess(UINT code);
DWORD GetEnvironmentVariable(LPCSTR name, LPSTR buf, DWORD n);
#define GetEnvironmentVariableA GetEnvironmentVariable
} // extern "C"

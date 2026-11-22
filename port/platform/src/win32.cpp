// win32.cpp: macOS implementations of the Win32 calls the engine makes (time, threads, files, text).
#include <unordered_map>
#include <mutex>
#include <ctype.h>
#include "s2win32.h"
#include <dirent.h>
#include <errno.h>
#include <fnmatch.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/mach_vm.h>
#include <mach-o/dyld.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <iconv.h>
#include <string>
#include <vector>
#include <mutex>
#include <condition_variable>
#include <chrono>
#include <thread>

#undef fopen

// ---------------------------------------------------------------------------------------------------
// time
static uint64_t S2Nanos()
{
	static mach_timebase_info_data_t tb = [] { mach_timebase_info_data_t t; mach_timebase_info(&t); return t; }();
	return mach_absolute_time() * tb.numer / tb.denom;
}
DWORD GetTickCount() { return (DWORD)(S2Nanos() / 1000000ull); }
DWORD timeGetTime() { return GetTickCount(); }
BOOL QueryPerformanceFrequency(LARGE_INTEGER *p) { p->QuadPart = 1000000000ll; return TRUE; }
BOOL QueryPerformanceCounter(LARGE_INTEGER *p) { p->QuadPart = (LONGLONG)S2Nanos(); return TRUE; }
void Sleep(DWORD ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }
// Kept as a plain variable so this file stays free of the Settings code (the texture tool links it without the game):
// settings.mm writes the player's choice, or the macOS setting, into it twice a second.
int s2doubleClickMs = 500;
DWORD GetDoubleClickTime() { return (DWORD)s2doubleClickMs; }

static void S2TmToSystemTime(const struct tm &t, int ms, SYSTEMTIME *s)
{
	s->wYear = (WORD)(t.tm_year + 1900); s->wMonth = (WORD)(t.tm_mon + 1); s->wDayOfWeek = (WORD)t.tm_wday;
	s->wDay = (WORD)t.tm_mday; s->wHour = (WORD)t.tm_hour; s->wMinute = (WORD)t.tm_min; s->wSecond = (WORD)t.tm_sec; s->wMilliseconds = (WORD)ms;
}
void GetLocalTime(SYSTEMTIME *s) { struct timeval tv; gettimeofday(&tv, 0); struct tm t; localtime_r(&tv.tv_sec, &t); S2TmToSystemTime(t, (int)(tv.tv_usec / 1000), s); }
void GetSystemTime(SYSTEMTIME *s) { struct timeval tv; gettimeofday(&tv, 0); struct tm t; gmtime_r(&tv.tv_sec, &t); S2TmToSystemTime(t, (int)(tv.tv_usec / 1000), s); }
// FILETIME: 100 ns ticks since 1601-01-01 UTC
static const uint64_t S2_EPOCH_DIFF = 116444736000000000ull;
static uint64_t S2FT(const FILETIME *f) { return ((uint64_t)f->dwHighDateTime << 32) | f->dwLowDateTime; }
static void S2SetFT(FILETIME *f, uint64_t v) { f->dwLowDateTime = (DWORD)v; f->dwHighDateTime = (DWORD)(v >> 32); }
static void S2UnixToFT(time_t t, long nsec, FILETIME *f) { S2SetFT(f, (uint64_t)t * 10000000ull + (uint64_t)(nsec / 100) + S2_EPOCH_DIFF); }
BOOL FileTimeToSystemTime(const FILETIME *f, SYSTEMTIME *s)
{
	uint64_t v = S2FT(f) - S2_EPOCH_DIFF; time_t t = (time_t)(v / 10000000ull); struct tm tm; gmtime_r(&t, &tm);
	S2TmToSystemTime(tm, (int)((v / 10000ull) % 1000), s); return TRUE;
}
BOOL FileTimeToLocalFileTime(const FILETIME *f, FILETIME *l)
{
	uint64_t v = S2FT(f) - S2_EPOCH_DIFF; time_t t = (time_t)(v / 10000000ull); struct tm tm; localtime_r(&t, &tm);
	S2SetFT(l, S2FT(f) + (int64_t)tm.tm_gmtoff * 10000000ll); return TRUE;
}
BOOL SystemTimeToFileTime(const SYSTEMTIME *s, FILETIME *f)
{
	struct tm t = {}; t.tm_year = s->wYear - 1900; t.tm_mon = s->wMonth - 1; t.tm_mday = s->wDay; t.tm_hour = s->wHour; t.tm_min = s->wMinute; t.tm_sec = s->wSecond;
	S2UnixToFT(timegm(&t), s->wMilliseconds * 1000000l, f); return TRUE;
}
LONG CompareFileTime(const FILETIME *a, const FILETIME *b) { uint64_t x = S2FT(a), y = S2FT(b); return x < y ? -1 : x > y ? 1 : 0; }

// ---------------------------------------------------------------------------------------------------
// synchronisation
void InitializeCriticalSection(CRITICAL_SECTION *cs)
{
	pthread_mutexattr_t a; pthread_mutexattr_init(&a); pthread_mutexattr_settype(&a, PTHREAD_MUTEX_RECURSIVE);
	pthread_mutex_init(&cs->m, &a); pthread_mutexattr_destroy(&a);
}
void DeleteCriticalSection(CRITICAL_SECTION *cs) { pthread_mutex_destroy(&cs->m); }
void EnterCriticalSection(CRITICAL_SECTION *cs) { pthread_mutex_lock(&cs->m); }
void LeaveCriticalSection(CRITICAL_SECTION *cs) { pthread_mutex_unlock(&cs->m); }
BOOL TryEnterCriticalSection(CRITICAL_SECTION *cs) { return pthread_mutex_trylock(&cs->m) == 0; }

namespace {
enum S2HandleKind { S2H_EVENT = 0x45564e54, S2H_THREAD = 0x54485244, S2H_FILE = 0x46494c45, S2H_FIND = 0x46494e44 };
struct S2Handle { uint32_t kind; virtual ~S2Handle() {} };
struct S2Event : S2Handle
{
	std::mutex m; std::condition_variable cv; bool manual, signalled;
	S2Event(bool man, bool init) : manual(man), signalled(init) { kind = S2H_EVENT; }
};
struct S2Thread : S2Handle
{
	std::thread t; std::mutex m; std::condition_variable cv; bool done = false; DWORD exitCode = 0;
	S2Thread() { kind = S2H_THREAD; }
	~S2Thread() { if (t.joinable()) t.detach(); }
};
struct S2File : S2Handle { FILE *f = nullptr; std::string path; S2File() { kind = S2H_FILE; } ~S2File() { if (f) fclose(f); } };
struct S2Find : S2Handle { std::vector<std::string> names; std::string dir; size_t pos = 0; S2Find() { kind = S2H_FIND; } };
template<class T> T *S2As(HANDLE h, uint32_t kind) { S2Handle *p = (S2Handle*)h; return (p && h != INVALID_HANDLE_VALUE && p->kind == kind) ? (T*)p : nullptr; }
}

HANDLE CreateEvent(void *, BOOL manualReset, BOOL initialState, LPCSTR) { return new S2Event(manualReset != 0, initialState != 0); }
BOOL SetEvent(HANDLE h)
{
	S2Event *e = S2As<S2Event>(h, S2H_EVENT); if (!e) return FALSE;
	{ std::lock_guard<std::mutex> l(e->m); e->signalled = true; }
	if (e->manual) e->cv.notify_all(); else e->cv.notify_one();
	return TRUE;
}
BOOL ResetEvent(HANDLE h) { S2Event *e = S2As<S2Event>(h, S2H_EVENT); if (!e) return FALSE; std::lock_guard<std::mutex> l(e->m); e->signalled = false; return TRUE; }
DWORD WaitForSingleObject(HANDLE h, DWORD ms)
{
	if (S2Event *e = S2As<S2Event>(h, S2H_EVENT))
	{
		std::unique_lock<std::mutex> l(e->m);
		auto ready = [e] { return e->signalled; };
		if (ms == INFINITE) e->cv.wait(l, ready);
		else if (!e->cv.wait_for(l, std::chrono::milliseconds(ms), ready)) return WAIT_TIMEOUT;
		if (!e->manual) e->signalled = false;
		return WAIT_OBJECT_0;
	}
	if (S2Thread *t = S2As<S2Thread>(h, S2H_THREAD))
	{
		std::unique_lock<std::mutex> l(t->m);
		auto ready = [t] { return t->done; };
		if (ms == INFINITE) t->cv.wait(l, ready);
		else if (!t->cv.wait_for(l, std::chrono::milliseconds(ms), ready)) return WAIT_TIMEOUT;
		return WAIT_OBJECT_0;
	}
	return WAIT_FAILED;
}
DWORD WaitForMultipleObjects(DWORD n, const HANDLE *h, BOOL all, DWORD ms)
{
	// the engine waits on at most a couple of handles; poll at 1 ms granularity
	uint64_t deadline = ms == INFINITE ? UINT64_MAX : S2Nanos() + (uint64_t)ms * 1000000ull;
	for (;;)
	{
		DWORD ready = 0, first = WAIT_TIMEOUT;
		for (DWORD i = 0; i < n; ++i)
			if (WaitForSingleObject(h[i], 0) == WAIT_OBJECT_0) { ++ready; if (first == WAIT_TIMEOUT) first = i; }
		if (all ? ready == n : ready > 0) return all ? WAIT_OBJECT_0 : WAIT_OBJECT_0 + first;
		if (S2Nanos() >= deadline) return WAIT_TIMEOUT;
		std::this_thread::sleep_for(std::chrono::milliseconds(1));
	}
}
HANDLE CreateThread(void *, SIZE_T, LPTHREAD_START_ROUTINE fn, void *arg, DWORD, DWORD *id)
{
	S2Thread *t = new S2Thread();
	t->t = std::thread([t, fn, arg] {
		DWORD r = fn(arg);
		std::lock_guard<std::mutex> l(t->m); t->exitCode = r; t->done = true; t->cv.notify_all();
	});
	if (id) *id = (DWORD)std::hash<std::thread::id>()(t->t.get_id());
	return t;
}
BOOL CloseHandle(HANDLE h)
{
	if (!h || h == INVALID_HANDLE_VALUE) return FALSE;
	S2Handle *p = (S2Handle*)h;
	if (p->kind != S2H_EVENT && p->kind != S2H_THREAD && p->kind != S2H_FILE && p->kind != S2H_FIND) return FALSE;
	delete p; return TRUE;
}
DWORD GetCurrentThreadId() { uint64_t tid; pthread_threadid_np(nullptr, &tid); return (DWORD)tid; }
BOOL SetThreadPriority(HANDLE, int) { return TRUE; }
HANDLE GetCurrentThread() { return (HANDLE)(intptr_t)-2; }
HANDLE GetCurrentProcess() { return (HANDLE)(intptr_t)-1; }

// ---------------------------------------------------------------------------------------------------
// paths: engine paths use '\', may carry a drive letter, and assume a case-insensitive file system
static std::string S2Slashes(const char *p)
{
	std::string s(p ? p : "");
	for (char &c : s) if (c == '\\') c = '/';
	if (s.size() >= 2 && s[1] == ':' && isalpha((unsigned char)s[0])) s.erase(0, 2);
	while (s.find("//") != std::string::npos) s.replace(s.find("//"), 2, "/");
	return s;
}
// Folder listings for S2Resolve: every failed lookup used to opendir and read the whole folder, and the engine probes for
// loose files that do not exist constantly (79% of the main thread in a hidden run). A listing is kept per folder and reread
// only when the folder's modification time changes, so a new save or test file is still seen.
struct S2DirListing { struct timespec stamp; std::unordered_map<std::string, std::string> names; };
static bool S2FindInDir(const std::string &dir, const std::string &part, std::string *found)
{
	static std::mutex lock;
	static std::unordered_map<std::string, S2DirListing> cache;
	struct stat st;
	if (stat(dir.c_str(), &st) != 0) return false;
	std::string key(part);
	for (char &c : key) c = (char)tolower((unsigned char)c);
	std::lock_guard<std::mutex> guard(lock);
	S2DirListing &l = cache[dir];
	if (l.stamp.tv_sec != st.st_mtimespec.tv_sec || l.stamp.tv_nsec != st.st_mtimespec.tv_nsec)
	{
		l.names.clear();
		if (DIR *d = opendir(dir.c_str()))
		{
			while (dirent *e = readdir(d))
			{
				std::string name(e->d_name);
				for (char &c : name) c = (char)tolower((unsigned char)c);
				l.names.emplace(std::move(name), e->d_name);
			}
			closedir(d);
		}
		l.stamp = st.st_mtimespec;
	}
	auto it = l.names.find(key);
	if (it == l.names.end()) return false;
	*found = it->second;
	return true;
}
// resolve each component case-insensitively when the exact name does not exist (case-sensitive volumes)
static std::string S2Resolve(const std::string &in)
{
	struct stat st;
	if (in.empty() || stat(in.c_str(), &st) == 0) return in;
	std::string out = in[0] == '/' ? "/" : "";
	size_t i = in[0] == '/' ? 1 : 0;
	while (i <= in.size())
	{
		size_t j = in.find('/', i); if (j == std::string::npos) j = in.size();
		std::string part = in.substr(i, j - i), base = out.empty() ? "." : out;
		std::string next = out + part;
		if (!part.empty() && stat(next.c_str(), &st) != 0)
		{
			std::string found;
			if (S2FindInDir(base, part, &found)) next = out + found;
		}
		out = next;
		if (j < in.size()) out += '/';
		i = j + 1;
	}
	return out;
}
const char *S2HostPath(const char *winPath, char *out, size_t outSize)
{
	std::string r = S2Resolve(S2Slashes(winPath));
	snprintf(out, outSize, "%s", r.c_str());
	return out;
}
FILE *S2fopen(const char *path, const char *mode)
{
	char buf[1024]; S2HostPath(path, buf, sizeof buf);
	return fopen(buf, mode);
}

HANDLE CreateFile(LPCSTR name, DWORD access, DWORD, void *, DWORD disposition, DWORD, HANDLE)
{
	char p[1024]; S2HostPath(name, p, sizeof p);
	struct stat st; bool exists = stat(p, &st) == 0 && !S_ISDIR(st.st_mode);
	const char *mode = nullptr;
	bool w = (access & GENERIC_WRITE) != 0, r = (access & GENERIC_READ) != 0 || !w;
	switch (disposition)
	{
	case CREATE_NEW: if (exists) { errno = EEXIST; return INVALID_HANDLE_VALUE; } mode = r ? "w+b" : "wb"; break;
	case CREATE_ALWAYS: mode = r ? "w+b" : "wb"; break;
	case OPEN_EXISTING: if (!exists) { errno = ENOENT; return INVALID_HANDLE_VALUE; } mode = w ? "r+b" : "rb"; break;
	case OPEN_ALWAYS: mode = exists ? (w ? "r+b" : "rb") : "w+b"; break;
	case TRUNCATE_EXISTING: if (!exists) { errno = ENOENT; return INVALID_HANDLE_VALUE; } mode = "w+b"; break;
	default: mode = "rb";
	}
	FILE *f = fopen(p, mode);
	if (!f) return INVALID_HANDLE_VALUE;
	S2File *h = new S2File(); h->f = f; h->path = p; return h;
}
BOOL ReadFile(HANDLE h, void *buf, DWORD n, DWORD *read, void *)
{
	S2File *f = S2As<S2File>(h, S2H_FILE); if (!f) return FALSE;
	size_t r = fread(buf, 1, n, f->f); if (read) *read = (DWORD)r; return !ferror(f->f);
}
BOOL WriteFile(HANDLE h, const void *buf, DWORD n, DWORD *written, void *)
{
	S2File *f = S2As<S2File>(h, S2H_FILE); if (!f) return FALSE;
	size_t r = fwrite(buf, 1, n, f->f); if (written) *written = (DWORD)r; return r == n;
}
DWORD SetFilePointer(HANDLE h, LONG dist, LONG *distHigh, DWORD method)
{
	S2File *f = S2As<S2File>(h, S2H_FILE); if (!f) return INVALID_FILE_SIZE;
	int64_t off = distHigh ? (((int64_t)*distHigh << 32) | (uint32_t)dist) : dist;
	if (fseeko(f->f, off, method == FILE_BEGIN ? SEEK_SET : method == FILE_END ? SEEK_END : SEEK_CUR) != 0) return INVALID_FILE_SIZE;
	int64_t pos = ftello(f->f); if (distHigh) *distHigh = (LONG)(pos >> 32); return (DWORD)pos;
}
DWORD GetFileSize(HANDLE h, DWORD *high)
{
	S2File *f = S2As<S2File>(h, S2H_FILE); if (!f) return INVALID_FILE_SIZE;
	struct stat st; if (fstat(fileno(f->f), &st) != 0) return INVALID_FILE_SIZE;
	if (high) *high = (DWORD)((uint64_t)st.st_size >> 32); return (DWORD)st.st_size;
}
BOOL GetFileTime(HANDLE h, FILETIME *c, FILETIME *a, FILETIME *w)
{
	S2File *f = S2As<S2File>(h, S2H_FILE); if (!f) return FALSE;
	struct stat st; if (fstat(fileno(f->f), &st) != 0) return FALSE;
	if (c) S2UnixToFT(st.st_birthtimespec.tv_sec, st.st_birthtimespec.tv_nsec, c);
	if (a) S2UnixToFT(st.st_atimespec.tv_sec, st.st_atimespec.tv_nsec, a);
	if (w) S2UnixToFT(st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec, w);
	return TRUE;
}
BOOL FlushFileBuffers(HANDLE h) { S2File *f = S2As<S2File>(h, S2H_FILE); return f && fflush(f->f) == 0; }
BOOL DeleteFile(LPCSTR name) { char p[1024]; S2HostPath(name, p, sizeof p); return unlink(p) == 0; }
BOOL CreateDirectory(LPCSTR name, void *) { std::string p = S2Slashes(name); return mkdir(p.c_str(), 0755) == 0; }
BOOL RemoveDirectory(LPCSTR name) { char p[1024]; S2HostPath(name, p, sizeof p); return rmdir(p) == 0; }
BOOL MoveFile(LPCSTR from, LPCSTR to) { char a[1024]; S2HostPath(from, a, sizeof a); std::string b = S2Slashes(to); return rename(a, b.c_str()) == 0; }
BOOL CopyFile(LPCSTR from, LPCSTR to, BOOL failIfExists)
{
	char a[1024]; S2HostPath(from, a, sizeof a); std::string b = S2Slashes(to);
	struct stat st; if (failIfExists && stat(b.c_str(), &st) == 0) return FALSE;
	FILE *in = fopen(a, "rb"); if (!in) return FALSE;
	FILE *out = fopen(b.c_str(), "wb"); if (!out) { fclose(in); return FALSE; }
	char buf[65536]; size_t n; bool ok = true;
	while ((n = fread(buf, 1, sizeof buf, in)) > 0) if (fwrite(buf, 1, n, out) != n) { ok = false; break; }
	fclose(in); fclose(out); return ok;
}
static DWORD S2Attributes(const char *path, const struct stat &st)
{
	DWORD a = S_ISDIR(st.st_mode) ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL;
	const char *b = strrchr(path, '/'); b = b ? b + 1 : path;
	if (b[0] == '.' && strcmp(b, ".") && strcmp(b, "..")) a |= FILE_ATTRIBUTE_HIDDEN;
	if (access(path, W_OK) != 0) a |= FILE_ATTRIBUTE_READONLY;
	return a;
}
DWORD GetFileAttributes(LPCSTR name) { char p[1024]; S2HostPath(name, p, sizeof p); struct stat st; return stat(p, &st) == 0 ? S2Attributes(p, st) : INVALID_FILE_ATTRIBUTES; }
BOOL SetFileAttributes(LPCSTR name, DWORD attr)
{
	char p[1024]; S2HostPath(name, p, sizeof p); struct stat st; if (stat(p, &st) != 0) return FALSE;
	mode_t m = st.st_mode; if (attr & FILE_ATTRIBUTE_READONLY) m &= ~(S_IWUSR | S_IWGRP | S_IWOTH); else m |= S_IWUSR;
	return chmod(p, m) == 0;
}
DWORD GetCurrentDirectory(DWORD n, LPSTR buf) { if (!getcwd(buf, n)) return 0; return (DWORD)strlen(buf); }
BOOL SetCurrentDirectory(LPCSTR dir) { char p[1024]; S2HostPath(dir, p, sizeof p); return chdir(p) == 0; }
DWORD GetModuleFileName(HMODULE, LPSTR buf, DWORD n)
{
	uint32_t size = n; if (_NSGetExecutablePath(buf, &size) != 0) return 0; return (DWORD)strlen(buf);
}

// directory enumeration with a Windows wildcard ("dir\*.sav")
static S2Find *S2FindOpen(const char *pattern)
{
	std::string p = S2Slashes(pattern), dir = ".", mask = p;
	size_t slash = p.rfind('/');
	if (slash != std::string::npos) { dir = p.substr(0, slash); mask = p.substr(slash + 1); if (dir.empty()) dir = "/"; }
	if (mask == "*.*") mask = "*";
	dir = S2Resolve(dir);
	DIR *d = opendir(dir.c_str()); if (!d) return nullptr;
	S2Find *f = new S2Find(); f->dir = dir;
	while (dirent *e = readdir(d)) if (fnmatch(mask.c_str(), e->d_name, FNM_CASEFOLD) == 0) f->names.push_back(e->d_name);
	closedir(d);
	if (f->names.empty()) { delete f; return nullptr; }
	return f;
}
static bool S2FindFill(S2Find *f, WIN32_FIND_DATA *fd)
{
	if (f->pos >= f->names.size()) return false;
	const std::string &n = f->names[f->pos++];
	std::string full = f->dir + "/" + n;
	struct stat st; memset(fd, 0, sizeof *fd);
	if (stat(full.c_str(), &st) == 0)
	{
		fd->dwFileAttributes = S2Attributes(full.c_str(), st);
		fd->nFileSizeLow = (DWORD)st.st_size; fd->nFileSizeHigh = (DWORD)((uint64_t)st.st_size >> 32);
		S2UnixToFT(st.st_birthtimespec.tv_sec, st.st_birthtimespec.tv_nsec, &fd->ftCreationTime);
		S2UnixToFT(st.st_atimespec.tv_sec, st.st_atimespec.tv_nsec, &fd->ftLastAccessTime);
		S2UnixToFT(st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec, &fd->ftLastWriteTime);
	}
	snprintf(fd->cFileName, sizeof fd->cFileName, "%s", n.c_str());
	return true;
}
HANDLE FindFirstFile(LPCSTR pattern, WIN32_FIND_DATA *fd)
{
	S2Find *f = S2FindOpen(pattern); if (!f) return INVALID_HANDLE_VALUE;
	S2FindFill(f, fd); return f;
}
BOOL FindNextFile(HANDLE h, WIN32_FIND_DATA *fd) { S2Find *f = S2As<S2Find>(h, S2H_FIND); return f && S2FindFill(f, fd); }
BOOL FindClose(HANDLE h) { return CloseHandle(h); }
static void S2FindToCrt(const WIN32_FIND_DATA &w, struct _finddata_t *fd)
{
	fd->attrib = (w.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY ? _A_SUBDIR : 0) | (w.dwFileAttributes & FILE_ATTRIBUTE_HIDDEN ? _A_HIDDEN : 0) | (w.dwFileAttributes & FILE_ATTRIBUTE_READONLY ? _A_RDONLY : 0);
	auto unix = [](const FILETIME &f) { return (int64_t)((S2FT(&f) - S2_EPOCH_DIFF) / 10000000ull); };
	fd->time_create = unix(w.ftCreationTime); fd->time_access = unix(w.ftLastAccessTime); fd->time_write = unix(w.ftLastWriteTime);
	fd->size = w.nFileSizeLow;
	snprintf(fd->name, sizeof fd->name, "%s", w.cFileName);
}
intptr_t _findfirst(const char *pattern, struct _finddata_t *fd)
{
	WIN32_FIND_DATA w; HANDLE h = FindFirstFile(pattern, &w); if (h == INVALID_HANDLE_VALUE) return -1;
	S2FindToCrt(w, fd); return (intptr_t)h;
}
int _findnext(intptr_t h, struct _finddata_t *fd) { WIN32_FIND_DATA w; if (!FindNextFile((HANDLE)h, &w)) return -1; S2FindToCrt(w, fd); return 0; }
int _findclose(intptr_t h) { return FindClose((HANDLE)h) ? 0 : -1; }
int _mkdir(const char *path) { std::string p = S2Slashes(path); return mkdir(p.c_str(), 0755); }
int _rmdir(const char *path) { char p[1024]; S2HostPath(path, p, sizeof p); return rmdir(p); }
void _splitpath(const char *path, char *drive, char *dir, char *fname, char *ext)
{
	std::string p(path ? path : "");
	if (drive) { if (p.size() >= 2 && p[1] == ':') { drive[0] = p[0]; drive[1] = ':'; drive[2] = 0; p.erase(0, 2); } else drive[0] = 0; }
	else if (p.size() >= 2 && p[1] == ':') p.erase(0, 2);
	size_t s = p.find_last_of("\\/"); std::string d = s == std::string::npos ? "" : p.substr(0, s + 1), f = s == std::string::npos ? p : p.substr(s + 1);
	size_t dot = f.rfind('.'); std::string e = dot == std::string::npos ? "" : f.substr(dot); if (dot != std::string::npos) f.erase(dot);
	if (dir) strcpy(dir, d.c_str());
	if (fname) strcpy(fname, f.c_str());
	if (ext) strcpy(ext, e.c_str());
}
void _makepath(char *path, const char *drive, const char *dir, const char *fname, const char *ext)
{
	std::string r;
	if (drive && *drive) { r += drive[0]; r += ':'; }
	if (dir && *dir) { r += dir; if (r.back() != '\\' && r.back() != '/') r += '\\'; }
	if (fname) r += fname;
	if (ext && *ext) { if (*ext != '.') r += '.'; r += ext; }
	strcpy(path, r.c_str());
}
char *_fullpath(char *abs, const char *rel, size_t n)
{
	std::string p = S2Slashes(rel);
	char cwd[1024]; if (p.empty() || p[0] != '/') { if (!getcwd(cwd, sizeof cwd)) return nullptr; p = std::string(cwd) + "/" + p; }
	if (!abs) abs = (char*)malloc(n = (n ? n : 1024));
	snprintf(abs, n, "%s", p.c_str()); return abs;
}

// ---------------------------------------------------------------------------------------------------
// process, memory, misc
void OutputDebugString(LPCSTR s) { if (s) fputs(s, stderr); }
BOOL IsDebuggerPresent()
{
	kinfo_proc info = {}; size_t size = sizeof info; int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
	if (sysctl(mib, 4, &info, &size, nullptr, 0) != 0) return FALSE;
	return (info.kp_proc.p_flag & P_TRACED) != 0;
}
// readable means mapped with read permission, which is what the Windows call reports
static BOOL S2Accessible(const void *p, UINT_PTR n, vm_prot_t need)
{
	if (!p) return FALSE;
	if (!n) return TRUE;
	mach_vm_address_t addr = (mach_vm_address_t)(uintptr_t)p, end = addr + n;
	while (addr < end)
	{
		mach_vm_address_t a = addr; mach_vm_size_t size = 0; vm_region_basic_info_data_64_t info; mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t obj;
		if (mach_vm_region(mach_task_self(), &a, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS) return FALSE;
		if (a > addr || (info.protection & need) != need) return FALSE;
		addr = a + size;
	}
	return TRUE;
}
BOOL IsBadReadPtr(const void *p, UINT_PTR n) { return !S2Accessible(p, n, VM_PROT_READ); }
BOOL IsBadWritePtr(void *p, UINT_PTR n) { return !S2Accessible(p, n, VM_PROT_READ | VM_PROT_WRITE); }
HMODULE GetModuleHandle(LPCSTR) { return (HMODULE)(intptr_t)1; }
HMODULE LoadLibrary(LPCSTR) { return nullptr; }
BOOL FreeLibrary(HMODULE) { return TRUE; }
void *GetProcAddress(HMODULE, LPCSTR) { return nullptr; }
void GlobalMemoryStatus(MEMORYSTATUS *ms)
{
	uint64_t mem = 0; size_t len = sizeof mem; sysctlbyname("hw.memsize", &mem, &len, nullptr, 0);
	vm_statistics64_data_t vm; mach_msg_type_number_t cnt = HOST_VM_INFO64_COUNT; host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &cnt);
	uint64_t avail = (uint64_t)(vm.free_count + vm.inactive_count) * vm_page_size;
	ms->dwLength = sizeof *ms; ms->dwMemoryLoad = mem ? (DWORD)(100 - avail * 100 / mem) : 0;
	ms->dwTotalPhys = (SIZE_T)mem; ms->dwAvailPhys = (SIZE_T)avail;
	ms->dwTotalPageFile = ms->dwTotalPhys; ms->dwAvailPageFile = ms->dwAvailPhys;
	ms->dwTotalVirtual = (SIZE_T)1 << 47; ms->dwAvailVirtual = ms->dwTotalVirtual;
}
static thread_local DWORD s2LastError;
DWORD GetLastError() { return s2LastError ? s2LastError : (DWORD)errno; }
void SetLastError(DWORD e) { s2LastError = e; }
void ExitProcess(UINT code) { exit((int)code); }
DWORD GetEnvironmentVariable(LPCSTR name, LPSTR buf, DWORD n) { const char *v = getenv(name); if (!v) return 0; snprintf(buf, n, "%s", v); return (DWORD)strlen(v); }

// ---------------------------------------------------------------------------------------------------
// text: the English release uses Windows-1252 as its ANSI code page
UINT GetACP() { return 1252; }
static size_t S2Iconv(const char *to, const char *from, const void *in, size_t inBytes, void *out, size_t outBytes)
{
	iconv_t cd = iconv_open(to, from); if (cd == (iconv_t)-1) return (size_t)-1;
	char *ip = (char*)in, *op = (char*)out; size_t il = inBytes, ol = outBytes;
	while (il > 0)
		if (iconv(cd, &ip, &il, &op, &ol) == (size_t)-1)
		{
			if (errno == EILSEQ && il > 0) { ++ip; --il; continue; } // skip bytes the code page cannot map
			break;
		}
	iconv_close(cd); return outBytes - ol;
}
static const char *S2CodePage(UINT cp) { return cp == CP_UTF8 ? "UTF-8" : cp == 1251 ? "CP1251" : "CP1252"; }
int MultiByteToWideChar(UINT cp, DWORD, LPCSTR s, int sn, LPWSTR w, int wn)
{
	if (sn < 0) sn = (int)strlen(s) + 1;
	std::vector<wchar_t> tmp((size_t)sn * 2 + 1);
	size_t bytes = S2Iconv("WCHAR_T", S2CodePage(cp), s, (size_t)sn, tmp.data(), tmp.size() * sizeof(wchar_t));
	if (bytes == (size_t)-1) return 0;
	int n = (int)(bytes / sizeof(wchar_t));
	if (wn == 0) return n;
	if (n > wn) n = wn;
	memcpy(w, tmp.data(), (size_t)n * sizeof(wchar_t));
	return n;
}
int WideCharToMultiByte(UINT cp, DWORD, LPCWSTR w, int wn, LPSTR s, int sn, LPCSTR, BOOL *used)
{
	if (used) *used = FALSE;
	if (wn < 0) wn = (int)wcslen(w) + 1;
	std::vector<char> tmp((size_t)wn * 4 + 1);
	size_t bytes = S2Iconv(cp == CP_UTF8 ? "UTF-8" : (std::string(S2CodePage(cp)) + "//TRANSLIT").c_str(), "WCHAR_T", w, (size_t)wn * sizeof(wchar_t), tmp.data(), tmp.size());
	if (bytes == (size_t)-1) return 0;
	int n = (int)bytes;
	if (sn == 0) return n;
	if (n > sn) n = sn;
	memcpy(s, tmp.data(), (size_t)n);
	return n;
}
int GetLocaleInfo(DWORD, DWORD type, LPSTR buf, int n)
{
	const char *v = type == LOCALE_IDATE ? "0" : ""; // 0 = month/day/year, as the US English locale
	if (n == 0) return (int)strlen(v) + 1;
	snprintf(buf, n, "%s", v); return (int)strlen(buf) + 1;
}
HKL GetKeyboardLayout(DWORD) { return (HKL)(intptr_t)0x04090409; }

// Windows wide printf semantics: %s/%c take wide arguments, %S/%C narrow ones; no buffer size is given
int S2vswprintf(wchar_t *buf, const wchar_t *fmt, va_list va)
{
	std::wstring f;
	for (const wchar_t *p = fmt; *p; ++p)
	{
		f += *p;
		if (*p != L'%') continue;
		++p;
		if (*p == L'%') { f += L'%'; continue; }
		while (*p && wcschr(L"-+ #0123456789.*hlLqjzt", *p)) { f += *p; ++p; }
		if (!*p) break;
		if (*p == L's' || *p == L'c') { f += L'l'; f += *p; }
		else if (*p == L'S') f += L's';
		else if (*p == L'C') f += L'c';
		else f += *p;
	}
	return vswprintf(buf, 1 << 20, f.c_str(), va);
}

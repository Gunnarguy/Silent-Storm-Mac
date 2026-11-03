// s2com.h: just enough COM to declare the Direct3D 9 and DirectInput interfaces on macOS.
// The implementations are native classes in port/platform/src; there is no COM runtime.
#pragma once
#include "s2win32.h"
#define __MSABI_LONG(x) x  /* keeps D3D constants 32-bit, as LONG is on Windows */
typedef uint64_t UINT64;
typedef uint32_t UINT32;
typedef int64_t INT64;
typedef int32_t INT32;
typedef GUID *LPGUID;
typedef const GUID *LPCGUID;
typedef struct _LUID { DWORD LowPart; LONG HighPart; } LUID;
typedef struct _RGNDATAHEADER { DWORD dwSize, iType, nCount, nRgnSize; RECT rcBound; } RGNDATAHEADER;
typedef struct _RGNDATA { RGNDATAHEADER rdh; char Buffer[1]; } RGNDATA;
typedef struct tagPALETTEENTRY PALETTEENTRY_;
#ifndef __OBJC__   // Objective-C reserves @interface
#define interface struct
#endif
#define PURE = 0
#define THIS_
#define THIS void
#define STDMETHODCALLTYPE
#define STDMETHODIMP HRESULT
#define STDMETHODIMP_(t) t
#define STDMETHOD(m) virtual HRESULT m
#define STDMETHOD_(t, m) virtual t m
#define DECLARE_INTERFACE(i) struct i
#define DECLARE_INTERFACE_(i, b) struct i : public b
#define DECLARE_INTERFACE_IID_(i, b, s) struct i : public b
#define DECLSPEC_UUID(x)
#define MIDL_INTERFACE(x) struct
#define __CRT_UUID_DECL(t, ...)
#define DECLSPEC_HIDDEN
#define DUMMYUNIONNAME
#define DUMMYSTRUCTNAME
#define DUMMYUNIONNAME1
#define DUMMYUNIONNAME2
#define DUMMYUNIONNAME3
#define DUMMYSTRUCTNAME1
#define DUMMYSTRUCTNAME2
#define C_ASSERT(e) static_assert(e, #e)
#define DEFINE_GUID(n, l, w1, w2, b1, b2, b3, b4, b5, b6, b7, b8) static const GUID n = { l, w1, w2, { b1, b2, b3, b4, b5, b6, b7, b8 } }
#define __uuidof(x) IID_##x
inline bool operator==(const GUID &a, const GUID &b) { return memcmp(&a, &b, sizeof(GUID)) == 0; }
inline bool operator!=(const GUID &a, const GUID &b) { return !(a == b); }
#define IsEqualGUID(a, b) ((a) == (b))
#define IsEqualIID(a, b) ((a) == (b))
struct IUnknown
{
	virtual HRESULT QueryInterface(REFIID riid, void **ppv) = 0;
	virtual ULONG AddRef() = 0;
	virtual ULONG Release() = 0;
	virtual ~IUnknown() {}
};
typedef IUnknown *LPUNKNOWN;
inline HRESULT CoInitialize(void *) { return S_OK; }
inline void CoUninitialize() {}

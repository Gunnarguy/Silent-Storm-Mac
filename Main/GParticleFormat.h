#ifndef __GPARTICLEFORMAT_H_
#define __GPARTICLEFORMAT_H_
#if _MSC_VER > 1000
#pragma once
#endif // _MSC_VER > 1000
////////////////////////////////////////////////////////////////////////////////////////////////////
#include <stdint.h>
#include "DG.h"
#include "GResource.h"
////////////////////////////////////////////////////////////////////////////////////////////////////
namespace NGScene
{
////////////////////////////////////////////////////////////////////////////////////////////////////
void Interpolate(const CVec3& v1, const CVec3& v2, float fAlpha, CVec3* pRes);
void Interpolate(const CVec2& v1, const CVec2& v2, float fAlpha, CVec2* pRes);
void Interpolate(const float& v1, const float& v2, float fAlpha, float* pRes);
void Interpolate(const DWORD& v1, const DWORD& v2, float fAlpha, DWORD* pRes);
void Interpolate(const short& v1, const short& v2, float fAlpha, short* pRes);
////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma pack( push, 2 )
////////////////////////////////////////////////////////////////////////////////////////////////////
template <class TValue>
class TKey
{
public:
	short nT;
	TValue value;
};
////////////////////////////////////////////////////////////////////////////////////////////////////
// could use coherence between fetches to make key retrieve faster
// The particle files are loaded as a memory image whose key arrays are referenced by 32-bit offsets
// that the loader fixes up. A 64-bit pointer would not fit the file's 2-byte-packed layout, so on 64-bit
// builds the field keeps a 32-bit offset relative to itself and behaves like a pointer.
template <class T> struct SRelativePtr
{
	int nOffset;
	T *Get() const { return (T*)( (char*)this + nOffset ); }
	T &operator[]( int i ) const { return Get()[i]; }
	T *operator->() const { return Get(); }
	operator T*() const { return Get(); }
	SRelativePtr &operator=( T *p ) { nOffset = (int)( (char*)p - (char*)this ); return *this; }
};
template <class TValue>
class TKeyTrack
{
public:
	short nKeys;
#if UINTPTR_MAX > 0xFFFFFFFFu
	SRelativePtr< TKey<TValue> > keys;
	int RawFileOffset() const { return keys.nOffset; }   // before the loader's fix-up
#else
	TKey<TValue> *keys;
	int RawFileOffset() const { return (int)keys; }
#endif

	void GetValue( float fT, TValue *pRes ) const
	{
		if ( nKeys == 1 )
		{
			*pRes = keys[0].value;
			return;
		}
		GetValueBinSearch( fT, pRes );
	}
private:
	void GetValueBinSearch( float fT, TValue *pRes ) const
	{
		int s = 0, e = nKeys - 1;
		short nT = Float2Int( fT - 0.5f );
		while( e - s > 1 )
		{
			int n = (s + e) / 2;
			if ( keys[n].nT <= nT )
				s = n;
			else
				e = n;
		}
		const TKey<TValue> &start = keys[s];
		const TKey<TValue> &end = keys[e];
		float fAlpha = (fT - start.nT) / (end.nT - start.nT);
		Interpolate( start.value, end.value, fAlpha, pRes );
	}
};
////////////////////////////////////////////////////////////////////////////////////////////////////
struct SParticle
{
	short nTStart;
	short nTEnd;
	TKeyTrack<CVec3> pos;
	TKeyTrack<float> rot;
	TKeyTrack<CVec2> scale;
	TKeyTrack<DWORD> color;
	TKeyTrack<short> sprite;
};
static_assert( sizeof( SParticle ) == 34, "SParticle must match the 2-byte-packed particle file layout" );
////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma pack( pop )
////////////////////////////////////////////////////////////////////////////////////////////////////
class CParticlesInfo: public CObjectBase
{
	OBJECT_BASIC_METHODS(CParticlesInfo);
public:
	CObj<CFileRequest> pData;
	//vector<char> pData;
	int nBytes;
	
	float fTEnd;
	float fFrameRate;
	int nParticles;
	SParticle *particles;

	CParticlesInfo() { nBytes = 0; nParticles = 0; }
	void CalcBound( SBound *pRes );
};
////////////////////////////////////////////////////////////////////////////////////////////////////
class CParticlesLoader: public CLazyResourceLoader<int, CParticlesInfo>
{
	OBJECT_BASIC_METHODS(CParticlesLoader);
	virtual CFileRequest* CreateRequest();
	virtual void RecalcValue( CFileRequest *p );
};
////////////////////////////////////////////////////////////////////////////////////////////////////
}
////////////////////////////////////////////////////////////////////////////////////////////////////
#endif
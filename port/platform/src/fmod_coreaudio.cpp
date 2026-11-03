// fmod_coreaudio.cpp: the FMOD 3 API subset the engine uses (third_party/fmod/include/fmod.h), implemented
// as a software mixer on a Core Audio output unit.
//
// Semantics follow FMOD 3.7: volumes and pans are 0..255 (pan 128 = centre, FSOUND_STEREOPAN = no panning),
// positions and loop points are in sample frames, FSOUND_SetVolume is scaled by the SFX master volume and
// FSOUND_SetVolumeAbsolute is not, 3D voices use inverse-distance rolloff between min and max distance,
// and channel handles carry a generation so a handle to a finished voice never controls a newer one.
#include "s2win32.h"
#include "fmod.h"
#include "s2settings.h"
#include <AudioToolbox/AudioToolbox.h>
#include <AudioUnit/AudioUnit.h>
#include <os/lock.h>
#include <vector>
#include <memory>
#include <string>
#include <cmath>

#undef fopen
#define STB_VORBIS_HEADER_ONLY
#include "../third_party/stb_vorbis.c"

namespace {

struct Lock { os_unfair_lock l = OS_UNFAIR_LOCK_INIT; void lock() { os_unfair_lock_lock(&l); } void unlock() { os_unfair_lock_unlock(&l); } };
struct Guard { Lock &k; explicit Guard(Lock &x) : k(x) { k.lock(); } ~Guard() { k.unlock(); } };

} // namespace

struct FSOUND_SAMPLE
{
	std::vector<float> pcm;   // interleaved
	int channels = 1;
	int rate = 44100;
	unsigned frames = 0;
	unsigned mode = FSOUND_LOOP_OFF | FSOUND_2D;
	int loopStart = 0, loopEnd = 0;   // inclusive end, in frames
	int defFreq = -1, defVol = 255, defPan = 128, defPri = 128;
	float minDist = 1.0f, maxDist = 1000000000.0f;
};

struct FSOUND_STREAM
{
	std::vector<unsigned char> file;   // whole file: Ogg is decoded incrementally from memory
	stb_vorbis *ogg = nullptr;
	std::unique_ptr<FSOUND_SAMPLE> pcm; // non-Ogg streams are decoded up front
	int channels = 2, rate = 44100;
	unsigned lengthFrames = 0;
	unsigned positionFrames = 0;
	unsigned mode = FSOUND_2D | FSOUND_LOOP_OFF;
	bool playing = false, finished = false;
	int channel = -1;
	FSOUND_STREAMCALLBACK sync = nullptr;
	intptr_t syncParam = 0;
	std::vector<float> fifo;   // decoded, not yet consumed frames (interleaved)
	double frac = 0;           // fractional read position into fifo
	void Reset() { fifo.clear(); frac = 0; }
	~FSOUND_STREAM() { if (ogg) stb_vorbis_close(ogg); }
};

namespace {

struct Voice
{
	bool active = false, paused = false, is3D = false, stereoPan = false;
	unsigned generation = 0;
	FSOUND_SAMPLE *sample = nullptr;
	FSOUND_STREAM *stream = nullptr;
	double pos = 0;               // fractional frame position in the sample
	unsigned loopMode = FSOUND_LOOP_OFF;
	int volume = 255, pan = 128, priority = 128;
	bool absoluteVolume = false;
	float position[3] = { 0, 0, 0 };
};

struct Mixer
{
	Lock lock;
	AudioComponentInstance unit = nullptr;
	double outRate = 48000;
	std::vector<Voice> voices;
	int sfxMaster = 255;
	float listenerPos[3] = { 0, 0, 0 }, listenerFwd[3] = { 0, 0, 1 }, listenerUp[3] = { 0, 1, 0 };
	int error = 0;
	bool initialised = false;
	std::vector<FSOUND_STREAM*> streams;
	FILE *capture = nullptr;               // S2_AUDIO_CAPTURE: dry L, dry R, 0, 0 per frame, float32, before the master gain
} g;

const int N_STREAM_SLOT = 0x40000000;   // stream voices are tagged so they never collide with sample slots
const int N_SLOT_BITS = 12;

int MakeHandle(int slot, unsigned gen) { return slot | (int)((gen & 0x3FFFF) << N_SLOT_BITS); }
Voice *VoiceFor(int handle)
{
	if (handle < 0) return nullptr;
	int slot = handle & ((1 << N_SLOT_BITS) - 1);
	unsigned gen = ((unsigned)handle >> N_SLOT_BITS) & 0x3FFFF;
	if (slot >= (int)g.voices.size()) return nullptr;
	Voice &v = g.voices[slot];
	if (!v.active || (handle >= (1 << N_SLOT_BITS) && (v.generation & 0x3FFFF) != gen)) return nullptr;
	return &v;
}

// --- decoding ---------------------------------------------------------------------------------------
struct MemFile { const unsigned char *data; size_t size; };
OSStatus MemRead(void *ud, SInt64 pos, UInt32 req, void *buf, UInt32 *got)
{
	MemFile *m = (MemFile*)ud;
	if (pos >= (SInt64)m->size) { *got = 0; return noErr; }
	size_t n = std::min((size_t)req, m->size - (size_t)pos);
	memcpy(buf, m->data + pos, n); *got = (UInt32)n; return noErr;
}
SInt64 MemSize(void *ud) { return (SInt64)((MemFile*)ud)->size; }

bool DecodeCoreAudio(const unsigned char *data, size_t size, FSOUND_SAMPLE *out)
{
	MemFile mf { data, size };
	AudioFileID af = nullptr;
	if (AudioFileOpenWithCallbacks(&mf, MemRead, nullptr, MemSize, nullptr, 0, &af) != noErr) return false;
	ExtAudioFileRef ef = nullptr;
	if (ExtAudioFileWrapAudioFileID(af, false, &ef) != noErr) { AudioFileClose(af); return false; }
	AudioStreamBasicDescription in = {}; UInt32 sz = sizeof in;
	ExtAudioFileGetProperty(ef, kExtAudioFileProperty_FileDataFormat, &sz, &in);
	AudioStreamBasicDescription f = {};
	f.mSampleRate = in.mSampleRate; f.mFormatID = kAudioFormatLinearPCM;
	f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
	f.mChannelsPerFrame = in.mChannelsPerFrame ? in.mChannelsPerFrame : 1;
	f.mBitsPerChannel = 32; f.mBytesPerFrame = 4 * f.mChannelsPerFrame; f.mFramesPerPacket = 1; f.mBytesPerPacket = f.mBytesPerFrame;
	ExtAudioFileSetProperty(ef, kExtAudioFileProperty_ClientDataFormat, sizeof f, &f);
	out->channels = (int)f.mChannelsPerFrame; out->rate = (int)in.mSampleRate;
	std::vector<float> buf(4096 * out->channels);
	for (;;)
	{
		AudioBufferList bl; bl.mNumberBuffers = 1;
		bl.mBuffers[0].mNumberChannels = f.mChannelsPerFrame; bl.mBuffers[0].mDataByteSize = (UInt32)(buf.size() * 4); bl.mBuffers[0].mData = buf.data();
		UInt32 frames = 4096;
		if (ExtAudioFileRead(ef, &frames, &bl) != noErr || frames == 0) break;
		out->pcm.insert(out->pcm.end(), buf.begin(), buf.begin() + frames * out->channels);
	}
	ExtAudioFileDispose(ef); AudioFileClose(af);
	out->frames = (unsigned)(out->pcm.size() / out->channels);
	return out->frames > 0;
}

bool DecodeOggWhole(const unsigned char *data, size_t size, FSOUND_SAMPLE *out)
{
	int err = 0; stb_vorbis *v = stb_vorbis_open_memory(data, (int)size, &err, nullptr);
	if (!v) return false;
	stb_vorbis_info info = stb_vorbis_get_info(v);
	out->channels = info.channels; out->rate = (int)info.sample_rate;
	std::vector<float> buf(4096 * info.channels);
	int n;
	while ((n = stb_vorbis_get_samples_float_interleaved(v, info.channels, buf.data(), (int)buf.size())) > 0)
		out->pcm.insert(out->pcm.end(), buf.begin(), buf.begin() + n * info.channels);
	stb_vorbis_close(v);
	out->frames = (unsigned)(out->pcm.size() / out->channels);
	return out->frames > 0;
}

bool IsOgg(const unsigned char *d, size_t n) { return n >= 4 && memcmp(d, "OggS", 4) == 0; }

bool ReadWholeFile(const char *name, std::vector<unsigned char> *out)
{
	char path[1024]; S2HostPath(name, path, sizeof path);
	FILE *f = fopen(path, "rb"); if (!f) return false;
	fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
	out->resize(n > 0 ? (size_t)n : 0);
	bool ok = n <= 0 || fread(out->data(), 1, (size_t)n, f) == (size_t)n;
	fclose(f); return ok;
}

// --- mixing -----------------------------------------------------------------------------------------
void Gains(const Voice &v, float *l, float *r)
{
	float vol = v.volume / 255.0f;
	if (!v.absoluteVolume) vol *= g.sfxMaster / 255.0f;
	float pan = v.pan / 255.0f;
	if (v.is3D && v.sample)
	{
		float d[3] = { v.position[0] - g.listenerPos[0], v.position[1] - g.listenerPos[1], v.position[2] - g.listenerPos[2] };
		float dist = sqrtf(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
		float mn = v.sample->minDist, mx = v.sample->maxDist;
		float cd = std::min(std::max(dist, mn), mx);
		vol *= mn / std::max(cd, 1e-6f);
		// right vector = up x forward (left-handed, as Direct3D and FMOD 3)
		const float *f = g.listenerFwd, *u = g.listenerUp;
		float right[3] = { u[1] * f[2] - u[2] * f[1], u[2] * f[0] - u[0] * f[2], u[0] * f[1] - u[1] * f[0] };
		float rl = sqrtf(right[0] * right[0] + right[1] * right[1] + right[2] * right[2]);
		float side = (dist > 1e-6f && rl > 1e-6f) ? (d[0] * right[0] + d[1] * right[1] + d[2] * right[2]) / (dist * rl) : 0;
		pan = 0.5f + 0.5f * side;
	}
	// equal-power pan; FSOUND_STEREOPAN leaves stereo material untouched
	if (v.stereoPan) { *l = *r = vol; return; }
	*l = vol * cosf(pan * (float)M_PI_2) * (float)M_SQRT2;
	*r = vol * sinf(pan * (float)M_PI_2) * (float)M_SQRT2;
	*l = std::min(*l, vol * 1.0f); *r = std::min(*r, vol * 1.0f);
}

// decode until the FIFO holds at least `frames` frames (or the stream ends)
void FillStream(FSOUND_STREAM *s, int frames)
{
	float buf[4096];
	while ((int)(s->fifo.size() / s->channels) < frames && !s->finished)
	{
		int n = stb_vorbis_get_samples_float_interleaved(s->ogg, s->channels, buf, 4096 - 4096 % s->channels);
		if (n <= 0)
		{
			if (s->mode & FSOUND_LOOP_NORMAL) { stb_vorbis_seek_start(s->ogg); s->positionFrames = 0; continue; }
			s->finished = true; break;
		}
		s->fifo.insert(s->fifo.end(), buf, buf + n * s->channels);
	}
}

OSStatus Render(void *, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32 frames, AudioBufferList *io)
{
	float *out = (float*)io->mBuffers[0].mData;
	memset(out, 0, frames * 2 * sizeof(float));
	Guard lk(g.lock);
	for (Voice &v : g.voices)
	{
		if (!v.active || v.paused) continue;
		float gl, gr; Gains(v, &gl, &gr);
		if (v.stream)
		{
			FSOUND_STREAM *s = v.stream;
			if (s->ogg)
			{
				double step = s->rate / g.outRate;
				FillStream(s, (int)ceil(s->frac + frames * step) + 2);
				int avail = (int)(s->fifo.size() / s->channels);
				const float *src = s->fifo.data();
				UInt32 i = 0;
				for (; i < frames; ++i)
				{
					int a = (int)s->frac; float t = (float)(s->frac - a);
					if (a + 1 >= avail) break;
					float L = src[a * s->channels] * (1 - t) + src[(a + 1) * s->channels] * t;
					float R = s->channels > 1 ? src[a * s->channels + 1] * (1 - t) + src[(a + 1) * s->channels + 1] * t : L;
					out[2 * i] += L * gl; out[2 * i + 1] += R * gr;
					s->frac += step;
				}
				int consumed = std::min((int)s->frac, avail);
				s->fifo.erase(s->fifo.begin(), s->fifo.begin() + consumed * s->channels);
				s->frac -= consumed;
				s->positionFrames += consumed;
				if (s->finished && i < frames) { v.active = false; s->playing = false; }
				continue;
			}
			if (!s->pcm) { v.active = false; continue; }
			v.sample = s->pcm.get();
		}
		FSOUND_SAMPLE *smp = v.sample;
		if (!smp || smp->frames == 0) { v.active = false; continue; }
		double step = smp->rate / g.outRate;
		int ch = smp->channels;
		unsigned loopEnd = (unsigned)std::min<int>(std::max(smp->loopEnd, 0), (int)smp->frames - 1);
		unsigned loopStart = (unsigned)std::max(smp->loopStart, 0);
		bool loop = (v.loopMode & FSOUND_LOOP_NORMAL) != 0 && loopEnd > loopStart;
		for (UInt32 i = 0; i < frames; ++i)
		{
			unsigned a = (unsigned)v.pos; float t = (float)(v.pos - a);
			unsigned b = a + 1;
			if (loop && b > loopEnd) b = loopStart;
			if (b >= smp->frames) b = a;
			const float *pa = &smp->pcm[(size_t)a * ch], *pb = &smp->pcm[(size_t)b * ch];
			float L = pa[0] * (1 - t) + pb[0] * t;
			float R = ch > 1 ? pa[1] * (1 - t) + pb[1] * t : L;
			out[2 * i] += L * gl; out[2 * i + 1] += R * gr;
			v.pos += step;
			if (loop && v.pos > loopEnd + 1) v.pos = loopStart + (v.pos - (loopEnd + 1));
			else if (!loop && v.pos >= smp->frames) { v.active = false; if (v.stream) v.stream->finished = true, v.stream->playing = false; break; }
		}
		if (v.stream) v.stream->positionFrames = (unsigned)v.pos;
	}
	if (g.capture)
	{
		static std::vector<float> frame;
		frame.resize(frames * 4);
		for (UInt32 i = 0; i < frames; ++i)
		{
			frame[4 * i] = out[2 * i]; frame[4 * i + 1] = out[2 * i + 1];
			frame[4 * i + 2] = 0.0f; frame[4 * i + 3] = 0.0f;
		}
		fwrite(frame.data(), sizeof(float), frames * 4, g.capture);
	}
	// Settings: master volume, and silence while another app is in front; ramped per sample so changes never click
	static float master = 1;
	float target = S2AudioTargetGain();
	float stepGain = (target - master) / (float)std::max<UInt32>(frames, 1);
	for (UInt32 i = 0; i < frames; ++i)
	{
		master += stepGain;
		out[2 * i] = std::max(-1.0f, std::min(1.0f, out[2 * i] * master));
		out[2 * i + 1] = std::max(-1.0f, std::min(1.0f, out[2 * i + 1] * master));
	}
	master = target;
	return noErr;
}

int AllocVoice(int priority, bool forStream)
{
	int best = -1;
	for (int i = forStream ? 0 : 1; i < (int)g.voices.size(); ++i)   // slot 0 is kept for streams
		if (!g.voices[i].active) { best = i; break; }
	if (best < 0 && !forStream)
	{
		// steal the lowest-priority voice (FMOD 3: higher number = lower priority? no: 0 lowest, 255 highest)
		int lowest = 256;
		for (int i = 1; i < (int)g.voices.size(); ++i)
			if (!g.voices[i].stream && g.voices[i].priority < lowest && g.voices[i].priority <= priority) { lowest = g.voices[i].priority; best = i; }
	}
	if (best < 0) return -1;
	Voice &v = g.voices[best];
	unsigned gen = v.generation + 1;
	v = Voice(); v.generation = gen;
	return best;
}

} // namespace

// ===== API =============================================================================================
extern "C" {

signed char __stdcall FSOUND_SetOutput(int) { return TRUE; }
signed char __stdcall FSOUND_SetDriver(int) { return TRUE; }
signed char __stdcall FSOUND_SetHWND(void *) { return TRUE; }
int __stdcall FSOUND_GetNumDrivers(void) { return 1; }
const char *__stdcall FSOUND_GetDriverName(int) { return "Core Audio"; }
signed char __stdcall FSOUND_GetDriverCaps(int, unsigned int *caps) { if (caps) *caps = 0; return TRUE; }
float __stdcall FSOUND_GetVersion(void) { return FMOD_VERSION; }
int __stdcall FSOUND_GetMixer(void) { return FSOUND_MIXER_QUALITY_FPU; }
void *__stdcall FSOUND_GetOutputHandle(void) { return g.unit; }
int __stdcall FSOUND_GetError(void) { return g.error; }
signed char __stdcall FSOUND_SetSpeakerMode(unsigned int) { return TRUE; }
void __stdcall FSOUND_SetSFXMasterVolume(int volume) { Guard lk(g.lock); g.sfxMaster = std::max(0, std::min(255, volume)); }
void __stdcall FSOUND_Update(void) {}
signed char __stdcall FSOUND_Init(int mixrate, int maxchannels, unsigned int)
{
	if (g.initialised) return TRUE;
	g.voices.assign((size_t)std::max(16, std::min(maxchannels + 1, (1 << N_SLOT_BITS) - 1)), Voice());
	AudioComponentDescription d = { kAudioUnitType_Output, kAudioUnitSubType_DefaultOutput, kAudioUnitManufacturer_Apple, 0, 0 };
	AudioComponent c = AudioComponentFindNext(nullptr, &d);
	if (!c || AudioComponentInstanceNew(c, &g.unit) != noErr) { g.error = 3; return FALSE; }
	g.outRate = mixrate > 0 ? mixrate : 44100;
	AudioStreamBasicDescription f = {};
	f.mSampleRate = g.outRate; f.mFormatID = kAudioFormatLinearPCM; f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
	f.mChannelsPerFrame = 2; f.mBitsPerChannel = 32; f.mBytesPerFrame = 8; f.mFramesPerPacket = 1; f.mBytesPerPacket = 8;
	AudioUnitSetProperty(g.unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f);
	AURenderCallbackStruct cb = { Render, nullptr };
	AudioUnitSetProperty(g.unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
	if (const char *pszCapture = getenv("S2_AUDIO_CAPTURE")) g.capture = fopen(pszCapture, "wb");
	if (AudioUnitInitialize(g.unit) != noErr || AudioOutputUnitStart(g.unit) != noErr) { g.error = 3; return FALSE; }
	g.initialised = true;
	return TRUE;
}
void __stdcall FSOUND_Close(void)
{
	if (g.unit) { AudioOutputUnitStop(g.unit); AudioUnitUninitialize(g.unit); AudioComponentInstanceDispose(g.unit); g.unit = nullptr; }
	if (g.capture) { fclose(g.capture); g.capture = nullptr; }
	Guard lk(g.lock); g.voices.clear(); g.initialised = false;
}

FSOUND_SAMPLE *__stdcall FSOUND_Sample_Load(int, const char *nameOrData, unsigned int mode, int offset, int length)
{
	std::vector<unsigned char> file;
	const unsigned char *data; size_t size;
	if (mode & FSOUND_LOADMEMORY) { data = (const unsigned char*)nameOrData + offset; size = (size_t)length; }
	else { if (!ReadWholeFile(nameOrData, &file)) { g.error = 9; return nullptr; } data = file.data() + offset; size = length > 0 ? (size_t)length : file.size() - offset; }
	FSOUND_SAMPLE *s = new FSOUND_SAMPLE();
	// stb_vorbis has no floor 0, and nearly all the speech uses it (Sounds.res 6,901 of 6,910 streams, measured), so a
	// refused stream goes to Core Audio, which decodes every stream of both games. Without this speech was silent.
	const bool bOgg = IsOgg(data, size);
	bool ok = bOgg ? DecodeOggWhole(data, size, s) : DecodeCoreAudio(data, size, s);
	if (!ok && bOgg) { *s = FSOUND_SAMPLE(); ok = DecodeCoreAudio(data, size, s); }
	static const bool bTrace = getenv("S2_LOG_SOUND") != nullptr;
	if (!ok)
	{
		fprintf(stderr, "[sound] sample rejected: %zu bytes, ogg %d\n", size, bOgg ? 1 : 0);
		delete s; g.error = 10; return nullptr;
	}
	if (bTrace) fprintf(stderr, "[sound] loaded %u frames, %d ch, %d Hz, ogg %d\n", s->frames, s->channels, s->rate, bOgg ? 1 : 0);
	s->mode = mode; s->loopStart = 0; s->loopEnd = (int)s->frames - 1;
	return s;
}
void __stdcall FSOUND_Sample_Free(FSOUND_SAMPLE *s)
{
	if (!s) return;
	{ Guard lk(g.lock); for (Voice &v : g.voices) if (v.sample == s && !v.stream) v.active = false; }
	delete s;
}
unsigned int __stdcall FSOUND_Sample_GetLength(FSOUND_SAMPLE *s) { return s ? s->frames : 0; }
signed char __stdcall FSOUND_Sample_GetLoopPoints(FSOUND_SAMPLE *s, int *a, int *b) { if (!s) return FALSE; if (a) *a = s->loopStart; if (b) *b = s->loopEnd; return TRUE; }
signed char __stdcall FSOUND_Sample_SetLoopPoints(FSOUND_SAMPLE *s, int a, int b) { if (!s) return FALSE; Guard lk(g.lock); s->loopStart = a; s->loopEnd = b; return TRUE; }
signed char __stdcall FSOUND_Sample_SetMode(FSOUND_SAMPLE *s, unsigned int mode)
{
	if (!s) return FALSE;
	Guard lk(g.lock);
	unsigned keep = s->mode & (FSOUND_2D | FSOUND_HW3D);
	if (mode & (FSOUND_2D | FSOUND_HW3D)) keep = mode & (FSOUND_2D | FSOUND_HW3D);
	s->mode = keep | (mode & (FSOUND_LOOP_OFF | FSOUND_LOOP_NORMAL));
	return TRUE;
}
signed char __stdcall FSOUND_Sample_SetDefaults(FSOUND_SAMPLE *s, int freq, int vol, int pan, int pri)
{
	if (!s) return FALSE;
	if (freq >= 0) s->defFreq = freq;
	if (vol >= 0) s->defVol = vol;
	if (pan >= 0) s->defPan = pan;
	if (pri >= 0) s->defPri = pri;
	return TRUE;
}
signed char __stdcall FSOUND_Sample_SetMinMaxDistance(FSOUND_SAMPLE *s, float mn, float mx) { if (!s) return FALSE; s->minDist = std::max(mn, 1e-4f); s->maxDist = std::max(mx, s->minDist); return TRUE; }

int __stdcall FSOUND_PlaySoundEx(int, FSOUND_SAMPLE *s, FSOUND_DSPUNIT *, signed char paused)
{
	if (!s || !g.initialised) return -1;
	static const bool bTrace = getenv("S2_LOG_SOUND") != nullptr;
	if (bTrace) fprintf(stderr, "[sound] play %u frames, 3d %d\n", s->frames, (s->mode & FSOUND_HW3D) ? 1 : 0);
	Guard lk(g.lock);
	int slot = AllocVoice(s->defPri, false);
	if (slot < 0) return -1;
	Voice &v = g.voices[slot];
	v.sample = s; v.active = true; v.paused = paused != 0;
	v.loopMode = (s->mode & FSOUND_LOOP_NORMAL) ? FSOUND_LOOP_NORMAL : FSOUND_LOOP_OFF;
	v.is3D = (s->mode & FSOUND_HW3D) != 0 && !(s->mode & FSOUND_2D);
	v.volume = s->defVol; v.pan = s->defPan; v.priority = s->defPri;
	return MakeHandle(slot, v.generation);
}
int __stdcall FSOUND_PlaySound(int ch, FSOUND_SAMPLE *s) { return FSOUND_PlaySoundEx(ch, s, nullptr, FALSE); }
signed char __stdcall FSOUND_StopSound(int ch)
{
	Guard lk(g.lock); Voice *v = VoiceFor(ch); if (!v) return FALSE;
	if (v->stream) v->stream->playing = false;
	v->active = false; return TRUE;
}
signed char __stdcall FSOUND_IsPlaying(int ch) { Guard lk(g.lock); Voice *v = VoiceFor(ch); return v && v->active; }
signed char __stdcall FSOUND_SetVolume(int ch, int vol) { Guard lk(g.lock); Voice *v = VoiceFor(ch); if (!v) return FALSE; v->volume = std::max(0, std::min(255, vol)); v->absoluteVolume = false; return TRUE; }
signed char __stdcall FSOUND_SetVolumeAbsolute(int ch, int vol) { Guard lk(g.lock); Voice *v = VoiceFor(ch); if (!v) return FALSE; v->volume = std::max(0, std::min(255, vol)); v->absoluteVolume = true; return TRUE; }
int __stdcall FSOUND_GetVolume(int ch) { Guard lk(g.lock); Voice *v = VoiceFor(ch); return v ? v->volume : 0; }
signed char __stdcall FSOUND_SetPaused(int ch, signed char p) { Guard lk(g.lock); Voice *v = VoiceFor(ch); if (!v) return FALSE; v->paused = p != 0; return TRUE; }
signed char __stdcall FSOUND_SetPan(int ch, int pan)
{
	Guard lk(g.lock); Voice *v = VoiceFor(ch); if (!v) return FALSE;
	if (pan == FSOUND_STEREOPAN) { v->stereoPan = true; v->pan = 128; }
	else { v->stereoPan = false; v->pan = std::max(0, std::min(255, pan)); }
	return TRUE;
}
signed char __stdcall FSOUND_SetCurrentPosition(int ch, unsigned int off)
{
	Guard lk(g.lock); Voice *v = VoiceFor(ch); if (!v || !v->sample) return FALSE;
	v->pos = std::min<double>(off, v->sample->frames ? v->sample->frames - 1 : 0); return TRUE;
}
unsigned int __stdcall FSOUND_GetCurrentPosition(int ch) { Guard lk(g.lock); Voice *v = VoiceFor(ch); return v ? (unsigned)v->pos : 0; }
int __stdcall FSOUND_GetFrequency(int ch)
{
	Guard lk(g.lock); Voice *v = VoiceFor(ch); if (!v) return 0;
	if (v->stream) return v->stream->rate;
	return v->sample ? (v->sample->defFreq > 0 ? v->sample->defFreq : v->sample->rate) : 0;
}
unsigned int __stdcall FSOUND_GetLoopMode(int ch) { Guard lk(g.lock); Voice *v = VoiceFor(ch); return v ? v->loopMode : 0; }
signed char __stdcall FSOUND_SetLoopMode(int ch, unsigned int m) { Guard lk(g.lock); Voice *v = VoiceFor(ch); if (!v) return FALSE; v->loopMode = m; return TRUE; }
int __stdcall FSOUND_GetPriority(int ch) { Guard lk(g.lock); Voice *v = VoiceFor(ch); return v ? v->priority : 0; }

signed char __stdcall FSOUND_3D_SetAttributes(int ch, const float *pos, const float *)
{
	Guard lk(g.lock); Voice *v = VoiceFor(ch); if (!v) return FALSE;
	if (pos) memcpy(v->position, pos, sizeof v->position);
	return TRUE;
}
void __stdcall FSOUND_3D_Listener_SetAttributes(const float *pos, const float *, float fx, float fy, float fz, float tx, float ty, float tz)
{
	Guard lk(g.lock);
	if (pos) memcpy(g.listenerPos, pos, sizeof g.listenerPos);
	g.listenerFwd[0] = fx; g.listenerFwd[1] = fy; g.listenerFwd[2] = fz;
	g.listenerUp[0] = tx; g.listenerUp[1] = ty; g.listenerUp[2] = tz;
}

FSOUND_STREAM *__stdcall FSOUND_Stream_Open(const char *nameOrData, unsigned int mode, int offset, int length)
{
	std::unique_ptr<FSOUND_STREAM> s(new FSOUND_STREAM());
	if (mode & FSOUND_LOADMEMORY) s->file.assign((const unsigned char*)nameOrData + offset, (const unsigned char*)nameOrData + offset + length);
	else if (!ReadWholeFile(nameOrData, &s->file)) { g.error = 9; return nullptr; }
	s->mode = mode;
	if (IsOgg(s->file.data(), s->file.size()))
	{
		int err = 0; s->ogg = stb_vorbis_open_memory(s->file.data(), (int)s->file.size(), &err, nullptr);
		if (s->ogg)
		{
			stb_vorbis_info info = stb_vorbis_get_info(s->ogg);
			s->channels = info.channels; s->rate = (int)info.sample_rate;
			s->lengthFrames = stb_vorbis_stream_length_in_samples(s->ogg);
		}
		else fprintf(stderr, "[sound] stream falls back to Core Audio (stb_vorbis error %d): %s\n", err, (mode & FSOUND_LOADMEMORY) ? "memory" : nameOrData);
	}
	if (!s->ogg)   // not Ogg, or Vorbis floor 0, which stb_vorbis refuses (23 of Silent Storm's 30 tracks, measured)
	{
		s->pcm.reset(new FSOUND_SAMPLE());
		if (!DecodeCoreAudio(s->file.data(), s->file.size(), s->pcm.get())) { g.error = 10; return nullptr; }
		s->pcm->loopStart = 0; s->pcm->loopEnd = (int)s->pcm->frames - 1;
		s->channels = s->pcm->channels; s->rate = s->pcm->rate; s->lengthFrames = s->pcm->frames;
		s->file.clear();
	}
	Guard lk(g.lock); g.streams.push_back(s.get());
	return s.release();
}
signed char __stdcall FSOUND_Stream_Close(FSOUND_STREAM *s)
{
	if (!s) return FALSE;
	{
		Guard lk(g.lock);
		for (Voice &v : g.voices) if (v.stream == s) v.active = false;
		g.streams.erase(std::remove(g.streams.begin(), g.streams.end(), s), g.streams.end());
	}
	delete s; return TRUE;
}
int __stdcall FSOUND_Stream_Play(int, FSOUND_STREAM *s)
{
	if (!s || !g.initialised) return -1;
	Guard lk(g.lock);
	for (Voice &v : g.voices) if (v.stream == s) v.active = false;
	int slot = AllocVoice(255, true);
	if (slot < 0) return -1;
	Voice &v = g.voices[slot];
	v.stream = s; v.active = true; v.priority = 255; v.stereoPan = s->channels > 1;
	v.loopMode = (s->mode & FSOUND_LOOP_NORMAL) ? FSOUND_LOOP_NORMAL : FSOUND_LOOP_OFF;
	if (s->pcm) { v.sample = s->pcm.get(); v.pos = s->positionFrames; }
	s->playing = true; s->finished = false;
	s->channel = MakeHandle(slot, v.generation);
	return s->channel;
}
signed char __stdcall FSOUND_Stream_Stop(FSOUND_STREAM *s)
{
	if (!s) return FALSE;
	Guard lk(g.lock);
	for (Voice &v : g.voices) if (v.stream == s) v.active = false;
	s->playing = false;
	if (s->ogg) stb_vorbis_seek_start(s->ogg);
	s->Reset(); s->finished = false;
	s->positionFrames = 0;
	return TRUE;
}
signed char __stdcall FSOUND_Stream_SetPosition(FSOUND_STREAM *s, unsigned int frame)
{
	if (!s) return FALSE;
	Guard lk(g.lock);
	frame = std::min(frame, s->lengthFrames);
	if (s->ogg) { stb_vorbis_seek(s->ogg, frame); s->Reset(); s->finished = false; }
	s->positionFrames = frame;
	for (Voice &v : g.voices) if (v.stream == s && s->pcm) v.pos = frame;
	return TRUE;
}
signed char __stdcall FSOUND_Stream_SetTime(FSOUND_STREAM *s, int ms) { return s ? FSOUND_Stream_SetPosition(s, (unsigned)((int64_t)ms * s->rate / 1000)) : FALSE; }
int __stdcall FSOUND_Stream_GetTime(FSOUND_STREAM *s) { if (!s) return 0; Guard lk(g.lock); return (int)((int64_t)s->positionFrames * 1000 / std::max(1, s->rate)); }
int __stdcall FSOUND_Stream_GetLengthMs(FSOUND_STREAM *s) { return s ? (int)((int64_t)s->lengthFrames * 1000 / std::max(1, s->rate)) : 0; }
// Sync points are WAV cue markers. The shipped music is Ogg Vorbis, which carries none, so FMOD 3
// never fired this callback for it; it is stored and not invoked, matching that behaviour.
signed char __stdcall FSOUND_Stream_SetSyncCallback(FSOUND_STREAM *s, FSOUND_STREAMCALLBACK cb, intptr_t ud) { if (!s) return FALSE; s->sync = cb; s->syncParam = ud; return TRUE; }

} // extern "C"

#define STB_VORBIS_NO_STDIO_OVERRIDE
#undef STB_VORBIS_HEADER_ONLY
#include "../third_party/stb_vorbis.c"

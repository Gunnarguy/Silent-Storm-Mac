// bink_avf.mm: the Bink video API on AVFoundation. The game's .bik movies are converted once to H.264/AAC
// MP4 files beside them (port/tools/convert_videos.sh); frames are decoded in hardware and the movie's
// audio track is the playback clock, as Bink's own sound track was.
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#include "s2win32.h"
#include "bink.h"
#include <string>

namespace {
struct S2Bink
{
	BINK b;                       // must stay first: the engine reads Width/Height/Frames/FrameNum through HBINK
	AVURLAsset *asset = nil;
	AVAssetReader *reader = nil;
	AVAssetReaderTrackOutput *output = nil;
	AVPlayer *audio = nil;
	CVPixelBufferRef frame = nullptr;
	U32 decoded = 0;              // frame number held in `frame`
	double fps = 25;
	uint64_t startNanos = 0, pausedNanos = 0;
	bool paused = false;
	float volume = 1;
};

uint64_t Now() { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

void StartReader(S2Bink *m, U32 fromFrame)
{
	[m->reader cancelReading];
	m->reader = [[AVAssetReader alloc] initWithAsset:m->asset error:nil];
	AVAssetTrack *track = [m->asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
	m->output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:@{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) }];
	m->output.alwaysCopiesSampleData = NO;
	[m->reader addOutput:m->output];
	if (fromFrame > 1) m->reader.timeRange = CMTimeRangeMake(CMTimeMakeWithSeconds((fromFrame - 1) / m->fps, 600), kCMTimePositiveInfinity);
	[m->reader startReading];
	m->decoded = fromFrame - 1;
}

double Clock(S2Bink *m)
{
	if (m->audio && m->audio.currentItem.status == AVPlayerItemStatusReadyToPlay && m->audio.rate > 0)
		return CMTimeGetSeconds(m->audio.currentTime);
	uint64_t now = m->paused ? m->pausedNanos : Now();
	return (now - m->startNanos) / 1e9;
}
}

extern "C" {

HBINK __stdcall BinkOpen(const char *name, U32 flags)
{
	if (!name || (flags & 0x04000000)) return nullptr;   // from-memory opens carry .bik bytes, which are not converted
	char path[1024]; S2HostPath(name, path, sizeof path);
	std::string mp4 = path;
	size_t dot = mp4.rfind('.'); if (dot != std::string::npos) mp4.erase(dot);
	mp4 += ".mp4";
	if (access(mp4.c_str(), R_OK) != 0) return nullptr;
	@autoreleasepool
	{
		S2Bink *m = new S2Bink();
		m->asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:mp4.c_str()]] options:@{ AVURLAssetPreferPreciseDurationAndTimingKey: @YES }];
		AVAssetTrack *video = [m->asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
		if (!video) { delete m; return nullptr; }
		CGSize size = video.naturalSize;
		m->fps = video.nominalFrameRate > 0 ? video.nominalFrameRate : 25;
		m->b.Width = (U32)size.width; m->b.Height = (U32)size.height;
		m->b.Frames = (U32)llround(CMTimeGetSeconds(m->asset.duration) * m->fps);
		m->b.FrameNum = 1; m->b.LastFrameNum = 0;
		m->b.FrameRate = (U32)llround(m->fps * 1000); m->b.FrameRateDiv = 1000;
		StartReader(m, 1);
		if ([m->asset tracksWithMediaType:AVMediaTypeAudio].count)
		{
			AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:m->asset];
			for (AVPlayerItemTrack *t in item.tracks) if ([t.assetTrack.mediaType isEqualToString:AVMediaTypeVideo]) t.enabled = NO;
			m->audio = [AVPlayer playerWithPlayerItem:item];
			[m->audio play];
		}
		m->startNanos = Now();
		return &m->b;
	}
}
void __stdcall BinkClose(HBINK h)
{
	if (!h) return;
	S2Bink *m = (S2Bink*)h;
	[m->audio pause]; [m->reader cancelReading];
	if (m->frame) CVPixelBufferRelease(m->frame);
	delete m;
}
S32 __stdcall BinkWait(HBINK h)
{
	if (!h) return 0;
	S2Bink *m = (S2Bink*)h;
	if (m->paused) return 1;
	return Clock(m) + 0.5 / m->fps >= (m->b.FrameNum - 1) / m->fps ? 0 : 1;
}
S32 __stdcall BinkDoFrame(HBINK h)
{
	if (!h) return 0;
	S2Bink *m = (S2Bink*)h;
	if (m->b.FrameNum <= m->decoded && m->frame) return 0;
	if (m->b.FrameNum < m->decoded) StartReader(m, m->b.FrameNum);
	@autoreleasepool
	{
		while (m->decoded < m->b.FrameNum)
		{
			CMSampleBufferRef sb = [m->output copyNextSampleBuffer];
			if (!sb) break;
			CVImageBufferRef img = CMSampleBufferGetImageBuffer(sb);
			if (img) { if (m->frame) CVPixelBufferRelease(m->frame); m->frame = CVPixelBufferRetain(img); }
			CFRelease(sb);
			++m->decoded;
		}
	}
	return 0;
}
void __stdcall BinkNextFrame(HBINK h)
{
	if (!h) return;
	S2Bink *m = (S2Bink*)h;
	m->b.LastFrameNum = m->b.FrameNum;
	if (m->b.FrameNum < m->b.Frames) ++m->b.FrameNum;
	else
	{
		m->b.FrameNum = 1;   // Bink wraps to the first frame; the engine stops non-looping movies itself
		StartReader(m, 1);
		[m->audio seekToTime:kCMTimeZero]; [m->audio play];
		m->startNanos = Now();
	}
}
void __stdcall BinkGoto(HBINK h, U32 frame, S32)
{
	if (!h) return;
	S2Bink *m = (S2Bink*)h;
	m->b.FrameNum = std::max(1u, std::min(frame, m->b.Frames));
	StartReader(m, m->b.FrameNum);
	CMTime t = CMTimeMakeWithSeconds((m->b.FrameNum - 1) / m->fps, 600);
	[m->audio seekToTime:t toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
	m->startNanos = Now() - (uint64_t)((m->b.FrameNum - 1) / m->fps * 1e9);
}
S32 __stdcall BinkPause(HBINK h, S32 pause)
{
	if (!h) return 0;
	S2Bink *m = (S2Bink*)h;
	if (pause && !m->paused) { m->paused = true; m->pausedNanos = Now(); [m->audio pause]; }
	else if (!pause && m->paused) { m->paused = false; m->startNanos += Now() - m->pausedNanos; [m->audio play]; }
	return pause;
}
void __stdcall BinkSetVolume(HBINK h, U32, S32 volume)
{
	if (!h) return;
	S2Bink *m = (S2Bink*)h;
	m->volume = std::max(0.0f, std::min(1.0f, volume / 32768.0f));
	m->audio.volume = m->volume;
}
S32 __stdcall BinkCopyToBuffer(HBINK h, void *dest, S32 pitch, U32 height, U32 x, U32 y, U32 flags)
{
	if (!h || !dest) return 0;
	S2Bink *m = (S2Bink*)h;
	if (!m->frame) return 0;
	CVPixelBufferLockBaseAddress(m->frame, kCVPixelBufferLock_ReadOnly);
	const uint8_t *src = (const uint8_t*)CVPixelBufferGetBaseAddress(m->frame);
	size_t srcPitch = CVPixelBufferGetBytesPerRow(m->frame);
	size_t w = std::min<size_t>(CVPixelBufferGetWidth(m->frame), m->b.Width), rows = std::min<size_t>({ CVPixelBufferGetHeight(m->frame), (size_t)height, (size_t)m->b.Height });
	bool to16 = (flags & 0xF) == 8;   // engine's 16-bit path (never taken on this build): BGRA -> 1555
	for (size_t r = 0; r < rows; ++r)
	{
		const uint8_t *s = src + r * srcPitch;
		uint8_t *d = (uint8_t*)dest + (r + y) * pitch;
		if (!to16) memcpy(d + x * 4, s, w * 4);
		else for (size_t i = 0; i < w; ++i) ((uint16_t*)d)[x + i] = (uint16_t)(0x8000 | ((s[i * 4 + 2] >> 3) << 10) | ((s[i * 4 + 1] >> 3) << 5) | (s[i * 4] >> 3));
	}
	CVPixelBufferUnlockBaseAddress(m->frame, kCVPixelBufferLock_ReadOnly);
	return 0;
}
S32 __stdcall BinkOpenDirectSound(U32) { return 1; }
S32 __stdcall BinkSetSoundSystem(BINKSNDSYSOPEN, U32) { return 1; }

} // extern "C"

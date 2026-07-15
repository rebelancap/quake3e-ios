// ios_snd.c — SNDDMA backend on AudioQueue (C API — no SDL, no ObjC).
// Classic id DMA model: the engine mixer paints ahead into dma.buffer
// (interleaved 16-bit ring); the AudioQueue callback consumes behind it.
// SNDDMA_GetDMAPos returns the ring-relative play cursor in samples;
// S_Base wrap-detects to build absolute soundtime.

#include "client/snd_local.h"

#include <AudioToolbox/AudioToolbox.h>
#include <pthread.h>

void Q3E_ActivateAudioSession(void); // ios_metal.m (AVAudioSession is ObjC)

#define Q3E_AQ_BUFFERS 3
#define Q3E_AQ_FRAMES  1024

static AudioQueueRef q3e_queue;
static AudioQueueBufferRef q3e_bufs[Q3E_AQ_BUFFERS];
static pthread_mutex_t q3e_snd_mutex = PTHREAD_MUTEX_INITIALIZER;
static unsigned int q3e_readpos; // bytes consumed from the ring, monotonic
static qboolean q3e_snd_active = qfalse;

static void q3e_aq_callback(void *userData, AudioQueueRef aq, AudioQueueBufferRef buf) {
	const unsigned int ringBytes = dma.samples * (dma.samplebits / 8);
	byte *out = (byte *)buf->mAudioData;
	const unsigned int want = buf->mAudioDataBytesCapacity;
	unsigned int pos, first;

	pthread_mutex_lock(&q3e_snd_mutex);
	pos = q3e_readpos % ringBytes;
	first = ringBytes - pos;
	if (first > want) {
		first = want;
	}
	memcpy(out, dma.buffer + pos, first);
	if (want > first) {
		memcpy(out + first, dma.buffer, want - first);
	}
	q3e_readpos += want;
	pthread_mutex_unlock(&q3e_snd_mutex);

	buf->mAudioDataByteSize = want;
	AudioQueueEnqueueBuffer(aq, buf, 0, NULL);
}

qboolean SNDDMA_Init(void) {
	AudioStreamBasicDescription fmt;
	OSStatus err;
	int i, khz, speed;

	khz = Cvar_VariableIntegerValue("s_khz");
	switch (khz) {
		case 48: speed = 48000; break;
		case 44: speed = 44100; break;
		case 11: speed = 11025; break;
		case 8:  speed = 8000;  break;
		default: speed = 22050; break;
	}

	Q3E_ActivateAudioSession();

	dma.channels = 2;
	dma.samplebits = 16;
	dma.isfloat = 0;
	dma.speed = speed;
	dma.fullsamples = 8192; // frames in ring (~0.37 s at 22 kHz)
	dma.samples = dma.fullsamples * dma.channels;
	dma.submission_chunk = 1;
	dma.driver = "AudioQueue";
	dma.buffer = calloc(1, dma.samples * (dma.samplebits / 8));

	memset(&fmt, 0, sizeof(fmt));
	fmt.mSampleRate = speed;
	fmt.mFormatID = kAudioFormatLinearPCM;
	fmt.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
	fmt.mBitsPerChannel = 16;
	fmt.mChannelsPerFrame = 2;
	fmt.mBytesPerFrame = 4;
	fmt.mFramesPerPacket = 1;
	fmt.mBytesPerPacket = 4;

	err = AudioQueueNewOutput(&fmt, q3e_aq_callback, NULL, NULL, NULL, 0, &q3e_queue);
	if (err != noErr) {
		Com_Printf(S_COLOR_YELLOW "AudioQueueNewOutput failed: %d\n", (int)err);
		free(dma.buffer);
		dma.buffer = NULL;
		return qfalse;
	}

	for (i = 0; i < Q3E_AQ_BUFFERS; i++) {
		err = AudioQueueAllocateBuffer(q3e_queue, Q3E_AQ_FRAMES * fmt.mBytesPerFrame, &q3e_bufs[i]);
		if (err != noErr) {
			Com_Printf(S_COLOR_YELLOW "AudioQueueAllocateBuffer failed: %d\n", (int)err);
			AudioQueueDispose(q3e_queue, true);
			free(dma.buffer);
			dma.buffer = NULL;
			return qfalse;
		}
		memset(q3e_bufs[i]->mAudioData, 0, q3e_bufs[i]->mAudioDataBytesCapacity);
		q3e_bufs[i]->mAudioDataByteSize = q3e_bufs[i]->mAudioDataBytesCapacity;
		AudioQueueEnqueueBuffer(q3e_queue, q3e_bufs[i], 0, NULL);
	}

	AudioQueueSetParameter(q3e_queue, kAudioQueueParam_Volume, 1.0f);
	q3e_readpos = 0;

	err = AudioQueueStart(q3e_queue, NULL);
	if (err != noErr) {
		Com_Printf(S_COLOR_YELLOW "AudioQueueStart failed: %d\n", (int)err);
		AudioQueueDispose(q3e_queue, true);
		free(dma.buffer);
		dma.buffer = NULL;
		return qfalse;
	}

	q3e_snd_active = qtrue;
	Com_Printf("iOS AudioQueue sound: %d Hz, %d ch, ring %d frames\n",
		dma.speed, dma.channels, dma.fullsamples);
	return qtrue;
}

int SNDDMA_GetDMAPos(void) {
	unsigned int posBytes;

	if (!q3e_snd_active) {
		return 0;
	}
	pthread_mutex_lock(&q3e_snd_mutex);
	posBytes = q3e_readpos;
	pthread_mutex_unlock(&q3e_snd_mutex);
	return (int)((posBytes / (dma.samplebits / 8)) % dma.samples);
}

void SNDDMA_BeginPainting(void) {
	if (q3e_snd_active) {
		pthread_mutex_lock(&q3e_snd_mutex);
	}
}

void SNDDMA_Submit(void) {
	if (q3e_snd_active) {
		pthread_mutex_unlock(&q3e_snd_mutex);
	}
}

void Q3E_SND_Pause(void) {
	if (q3e_snd_active) {
		AudioQueuePause(q3e_queue);
	}
}

void Q3E_SND_Resume(void) {
	if (q3e_snd_active) {
		AudioQueueStart(q3e_queue, NULL);
	}
}

void SNDDMA_Shutdown(void) {
	if (!q3e_snd_active) {
		return;
	}
	q3e_snd_active = qfalse;
	AudioQueueStop(q3e_queue, true);
	AudioQueueDispose(q3e_queue, true);
	free(dma.buffer);
	dma.buffer = NULL;
}

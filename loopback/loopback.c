// micboost loopback — a two-channel virtual audio device: whatever is played to it comes back on
// its input. An AudioServerPlugIn, loaded by coreaudiod, written against AudioServerPlugIn.h.
//
// What it deliberately does not have: a mirrored device, volume or mute controls, a box object,
// more than one sample rate, more than two channels.
//
// The one design decision worth stating. A reader is served the overlap between what it asks for
// and what has actually been written, and zeros for the rest. There is no shared "is anyone
// writing" flag and no client ever clears the ring for another: two apps reading this device at
// once cannot silence each other.

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

#define kDriver_Name        "micboost loopback"
#define kDevice_Name        "micboost"
#define kDevice_UID         "me.pecheny.micboost.loopback.device"
#define kDevice_ModelUID    "me.pecheny.micboost.loopback.model"
#define kManufacturer       "pecheny.me"

enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject,
    kObjectID_Device        = 2,
    kObjectID_Stream_Input  = 3,
    kObjectID_Stream_Output = 4,
};

#define kChannels           2
#define kSampleRate         48000.0
#define kBytesPerFrame      (kChannels * sizeof(Float32))
#define kRing_Frames        65536              // 1.4 s at 48 kHz: far more than any IO cycle
#define kZeroTimeStamp_Period 16384

// ---------------------------------------------------------------- state

static pthread_mutex_t  gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32           gRefCount               = 0;
static AudioServerPlugInHostRef gHost           = NULL;
static UInt32           gIORunningCount         = 0;
static Float64          gHostTicksPerFrame      = 0;
static UInt64           gAnchorHostTime         = 0;
static UInt64           gTimeStampCount         = 0;
static Boolean          gStreamsActive          = true;

static Float32          gRing[kRing_Frames * kChannels];
// Sample time up to which gRing holds real audio. Written by the output path, read by the input
// path; relaxed atomics keep both well defined without putting a barrier on the IO thread.
static _Atomic Float64  gWrittenTo              = 0;

static AudioStreamBasicDescription StreamFormat(void)
{
    AudioStreamBasicDescription f = {0};
    f.mSampleRate       = kSampleRate;
    f.mFormatID         = kAudioFormatLinearPCM;
    f.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket   = kBytesPerFrame;
    f.mFramesPerPacket  = 1;
    f.mBytesPerFrame    = kBytesPerFrame;
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel   = 32;
    return f;
}

// ---------------------------------------------------------------- ring

// Copy `frames` frames into the ring at sample time `at`, wrapping once.
static void RingWrite(Float64 at, UInt32 frames, const Float32* src)
{
    UInt32 start = (UInt32)((UInt64)at % kRing_Frames);
    UInt32 first = kRing_Frames - start;
    if (first > frames) first = frames;
    memcpy(gRing + (size_t)start * kChannels, src, (size_t)first * kBytesPerFrame);
    memcpy(gRing, src + (size_t)first * kChannels, (size_t)(frames - first) * kBytesPerFrame);
}

static void RingRead(Float64 at, UInt32 frames, Float32* dst)
{
    UInt32 start = (UInt32)((UInt64)at % kRing_Frames);
    UInt32 first = kRing_Frames - start;
    if (first > frames) first = frames;
    memcpy(dst, gRing + (size_t)start * kChannels, (size_t)first * kBytesPerFrame);
    memcpy(dst + (size_t)first * kChannels, gRing, (size_t)(frames - first) * kBytesPerFrame);
}

static void RingZero(Float64 at, UInt32 frames)
{
    if (frames > kRing_Frames) frames = kRing_Frames;
    UInt32 start = (UInt32)((UInt64)at % kRing_Frames);
    UInt32 first = kRing_Frames - start;
    if (first > frames) first = frames;
    memset(gRing + (size_t)start * kChannels, 0, (size_t)first * kBytesPerFrame);
    memset(gRing, 0, (size_t)(frames - first) * kBytesPerFrame);
}

// ---------------------------------------------------------------- properties

static Boolean HasProperty(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress);
static OSStatus GetPropertyDataSize(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress, UInt32* outSize);
static OSStatus GetPropertyData(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress,
                                UInt32 inDataSize, UInt32* outDataSize, void* outData);

#define WANT(bytes)  if (inDataSize < (bytes)) return kAudioHardwareBadPropertySizeError;

static OSStatus PlugInProperty(const AudioObjectPropertyAddress* a, UInt32 inQualifierDataSize,
                               const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:
            WANT(sizeof(AudioClassID)); *(AudioClassID*)outData = kAudioObjectClassID; *outDataSize = sizeof(AudioClassID); return 0;
        case kAudioObjectPropertyClass:
            WANT(sizeof(AudioClassID)); *(AudioClassID*)outData = kAudioPlugInClassID; *outDataSize = sizeof(AudioClassID); return 0;
        case kAudioObjectPropertyOwner:
            WANT(sizeof(AudioObjectID)); *(AudioObjectID*)outData = kAudioObjectUnknown; *outDataSize = sizeof(AudioObjectID); return 0;
        case kAudioObjectPropertyManufacturer:
            WANT(sizeof(CFStringRef)); *(CFStringRef*)outData = CFSTR(kManufacturer); *outDataSize = sizeof(CFStringRef); return 0;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            if (inDataSize >= sizeof(AudioObjectID)) {
                *(AudioObjectID*)outData = kObjectID_Device;
                *outDataSize = sizeof(AudioObjectID);
            } else {
                *outDataSize = 0;
            }
            return 0;
        case kAudioPlugInPropertyBoxList:
            *outDataSize = 0; return 0;
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            // Asked without a qualifier when the Host only wants the size, so answer either way.
            WANT(sizeof(AudioObjectID));
            AudioObjectID match = kAudioObjectUnknown;
            if (inQualifierData != NULL && inQualifierDataSize == sizeof(CFStringRef)
                && CFStringCompare(*((CFStringRef*)inQualifierData), CFSTR(kDevice_UID), 0) == kCFCompareEqualTo)
                match = kObjectID_Device;
            *(AudioObjectID*)outData = match;
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        }
        case kAudioPlugInPropertyResourceBundle:
            WANT(sizeof(CFStringRef)); *(CFStringRef*)outData = CFSTR(""); *outDataSize = sizeof(CFStringRef); return 0;
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus DeviceProperty(const AudioObjectPropertyAddress* a, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:
            WANT(sizeof(AudioClassID)); *(AudioClassID*)outData = kAudioObjectClassID; *outDataSize = sizeof(AudioClassID); return 0;
        case kAudioObjectPropertyClass:
            WANT(sizeof(AudioClassID)); *(AudioClassID*)outData = kAudioDeviceClassID; *outDataSize = sizeof(AudioClassID); return 0;
        case kAudioObjectPropertyOwner:
            WANT(sizeof(AudioObjectID)); *(AudioObjectID*)outData = kObjectID_PlugIn; *outDataSize = sizeof(AudioObjectID); return 0;
        case kAudioObjectPropertyName:
            WANT(sizeof(CFStringRef)); *(CFStringRef*)outData = CFSTR(kDevice_Name); *outDataSize = sizeof(CFStringRef); return 0;
        case kAudioObjectPropertyManufacturer:
            WANT(sizeof(CFStringRef)); *(CFStringRef*)outData = CFSTR(kManufacturer); *outDataSize = sizeof(CFStringRef); return 0;
        case kAudioDevicePropertyDeviceUID:
            WANT(sizeof(CFStringRef)); *(CFStringRef*)outData = CFSTR(kDevice_UID); *outDataSize = sizeof(CFStringRef); return 0;
        case kAudioDevicePropertyModelUID:
            WANT(sizeof(CFStringRef)); *(CFStringRef*)outData = CFSTR(kDevice_ModelUID); *outDataSize = sizeof(CFStringRef); return 0;
        case kAudioDevicePropertyTransportType:
            WANT(sizeof(UInt32)); *(UInt32*)outData = kAudioDeviceTransportTypeVirtual; *outDataSize = sizeof(UInt32); return 0;
        case kAudioDevicePropertyClockDomain:
            WANT(sizeof(UInt32)); *(UInt32*)outData = 0; *outDataSize = sizeof(UInt32); return 0;
        case kAudioDevicePropertyDeviceIsAlive:
            WANT(sizeof(UInt32)); *(UInt32*)outData = 1; *outDataSize = sizeof(UInt32); return 0;
        case kAudioDevicePropertyDeviceIsRunning:
            WANT(sizeof(UInt32)); *(UInt32*)outData = gIORunningCount > 0; *outDataSize = sizeof(UInt32); return 0;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            WANT(sizeof(UInt32)); *(UInt32*)outData = 1; *outDataSize = sizeof(UInt32); return 0;
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
            WANT(sizeof(UInt32)); *(UInt32*)outData = 0; *outDataSize = sizeof(UInt32); return 0;
        case kAudioDevicePropertyZeroTimeStampPeriod:
            WANT(sizeof(UInt32)); *(UInt32*)outData = kZeroTimeStamp_Period; *outDataSize = sizeof(UInt32); return 0;
        case kAudioDevicePropertyIsHidden:
            WANT(sizeof(UInt32)); *(UInt32*)outData = 0; *outDataSize = sizeof(UInt32); return 0;
        case kAudioDevicePropertyNominalSampleRate:
            WANT(sizeof(Float64)); *(Float64*)outData = kSampleRate; *outDataSize = sizeof(Float64); return 0;
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            if (inDataSize < sizeof(AudioValueRange)) { *outDataSize = 0; return 0; }
            AudioValueRange* r = (AudioValueRange*)outData;
            r->mMinimum = kSampleRate; r->mMaximum = kSampleRate;
            *outDataSize = sizeof(AudioValueRange);
            return 0;
        }
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            WANT(2 * sizeof(UInt32));
            ((UInt32*)outData)[0] = 1; ((UInt32*)outData)[1] = 2;
            *outDataSize = 2 * sizeof(UInt32);
            return 0;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 size = offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription);
            WANT(size);
            AudioChannelLayout* l = (AudioChannelLayout*)outData;
            memset(l, 0, size);
            l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            l->mNumberChannelDescriptions = kChannels;
            for (UInt32 c = 0; c < kChannels; c++) {
                l->mChannelDescriptions[c].mChannelLabel = kAudioChannelLabel_Left + c;
                l->mChannelDescriptions[c].mChannelFlags = kAudioChannelFlags_AllOff;
            }
            *outDataSize = size;
            return 0;
        }
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertyRelatedDevices:
            if (a->mSelector == kAudioDevicePropertyRelatedDevices && inDataSize >= sizeof(AudioObjectID)) {
                *(AudioObjectID*)outData = kObjectID_Device;
                *outDataSize = sizeof(AudioObjectID);
            } else {
                *outDataSize = 0;
            }
            return 0;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams: {
            AudioObjectID ids[2]; UInt32 count = 0;
            if (a->mScope == kAudioObjectPropertyScopeGlobal || a->mScope == kAudioObjectPropertyScopeInput)
                ids[count++] = kObjectID_Stream_Input;
            if (a->mScope == kAudioObjectPropertyScopeGlobal || a->mScope == kAudioObjectPropertyScopeOutput)
                ids[count++] = kObjectID_Stream_Output;
            UInt32 fits = inDataSize / sizeof(AudioObjectID);
            if (fits > count) fits = count;
            memcpy(outData, ids, fits * sizeof(AudioObjectID));
            *outDataSize = fits * sizeof(AudioObjectID);
            return 0;
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus StreamProperty(AudioObjectID inObjectID, const AudioObjectPropertyAddress* a,
                               UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    Boolean isInput = (inObjectID == kObjectID_Stream_Input);
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:
            WANT(sizeof(AudioClassID)); *(AudioClassID*)outData = kAudioObjectClassID; *outDataSize = sizeof(AudioClassID); return 0;
        case kAudioObjectPropertyClass:
            WANT(sizeof(AudioClassID)); *(AudioClassID*)outData = kAudioStreamClassID; *outDataSize = sizeof(AudioClassID); return 0;
        case kAudioObjectPropertyOwner:
            WANT(sizeof(AudioObjectID)); *(AudioObjectID*)outData = kObjectID_Device; *outDataSize = sizeof(AudioObjectID); return 0;
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0; return 0;
        case kAudioStreamPropertyIsActive:
            WANT(sizeof(UInt32)); *(UInt32*)outData = gStreamsActive; *outDataSize = sizeof(UInt32); return 0;
        case kAudioStreamPropertyDirection:
            WANT(sizeof(UInt32)); *(UInt32*)outData = isInput ? 1 : 0; *outDataSize = sizeof(UInt32); return 0;
        case kAudioStreamPropertyTerminalType:
            WANT(sizeof(UInt32));
            *(UInt32*)outData = isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker;
            *outDataSize = sizeof(UInt32); return 0;
        case kAudioStreamPropertyStartingChannel:
            WANT(sizeof(UInt32)); *(UInt32*)outData = 1; *outDataSize = sizeof(UInt32); return 0;
        case kAudioStreamPropertyLatency:
            WANT(sizeof(UInt32)); *(UInt32*)outData = 0; *outDataSize = sizeof(UInt32); return 0;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            WANT(sizeof(AudioStreamBasicDescription));
            *(AudioStreamBasicDescription*)outData = StreamFormat();
            *outDataSize = sizeof(AudioStreamBasicDescription); return 0;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            if (inDataSize < sizeof(AudioStreamRangedDescription)) { *outDataSize = 0; return 0; }
            AudioStreamRangedDescription* d = (AudioStreamRangedDescription*)outData;
            d->mFormat = StreamFormat();
            d->mSampleRateRange.mMinimum = kSampleRate;
            d->mSampleRateRange.mMaximum = kSampleRate;
            *outDataSize = sizeof(AudioStreamRangedDescription);
            return 0;
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus GetPropertyData(AudioObjectID inObjectID, const AudioObjectPropertyAddress* a,
                                UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    switch (inObjectID) {
        case kObjectID_PlugIn:        return PlugInProperty(a, 0, NULL, inDataSize, outDataSize, outData);
        case kObjectID_Device:        return DeviceProperty(a, inDataSize, outDataSize, outData);
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output: return StreamProperty(inObjectID, a, inDataSize, outDataSize, outData);
    }
    return kAudioHardwareBadObjectError;
}

static Boolean HasProperty(AudioObjectID inObjectID, const AudioObjectPropertyAddress* a)
{
    UInt32 size = 0;
    return GetPropertyDataSize(inObjectID, a, &size) == 0;
}

// The size of a property is the size the getter reports when given room for anything.
static OSStatus GetPropertyDataSize(AudioObjectID inObjectID, const AudioObjectPropertyAddress* a, UInt32* outSize)
{
    char scratch[4096];
    UInt32 written = 0;
    OSStatus err = GetPropertyData(inObjectID, a, (UInt32)sizeof(scratch), &written, scratch);
    if (err == 0) *outSize = written;
    return err;
}

// ---------------------------------------------------------------- driver interface

static HRESULT QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG AddRef(void* inDriver);
static ULONG Release(void* inDriver);

static OSStatus Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    (void)inDriver;
    gHost = inHost;
    struct mach_timebase_info tb;
    mach_timebase_info(&tb);
    gHostTicksPerFrame = ((Float64)tb.denom / (Float64)tb.numer) * 1000000000.0 / kSampleRate;
    return 0;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc,
                             const AudioServerPlugInClientInfo* info, AudioObjectID* out)
{ (void)d; (void)desc; (void)info; (void)out; return kAudioHardwareUnsupportedOperationError; }

static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id)
{ (void)d; (void)id; return kAudioHardwareUnsupportedOperationError; }

static OSStatus AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo* c)
{ (void)d; (void)id; (void)c; return 0; }

static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo* c)
{ (void)d; (void)id; (void)c; return 0; }

static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 action, void* info)
{ (void)d; (void)id; (void)action; (void)info; return 0; }

static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 action, void* info)
{ (void)d; (void)id; (void)action; (void)info; return 0; }

static Boolean Driver_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t client,
                                  const AudioObjectPropertyAddress* a)
{ (void)d; (void)client; return HasProperty(id, a); }

static OSStatus Driver_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t client,
                                          const AudioObjectPropertyAddress* a, Boolean* out)
{
    (void)d; (void)client;
    if (!HasProperty(id, a)) return kAudioHardwareUnknownPropertyError;
    *out = (id == kObjectID_Stream_Input || id == kObjectID_Stream_Output)
        && (a->mSelector == kAudioStreamPropertyIsActive
            || a->mSelector == kAudioStreamPropertyVirtualFormat
            || a->mSelector == kAudioStreamPropertyPhysicalFormat);
    if (id == kObjectID_Device && a->mSelector == kAudioDevicePropertyNominalSampleRate) *out = true;
    return 0;
}

static OSStatus Driver_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t client,
                                           const AudioObjectPropertyAddress* a, UInt32 qsize, const void* q, UInt32* out)
{ (void)d; (void)client; (void)qsize; (void)q; return GetPropertyDataSize(id, a, out); }

static OSStatus Driver_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t client,
                                       const AudioObjectPropertyAddress* a, UInt32 qsize, const void* q,
                                       UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    (void)d; (void)client;
    if (id == kObjectID_PlugIn && a->mSelector == kAudioPlugInPropertyTranslateUIDToDevice)
        return PlugInProperty(a, qsize, q, inDataSize, outDataSize, outData);
    return GetPropertyData(id, a, inDataSize, outDataSize, outData);
}

static OSStatus Driver_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t client,
                                       const AudioObjectPropertyAddress* a, UInt32 qsize, const void* q,
                                       UInt32 inDataSize, const void* inData)
{
    (void)d; (void)client; (void)qsize; (void)q;
    if (id == kObjectID_Stream_Input || id == kObjectID_Stream_Output) {
        switch (a->mSelector) {
            case kAudioStreamPropertyIsActive:
                if (inDataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                gStreamsActive = *((const UInt32*)inData) != 0;
                return 0;
            // One format, so accepting it is the whole implementation and anything else is refused.
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat: {
                if (inDataSize != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
                const AudioStreamBasicDescription* f = (const AudioStreamBasicDescription*)inData;
                if (f->mFormatID != kAudioFormatLinearPCM || f->mSampleRate != kSampleRate
                    || f->mChannelsPerFrame != kChannels || f->mBitsPerChannel != 32)
                    return kAudioDeviceUnsupportedFormatError;
                return 0;
            }
        }
    }
    if (id == kObjectID_Device && a->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inDataSize != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return (*((const Float64*)inData) == kSampleRate) ? 0 : kAudioHardwareIllegalOperationError;
    }
    return HasProperty(id, a) ? kAudioHardwareUnsupportedOperationError : kAudioHardwareUnknownPropertyError;
}

// ---------------------------------------------------------------- IO

static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client)
{
    (void)d; (void)client;
    if (id != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIORunningCount == 0) {
        memset(gRing, 0, sizeof(gRing));
        atomic_store_explicit(&gWrittenTo, 0, memory_order_relaxed);
        gTimeStampCount = 0;
        gAnchorHostTime = mach_absolute_time();
    }
    gIORunningCount++;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client)
{
    (void)d; (void)client;
    if (id != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIORunningCount > 0) gIORunningCount--;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

// The device's clock: a sample time and the host time at which it happened, one per period.
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client,
                                 Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
    (void)d; (void)client;
    if (id != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    UInt64 period = (UInt64)(kZeroTimeStamp_Period * gHostTicksPerFrame);
    UInt64 next = gAnchorHostTime + (gTimeStampCount + 1) * period;
    if (mach_absolute_time() >= next) gTimeStampCount++;
    *outSampleTime = (Float64)(gTimeStampCount * kZeroTimeStamp_Period);
    *outHostTime = gAnchorHostTime + gTimeStampCount * period;
    *outSeed = 1;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client,
                                  UInt32 op, Boolean* outWillDo, Boolean* outWillDoInPlace)
{
    (void)d; (void)client;
    if (id != kObjectID_Device) return kAudioHardwareBadObjectError;
    Boolean will = (op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix);
    *outWillDo = will;
    *outWillDoInPlace = true;
    return 0;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 op,
                                 UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle)
{ (void)d; (void)id; (void)client; (void)op; (void)frames; (void)cycle; return 0; }

static OSStatus EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 op,
                               UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle)
{ (void)d; (void)id; (void)client; (void)op; (void)frames; (void)cycle; return 0; }

static OSStatus DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, AudioObjectID stream, UInt32 client,
                              UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle,
                              void* ioMainBuffer, void* ioSecondaryBuffer)
{
    (void)d; (void)client; (void)stream; (void)ioSecondaryBuffer;
    if (id != kObjectID_Device) return kAudioHardwareBadObjectError;

    if (op == kAudioServerPlugInIOOperationWriteMix) {
        Float64 at = cycle->mOutputTime.mSampleTime;
        Float64 written = atomic_load_explicit(&gWrittenTo, memory_order_relaxed);
        // A writer that resumes after a pause leaves a gap of stale frames behind it. Clear it,
        // so no reader is ever handed audio from minutes ago.
        if (at > written) RingZero(written, (UInt32)(at - written));
        RingWrite(at, frames, (const Float32*)ioMainBuffer);
        atomic_store_explicit(&gWrittenTo, at + frames, memory_order_release);
        return 0;
    }

    if (op == kAudioServerPlugInIOOperationReadInput) {
        Float64 at = cycle->mInputTime.mSampleTime;
        Float64 written = atomic_load_explicit(&gWrittenTo, memory_order_acquire);
        SInt64 ahead = (SInt64)(written - at);              // frames of real audio from `at` on
        if (ahead > (SInt64)frames) ahead = frames;
        if (at + frames < written - kRing_Frames) ahead = 0;   // asked for frames long overwritten
        if (ahead < 0) ahead = 0;
        if (ahead > 0) RingRead(at, (UInt32)ahead, (Float32*)ioMainBuffer);
        if ((UInt32)ahead < frames)
            memset((Float32*)ioMainBuffer + (size_t)ahead * kChannels, 0,
                   (size_t)(frames - (UInt32)ahead) * kBytesPerFrame);
        return 0;
    }
    return 0;
}

// ---------------------------------------------------------------- plug-in boilerplate

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    QueryInterface,
    AddRef,
    Release,
    Initialize,
    CreateDevice,
    DestroyDevice,
    AddDeviceClient,
    RemoveDeviceClient,
    PerformDeviceConfigurationChange,
    AbortDeviceConfigurationChange,
    Driver_HasProperty,
    Driver_IsPropertySettable,
    Driver_GetPropertyDataSize,
    Driver_GetPropertyData,
    Driver_SetPropertyData,
    StartIO,
    StopIO,
    GetZeroTimeStamp,
    WillDoIOOperation,
    BeginIOOperation,
    DoIOOperation,
    EndIOOperation,
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

static HRESULT QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    CFUUIDRef uuid = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    Boolean ours = CFEqual(uuid, IUnknownUUID) || CFEqual(uuid, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(uuid);
    if (!ours) return E_NOINTERFACE;
    pthread_mutex_lock(&gStateMutex);
    gRefCount++;
    pthread_mutex_unlock(&gStateMutex);
    *outInterface = gDriverRef;
    return 0;
}

static ULONG AddRef(void* inDriver)
{
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    ULONG n = ++gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return n;
}

static ULONG Release(void* inDriver)
{
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    ULONG n = gRefCount > 0 ? --gRefCount : 0;
    pthread_mutex_unlock(&gStateMutex);
    return n;
}

void* micboostLoopbackCreate(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
void* micboostLoopbackCreate(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
    (void)inAllocator;
    return CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID) ? gDriverRef : NULL;
}

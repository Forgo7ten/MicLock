import CoreAudio

/// The three HAL calls used by the provider, injectable for buffer/ownership tests.
/// No cache, queue or extra lifecycle: production forwards directly to CoreAudio.
struct CoreAudioPropertyAccess {
    var getSize: (AudioObjectID, UnsafePointer<AudioObjectPropertyAddress>, UInt32,
                  UnsafeRawPointer?, UnsafeMutablePointer<UInt32>) -> OSStatus
    var getData: (AudioObjectID, UnsafePointer<AudioObjectPropertyAddress>, UInt32,
                  UnsafeRawPointer?, UnsafeMutablePointer<UInt32>, UnsafeMutableRawPointer) -> OSStatus
    var setData: (AudioObjectID, UnsafePointer<AudioObjectPropertyAddress>, UInt32,
                  UnsafeRawPointer?, UInt32, UnsafeRawPointer) -> OSStatus

    static var live: Self {
        Self(getSize: AudioObjectGetPropertyDataSize,
             getData: AudioObjectGetPropertyData,
             setData: AudioObjectSetPropertyData)
    }
}

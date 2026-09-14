import Foundation
import CoreAudio

/// Exercises the production provider with fake C property functions, not the
/// higher-level FakeAudioDeviceProvider used by policy tests.
private final class PropertyFixture {
    var ids: [AudioDeviceID] = [10]
    var advertisedListSize: UInt32 = 4
    var returnedListSize: UInt32?
    var uid: String? = "test-device-10"
    var uidStatus: OSStatus = noErr
    var uidSize = UInt32(MemoryLayout<CFTypeRef?>.size)
    var translatedID: AudioDeviceID = 10
    var translationStatus: OSStatus = noErr
    var setterStatus: OSStatus = noErr
    var currentSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    var currentID: AudioDeviceID = 10
    var transportType: UInt32 = kAudioDeviceTransportTypeBuiltIn
    var transportStatus: OSStatus = noErr
    var transportSize = UInt32(MemoryLayout<UInt32>.size)
    var queriedObjects: [AudioObjectID] = []
    var requestedUIDs: [String] = []
    var writtenIDs: [AudioDeviceID] = []
    var enumerationCount = 0

    var access: CoreAudioPropertyAccess {
        .init(getSize: { [self] object, address, _, _, size in
            queriedObjects.append(object)
            switch address.pointee.mSelector {
            case kAudioHardwarePropertyDevices:
                enumerationCount += 1
                size.pointee = advertisedListSize
            case kAudioDevicePropertyStreams:
                size.pointee = UInt32(MemoryLayout<AudioStreamID>.size)
            default: return -20
            }
            return noErr
        }, getData: { [self] object, address, qualifierSize, qualifier, size, data in
            queriedObjects.append(object)
            switch address.pointee.mSelector {
            case kAudioHardwarePropertyDevices:
                let capacity = Int(size.pointee) / MemoryLayout<AudioDeviceID>.size
                let destination = data.assumingMemoryBound(to: AudioDeviceID.self)
                for (index, id) in ids.prefix(capacity).enumerated() { destination[index] = id }
                size.pointee = returnedListSize ?? UInt32(ids.count * MemoryLayout<AudioDeviceID>.size)
            case kAudioHardwarePropertyDefaultInputDevice:
                data.assumingMemoryBound(to: AudioDeviceID.self).pointee = currentID
                size.pointee = currentSize
            case kAudioDevicePropertyDeviceUID:
                guard uidStatus == noErr else { return uidStatus }
                let destination = data.assumingMemoryBound(to: Unmanaged<CFString>?.self)
                destination.pointee = uid.map { Unmanaged.passRetained($0 as CFString) }
                size.pointee = uidSize
            case kAudioObjectPropertyName:
                data.assumingMemoryBound(to: Unmanaged<CFString>?.self).pointee =
                    .passRetained("Test Microphone" as CFString)
                size.pointee = UInt32(MemoryLayout<CFTypeRef?>.size)
            case kAudioDevicePropertyTransportType:
                guard transportStatus == noErr else { return transportStatus }
                data.assumingMemoryBound(to: UInt32.self).pointee = transportType
                size.pointee = transportSize
            case kAudioHardwarePropertyTranslateUIDToDevice:
                guard qualifierSize == UInt32(MemoryLayout<CFString>.size), let qualifier else { return -21 }
                requestedUIDs.append(qualifier.assumingMemoryBound(to: CFString.self).pointee as String)
                guard translationStatus == noErr else { return translationStatus }
                data.assumingMemoryBound(to: AudioDeviceID.self).pointee = translatedID
                size.pointee = UInt32(MemoryLayout<AudioDeviceID>.size)
            default: return -22
            }
            return noErr
        }, setData: { [self] _, address, _, _, size, data in
            guard address.pointee.mSelector == kAudioHardwarePropertyDefaultInputDevice,
                  size == UInt32(MemoryLayout<AudioDeviceID>.size) else { return -23 }
            writtenIDs.append(data.assumingMemoryBound(to: AudioDeviceID.self).pointee)
            return setterStatus
        })
    }
}

@MainActor
func runLiveAudioDeviceProviderTests() {
    test("provider: return actual device count after a shrinking HAL read")
    let shrinking = PropertyFixture()
    shrinking.advertisedListSize = 12
    let provider = LiveAudioDeviceProvider(access: shrinking.access)
    do {
        let snapshot = try provider.listInputDevices()
        expect(snapshot.devices.count == 1, "unused zero tail is not a device")
        expect(snapshot.isComplete, "a complete shorter list is not partial")
        expect(!shrinking.queriedObjects.contains(0), "never query phantom object zero")
    } catch { expect(false, "valid shrinking list must succeed: \(error)") }

    for (allocated, returned) in [(UInt32(5), UInt32(4)), (4, 3), (4, 8)] {
        test("provider: malformed list size is an explicit data error")
        let fixture = PropertyFixture()
        fixture.advertisedListSize = allocated
        fixture.returnedListSize = returned
        do {
            _ = try LiveAudioDeviceProvider(access: fixture.access).listInputDevices()
            expect(false, "malformed list size must not be accepted")
        } catch let error as AudioDeviceProviderError {
            if case .invalidPropertyData = error { expect(true, "invalid data is not OSStatus=0") }
            else { expect(false, "wrong error for malformed size: \(error)") }
        } catch { expect(false, "unexpected error: \(error)") }
    }

    for uid: String? in [nil, ""] {
        test("provider: noErr with null or empty UID is malformed data")
        let fixture = PropertyFixture(); fixture.uid = uid
        let instance = LiveAudioDeviceProvider(access: fixture.access)
        do {
            _ = try instance.currentInputDevice()
            expect(false, "missing UID must not become a usable device")
        } catch let error as AudioDeviceProviderError {
            if case .invalidPropertyData(.queryDeviceUID, _, _) = error {
                expect(true, "UID failure is classified without fabricating an OSStatus")
            } else { expect(false, "wrong UID error: \(error)") }
        } catch { expect(false, "unexpected UID error") }
        do {
            let snapshot = try instance.listInputDevices()
            expect(snapshot.devices.isEmpty && !snapshot.isComplete, "invalid UID yields a partial snapshot, not a fake healthy device")
        } catch { expect(false, "per-device failure should not discard the entire snapshot") }
    }

    test("provider: retain real HAL status and reject malformed scalar sizes")
    let failure = PropertyFixture(); failure.uidStatus = -77
    do {
        _ = try LiveAudioDeviceProvider(access: failure.access).currentInputDevice()
        expect(false, "real property failure must throw")
    } catch let error as AudioDeviceProviderError {
        if case .coreAudio(.queryDeviceUID, _, -77) = error { expect(true, "real error status preserved") }
        else { expect(false, "real error must not become malformed-data error") }
    } catch { expect(false, "unexpected error") }
    for malformedUID in [false, true] {
        let fixture = PropertyFixture()
        if malformedUID { fixture.uidSize = 0 } else { fixture.currentSize = 0 }
        do {
            _ = try LiveAudioDeviceProvider(access: fixture.access).currentInputDevice()
            expect(false, "wrong scalar/string result size must fail")
        } catch { expect(true, "malformed result rejected") }
    }

    test("provider: transport failure makes topology partial")
    let transportFailure = PropertyFixture(); transportFailure.transportStatus = -78
    do {
        let snapshot = try LiveAudioDeviceProvider(access: transportFailure.access).listInputDevices()
        expect(snapshot.devices.isEmpty, "device with unreadable transport is not classified as healthy")
        expect(snapshot.incompleteDeviceIDs == [10], "transport failure records the incomplete device")
        expect(!snapshot.isComplete, "transport failure must make topology partial")
        if let issue = snapshot.issues.first,
           case .coreAudio(.queryTransportType, let objectID, -78) = issue {
            expect(objectID == 10, "transport OSStatus retains the failing object")
        } else {
            expect(false, "transport OSStatus must be preserved as queryTransportType")
        }
    } catch {
        expect(false, "per-device transport failure should return a partial snapshot: \(error)")
    }

    for malformedSize: UInt32 in [0, 8] {
        test("provider: malformed transport size makes topology partial")
        let fixture = PropertyFixture(); fixture.transportSize = malformedSize
        do {
            let snapshot = try LiveAudioDeviceProvider(access: fixture.access).listInputDevices()
            expect(snapshot.devices.isEmpty, "malformed transport must not fabricate a healthy device")
            expect(snapshot.incompleteDeviceIDs == [10], "malformed transport records the incomplete device")
            expect(!snapshot.isComplete, "malformed transport must make topology partial")
            if let issue = snapshot.issues.first,
               case .invalidPropertyData(.queryTransportType, _, _) = issue {
                expect(true, "malformed transport is classified as invalid property data")
            } else {
                expect(false, "wrong error for malformed transport size")
            }
        } catch {
            expect(false, "malformed per-device transport should return a partial snapshot: \(error)")
        }
    }

    test("provider: UID lookup is direct, fresh, and independent of broken neighbours")
    let translation = PropertyFixture()
    translation.advertisedListSize = 3 // Unusable if enumeration were attempted.
    let setter = LiveAudioDeviceProvider(access: translation.access)
    do {
        try setter.setInputDevice(uid: "chosen")
        translation.translatedID = 42
        try setter.setInputDevice(uid: "chosen")
        expect(translation.writtenIDs == [10, 42], "each write resolves the current AudioDeviceID")
        expect(translation.requestedUIDs == ["chosen", "chosen"], "UID qualifier is passed correctly")
        expect(translation.enumerationCount == 0, "unrelated devices are never enumerated during lookup")
    } catch { expect(false, "direct translation should succeed: \(error)") }
    translation.translatedID = kAudioObjectUnknown
    do { try setter.setInputDevice(uid: "missing"); expect(false, "unknown ID must fail") }
    catch let error as AudioDeviceProviderError {
        if case .targetDeviceNotFound(uid: "missing") = error { expect(true, "unknown sentinel means not found") }
        else { expect(false, "wrong lookup error") }
    } catch { expect(false, "unexpected lookup error") }
    expect(translation.writtenIDs.count == 2, "missing target never submits a write")
    do { try setter.setInputDevice(uid: ""); expect(false, "empty requested UID must fail") }
    catch { expect(true, "empty UID rejected before lookup") }
    expect(translation.requestedUIDs.count == 3, "empty UID did not reach HAL")
    translation.translatedID = 10
    translation.setterStatus = -88
    do { try setter.setInputDevice(uid: "chosen"); expect(false, "rejected setter must throw") }
    catch let error as AudioDeviceProviderError {
        if case .coreAudio(.setDefaultInputDevice, _, -88) = error { expect(true, "setter OSStatus preserved") }
        else { expect(false, "wrong setter failure") }
    } catch { expect(false, "unexpected setter error") }
}

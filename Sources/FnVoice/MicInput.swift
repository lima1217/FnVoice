import AVFoundation
import CoreAudio
import ObjCTry

/// The mic engine behind both capture paths. Every AVAudioEngine call runs on a private serial
/// queue, never the main thread, and opening the mic is bounded by `openTimeout`. After AirPods
/// reconnected (device IDs renumbered), `inputNode` on a fresh engine spun inside CoreAudio's
/// `GetHWFormat` for minutes; on the main thread that froze the whole app. Now that press fails
/// with `CaptureError.micTimeout`, the stuck queue is abandoned with its engine, and the next
/// press starts on a new pair.
@MainActor final class MicInput {
    /// Cold first `inputNode` access in a process is 1.9–2.4 s (see `warmUpAudioInput`), warm
    /// under 60 ms.
    static let openTimeout: Duration = .seconds(5)

    /// The input device or its format changed while the mic was open (AirPods → HFP).
    var onConfigurationChange: (() -> Void)?

    private var mic = Mic()
    private var listening = false

    /// Opens the mic and streams its buffers to `tap`; returns the hardware format.
    func start(tap: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws -> AVAudioFormat {
        listenForDefaultInputChanges()
        let mic = self.mic
        let onChange = configurationCallback()
        let once = OnceFlag()
        do {
            return try await withCheckedThrowingContinuation { cont in
                mic.queue.async {
                    let result = Result { try mic.open(fresh: false, tap: tap, onChange: onChange) }
                    if once.claim() {
                        cont.resume(with: result)
                    } else if case .success = result {
                        mic.close() // gave up on it already; nobody else would close it
                    }
                }
                Task {
                    try? await Task.sleep(for: Self.openTimeout)
                    if once.claim() { cont.resume(throwing: CaptureError.micTimeout) }
                }
            }
        } catch CaptureError.micTimeout {
            Log.audio.error("mic did not open within \(Self.openTimeout, privacy: .public); abandoning that engine")
            if self.mic === mic { self.mic = Mic() }
            throw CaptureError.micTimeout
        }
    }

    /// Reopens on a fresh engine after a configuration change, keeping the same tap. Enqueued
    /// right away, so it stays ordered with `stop()` and the next `start`.
    func restart(tap: @escaping @Sendable (AVAudioPCMBuffer) -> Void, onFailure: @escaping @Sendable @MainActor (Error) -> Void) {
        let mic = self.mic
        let onChange = configurationCallback()
        mic.queue.async {
            do {
                _ = try mic.open(fresh: true, tap: tap, onChange: onChange)
            } catch {
                Log.audio.error("rebuild failed: \(String(describing: error), privacy: .public)")
                Task { @MainActor in onFailure(error) }
            }
        }
    }

    func stop() {
        let mic = self.mic
        mic.queue.async { mic.close() }
    }

    private func configurationCallback() -> @Sendable () -> Void {
        { [weak self] in MainActor.assumeIsolated { self?.onConfigurationChange?() } }
    }

    /// The engine notices device changes only while running. One switched while idle leaves it
    /// with a stale format (the tap is then refused), so drop it and open a fresh one next time.
    private func listenForDefaultInputChanges() {
        guard !listening else { return }
        listening = true
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let mic = self?.mic else { return }
                Log.audio.info("default input device changed")
                mic.queue.async { mic.dropIfIdle() }
            }
        }
        if status != noErr { Log.audio.error("default input listener not installed: \(status)") }
    }
}

/// AVAudioEngine state, touched only on `queue`.
private final class Mic: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.local.fnvoice.mic", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?

    private struct TapRefused: Error { let message: String }

    func open(fresh: Bool, tap: @escaping @Sendable (AVAudioPCMBuffer) -> Void, onChange: @escaping @Sendable () -> Void) throws -> AVAudioFormat {
        if fresh { discard() }
        do {
            return try attach(tap: tap, onChange: onChange)
        } catch let refused as TapRefused {
            // A format change on the same device (AirPods 48k ↔ HFP 24k) isn't a default-device
            // change, so the idle listener misses it; a fresh engine reads the current format.
            Log.audio.notice("tap refused (\(refused.message, privacy: .public)); retrying on a fresh engine")
            discard()
            do {
                return try attach(tap: tap, onChange: onChange)
            } catch let again as TapRefused {
                throw CaptureError.engine(again.message)
            }
        }
    }

    func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let engine else { return }
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    func dropIfIdle() {
        guard engine?.isRunning != true else { return } // a running engine reports the change itself
        engine = nil
    }

    private func discard() {
        close()
        engine = nil
    }

    private func attach(tap: @escaping @Sendable (AVAudioPCMBuffer) -> Void, onChange: @escaping @Sendable () -> Void) throws -> AVAudioFormat {
        let engine = self.engine ?? AVAudioEngine()
        self.engine = engine
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInputDevice }
        // AVFAudio raises an Objective-C exception (not a Swift error) when `format` no longer
        // matches the hardware; caught here so it never unwinds through Swift frames.
        var error: NSError?
        let ok = FNTryObjC({
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in tap(buffer) }
        }, &error)
        if !ok { throw TapRefused(message: error?.localizedDescription ?? "installTap failed") }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            node.removeTap(onBus: 0)
            throw CaptureError.engine(error.localizedDescription)
        }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { _ in onChange() }
        return format
    }
}

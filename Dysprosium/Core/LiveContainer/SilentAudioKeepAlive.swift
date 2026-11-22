import AVFoundation
import Foundation
import UIKit

/// Maintains full-speed background thread execution inside LiveContainer by driving
/// a zero-amplitude mono PCM buffer ONLY while backgrounding/backgrounded with active work.
/// Pre-arms on `willResignActive` so iOS grants background audio before entering background
/// (avoiding `!pla` start rejection), tears down `AVAudioEngine` immediately on foreground
/// or queue idle, and keeps `.playback` + `.mixWithOthers` clean without interrupting
/// foreground or PiP web video playback.
@MainActor
public final class SilentAudioKeepAlive {
    public static let shared = SilentAudioKeepAlive()

    private static let sampleRate: Double = 8_000
    private static let bufferDuration: Double = 2.0

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var notificationTokens: [NSObjectProtocol] = []
    private var lifecycleTokens: [NSObjectProtocol] = []
    private var isRequiredByTransfers: Bool = false
    private var isBackgroundOrResigning: Bool = false

    public private(set) var isActive: Bool = false

    private init() {
        isBackgroundOrResigning = UIApplication.shared.applicationState != .active
        let nc = NotificationCenter.default
        lifecycleTokens.append(
            nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Pre-arm while still holding foreground audio activation privileges so iOS
                    // does not reject audio start with `!pla` once `didEnterBackground` fires.
                    self.isBackgroundOrResigning = true
                    self.reconcileState()
                }
            }
        )
        lifecycleTokens.append(
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isBackgroundOrResigning = true
                    self.reconcileState()
                }
            }
        )
        lifecycleTokens.append(
            nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isBackgroundOrResigning = false
                    self.reconcileState()
                }
            }
        )
        lifecycleTokens.append(
            nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isBackgroundOrResigning = false
                    self.reconcileState()
                }
            }
        )
    }

    public func setRequired(_ required: Bool) {
        isRequiredByTransfers = required
        reconcileState()
    }

    private var shouldRunNow: Bool {
        isRequiredByTransfers && isBackgroundOrResigning && LiveContainerEnvironment.isRunningInLiveContainer
    }

    private func reconcileState() {
        // Only run silent audio DSP while resigning/backgrounded inside LiveContainer with active transfers.
        if shouldRunNow {
            startIfNeeded()
        } else {
            stop()
        }
    }

    @discardableResult
    public func startIfNeeded() -> Bool {
        if isActive {
            if engine?.isRunning == true {
                return true
            }
            // Recover from a wedged or halted engine state.
            removeInterruptionObservers()
            tearDownAudioGraph()
            isActive = false
        }
        do {
            try startAudioGraph()
            installInterruptionObservers()
            isActive = true
            return true
        } catch {
            removeInterruptionObservers()
            tearDownAudioGraph()
            isActive = false
            return false
        }
    }

    public func stop() {
        guard isActive || engine != nil || !notificationTokens.isEmpty else { return }
        isActive = false
        removeInterruptionObservers()
        tearDownAudioGraph()
        // Intentionally do NOT call `AVAudioSession.sharedInstance().setActive(false)` here:
        // deactivating the shared process audio session interrupts foreground and PiP WebKit
        // video audio. Tearing down `AVAudioEngine` releases our IOProc while keeping
        // `.playback` + `.mixWithOthers` clean.
    }

    private func startAudioGraph() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setPreferredIOBufferDuration(0.5)
        try session.setActive(true)

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1),
              let silentBuffer = Self.makeSilentBuffer(format: format) else {
            throw CocoaError(.featureUnsupported)
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        player.scheduleBuffer(silentBuffer, at: nil, options: [.loops])
        player.play()

        self.engine = engine
        self.playerNode = player
    }

    private func tearDownAudioGraph() {
        playerNode?.stop()
        engine?.stop()
        engine?.reset()
        playerNode = nil
        engine = nil
    }

    private func restartAfterSystemEvent() {
        guard isActive else { return }
        guard shouldRunNow else {
            stop()
            return
        }
        tearDownAudioGraph()
        do {
            try startAudioGraph()
        } catch {
            removeInterruptionObservers()
            tearDownAudioGraph()
            isActive = false
        }
    }

    private static func makeSilentBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(sampleRate * bufferDuration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData else {
            return nil
        }
        buffer.frameLength = frames
        for index in 0..<Int(format.channelCount) {
            channels[index].update(repeating: 0, count: Int(frames))
        }
        return buffer
    }

    private func installInterruptionObservers() {
        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard raw.flatMap(AVAudioSession.InterruptionType.init) == .ended else { return }
                MainActor.assumeIsolated {
                    self?.restartAfterSystemEvent()
                }
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.restartAfterSystemEvent()
                }
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.restartAfterSystemEvent()
                }
            }
        )
    }

    private func removeInterruptionObservers() {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
    }
}

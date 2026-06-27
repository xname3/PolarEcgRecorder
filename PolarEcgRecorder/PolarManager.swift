import Foundation
import Combine
import CoreBluetooth
import PolarBleSdk
import UserNotifications
import ActivityKit
import UIKit

class PolarManager: ObservableObject {
    static let shared = PolarManager()

    private var api = PolarBleApiDefaultImpl.polarImplementation(
        DispatchQueue.main,
        features: [
            PolarBleSdkFeature.feature_hr,
            PolarBleSdkFeature.feature_battery_info,
            PolarBleSdkFeature.feature_polar_offline_recording,
            PolarBleSdkFeature.feature_polar_online_streaming
        ]
    )

    @Published var deviceId: String = ""
    @Published var isConnected: Bool = false
    @Published var isStreaming: Bool = false
    @Published var isEventRecording: Bool = false
    @Published var currentHR: UInt8 = 0
    @Published var batteryLevel: UInt = 0
    // NEW
    @Published var currentRMSSD: Double = 0.0
    @Published var lastRRInterval: Int = 0

    private var filterBaseline: Double = 0.0
    private var filterSmoothed: Double = 0.0

    // Rolling 1-minute buffers
    private var ecgRolling: [(date: Date, ts: UInt64, val: Int32)] = []
    private var hrRolling:  [(date: Date, ts: UInt64, bpm: UInt8)] = []
    private var rrRolling:  [Int] = []         // NEW: last ~300 RR intervals (~5 min)

    private var eventRecordTask: Task<Void, Never>? = nil
    let ecgDataPublisher = PassthroughSubject<Int32, Never>()
    private var hrTask:  Task<Void, Never>?
    private var ecgTask: Task<Void, Never>?

    private var activeActivity: Activity<EcgActivityAttributes>? = nil

    private init() {
        api.observer = self
        setupDarwinObserver()
    }

    // MARK: - ECG filter (baseline wander + smoothing)
    private func filterEcgSample(_ raw: Int32) -> Int32 {
        let v = Double(raw)
        filterBaseline = 0.98 * filterBaseline + 0.02 * v
        filterSmoothed = 0.35 * (v - filterBaseline) + 0.65 * filterSmoothed
        return Int32(filterSmoothed)
    }

    // MARK: - HRV
    func calculateRMSSD(_ rr: [Int]) -> Double {
        guard rr.count > 1 else { return 0 }
        let sumSq = zip(rr, rr.dropFirst()).reduce(0.0) { acc, pair in
            let d = Double(pair.1 - pair.0); return acc + d * d
        }
        return sqrt(sumSq / Double(rr.count - 1))
    }

    // MARK: - Connection
    func autoConnect() {
        Task { @MainActor in
            if let savedId = UserDefaults.standard.string(forKey: "LastPolarDeviceID") {
                do { try api.connectToDevice(savedId) }
                catch { print("❌ connectToDevice: \(error)") }
            }
            do { try await api.startAutoConnectToDevice(-85, service: nil, polarDeviceType: "H10") }
            catch { print("❌ autoConnect: \(error)") }
        }
    }

    func disconnect() {
        guard !deviceId.isEmpty else { return }
        do {
            try api.disconnectFromDevice(deviceId)
            stopStreaming(); stopEventRecordingWindow(); stopAllStreams()
        } catch { print("disconnect error: \(error)") }
    }

    // MARK: - Streams
    private func startAllStreams() {
        stopAllStreams()

        // ── HR + RR ──────────────────────────────────────────────────────────
        hrTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                guard self.isConnected else { return }

                let stream = api.startHrStreaming(deviceId)
                for try await hrData in stream {
                    for sample in hrData {
                        let hr = sample.hr
                        let rrs = sample.rrsMs          // ← RR intervals from Polar SDK

                        self.currentHR = hr
                        self.updateLiveActivity()

                        if !rrs.isEmpty {
                            self.lastRRInterval = rrs.last ?? 0
                            self.rrRolling.append(contentsOf: rrs)
                            if self.rrRolling.count > 300 {
                                self.rrRolling = Array(self.rrRolling.suffix(300))
                            }
                            if self.rrRolling.count >= 5 {
                                self.currentRMSSD = self.calculateRMSSD(self.rrRolling)
                            }
                        }

                        let now = Date()
                        let ts  = UInt64(now.timeIntervalSince1970 * 1000)

                        self.hrRolling.append((now, ts, hr))
                        self.hrRolling.removeAll { now.timeIntervalSince($0.date) > 60 }

                        if self.isStreaming || self.isEventRecording {
                            StorageManager.shared.appendHR(timestamp: ts, bpm: hr)
                            if !rrs.isEmpty {
                                StorageManager.shared.appendRR(
                                    timestamp: ts,
                                    rrIntervals: rrs,
                                    rmssd: self.currentRMSSD
                                )
                            }
                        }
                    }
                }
            } catch { print("❌ HR stream: \(error)") }
        }

        // ── ECG ──────────────────────────────────────────────────────────────
        ecgTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 2_500_000_000)
                guard self.isConnected else { return }

                let settings = try await api.requestStreamSettings(deviceId, feature: .ecg)
                let stream   = api.startEcgStreaming(deviceId, settings: settings.maxSettings())

                for try await ecgData in stream {
                    let now = Date()
                    let baseTimestampMs = UInt64(now.timeIntervalSince1970 * 1000)
                    let sampleIntervalMs: Double = 1000.0 / 130.0
                    let totalSamples = ecgData.count

                    for (index, sample) in ecgData.enumerated() {
                        let offsetMs = Double(totalSamples - 1 - index) * sampleIntervalMs
                        let sampleTs = baseTimestampMs - UInt64(offsetMs)
                        let v   = self.filterEcgSample(sample.voltage)

                        self.ecgRolling.append((now, sampleTs, v))
                        self.ecgRolling.removeAll { now.timeIntervalSince($0.date) > 60 }

                        self.ecgDataPublisher.send(v)

                        if self.isStreaming || self.isEventRecording {
                            StorageManager.shared.appendECG(timestamp: sampleTs, microVolts: v)
                        }
                    }
                }
            } catch { print("❌ ECG stream: \(error)") }
        }
    }

    private func stopAllStreams() {
        hrTask?.cancel();  ecgTask?.cancel()
        hrTask = nil;      ecgTask = nil
        ecgRolling.removeAll(); hrRolling.removeAll(); rrRolling.removeAll()
        currentRMSSD = 0;  lastRRInterval = 0
    }

    // MARK: - Darwin Notification Observer
    private func setupDarwinObserver() {
        let notificationName = "com.ecgpolar.mark_event" as CFString
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        CFNotificationCenterAddObserver(
            center,
            observer,
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let mySelf = Unmanaged<PolarManager>.fromOpaque(observer).takeUnretainedValue()
                mySelf.handleDarwinEvent()
            },
            notificationName,
            nil,
            .deliverImmediately
        )
    }

    private func handleDarwinEvent() {
        DispatchQueue.main.async {
            if self.isConnected {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                StorageManager.shared.markEvent()
                if !self.isStreaming {
                    self.startEventRecordingWindow()
                }
            }
        }
    }

    // MARK: - Live Activity helpers
    private func startLiveActivity() {
        guard activeActivity == nil else { return }
        let attributes = EcgActivityAttributes(sessionName: "Polar ECG")
        let state = EcgActivityAttributes.ContentState(
            isEventRecording: isEventRecording,
            currentHR: Int(currentHR)
        )
        do {
            activeActivity = try Activity<EcgActivityAttributes>.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            print("🟢 Started Live Activity: \(activeActivity?.id ?? "")")
        } catch {
            print("❌ Failed to start Live Activity: \(error)")
        }
    }
    
    private func updateLiveActivity() {
        guard let activity = activeActivity else { return }
        let state = EcgActivityAttributes.ContentState(
            isEventRecording: isEventRecording,
            currentHR: Int(currentHR)
        )
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }
    
    private func stopLiveActivity() {
        guard let activity = activeActivity else { return }
        let state = EcgActivityAttributes.ContentState(
            isEventRecording: false,
            currentHR: 0
        )
        Task {
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
            await MainActor.run {
                self.activeActivity = nil
            }
        }
    }

    // MARK: - Session control
    // NOTE: startStreaming / stopStreaming do NOT call StorageManager —
    //       DashboardView.startSession() owns that to avoid double-start.
    func startStreaming() {
        guard isConnected, !deviceId.isEmpty, !isStreaming, !isEventRecording else { return }
        isStreaming = true
        startLiveActivity()
    }

    func stopStreaming() {
        guard isStreaming else { return }
        isStreaming = false
        if !isEventRecording {
            stopLiveActivity()
        }
    }

    @MainActor
    func startEventRecordingWindow() {
        guard isConnected, !deviceId.isEmpty, !isStreaming, !isEventRecording else { return }
        isEventRecording = true
        startLiveActivity()
        updateLiveActivity()
        StorageManager.shared.startNewSession()

        // Flush rolling buffers (past 30 s)
        for item in ecgRolling { StorageManager.shared.appendECG(timestamp: item.ts, microVolts: item.val) }
        for item in hrRolling  { StorageManager.shared.appendHR (timestamp: item.ts, bpm: item.bpm) }
        if !rrRolling.isEmpty  {
            let ts = UInt64(Date().timeIntervalSince1970 * 1000)
            StorageManager.shared.appendRR(timestamp: ts, rrIntervals: rrRolling, rmssd: currentRMSSD)
        }

        eventRecordTask?.cancel()
        eventRecordTask = Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000) // +15 seconds
            await MainActor.run { self.stopEventRecordingWindow() }
        }
    }

    @MainActor
    func stopEventRecordingWindow() {
        guard isEventRecording else { return }
        isEventRecording = false
        eventRecordTask?.cancel(); eventRecordTask = nil
        StorageManager.shared.stopSession()
        updateLiveActivity()
        if !isStreaming {
            stopLiveActivity()
        }
    }
}

// MARK: - Polar SDK delegates
extension PolarManager: PolarBleApiObserver {
    func deviceConnecting(_ i: PolarDeviceInfo) {}
    func deviceConnected(_ i: PolarDeviceInfo) {
        DispatchQueue.main.async {
            self.deviceId    = i.deviceId
            UserDefaults.standard.set(i.deviceId, forKey: "LastPolarDeviceID")
            self.isConnected = true
            self.startAllStreams()
        }
    }
    func deviceDisconnected(_ i: PolarDeviceInfo, pairingError: Bool) {
        DispatchQueue.main.async {
            self.isConnected = false; self.isStreaming = false; self.isEventRecording = false
            self.stopAllStreams(); self.currentHR = 0; self.batteryLevel = 0
            self.stopLiveActivity()
        }
    }
    func batteryLevelReceived(_ id: String, batteryLevel: UInt) {
        DispatchQueue.main.async { self.batteryLevel = batteryLevel }
    }
    func disInformationReceived(_ id: String, uuid: UUID, value: String) {}
    func blePowerOn()  {}
    func blePowerOff() {}
    func polarityMessageReceived(_ id: String, isPolarityReversed: Bool) {}
}

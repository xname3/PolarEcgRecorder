import Foundation
import Combine
import CoreBluetooth
import PolarBleSdk

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

    private init() { api.observer = self }

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
                    for sample in ecgData {
                        let v   = self.filterEcgSample(sample.voltage)
                        let now = Date()

                        self.ecgRolling.append((now, sample.timeStamp, v))
                        self.ecgRolling.removeAll { now.timeIntervalSince($0.date) > 60 }

                        self.ecgDataPublisher.send(v)

                        if self.isStreaming || self.isEventRecording {
                            StorageManager.shared.appendECG(timestamp: sample.timeStamp, microVolts: v)
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

    // MARK: - Session control
    // NOTE: startStreaming / stopStreaming do NOT call StorageManager —
    //       DashboardView.startSession() owns that to avoid double-start.
    func startStreaming() {
        guard isConnected, !deviceId.isEmpty, !isStreaming, !isEventRecording else { return }
        isStreaming = true
    }

    func stopStreaming() {
        guard isStreaming else { return }
        isStreaming = false
    }

    @MainActor
    func startEventRecordingWindow() {
        guard isConnected, !deviceId.isEmpty, !isStreaming, !isEventRecording else { return }
        isEventRecording = true
        StorageManager.shared.startNewSession()

        // Flush rolling buffers (past 60 s)
        for item in ecgRolling { StorageManager.shared.appendECG(timestamp: item.ts, microVolts: item.val) }
        for item in hrRolling  { StorageManager.shared.appendHR (timestamp: item.ts, bpm: item.bpm) }
        if !rrRolling.isEmpty  {
            let ts = UInt64(Date().timeIntervalSince1970 * 1000)
            StorageManager.shared.appendRR(timestamp: ts, rrIntervals: rrRolling, rmssd: currentRMSSD)
        }

        eventRecordTask?.cancel()
        eventRecordTask = Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            await MainActor.run { self.stopEventRecordingWindow() }
        }
    }

    @MainActor
    func stopEventRecordingWindow() {
        guard isEventRecording else { return }
        isEventRecording = false
        eventRecordTask?.cancel(); eventRecordTask = nil
        StorageManager.shared.stopSession()
    }
}

// MARK: - Polar SDK delegates
extension PolarManager: PolarBleApiObserver {
    func deviceConnecting(_ i: PolarDeviceInfo) {}
    func deviceConnected(_ i: PolarDeviceInfo) {
        DispatchQueue.main.async {
            self.deviceId    = i.deviceId
            self.isConnected = true
            self.startAllStreams()
        }
    }
    func deviceDisconnected(_ i: PolarDeviceInfo, pairingError: Bool) {
        DispatchQueue.main.async {
            self.isConnected = false; self.isStreaming = false; self.isEventRecording = false
            self.stopAllStreams(); self.currentHR = 0; self.batteryLevel = 0
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

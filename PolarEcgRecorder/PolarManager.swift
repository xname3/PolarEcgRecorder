import Foundation
import Combine
import CoreBluetooth
import PolarBleSdk
import UserNotifications
import ActivityKit
import UIKit
import CoreML
import SwiftUI

class PolarManager: ObservableObject {
    static let shared = PolarManager()

    private var api = PolarBleApiDefaultImpl.polarImplementation(
        DispatchQueue(label: "com.ecgpolar.ble", qos: .background),
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
    @Published var isConnecting: Bool = false
    @Published var connectionFailed: Bool = false

    // MARK: - Real-time Extrasystole Detection
    @Published var rtExtrasystoleCount: Int = 0
    @AppStorage("realTimeExtrasystoleDetection") private var rtDetectionEnabled: Bool = false
    @AppStorage("beepOnExtrasystole") private var rtBeepEnabled: Bool = true
    @AppStorage("rtUseAIDetection") private var rtUseAIDetection: Bool = true
    private var morphologyModel: ECGMorphologyClassifier?
    private var rtThreshold: Double = 400.0
    private var rtLastPeakTimestamp: UInt64 = 0
    private var rtNormalRRs: [Double] = []
    private var rtEcgBuffer: [(timestamp: UInt64, value: Double)] = [] // Stores (timestamp, Butterworth-filtered value)
    
    // Butterworth filter coefficients & state
    private var btB0: Double = 0.0
    private var btB1: Double = 0.0
    private var btB2: Double = 0.0
    private var btA1: Double = 0.0
    private var btA2: Double = 0.0
    private var btW1: Double = 0.0
    private var btW2: Double = 0.0

    // Real-time peak detector state
    private var rtSearchIdx: Int = 0
    private var rtLockoutEndIndex: Int = 0
    private var rtSamplesProcessed: Int = 0

    private var filterBaseline: Double = 0.0
    private var filterSmoothed: Double = 0.0

    // Rolling 1-minute buffers
    private var ecgRolling: [(date: Date, ts: UInt64, val: Int32)] = []
    private var hrRolling:  [(date: Date, ts: UInt64, bpm: UInt8)] = []
    private var rrRolling:  [Int] = []         // NEW: last ~300 RR intervals (~5 min)

    private var eventRecordTask: Task<Void, Never>? = nil
    let ecgDataPublisher = PassthroughSubject<[Int32], Never>()
    private var hrTask:  Task<Void, Never>?
    private var ecgTask: Task<Void, Never>?

    private var activeActivity: Activity<EcgActivityAttributes>? = nil
    private var lastBufferTrim: Date = Date()

    private init() {
        api.observer = self
        setupDarwinObserver()
        do {
            morphologyModel = try ECGMorphologyClassifier(configuration: MLModelConfiguration())
        } catch {
            print("Failed to load ECGMorphologyClassifier: \(error)")
        }
        
        // Init Butterworth 0.67 Hz cutoff coefficients at 130 Hz sample rate
        let sampleRate: Double = 130.0
        let cutoff: Double = 0.67
        let omega = tan(Double.pi * cutoff / sampleRate)
        let omega2 = omega * omega
        let sqrt2 = sqrt(2.0)
        let denom = 1.0 + sqrt2 * omega + omega2
        
        self.btB0 =  1.0 / denom
        self.btB1 = -2.0 / denom
        self.btB2 =  1.0 / denom
        self.btA1 =  2.0 * (omega2 - 1.0) / denom
        self.btA2 =  (1.0 - sqrt2 * omega + omega2) / denom
    }
    
    private func applyRtHighPass(_ sample: Double) -> Double {
        let w0 = sample - btA1 * btW1 - btA2 * btW2
        let filtered = btB0 * w0 + btB1 * btW1 + btB2 * btW2
        btW2 = btW1
        btW1 = w0
        return filtered
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
        guard !isConnecting else { return }
        isConnecting = true
        connectionFailed = false
        
        Task { @MainActor in
            if let savedId = UserDefaults.standard.string(forKey: "LastPolarDeviceID") {
                do { try api.connectToDevice(savedId) }
                catch { print("❌ connectToDevice: \(error)") }
            }
            do { try await api.startAutoConnectToDevice(-85, service: nil, polarDeviceType: "H10") }
            catch { print("❌ autoConnect: \(error)") }
            
            // 10-second timeout
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if !self.isConnected {
                self.isConnecting = false
                self.connectionFailed = true
            }
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

                        DispatchQueue.main.async {
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
                        }

                        let now = Date()
                        let ts  = UInt64(now.timeIntervalSince1970 * 1000)

                        self.hrRolling.append((now, ts, hr))

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
                    // Trim rolling buffer once per HR packet
                    if Date().timeIntervalSince(self.lastBufferTrim) > 2.0 {
                        self.hrRolling.removeAll { Date().timeIntervalSince($0.date) > 60 }
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

                    var batchForStorage: [(UInt64, Int32)] = []
                    var batchForUI: [Int32] = []
                    batchForStorage.reserveCapacity(totalSamples)
                    batchForUI.reserveCapacity(totalSamples)

                    var newRolling: [(date: Date, ts: UInt64, val: Int32)] = []
                    newRolling.reserveCapacity(totalSamples)

                    for (index, sample) in ecgData.enumerated() {
                        let offsetMs = Double(totalSamples - 1 - index) * sampleIntervalMs
                        let sampleTs = baseTimestampMs - UInt64(offsetMs)
                        let v   = self.filterEcgSample(sample.voltage)

                        newRolling.append((now, sampleTs, v))
                        batchForUI.append(v)

                        if self.isStreaming || self.isEventRecording {
                            batchForStorage.append((sampleTs, v))
                        }

                        // --- Real-time Extrasystole Detection (Butterworth-filtered buffer) ---
                        if self.rtDetectionEnabled {
                            let v_bt = self.applyRtHighPass(Double(v))
                            self.rtEcgBuffer.append((sampleTs, v_bt))
                            self.rtSamplesProcessed += 1
                        }
                    }

                    if self.rtDetectionEnabled {
                        if self.rtSamplesProcessed > 500 {
                            while self.rtSearchIdx + 64 < self.rtEcgBuffer.count {
                                let val = self.rtEcgBuffer[self.rtSearchIdx].value
                                let timestamp = self.rtEcgBuffer[self.rtSearchIdx].timestamp
                                
                                if self.rtSearchIdx < self.rtLockoutEndIndex {
                                    self.rtSearchIdx += 1
                                    continue
                                }
                                
                                if val > self.rtThreshold {
                                    let endIdx = self.rtSearchIdx + 15
                                    var peakIdx = self.rtSearchIdx
                                    var peakVal = val
                                    for j in self.rtSearchIdx...endIdx {
                                        if self.rtEcgBuffer[j].value > peakVal {
                                            peakVal = self.rtEcgBuffer[j].value
                                            peakIdx = j
                                        }
                                    }
                                    
                                    if peakIdx + 64 >= self.rtEcgBuffer.count {
                                        break // Wait for more samples to complete the window
                                    }
                                    
                                    let detectedPeak = self.rtEcgBuffer[peakIdx]
                                    var currentRR: Double = 0
                                    if self.rtLastPeakTimestamp > 0 && detectedPeak.timestamp > self.rtLastPeakTimestamp {
                                        currentRR = Double(detectedPeak.timestamp - self.rtLastPeakTimestamp)
                                    }
                                    
                                    let windowStart = peakIdx - 65
                                    let windowEnd = peakIdx + 64
                                    if windowStart >= 0 {
                                        let window = self.rtEcgBuffer[windowStart...windowEnd].map { $0.value }
                                        if let maxVal = window.max(), let minVal = window.min(), (maxVal - minVal) >= 150.0 {
                                            let mean = window.reduce(0, +) / Double(window.count)
                                            let variance = window.map { pow($0 - mean, 2) }.reduce(0, +) / Double(window.count)
                                            let std = sqrt(variance)
                                            
                                            if std > 0 {
                                                let normalized = window.map { Float32(($0 - mean) / std) }
                                                let avgNormalRR = self.rtNormalRRs.isEmpty ? 0.0 : self.rtNormalRRs.reduce(0, +) / Double(self.rtNormalRRs.count)
                                                let isPrematureCandidate = self.rtNormalRRs.count >= 2 && currentRR > 0 && currentRR < avgNormalRR * 0.80
                                                let shouldRunML = (isPrematureCandidate || self.rtNormalRRs.count < 2) && currentRR > 0
                                                
                                                if self.rtUseAIDetection {
                                                    if shouldRunML, let model = self.morphologyModel {
                                                        do {
                                                            let mlArray = try MLMultiArray(shape: [1, 130, 1], dataType: .float32)
                                                            for (index, value) in normalized.enumerated() {
                                                                mlArray[index] = NSNumber(value: value)
                                                            }
                                                            let input = ECGMorphologyClassifierInput(signal: mlArray)
                                                            let prediction = try await model.prediction(input: input)
                                                            
                                                            if prediction.classLabel == "V" || prediction.classLabel == "A" {
                                                                self.rtExtrasystoleCount += 1
                                                                if self.rtBeepEnabled {
                                                                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                                                                }
                                                            } else if prediction.classLabel == "N" {
                                                                self.rtNormalRRs.append(currentRR)
                                                                if self.rtNormalRRs.count > 4 { self.rtNormalRRs.removeFirst() }
                                                            }
                                                        } catch {
                                                            print("Real-time CoreML prediction error: \(error)")
                                                        }
                                                    } else if currentRR > 0 {
                                                        self.rtNormalRRs.append(currentRR)
                                                        if self.rtNormalRRs.count > 4 { self.rtNormalRRs.removeFirst() }
                                                    }
                                                } else {
                                                    // Heuristics only (RR Interval Deviation)
                                                    if isPrematureCandidate {
                                                        self.rtExtrasystoleCount += 1
                                                        if self.rtBeepEnabled {
                                                            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                                                        }
                                                    } else if currentRR > 0 {
                                                        self.rtNormalRRs.append(currentRR)
                                                        if self.rtNormalRRs.count > 4 { self.rtNormalRRs.removeFirst() }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    
                                    self.rtLastPeakTimestamp = detectedPeak.timestamp
                                    self.rtThreshold = max(250.0, peakVal * 0.6)
                                    
                                    let lockoutMs: Double
                                    if self.rtNormalRRs.isEmpty {
                                        lockoutMs = 300.0
                                    } else {
                                        let avgRR = self.rtNormalRRs.reduce(0, +) / Double(self.rtNormalRRs.count)
                                        lockoutMs = min(350.0, max(200.0, avgRR * 0.40))
                                    }
                                    let lockoutSamples = Int(lockoutMs * 0.13)
                                    self.rtLockoutEndIndex = peakIdx + lockoutSamples
                                    self.rtSearchIdx = peakIdx + lockoutSamples
                                } else {
                                    let timeSinceLastPeak = self.rtLastPeakTimestamp > 0 && timestamp > self.rtLastPeakTimestamp
                                        ? timestamp - self.rtLastPeakTimestamp
                                        : 0
                                    if timeSinceLastPeak > 2000 {
                                        self.rtThreshold = max(200.0, self.rtThreshold * 0.95)
                                    }
                                    self.rtSearchIdx += 1
                                }
                            }
                        } else {
                            // During stabilization phase, keep search index aligned with buffer end
                            self.rtSearchIdx = max(0, self.rtEcgBuffer.count - 65)
                        }
                        
                        let trimCount = self.rtSearchIdx - 100
                        if trimCount > 0 {
                            self.rtEcgBuffer.removeFirst(trimCount)
                            self.rtSearchIdx -= trimCount
                            self.rtLockoutEndIndex = max(0, self.rtLockoutEndIndex - trimCount)
                        }
                    }

                    DispatchQueue.main.async { [newRolling, batchForUI] in
                        self.ecgRolling.append(contentsOf: newRolling)
                        // Trim rolling buffer every 2 seconds to avoid O(N^2) overhead
                        if now.timeIntervalSince(self.lastBufferTrim) > 2.0 {
                            self.ecgRolling.removeAll { now.timeIntervalSince($0.date) > 60 }
                            self.lastBufferTrim = now
                        }
                        self.ecgDataPublisher.send(batchForUI)
                    }

                    if !batchForStorage.isEmpty {
                        StorageManager.shared.appendECGBatch(batchForStorage)
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
        rtExtrasystoleCount = 0
        rtEcgBuffer.removeAll()
        rtNormalRRs.removeAll()
        rtLastPeakTimestamp = 0
        rtThreshold = 400.0
        btW1 = 0.0
        btW2 = 0.0
        rtSearchIdx = 0
        rtLockoutEndIndex = 0
        rtSamplesProcessed = 0
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
        updateLiveActivity()
    }

    func stopStreaming() {
        guard isStreaming else { return }
        isStreaming = false
        updateLiveActivity()
    }

    @MainActor
    func startEventRecordingWindow() {
        guard isConnected, !deviceId.isEmpty, !isStreaming, !isEventRecording else { return }
        isEventRecording = true
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
            self.isConnecting = false
            self.connectionFailed = false
            self.startAllStreams()
            self.startLiveActivity()
        }
    }
    func deviceDisconnected(_ i: PolarDeviceInfo, pairingError: Bool) {
        DispatchQueue.main.async {
            self.isConnected = false; self.isStreaming = false; self.isEventRecording = false
            self.isConnecting = false
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

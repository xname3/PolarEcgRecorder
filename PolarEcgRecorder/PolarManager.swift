import Foundation
import Combine
import CoreBluetooth
import PolarBleSdk

class PolarManager: ObservableObject {
    static let shared = PolarManager()
    
    private var api = PolarBleApiDefaultImpl.polarImplementation(
        DispatchQueue.main,
        features: [PolarBleSdkFeature.feature_hr,
                   PolarBleSdkFeature.feature_battery_info,
                   PolarBleSdkFeature.feature_polar_offline_recording,
                   PolarBleSdkFeature.feature_polar_online_streaming]
    )
    
    @Published var deviceId: String = ""
    @Published var isConnected: Bool = false
    @Published var isStreaming: Bool = false
    @Published var isEventRecording: Bool = false
    @Published var currentHR: UInt8 = 0
    @Published var batteryLevel: UInt = 0
    
    private var filterBaseline: Double = 0.0
    private var filterSmoothed: Double = 0.0

    // Dočasné pamäťové buffre pre uloženie poslednej 1 minúty (ACC vymazané)
    private var ecgRolling: [(date: Date, ts: UInt64, val: Int32)] = []
    private var hrRolling: [(date: Date, ts: UInt64, bpm: UInt8)] = []
    
    private var eventRecordTask: Task<Void, Never>? = nil

    private func filterEcgSample(_ rawValue: Int32) -> Int32 {
        let raw = Double(rawValue)
        filterBaseline = (0.98 * filterBaseline) + (0.02 * raw)
        let detrended = raw - filterBaseline
        filterSmoothed = (0.35 * detrended) + (0.65 * filterSmoothed)
        return Int32(filterSmoothed)
    }
    
    let ecgDataPublisher = PassthroughSubject<Int32, Never>()
    
    private var hrTask: Task<Void, Never>?
    private var ecgTask: Task<Void, Never>?
    
    private init() {
        setupPolarApi()
    }
    
    private func setupPolarApi() {
        api.observer = self
    }
    
    func autoConnect() {
        print("▶️ Tlačidlo stlačené: Volám autoConnect()...")
        Task { @MainActor in
            do {
                print("🔍 Polar SDK: Spúšťam vyhľadávanie Polar H10...")
                try await api.startAutoConnectToDevice(-85, service: nil, polarDeviceType: "H10")
            } catch {
                print("❌ Polar SDK: Auto-connect zlyhal: \(error)")
            }
        }
    }

    func disconnect() {
        if !deviceId.isEmpty {
            do {
                try api.disconnectFromDevice(deviceId)
                stopStreaming()
                stopEventRecordingWindow()
                stopAllStreams()
            } catch {
                print("Failed to disconnect: \(error)")
            }
        }
    }
    
    private func startAllStreams() {
        stopAllStreams()
        
        // 1. HR Stream
        hrTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000) // Bezpečný štart
                guard self.isConnected else { return }
                
                let stream = api.startHrStreaming(deviceId)
                for try await hrData in stream {
                    for sample in hrData {
                        let hrValue = sample.hr
                        self.currentHR = hrValue
                        
                        let now = Date()
                        let timestamp = UInt64(now.timeIntervalSince1970 * 1000)
                        
                        self.hrRolling.append((now, timestamp, hrValue))
                        self.hrRolling.removeAll { now.timeIntervalSince($0.date) > 60 }
                        
                        if self.isStreaming || self.isEventRecording {
                            StorageManager.shared.appendHR(timestamp: timestamp, bpm: hrValue)
                        }
                    }
                }
            } catch { print("❌ HR Stream error: \(error)") }
        }
        
        // 2. ECG Stream
        ecgTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 2_500_000_000) // Bezpečný rozostup
                guard self.isConnected else { return }
                
                let settings = try await api.requestStreamSettings(deviceId, feature: .ecg)
                let stream = api.startEcgStreaming(deviceId, settings: settings.maxSettings())
                
                for try await ecgData in stream {
                    for sample in ecgData {
                        let filteredVoltage = self.filterEcgSample(sample.voltage)
                        let now = Date()
                        
                        self.ecgRolling.append((now, sample.timeStamp, filteredVoltage))
                        self.ecgRolling.removeAll { now.timeIntervalSince($0.date) > 60 }
                        
                        self.ecgDataPublisher.send(filteredVoltage)
                        
                        if self.isStreaming || self.isEventRecording {
                            StorageManager.shared.appendECG(timestamp: sample.timeStamp, microVolts: filteredVoltage)
                        }
                    }
                }
            } catch { print("❌ ECG Stream error: \(error)") }
        }
    }
    
    private func stopAllStreams() {
        hrTask?.cancel(); ecgTask?.cancel()
        hrTask = nil; ecgTask = nil
        ecgRolling.removeAll(); hrRolling.removeAll()
    }
    
    func startStreaming() {
        guard isConnected, !deviceId.isEmpty, !isStreaming, !isEventRecording else { return }
        StorageManager.shared.startNewSession()
        isStreaming = true
    }
    
    func stopStreaming() {
        guard isStreaming else { return }
        StorageManager.shared.stopSession()
        isStreaming = false
    }
    
    @MainActor
    func startEventRecordingWindow() {
        guard isConnected, !deviceId.isEmpty, !isStreaming, !isEventRecording else { return }
        
        print("🚨 Spúšťam núdzový záznam: Ukladám -1 minútu z pamäte...")
        isEventRecording = true
        
        StorageManager.shared.startNewSession()
        
        let ecgDump = ecgRolling
        let hrDump = hrRolling
        
        for item in ecgDump { StorageManager.shared.appendECG(timestamp: item.ts, microVolts: item.val) }
        for item in hrDump { StorageManager.shared.appendHR(timestamp: item.ts, bpm: item.bpm) }
        
        print("✅ Minulosť zapísaná. Teraz nahrávam nasledujúcu 1 minútu...")
        
        eventRecordTask?.cancel()
        eventRecordTask = Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            await MainActor.run {
                self.stopEventRecordingWindow()
            }
        }
    }
    
    @MainActor
    func stopEventRecordingWindow() {
        guard isEventRecording else { return }
        print("⏱️ Budúca minúta ubehla. Uzatváram automatický záznam eventu.")
        isEventRecording = false
        eventRecordTask?.cancel()
        eventRecordTask = nil
        StorageManager.shared.stopSession()
    }
}

// MARK: - Polar SDK Observers
extension PolarManager: PolarBleApiObserver {
    func deviceConnecting(_ polarDeviceInfo: PolarBleSdk.PolarDeviceInfo) {}
    
    func deviceConnected(_ polarDeviceInfo: PolarBleSdk.PolarDeviceInfo) {
        print("🔗 Polar SDK: Pripojené! Inicializujem Bluetooth charakteristiky...")
        DispatchQueue.main.async {
            self.deviceId = polarDeviceInfo.deviceId
            self.isConnected = true
            self.startAllStreams()
        }
    }
    
    func deviceDisconnected(_ polarDeviceInfo: PolarBleSdk.PolarDeviceInfo, pairingError: Bool) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.isStreaming = false
            self.isEventRecording = false
            self.stopAllStreams()
            self.currentHR = 0
            self.batteryLevel = 0
        }
    }

    func batteryLevelReceived(_ identifier: String, batteryLevel: UInt) {
        DispatchQueue.main.async { self.batteryLevel = batteryLevel }
    }
    
    func disInformationReceived(_ identifier: String, uuid: Foundation.UUID, value: String) {}
    func blePowerOn() {}
    func blePowerOff() {}
    func polarityMessageReceived(_ identifier: String, isPolarityReversed: Bool) {}
}

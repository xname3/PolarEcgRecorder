import Foundation
import Combine
import SwiftUI

// MARK: - Event Marker
class EventState: ObservableObject {
    @Published var isEventMarked: Bool = false
    
    // Oprava: Zaistíme, že zápis do @Published prebehne vždy na hlavnom vlákne
    @MainActor
    func triggerEvent() {
        self.isEventMarked = true
    }
}

// MARK: - Storage Manager
class StorageManager {
    static let shared = StorageManager()
    
    var eventState: EventState?
    
    private var ecgFileHandle: FileHandle?
    private var hrFileHandle: FileHandle?
    // ACC FileHandle bol vymazaný
    
    private var currentSessionStartTime: Date?
    private let splitInterval: TimeInterval = 3600 // 1 hodina
    
    private let ioQueue = DispatchQueue(label: "com.ecgpolar.ioqueue", qos: .background)
    
    private init() {}
    
    func startNewSession() {
        ioQueue.async {
            self.internalStartNewSession()
        }
    }
    
    func stopSession() {
        ioQueue.async {
            self.internalStopSession()
        }
    }
    
    private func internalStartNewSession() {
        internalStopSession()
        let now = Date()
        currentSessionStartTime = now
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timeString = formatter.string(from: now)
        
        ecgFileHandle = createAndOpenCSV(prefix: "ECG", timeString: timeString, header: "timestamp,microvolts,event\n")
        hrFileHandle = createAndOpenCSV(prefix: "HR", timeString: timeString, header: "timestamp,bpm,event\n")
        // ACC vytváranie súboru vymazané
        
        print("Session started at \(timeString)")
    }
    
    private func internalStopSession() {
        ecgFileHandle?.closeFile()
        hrFileHandle?.closeFile()
        
        ecgFileHandle = nil
        hrFileHandle = nil
        currentSessionStartTime = nil
    }
    
    private func checkAndRotateFilesIfNeeded() {
        guard let start = currentSessionStartTime else { return }
        if Date().timeIntervalSince(start) >= splitInterval {
            print("1 hour reached. Rotating CSV files...")
            internalStartNewSession()
        }
    }
    
    private func createAndOpenCSV(prefix: String, timeString: String, header: String) -> FileHandle? {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileName = "\(prefix)_\(timeString).csv"
        let fileURL = documentsPath.appendingPathComponent(fileName)
        
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
            
            if let targetFileHandle = try? FileHandle(forWritingTo: fileURL) {
                targetFileHandle.seekToEndOfFile()
                if let data = header.data(using: .utf8) {
                    targetFileHandle.write(data)
                }
                targetFileHandle.closeFile()
            }
        }
        
        return try? FileHandle(forWritingTo: fileURL)
    }
    
    // 🚨 FIX VAROVANIA: Zmena @Published premennej sa odosiela na Main Vlákno
    private func consumeEventTag() -> String {
        guard let state = eventState else { return "" }
        if state.isEventMarked {
            DispatchQueue.main.async {
                state.isEventMarked = false
            }
            return "EVENT"
        }
        return ""
    }
    
    // MARK: - Append Data Methods
    
    func appendECG(timestamp: UInt64, microVolts: Int32) {
        ioQueue.async {
            self.checkAndRotateFilesIfNeeded()
            let tag = self.consumeEventTag()
            let line = "\(timestamp),\(microVolts),\(tag)\n"
            if let data = line.data(using: .utf8) {
                self.ecgFileHandle?.seekToEndOfFile()
                self.ecgFileHandle?.write(data)
            }
        }
    }
    
    func appendHR(timestamp: UInt64, bpm: UInt8) {
        ioQueue.async {
            self.checkAndRotateFilesIfNeeded()
            let tag = self.consumeEventTag()
            let line = "\(timestamp),\(bpm),\(tag)\n"
            if let data = line.data(using: .utf8) {
                self.hrFileHandle?.seekToEndOfFile()
                self.hrFileHandle?.write(data)
            }
        }
    }
    
    // appendACC metóda bola kompletne odstránená
    
    // MARK: - Správa súborov (História)
    
    // Načítanie všetkých uložených session súborov zoradených od najnovšieho
    func getAllSavedFiles() -> [URL] {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let files = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: nil)
            return files.filter { $0.pathExtension == "csv" }.sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
        } catch {
            print("Error reading documents directory: \(error)")
            return []
        }
    }
    
    // Vymazanie súboru z pamäte iPhonu
    func deleteSession(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            print("✅ Súbor úspešne vymazaný: \(url.lastPathComponent)")
        } catch {
            print("❌ Chyba pri mazaní súboru: \(error)")
        }
    }
}

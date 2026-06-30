import Foundation
import SwiftUI
import Combine

// MARK: - Storage Manager
public class StorageManager {
    public static let shared = StorageManager()
    public var eventState: EventState?

    private var ecgHandle: FileHandle?
    private var hrHandle:  FileHandle?
    private var rrHandle:  FileHandle?

    private var sessionStart: Date?
    private let splitInterval: TimeInterval = 3600
    private let ioQ = DispatchQueue(label: "com.ecgpolar.io", qos: .background)

    private init() {}

    // MARK: - Session lifecycle
    public func startNewSession() { ioQ.async { self.internalStart() } }
    public func stopSession()      { ioQ.async { self.internalStop()  } }

    private func internalStart() {
        internalStop()
        let now = Date()
        sessionStart = now
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let ts = f.string(from: now)

        ecgHandle = makeHandle(prefix: "ECG", ts: ts, header: "timestamp,microvolts,event\n")
        hrHandle  = makeHandle(prefix: "HR",  ts: ts, header: "timestamp,bpm,event\n")
        rrHandle  = makeHandle(prefix: "HRV", ts: ts, header: "timestamp,rmssd,rr_intervals_ms\n")
        print("✅ Session started: \(ts)")
    }

    private func internalStop() {
        [ecgHandle, hrHandle, rrHandle].forEach { $0?.closeFile() }
        ecgHandle = nil; hrHandle = nil; rrHandle = nil; sessionStart = nil
    }

    private func rotateIfNeeded() {
        guard let s = sessionStart, Date().timeIntervalSince(s) >= splitInterval else { return }
        internalStart()
    }

    private func makeHandle(prefix: String, ts: String, header: String) -> FileHandle? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url  = docs.appendingPathComponent("\(prefix)_\(ts).csv")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: header.data(using: .utf8))
        }
        let h = try? FileHandle(forWritingTo: url)
        h?.seekToEndOfFile()
        return h
    }

    // MARK: - Event tag
    private var ecgEventTimestamp: UInt64? = nil
    private var hrEventTimestamp: UInt64? = nil

    public func markEvent() {
        let ts = UInt64(Date().timeIntervalSince1970 * 1000)
        ioQ.async {
            self.ecgEventTimestamp = ts
            self.hrEventTimestamp = ts
        }
    }

    private func consumeEcgEventTag(for ts: UInt64) -> String {
        guard let et = ecgEventTimestamp else { return "" }
        if ts >= et { ecgEventTimestamp = nil; return "EVENT" }
        return ""
    }

    private func consumeHrEventTag(for ts: UInt64) -> String {
        guard let et = hrEventTimestamp else { return "" }
        if ts >= et { hrEventTimestamp = nil; return "EVENT" }
        return ""
    }

    // MARK: - Append helpers
    public func appendECG(timestamp: UInt64, microVolts: Int32) {
        ioQ.async {
            self.rotateIfNeeded()
            let tag = self.consumeEcgEventTag(for: timestamp)
            self.write("\(timestamp),\(microVolts),\(tag)\n", to: self.ecgHandle)
        }
    }

    public func appendECGBatch(_ batch: [(UInt64, Int32)]) {
        ioQ.async {
            self.rotateIfNeeded()
            var chunk = ""
            for (ts, v) in batch {
                let tag = self.consumeEcgEventTag(for: ts)
                chunk.append("\(ts),\(v),\(tag)\n")
            }
            self.write(chunk, to: self.ecgHandle)
        }
    }

    public func appendHR(timestamp: UInt64, bpm: UInt8) {
        ioQ.async {
            let tag = self.consumeHrEventTag(for: timestamp)
            self.write("\(timestamp),\(bpm),\(tag)\n", to: self.hrHandle)
        }
    }

    /// Writes RMSSD and raw RR intervals (ms) to a dedicated HRV file.
    public func appendRR(timestamp: UInt64, rrIntervals: [Int], rmssd: Double) {
        ioQ.async {
            let rrs = rrIntervals.map(String.init).joined(separator: ";")
            self.write("\(timestamp),\(String(format: "%.2f", rmssd)),\(rrs)\n", to: self.rrHandle)
        }
    }

    private func write(_ line: String, to handle: FileHandle?) {
        guard let d = line.data(using: .utf8) else { return }
        handle?.write(d)
    }

    // MARK: - File management
    public func getAllSavedFiles() -> [URL] {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let all  = (try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.pathExtension == "csv" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Groups ECG / HR / HRV files by session timestamp.
    public func getGroupedSessions() -> [SessionGroup] {
        var groups: [String: SessionGroup] = [:]
        for url in getAllSavedFiles() {
            let name = url.deletingPathExtension().lastPathComponent
            // Format: PREFIX_YYYY-MM-DD_HH-mm-ss  →  split on first "_"
            guard let cut = name.firstIndex(of: "_") else { continue }
            let prefix = String(name[name.startIndex..<cut])
            let key    = String(name[name.index(after: cut)...])
            if groups[key] == nil { groups[key] = SessionGroup(sessionKey: key) }
            switch prefix {
            case "ECG": groups[key]?.ecgURL = url
            case "HR":  groups[key]?.hrURL  = url
            case "HRV": groups[key]?.hrvURL = url
            default: break
            }
        }
        return groups.values.filter { !$0.allURLs.isEmpty }.sorted { $0.sessionKey > $1.sessionKey }
    }

    public func deleteFile(at url: URL)            { try? FileManager.default.removeItem(at: url) }
    public func deleteGroup(_ g: SessionGroup) {
        g.allURLs.forEach { deleteFile(at: $0) }
        
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let pdfURL = docs.appendingPathComponent("ECG_Report_\(g.sessionKey).pdf")
        deleteFile(at: pdfURL)
    }
}

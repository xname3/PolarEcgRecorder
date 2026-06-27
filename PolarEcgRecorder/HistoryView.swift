import SwiftUI
import UIKit

// 💡 Pomocná štruktúra, aby sme mohli použiť bezpečnejší .sheet(item:)
struct ShareableFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct HistoryView: View {
    @State private var savedFiles: [URL] = []
    
    // 🚨 ZMENA: Namiesto dvoch premenných (Bool a URL) držíme iba jeden stav
    @State private var fileToShare: ShareableFile? = nil
    
    var body: some View {
        List {
            if savedFiles.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 10) {
                            Image(systemName: "folder.badge.questionmark")
                                .font(.system(size: 40))
                                .foregroundColor(.gray)
                            Text("Žiadne uložené záznamy")
                                .font(.headline)
                                .foregroundColor(.gray)
                        }
                        .padding(.vertical, 40)
                        Spacer()
                    }
                }
            } else {
                ForEach(savedFiles, id: \.self) { fileURL in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(fileURL.lastPathComponent)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                            
                            Text(getFileSize(url: fileURL))
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        
                        Spacer()
                        
                        // Tlačidlo zdieľania
                        Button(action: {
                            prepareAndShare(fileURL: fileURL)
                        }) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title3)
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
                .onDelete(perform: deleteItems)
            }
        }
        .navigationTitle("História meraní")
        .onAppear {
            loadFiles()
        }
        // 🚨 FIX ČIERNEJ OBRAZOVKY: Sheet sa otvorí AŽ vtedy, keď fileToShare nie je nil
        .sheet(item: $fileToShare, onDismiss: { cleanTemporaryFiles() }) { shareable in
            ActivityViewController(activityItems: [shareable.url])
        }
    }
    
    private func loadFiles() {
        savedFiles = StorageManager.shared.getAllSavedFiles()
    }
    
    private func deleteItems(at offsets: IndexSet) {
        for index in offsets {
            let fileURL = savedFiles[index]
            StorageManager.shared.deleteSession(at: fileURL)
        }
        savedFiles.remove(atOffsets: offsets)
    }
    
    // Príprava súboru v temporary adresári
    private func prepareAndShare(fileURL: URL) {
        let fileManager = FileManager.default
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let tempFileURL = tempDirectory.appendingPathComponent(fileURL.lastPathComponent)
        
        try? fileManager.removeItem(at: tempFileURL)
        
        do {
            try fileManager.copyItem(at: fileURL, to: tempFileURL)
            print("✅ Súbor úspešne skopírovaný do temp zóny pre zdieľanie: \(tempFileURL.lastPathComponent)")
            
            // Priradenie sem okamžite a plynule vyvolá sheet so správnymi dátami
            self.fileToShare = ShareableFile(url: tempFileURL)
        } catch {
            print("❌ Chyba pri príprave súboru na zdieľanie: \(error)")
            self.fileToShare = ShareableFile(url: fileURL)
        }
    }
    
    private func cleanTemporaryFiles() {
        if let url = fileToShare?.url {
            try? FileManager.default.removeItem(at: url)
        }
        fileToShare = nil
    }
    
    private func getFileSize(url: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? Int64 else {
            return "Neznáma veľkosť"
        }
        
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }
}

// MARK: - UIKit Activity View Wrapper
struct ActivityViewController: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: UIViewControllerRepresentableContext<ActivityViewController>) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
        // Vylúčenie shareplay, aby systém netlačil Collaboration režimy
        controller.excludedActivityTypes = [.sharePlay]
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: UIViewControllerRepresentableContext<ActivityViewController>) {}
}

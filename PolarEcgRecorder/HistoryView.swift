import SwiftUI
import UIKit

struct ShareableFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct HistoryView: View {
    @State private var sessions: [SessionGroup] = []
    @State private var fileToShare: ShareableFile? = nil
    @State private var isGeneratingPDF = false
    @State private var deleteAlert: SessionGroup? = nil

    var body: some View {
        List {
            if sessions.isEmpty {
                emptyState
            } else {
                ForEach(sessions) { group in
                    ZStack {
                        NavigationLink(destination: SessionDetailView(group: group)) {
                            EmptyView()
                        }.opacity(0)
                        
                        SessionGroupRow(
                            group: group,
                            onShareFile:   { share(url: $0) },
                            onDelete:      { deleteAlert = group }
                        )
                    }
                }
            }
        }
        .navigationTitle("Measurement History")
        .onAppear { reload() }
        .sheet(item: $fileToShare, onDismiss: cleanTemp) { f in
            ActivityViewController(activityItems: [f.url])
        }
        .alert("Delete session?", isPresented: showDeleteAlert, presenting: deleteAlert) { g in
            Button("Delete", role: .destructive) {
                StorageManager.shared.deleteGroup(g); reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: { g in
            Text("All files will be deleted for \(g.displayName).")
        }
    }

    private var showDeleteAlert: Binding<Bool> {
        .init(get: { deleteAlert != nil }, set: { if !$0 { deleteAlert = nil } })
    }

    @ViewBuilder
    private var emptyState: some View {
        Section {
            HStack {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.questionmark").font(.system(size: 40)).foregroundColor(.gray)
                    Text("No saved records").font(.headline).foregroundColor(.gray)
                }
                .padding(.vertical, 40)
                Spacer()
            }
        }
    }

    private func reload() { sessions = StorageManager.shared.getGroupedSessions() }

    private func share(url: URL) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: tmp)
        if (try? FileManager.default.copyItem(at: url, to: tmp)) != nil {
            fileToShare = ShareableFile(url: tmp)
        } else {
            fileToShare = ShareableFile(url: url)
        }
    }

    private func cleanTemp() {
        if let url = fileToShare?.url { try? FileManager.default.removeItem(at: url) }
        fileToShare = nil
    }
}

// MARK: - Session Group Row
struct SessionGroupRow: View {
    let group: SessionGroup
    let onShareFile:   (URL) -> Void
    let onDelete:      () -> Void

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.path.ecg.rectangle.fill")
                    .foregroundColor(.red).font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.displayName)
                        .font(.system(.subheadline, design: .rounded)).fontWeight(.semibold)
                    Text("\(group.allURLs.count) files  •  \(group.totalSizeString)")
                        .font(.caption).foregroundColor(.secondary)
                }

                Spacer()

                // Expand
                Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary).font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 8)

            if expanded {
                VStack(spacing: 6) {
                    if let u = group.ecgURL { FileRow(url: u, icon: "waveform",      color: .red,    onShare: onShareFile) }
                    if let u = group.hrURL  { FileRow(url: u, icon: "heart.fill",   color: .red,    onShare: onShareFile) }
                    if let u = group.hrvURL { FileRow(url: u, icon: "chart.xyaxis.line", color: .indigo, onShare: onShareFile) }
                }
                .padding(.leading, 36).padding(.bottom, 8)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
        }
    }
}

struct FileRow: View {
    let url: URL; let icon: String; let color: Color
    let onShare: (URL) -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundColor(color).font(.caption).frame(width: 16)
            Text(url.lastPathComponent).font(.caption).foregroundColor(.secondary).lineLimit(1)
            Spacer()
            Button { onShare(url) } label: {
                Image(systemName: "square.and.arrow.up").font(.caption).foregroundColor(.blue)
            }.buttonStyle(.borderless)
        }
    }
}

// MARK: - UIKit share sheet wrapper
struct ActivityViewController: UIViewControllerRepresentable {
    var activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        vc.excludedActivityTypes = [.sharePlay]
        return vc
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct SessionDetailView: View {
    let group: SessionGroup
    
    @State private var isAnalyzing = true
    @State private var anomalies: [AnomalyEvent] = []
    @State private var isGeneratingPDF = false
    @State private var fileToShare: ShareableFile? = nil
    @State private var pdfError: String? = nil
    @State private var showPdfError = false
    @State private var integrityError: String? = nil
    
    var body: some View {
        VStack {
            if isAnalyzing {
                VStack(spacing: 16) {
                    ProgressView("Analyzing ECG Signal...")
                        .scaleEffect(1.2)
                    Text("Detecting R-peaks & structural anomalies")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
            } else if let integrityError = integrityError {
                VStack(spacing: 16) {
                    Image(systemName: "xmark.octagon.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.red)
                    Text("Session Corrupted")
                        .font(.title2.bold())
                    Text(integrityError)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else if anomalies.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green)
                    Text("No structural anomalies detected.")
                        .font(.title3.bold())
                    Text("The RR intervals stayed within normal bounds.\nNo pauses >1.5s or premature beats <0.4s found.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                List {
                    Section(header: Text("Detected Anomalies (\(anomalies.count))")) {
                        ForEach(anomalies) { anomaly in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(anomaly.type == .dropout ? .red : .orange)
                                    Text(anomaly.type.rawValue)
                                        .font(.headline)
                                    Spacer()
                                    Text("\(Int(anomaly.rrInterval)) ms")
                                        .font(.subheadline.bold())
                                        .foregroundColor(.secondary)
                                }
                                
                                Text("Time: \(formatTimestamp(anomaly.timestamp))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            
            if !isAnalyzing && integrityError == nil {
                Button {
                    generateFullPDF()
                } label: {
                    HStack {
                        Image(systemName: "doc.richtext.fill")
                        Text("Export Full Comprehensive Report")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(12)
                }
                .padding()
            }
        }
        .navigationTitle("Session Analysis")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            runAnalysis()
        }
        .sheet(item: $fileToShare, onDismiss: cleanTemp) { f in
            ActivityViewController(activityItems: [f.url])
        }
        .overlay {
            if isGeneratingPDF {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView().scaleEffect(1.4).tint(.white)
                        Text("Generating Comprehensive PDF...").foregroundColor(.white).font(.headline)
                    }
                    .padding(28)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color(.systemGray)))
                }
            }
        }
        .alert("Report Generation Failed", isPresented: $showPdfError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(pdfError ?? "Unknown error occurred.")
        }
    }
    
    private func runAnalysis() {
        guard let url = group.ecgURL else {
            isAnalyzing = false
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            var ecgData = ReportGenerator.parseECG(url)
            var hrData = ReportGenerator.parseHR(group.hrURL)
            var hrvData = ReportGenerator.parseHRV(group.hrvURL)
            
            do {
                try ReportGenerator.validateDataIntegrity(ecg: &ecgData, hr: &hrData, hrv: &hrvData)
            } catch {
                DispatchQueue.main.async {
                    self.integrityError = error.localizedDescription
                    self.isAnalyzing = false
                }
                return
            }
            
            let detected = ECGAnalyzer.analyze(ecgData: ecgData)
            
            DispatchQueue.main.async {
                self.anomalies = detected
                self.isAnalyzing = false
            }
        }
    }
    
    private func generateFullPDF() {
        isGeneratingPDF = true
        // Pass the already detected anomalies down to the generator
        ReportGenerator.generate(group: group, anomalies: anomalies) { result in
            isGeneratingPDF = false
            switch result {
            case .success(let url):
                fileToShare = ShareableFile(url: url)
            case .failure(let error):
                pdfError = error.localizedDescription
                showPdfError = true
            }
        }
    }
    
    private func formatTimestamp(_ ts: UInt64) -> String {
        let date = Date(timeIntervalSince1970: Double(ts) / 1000.0)
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium
        return df.string(from: date)
    }
    
    private func cleanTemp() {
        if let url = fileToShare?.url { try? FileManager.default.removeItem(at: url) }
        fileToShare = nil
    }
}

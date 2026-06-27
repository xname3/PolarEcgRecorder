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
                    SessionGroupRow(
                        group: group,
                        onGeneratePDF: { generatePDF(for: group) },
                        onShareFile:   { share(url: $0) },
                        onDelete:      { deleteAlert = group }
                    )
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
        .overlay {
            if isGeneratingPDF {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView().scaleEffect(1.4).tint(.white)
                        Text("Generating PDF report...").foregroundColor(.white).font(.headline)
                    }
                    .padding(28)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color(.systemGray)))
                }
            }
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

    private func generatePDF(for group: SessionGroup) {
        isGeneratingPDF = true
        ReportGenerator.generate(group: group) { url in
            isGeneratingPDF = false
            if let url { fileToShare = ShareableFile(url: url) }
        }
    }

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
    let onGeneratePDF: () -> Void
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

                // PDF button
                Button(action: onGeneratePDF) {
                    Label("PDF", systemImage: "doc.richtext.fill")
                        .labelStyle(.iconOnly)
                        .font(.title3).foregroundColor(.blue)
                }
                .buttonStyle(.borderless)

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
            Button(action: onGeneratePDF) { Label("PDF", systemImage: "doc.richtext.fill") }.tint(.blue)
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

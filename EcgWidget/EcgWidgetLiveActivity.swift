import ActivityKit
import WidgetKit
import SwiftUI

struct EcgWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: EcgActivityAttributes.self) { context in
            // Lock Screen UI
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "waveform.path.ecg")
                        .foregroundColor(.red)
                        .font(.title2)
                    VStack(alignment: .leading) {
                        Text("Polar ECG Recorder")
                            .font(.headline)
                        Text(context.state.isEventRecording ? "Zaznamenávam udalosť..." : "Monitorovanie aktívne")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if context.state.currentHR > 0 {
                        Text("\(context.state.currentHR) BPM")
                            .font(.title.bold())
                            .foregroundColor(.red)
                    }
                }
                
                Button(intent: MarkEventIntent()) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Označiť udalosť")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.orange)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .activityBackgroundTint(Color(.systemBackground).opacity(0.8))
            .activitySystemActionForegroundColor(Color.orange)
            
        } dynamicIsland: { context in
            // Dynamic Island layout
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("\(context.state.currentHR) BPM", systemImage: "waveform.path.ecg")
                        .foregroundColor(.red)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.isEventRecording ? "EVENT" : "ECG")
                        .foregroundColor(.orange)
                        .bold()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Button(intent: MarkEventIntent()) {
                        Text("Mark Event")
                            .bold()
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity)
                            .background(Color.orange)
                            .cornerRadius(8)
                    }
                }
            } compactLeading: {
                Image(systemName: "waveform.path.ecg").foregroundColor(.red)
            } compactTrailing: {
                Text("\(context.state.currentHR)")
            } minimal: {
                Image(systemName: "waveform.path.ecg").foregroundColor(.red)
            }
        }
    }
}

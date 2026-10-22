import SwiftUI

struct SettingsView: View {
    @Environment(MixStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Storage") {
                    LabeledContent("Mixes", value: "\(store.items.count)")
                    LabeledContent("Space used", value: ByteCountFormatter.string(fromByteCount: Int64(store.totalBytes), countStyle: .file))
                }

                Section {
                    Text("In Passable on your Mac, build a set, click the iPhone button in the transport bar at the bottom and choose this phone. Both need to be on the same Wi-Fi. Or choose Save as File… in the same panel and AirDrop the file.")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                } header: {
                    Text("Sending a set")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
        .incomingAlerts()
    }
}

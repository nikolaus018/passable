import SwiftUI

struct SettingsView: View {
    @Environment(MixStore.self) private var store
    @Environment(Receiver.self) private var receiver
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Storage") {
                    LabeledContent("Mixes", value: "\(store.items.count)")
                    LabeledContent("Space used", value: ByteCountFormatter.string(fromByteCount: Int64(store.totalBytes), countStyle: .file))
                }

                Section {
                    TextField(UIDevice.current.name, text: $name)
                        .submitLabel(.done)
                        .onSubmit { receiver.rename(name) }
                        .disabled(!receiver.canRename)
                } header: {
                    Text("Name on your Mac")
                } footer: {
                    Text("Your Mac lists this phone under this name. Give each phone its own, so you send to the right one.")
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
            .onAppear { name = receiver.displayName == UIDevice.current.name ? "" : receiver.displayName }
            // (However the sheet goes away: Done, or a swipe.)
            .onDisappear { receiver.rename(name) }
        }
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
        .incomingAlerts()
    }
}

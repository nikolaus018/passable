import SwiftUI
import UniformTypeIdentifiers

/// "iPhone" in the transport bar: pick a phone nearby and send it the set,
/// or save the set as a file for AirDrop.
struct PhoneButton: View {
    @EnvironmentObject private var set: SetSession
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Label("iPhone", systemImage: "iphone.and.arrow.forward")
        }
        .disabled(set.mix == nil)
        .help("Send this set to the Passable app on your iPhone")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            PhonePanel(link: set.phoneLink, close: { open = false })
        }
    }
}

private struct PhonePanel: View {
    @EnvironmentObject private var set: SetSession
    @ObservedObject var link: PhoneLink
    var close: () -> Void
    @State private var title = PhoneMix.suggestedTitle()

    private var cleanTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? PhoneMix.suggestedTitle() : t
    }

    private var mixType: UTType { UTType(filenameExtension: PassableMix.fileExtension) ?? .data }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send to iPhone").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Name on the phone").font(.caption).foregroundStyle(.secondary)
                TextField("Set", text: $title).textFieldStyle(.roundedBorder)
            }

            Divider()

            if let problem = link.problem {
                Label(problem, systemImage: "wifi.exclamationmark")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } else if link.phones.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for iPhones…")
                }
                Text("Open Passable on your iPhone and keep it on screen. Both need to be on the same Wi-Fi.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(link.phones) { phone in
                    HStack {
                        Image(systemName: "iphone")
                        Text(phone.name).lineLimit(1)
                        Spacer()
                        Button("Send") {
                            set.exportPhoneMix(title: cleanTitle, to: .phone(phone))
                            close()
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(set.exportProgress != nil)
                    }
                }
                Text("The phone asks before anything arrives.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            Button("Save as File…") {
                let name = PhoneMix.suggestedFileName(cleanTitle)
                let title = cleanTitle
                close()
                DispatchQueue.main.async {
                    OpenPanel.save(name: name, types: [mixType]) { set.exportPhoneMix(title: title, to: .file($0)) }
                }
            }
            .disabled(set.exportProgress != nil)
            Text("For AirDrop or Files. Rendering takes a moment.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { link.startLooking() }
        .onDisappear { link.stopLooking() }
    }
}

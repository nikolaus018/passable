import SwiftUI

/// The "a Mac wants to send you a set" question, and anything that went
/// wrong. iOS can't show an alert from a screen that another one covers, so
/// every screen that can cover the library (the player, settings) carries
/// these too, and the library's own stands down while one is up.
struct IncomingAlerts: ViewModifier {
    @Environment(MixStore.self) private var store
    @Environment(Player.self) private var player
    @Environment(Receiver.self) private var receiver
    /// False while another screen covers this one.
    var isFront = true

    func body(content: Content) -> some View {
        content
            .alert(offerTitle, isPresented: Binding(get: { isFront && receiver.offer != nil }, set: { _ in }),
                   presenting: receiver.offer) { _ in
                Button("Accept") { receiver.accept() }
                Button("Decline", role: .cancel) { receiver.decline() }
            } message: { offer in
                Text(offerMessage(offer))
            }
            .alert("Something went wrong", isPresented: Binding(get: { isFront && errorText != nil },
                                                                set: { if !$0 { clearErrors() } })) {
                Button("OK", role: .cancel) { clearErrors() }
            } message: {
                Text(errorText ?? "")
            }
    }

    private var offerTitle: String {
        guard let offer = receiver.offer else { return "" }
        return "Receive “\(offer.invitation.title)”?"
    }

    private func offerMessage(_ offer: Receiver.Offer) -> String {
        let i = offer.invitation
        var parts: [String] = []
        if i.songs > 0 { parts.append("\(i.songs) songs") }
        if i.minutes > 0 { parts.append("\(i.minutes) min") }
        if i.bytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(i.bytes), countStyle: .file)) }
        let detail = parts.isEmpty ? "" : " (\(parts.joined(separator: " · ")))"
        return "“\(offer.macName)” wants to send you a set\(detail)."
    }

    private var errorText: String? { store.errorMessage ?? receiver.errorMessage ?? player.errorMessage }

    private func clearErrors() {
        store.errorMessage = nil
        receiver.errorMessage = nil
        player.errorMessage = nil
    }
}

extension View {
    func incomingAlerts(isFront: Bool = true) -> some View { modifier(IncomingAlerts(isFront: isFront)) }
}

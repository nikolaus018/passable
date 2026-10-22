import Foundation

// Sends a .passablemix to a Passable iPhone app nearby, using the same
// PhoneLink that Passable on the Mac uses. For testing the Wi-Fi path:
//
//   swiftc -O Tools/SendMix/main.swift ../Passable/Model/PassableMix.swift \
//       ../Passable/Library/PhoneLink.swift -o /tmp/send-mix
//   /tmp/send-mix "Samples/Sample Set.passablemix"

guard CommandLine.arguments.count > 1 else {
    print("usage: send-mix <file.passablemix>")
    exit(2)
}
let file = URL(fileURLWithPath: CommandLine.arguments[1])

Task { @MainActor in
    do {
        let manifest = try PassableMix.readManifest(from: file)
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        let link = PhoneLink()
        link.startLooking()
        print("Looking for iPhones…")
        var waited = 0.0
        while link.phones.isEmpty && link.problem == nil && waited < 30 {
            try await Task.sleep(nanoseconds: 250_000_000)
            waited += 0.25
        }
        if let problem = link.problem { print("Problem: \(problem)"); exit(1) }
        guard let phone = link.phones.first else { print("No iPhone found in 30 s."); exit(1) }
        print("Found \(phone.name). Asking it to accept “\(manifest.title)”…")
        let invitation = PassableMix.Invitation(title: manifest.title, songs: manifest.songs.count, bytes: size,
                                                minutes: Int((manifest.duration / 60).rounded()))
        var lastPrinted = -1
        try await link.send(file, to: phone, invitation: invitation) { p in
            let pct = Int(p * 100) / 10 * 10
            if pct != lastPrinted { lastPrinted = pct; print("  \(Int(p * 100))%") }
        }
        print("Sent.")
        exit(0)
    } catch {
        print("Failed: \(error.localizedDescription)")
        exit(1)
    }
}
RunLoop.main.run()

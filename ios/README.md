# Passable for iPhone

Plays the sets you build in **Passable on the Mac**, with every transition exactly as rendered there, and knows
which song is playing, so Next, Previous, the track list and the lock screen work on songs, not on one long file.

The Mac renders; the phone plays. Nothing is mixed on the phone.

## Getting a set onto the phone

1. Open Passable on the iPhone and leave it on screen (it says **Ready for your Mac**).
2. In Passable on the Mac, build a set, then click **iPhone** in the transport bar and pick the phone.
3. Tap **Accept** on the phone right away. The Mac then renders the set (a few seconds per song) while the phone keeps its screen on, packs it and sends it over Wi-Fi.

Both devices must be on the same Wi-Fi. The first time, each asks for **Local Network** access: say yes.
The phone asks before every transfer and everything is encrypted in transit.

No Wi-Fi? In the Mac's iPhone panel choose **Save as File…** and AirDrop the `.passablemix`, or use **+** in the app.

## What you get

- **Library** of mixes, each with its waveform coloured by song: blue and orange alternate like the Mac's two
  decks, and slide into each other across a transition.
- **Player** with artwork, BPM and key, a *Mixing into…* strip while a blend plays, a scrubbable waveform with the
  song's name under your finger, and a **track list** showing each blend (type and length) between songs.
- **Next / Previous** skip between transitions. A skip lands **four bars before the blend** into the next song
  (the Mac's cue point, stored per transition), never after it, so the transition is always heard. Previous restarts
  that lead-in; pressed again within three seconds it goes to the one before.
- Lock screen, Control Center and headphone buttons show the playing *song* with its own length, and Next/Previous work.
- Resumes where you left off, per mix. Pauses when headphones are unplugged.

## The `.passablemix` file

One continuous AAC render plus a JSON map, in a small chunked container (magic `PASSMIX\r\n\x1A\n`, version, then
`MNFT` manifest, `AUDI` audio, `END `; unknown chunks are skipped, so the format can grow).
The layout, the manifest types and the skip logic are in [`Passable/Model/PassableMix.swift`](../Passable/Model/PassableMix.swift),
the Mac app's own file: the iPhone app compiles that same file, so the two can't drift apart.

Per song the manifest holds, in seconds into the audio: `start` (the blend into it begins), `handover` (it takes over),
`solo` (the blend is over) and `end`, plus title, artist (split from "Artist - Title"), BPM and Camelot key.
Per transition: `begins`, `handover`, `end`, the preset name and what makes it special.


## How it fits together

| | |
|---|---|
| `Model/MixStore` | The library on disk (one folder per mix); unpacks incoming files off the main thread |
| `Model/Player` | `AVAudioPlayer` plus the song map; lock screen, remote commands, interruptions |
| `Model/Receiver` | Multipeer Connectivity: waits for a Mac, asks before accepting, encrypted |
| `Model/Waveform` | Peak outline of a mix (4 per second), cached next to the audio |
| `UI/` | SwiftUI: library, player, track list, waveform, mini player, settings |

On the Mac: `Library/PhoneLink.swift` finds phones and sends; `Model/PhoneMix.swift` turns a planned set into the map;
`SetSession.exportPhoneMix` renders and packs.

## Build

```sh
brew install xcodegen
xcodegen generate && open PassableIos.xcodeproj
```

Signing uses the team in `project.yml` (`DEVELOPMENT_TEAM`); change it if that's not yours. The unit tests
(`PassableIosTests`) cover the file format (including truncated and newer-format files), the skip logic and the waveform.

## Putting it on your iPhone

```sh
Tools/install-on-iphone.sh privat --send     # build, install, launch, then send the sample set
```

Signing needs an Apple ID under Xcode > Settings > Accounts (the team in `project.yml`), and the phone unlocked
with Developer Mode on. After that, Run from Xcode works too.

## Trying it without a Mac set

```sh
# a synthetic 4-song set with real blends, to open on the phone or simulator
swiftc -O Tools/SampleMix/main.swift ../Passable/Model/PassableMix.swift -o /tmp/make-sample-mix
/tmp/make-sample-mix Samples/Sample.passablemix

# send a file to a phone nearby with the Mac app's own PhoneLink
swiftc -O Tools/SendMix/main.swift ../Passable/Model/PassableMix.swift ../Passable/Library/PhoneLink.swift -o /tmp/send-mix
/tmp/send-mix Samples/Sample.passablemix
```

(The simulator can't open files from `~/Documents` with `simctl openurl`; copy the file to `/tmp` first.)

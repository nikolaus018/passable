# Passable for Windows

A native WinUI 3 player for `.passablemix` files: the same sets Passable for iPhone plays, with every transition exactly as
rendered on the Mac. The Mac renders; Windows plays. Nothing is mixed here.

## What you get

- **Library** of mixes (one folder each under `%LOCALAPPDATA%\Passable\Mixes`). Add files with **+** / Ctrl+O, by dragging
  them onto the window, or by double-clicking a `.passablemix` in Explorer. Sending the same set again replaces it.
- **Player** with artwork, BPM and key, a *Mixing into…* strip while a blend plays, a scrubbable waveform coloured by song
  (blue and orange alternate like the Mac's two decks and slide into each other across a transition) and a **track list**
  showing each blend (type and length).
- **Next / Previous** skip between transitions, as on the phone: a skip lands four bars **before** the blend into the next
  song (the Mac's cue point, stored per transition), so the transition is always heard. Previous restarts that lead-in;
  pressed again within three seconds it goes to the one before. Ctrl+→ / Ctrl+←, or the keyboard's media keys.
- Media keys and the Windows volume flyout show the playing *song* with its own length.
- Resumes where you left off, per mix. Space plays and pauses.

## Getting a set onto the PC

In Passable on the Mac, click **iPhone** in the transport bar, choose **Save as File…**, and move the `.passablemix` over
(AirDrop to the iPhone isn't needed: any cloud drive, USB stick or network share will do).

## The file

One continuous AAC render plus a JSON map in a small chunked container (magic `PASSMIX\r\n\x1A\n`, version, `MNFT`
manifest, `AUDI` audio, `END `; unknown chunks are skipped). The layout is documented in
[`Passable/Model/PassableMix.swift`](../Passable/Model/PassableMix.swift); [`Model/PassableMix.cs`](PassableWin/Model/PassableMix.cs)
is its port, skip logic included. The tests read `ios/Samples/Sample Set.passablemix`, the file the phone app's own tests use.

## Build and install

Needs the .NET 8 SDK on Windows 10 (1809) or later. No Visual Studio required.

```powershell
powershell -ExecutionPolicy Bypass -File windows\install.ps1   # publish, Start menu shortcut, .passablemix association
dotnet test windows\PassableWin.Tests                           # the format and the skip logic
dotnet run --project windows\PassableWin -p:Platform=x64        # just run it
```

The install is self-contained and per-user (`%LOCALAPPDATA%\Programs\Passable`); no admin rights are needed.

## How it fits together

| | |
|---|---|
| `Model/PassableMix.cs` | The file format, manifest types and skip logic (no UI dependencies; compiled by the tests too) |
| `Model/MixStore.cs` | The library on disk; unpacks incoming files off the UI thread; remembers positions |
| `Model/Player.cs` | `MediaPlayer` plus the song map; media keys (SMTC) |
| `Model/Waveform.cs` | Peak outline of a mix (4 per second, decoded with Media Foundation), cached beside the audio |
| `MainWindow.xaml(.cs)` | Library, player, waveform, track list |

# Mac Recorder

One shortcut for screen recording on macOS, with a round camera bubble and a live mic switch.

Press **Cmd+Shift+9** and a small panel opens with three buttons:

- **Record / Stop** — starts or stops the screen recording.
- **Mic on / off** — turns your microphone on or off, also during a recording.
- **Camera on / off** — shows your camera in a round bubble in the top-left corner.

While you record, the panel hides. Press the shortcut again to bring it back and stop.
The panel never appears in the video. The camera bubble does.
The camera is on only while the panel is open or a recording runs.

Videos are saved to `~/Movies/Recordings` as `.mp4`.

## Install

You need macOS 14 or newer and the Xcode command line tools (`xcode-select --install`).

```bash
git clone https://github.com/RotemElya/mac-recorder.git
cd mac-recorder
./install.sh
```

The script builds the app, copies it to `/Applications` and starts it at login.
macOS asks for three permissions: **Screen Recording**, **Microphone** and **Camera**.
After you allow Screen Recording, quit the app (right-click the menu bar dot, then Quit) and open it again.

## Change the shortcut

```bash
defaults write dev.macrecorder.app hotkey -string "ctrl+option+r"
```

Then quit and reopen the app. Use `cmd`, `shift`, `option`, `ctrl` plus one letter, digit or `space`.

## Remove

```bash
./uninstall.sh
```

## Notes

- The app is signed locally, not with an Apple developer account. Build it on your own Mac with `install.sh`. A downloaded copy is blocked by macOS.
- Only the microphone is recorded, not the sound of the system.

## License

MIT

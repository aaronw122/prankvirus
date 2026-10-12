# PrankVirus

A macOS menu-bar prank with two effects, each on its own hotkey. Use it on your
own Mac or with the owner's agreement.

| Hotkey | Effect |
|---|---|
| **Control + Option + Command + A** | Glitch: the screen shakes, splits into red/green/blue copies and its colours scramble |
| **Control + Option + Command + S** | Shift: the whole screen, menu bar and Dock included, slides 300 points right |

- Press the same hotkey again to turn an effect off; the other hotkey swaps effects.
- Each effect turns itself off after **30 seconds**.
- No permission prompts: no Screen Recording, no Accessibility.
- The eye icon in the menu bar has both toggles and **Quit**.
- Mouse clicks still land where the real windows are, not where they appear.

## Install

```bash
brew install aaronw122/tap/prankvirus
brew services start prankvirus
```

`brew services start` also starts it at every login. To stop it now and at login:

```bash
brew services stop prankvirus
```

To remove it:

```bash
brew uninstall prankvirus
```

If AsciiVisor is installed too, stop it first (`brew services stop asciivisor`):
both use Control + Option + Command + A, and only one app can own a hotkey.

## Build from source

Requires macOS 14 or later and a Swift toolchain (the Command Line Tools are enough).

```bash
swift build -c release
.build/release/prankvirus
```

`kill -USR1 <pid>` toggles the glitch and `kill -USR2 <pid>` the shift.

## How it works

Each effect is a borderless window above the menu bar holding private
`CABackdropLayer`s, the layer `NSVisualEffectView` is built on. WindowServer
samples everything behind the window and runs it through private Core Animation
filters, so the screen's pixels never reach this process and macOS does not ask
for Screen Recording.

- **Shift:** one `displacementMap` filter with a constant offset.
- **Glitch:** a port of `reference/03-shaky.metal`. A GPU-generated jitter map
  drives `displacementMap`, `chromaticAberration` splits the colour channels,
  and a 256³ lookup table applies the shader's hue remap. Four masked layers
  rebuild the shader's wrap-around at the screen edges.

The glitch matches the original shader across the screen except at the two
wrap seams (10% in from the left and bottom), where the colour fringes smear
instead of wrapping.

These are private Core Animation APIs. They may change in any macOS release; if
they are missing, the app logs it and does nothing.

## Licence

MIT. See [LICENSE](LICENSE), which also covers the webgl-noise routines in
`reference/common.metal`.

# PrankVirus

A macOS prank with two effects, each on its own hotkey. Use it on your own Mac
or with the owner's agreement.

| Hotkey | Effect | Preview |
|---|---|---|
| **Control + Option + Command + G** | Glitch: the screen shakes, splits into red/green/blue copies and its colours scramble | <img src="docs/glitch.png" alt="Glitch effect: the screen split into shaking colour copies" width="360"> |
| **Control + Option + Command + S** | Shift: the whole screen, menu bar and Dock included, slides 300 points right; the uncovered strip on the left goes black | <img src="docs/shift.png" alt="Shift effect: the screen pushed 300 points right with a black strip on the left" width="360"> |

- Press the same hotkey again to turn an effect off; the other hotkey swaps effects.
- Effects stay on until toggled off, unless started with a timeout (see below).
- Mouse clicks still land where the real windows are, not where they appear.

## install

```bash
brew install aaronw122/tap/prankvirus
```

## how to use

### check that the keys actually work

```bash
## run: 
prankvirus check
```

`prankvirus check` asks you to press each hotkey and confirms the press reaches
PrankVirus on this Mac. It also flags a clashing macOS system shortcut or key remappers.  

**if you don't check this, you could enable it on your friends computer, and it might be very difficult for them to turn off.**

### activate prank

```bash
## run: 
prankvirus start
```

`prankvirus start` runs it in the background. you can toggle on and off with the key mappings: 
1. **Control + Option + Command + G** for glitch
2. **Control + Option + Command + S** for shift

if you want to specify how much time you want it to run, instead use a number following the start.
(this is an additional safeguard if you are worried the keymappings might not work)

any number of minutes works, including decimals:

```bash
prankvirus start -30     # 30 minutes
prankvirus start -1.5    # 90 seconds
prankvirus start -120    # 2 hours
```

### stopping prank

```bash
prankvirus stop
```

## removing the package:

```bash
prankvirus stop
brew uninstall prankvirus
```

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

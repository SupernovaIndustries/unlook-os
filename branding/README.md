# Branding — Supernova / Unlook

```
branding/assets/background.png   boot splash (Plymouth), 2560×1440, Supernova logo already centred
branding/assets/logo.png         Supernova Industries logo (colour, transparent) — README / docs
```

The pi-gen stage `04-branding` installs the Plymouth theme `unlook` when
`background.png` exists (and `BRANDING=auto` in `config/unlook-os.conf`): the
image is scaled to cover the screen and centred; the margin colour matches the
artwork's dark teal. Without it the image boots with a plain console.

| File | Format | Notes |
| --- | --- | --- |
| `background.png` | PNG, ≤ 8 MiB | 16:9 recommended; other aspect ratios are cropped at the edges, so keep the logo in the centre |
| `logo.png` | PNG with alpha | not drawn on the splash (the background already carries the mark) |

- Shown on HDMI/DSI only; the serial console stays a plain boot log.
- The firmware rainbow is disabled (`disable_splash=1`); the firmware cannot show
  a custom image, so the splash appears when the initramfs starts (≈ 2 s).
- Files are checked at build time (PNG signature, size).

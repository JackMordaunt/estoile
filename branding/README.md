# branding

leita's mark and the hero lockup, each in a light and a dark version, exported
from the logo tool, which keeps the candidates the found cell was chosen from.
The window draws the same mark from `gui/mark`.

| file | what it is |
|------|------------|
| `mark-{light,dark}.{svg,png}` | the found cell alone: the sunburst with the find lit, transparent, 1024 px PNG |
| `hero-{light,dark}.{svg,png}` | mark and the leita wordmark, for the README |
| `icon.{svg,png}` | the light mark on a rounded `#f0eee8` plate in Apple's 824 px grid, 1024 px PNG: Leita.app's icon, which `just bundle` makes `Leita.icns` from. The plate keeps the dark ink legible on a dark Dock, where the bare mark would vanish; `icon.png` is `rsvg-convert -w 1024 icon.svg` |
| `demo.mp4` | the window scanning the made-up disk (`LEITA_SYNTHETIC`) in all three views, light then dark: 2560×1640 (1280×820 at 2×), 60 fps, H.264 |
| `demo-poster.png` | the demo's frame at 13.5 s, which the README shows and links to the video |

Ink is `#1c1b1a` on light, `#f0eee8` on dark; the find is sea, `#0e7490`, in
both. The wordmark is JetBrains Mono Bold, named rather than embedded, so a
renderer without it falls back to its own monospace.

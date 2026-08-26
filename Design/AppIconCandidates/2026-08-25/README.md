# PasteBuddy app icon candidates — 2026-08-25

These four raster concepts were generated independently with the built-in image generation workflow. They are selection masters, not production Icon Composer assets. The existing app icon and asset catalog were not replaced.

## Candidate overview

| # | Direction | Visual read | 24–64 px check | Light/dark check |
| --- | --- | --- | --- | --- |
| 1 | Folded P | Two graphite content cards joined by a coral folded return | The `P` and coral return remain legible at 24 px | Clean edges; the graphite body loses some contrast on the dark background |
| 2 | Pocket Stack | An open forest-teal pocket holding two content cards | Pocket and two-card crown remain recognizable at 24 px | Clean and readable on both backgrounds |
| 3 | Paste Loop | A continuous navy ribbon with a chartreuse inner face | Loop and crossover survive at 24 px | Clean edges; navy has lower contrast on dark, and the form can read as an infinity loop |
| 4 | Snap Tiles | Two offset tiles joined by a precise interlock | Two-tile silhouette survives at 24 px; amber interlock becomes secondary | Clean and readable; rear graphite tile has lower contrast on dark |

The first four columns of `small-size-contact-sheet.png` are 24, 32, 48, and 64 px respectively. `background-contact-sheet.png` shows checkerboard, light, and dark backgrounds respectively.

## Transparency verification

All masters are 1254 × 1254, 8-bit RGBA PNG files. ImageMagick alpha extraction reported both fully transparent and fully opaque pixels for every master:

| Direction | Alpha minimum | Alpha maximum | Mean alpha (16-bit scale) |
| --- | ---: | ---: | ---: |
| Folded P | 0 | 65535 | 21031.6 |
| Pocket Stack | 0 | 65535 | 30956.4 |
| Paste Loop | 0 | 65535 | 26358.3 |
| Snap Tiles | 0 | 65535 | 28540.6 |

Checkerboard, light, and dark composites were visually inspected. No baked white rectangle or obvious light fringe was found. Sub-1% alpha residue outside each visible silhouette was normalized to fully transparent; the resulting non-zero alpha bounds retain comfortable canvas padding. The `preview-*.png` files are flattened QA previews; each `master.png` and every file under `sizes/` retains alpha.

## Final generation prompts

### 1. Folded P

```text
Use case: logo-brand
Asset type: transparent 1:1 master concept for a macOS, iOS, and iPadOS productivity app icon
Primary request: Design “Folded P”, a new abstract geometric P constructed from exactly two overlapping content cards and one precise folded return. The negative space should subtly imply copy, collection, and paste without using arrows. It must not resemble the existing PasteBuddy blue-purple gradient P.
Scene/backdrop: fully transparent canvas; actual alpha transparency everywhere outside the symbol; no background tile, no rounded-square container, no circle, no environmental scene, no floor, no shadow outside the mark
Subject: one centered, dominant, compact silhouette; the two cards merge into a memorable P-like glyph with generous intentional negative space and thick geometry that remains readable at 24 px
Style/medium: polished vector-friendly app icon concept, crisp geometric edges, restrained contemporary Silicon Valley productivity-tool branding
Composition/framing: centered with comfortable optical padding; critical form inside the safe center; square 1:1 image
Color palette: deep graphite body with a single warm coral-red folded accent; solid colors or only extremely subtle material shading within the mark, never a decorative gradient
Materials/textures: restrained satin material, one overlap cue only, no gloss, no glow
Text: none
Constraints: genuine transparent PNG alpha; high contrast; unique silhouette; readable in grayscale and at 24, 32, 48, and 64 px; no pre-baked system mask; no exterior drop shadow
Avoid: letters rendered as typography, clipboard cliché, paperclip, checkmark, AI sparkle, badges, UI screenshot, tiny details, thin strokes, neon, blue-purple gradient, white backing, checkerboard drawn into the image, watermark
```

### 2. Pocket Stack

```text
Use case: logo-brand
Asset type: transparent 1:1 master concept for a macOS, iOS, and iPadOS productivity app icon
Primary request: Design “Pocket Stack”, a distinctive open pocket receiving exactly two offset content cards, expressing effortless collection and quick retrieval of copied content. The pocket opening and card overlap must form one memorable, compact silhouette—not a generic clipboard, folder, inbox tray, or wallet.
Scene/backdrop: fully transparent canvas; actual alpha transparency everywhere outside the symbol; no background tile, no rounded-square container, no circle, no scene, no floor, no exterior shadow
Subject: one centered symbol made from a softly angular open pocket plus two broad cards; the front pocket lip creates a crisp upward notch and the rear cards create a controlled stepped crown; use large shapes only
Style/medium: polished vector-friendly app icon concept, precise geometric construction with friendly radii, restrained Silicon Valley productivity-tool branding
Composition/framing: centered with optical balance and comfortable padding; square 1:1 image; keep critical shape in safe center
Color palette: dark forest-teal pocket with one vivid mint card and one warm ivory card; limited solid palette, no rainbow or random gradient
Materials/textures: subtle matte depth from one overlap and one inner edge only; no gloss, no glow
Text: none
Constraints: genuine transparent PNG alpha; unique black-and-white silhouette; high contrast; readable in grayscale and at 24, 32, 48, and 64 px; no pre-baked system mask; no exterior drop shadow
Avoid: clipboard cliché, folder tab, download arrow, checkmark, paperclip, document text lines, AI sparkle, badges, UI screenshot, micro-details, thin outlines, neon, blue-purple palette, white backing, checkerboard drawn into image, watermark
```

### 3. Paste Loop

```text
Use case: logo-brand
Asset type: transparent 1:1 master concept for a macOS, iOS, and iPadOS productivity app icon
Primary request: Design “Paste Loop”, one continuous broad ribbon that travels through three states—input, held center, output—using a compact looping path and intentional negative space. It should suggest copy, temporary memory, and reuse without arrows, letters, infinity-symbol cliché, or clipboard imagery.
Scene/backdrop: fully transparent canvas; actual alpha transparency everywhere outside the symbol and in its intentional openings; no background tile, no rounded-square container, no circle, no scene, no floor, no exterior shadow
Subject: a single centered continuous ribbon forming an asymmetric rounded loop with one precise crossover; the silhouette should feel engineered, compact, and unmistakable, with thick widths and only two negative-space openings
Style/medium: vector-friendly abstract app mark, crisp geometric construction, sophisticated restrained Silicon Valley developer-tool branding
Composition/framing: centered and optically balanced, generous clear padding, critical geometry inside safe center, square 1:1 image
Color palette: dark midnight navy ribbon with a single electric chartreuse inner face revealed only at the crossover; mostly solid color, no decorative gradient
Materials/textures: one folded crossover cue, subtle matte depth only, no glass, no glow, no gloss
Text: none
Constraints: genuine transparent PNG alpha; strong unique black-and-white silhouette; high contrast; readable in grayscale and at 24, 32, 48, and 64 px; no pre-baked platform mask; no exterior drop shadow
Avoid: infinity sign, recycle arrows, refresh icon, chain link, letter P, paperclip, clipboard, checkmark, AI sparkle, badges, UI screenshot, tiny details, thin strokes, neon glow, blue-purple gradient, white backing, checkerboard drawn into image, watermark
```

### 4. Snap Tiles

```text
Use case: logo-brand
Asset type: transparent 1:1 master concept for a macOS, iOS, and iPadOS productivity app icon
Primary request: Design “Snap Tiles”, two offset rounded square content tiles joined through one precise interlocking negative-space bite, expressing copied content that snaps into a reusable collection. The interlock must be the distinctive feature, not a generic overlapping-squares copy icon.
Scene/backdrop: fully transparent canvas; actual alpha transparency everywhere outside the symbol and through its negative-space cutout; no background tile, no outer rounded-square container, no circle, no scene, no floor, no exterior shadow
Subject: exactly two thick, softly rounded tiles with clearly different positions; one clean geometric notch on each creates a shared dovetail-like negative space at their overlap; one dominant compact silhouette, no extra parts
Style/medium: polished vector-friendly app icon concept, highly precise minimal geometry, restrained modern Silicon Valley productivity-tool branding
Composition/framing: centered with strong optical balance and generous padding, slightly diagonal energy, critical form inside safe center, square 1:1 image
Color palette: near-black graphite rear tile and saturated cobalt front tile with one small warm amber inner edge at the interlock; limited solid palette, no decorative gradient
Materials/textures: flat-to-subtle satin, a single overlap depth cue, crisp edges, no gloss, no glow
Text: none
Constraints: genuine transparent PNG alpha; unique black-and-white silhouette; high contrast; readable in grayscale and at 24, 32, 48, and 64 px; no pre-baked platform mask; no exterior drop shadow
Avoid: generic duplicate/copy symbol, puzzle-piece lobes, chain link, clipboard, checkmark, letter P, arrows, AI sparkle, badge, UI screenshot, tiny details, thin strokes, neon, blue-purple gradient, white backing, checkerboard drawn into image, watermark
```

## Production note

Once a direction is selected, reconstruct it as editable vector layers before Icon Composer or store export. Do not submit these generated raster concepts as the final production asset without that cleanup and platform-specific export pass.

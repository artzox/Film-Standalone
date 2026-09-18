# Contributing a Film LUT to Film-Standalone

Thanks for wanting to add a stock! Emulation LUTs are one of the highest-value contributions to this project. This guide covers what a clean LUT PR looks like so it drops into the pipeline without a round of back-and-forth.

The single most important thing to get right is **which color space the LUT is authored in and where in the pipeline it's applied** — see section 2. Everything else is mechanical.

---

## 1. Format & file layout

> ⚠️ **Fill in (repo-specific):**
> - **Storage format:** _e.g. PNG strip / `.cube` / baked header_
> - **Dimensions & layout:** _e.g. 33³ → 1089×33 horizontal strip, 8-bit_
> - **Repo location:** _e.g. `/textures/luts/`_
> - **Naming convention:** _e.g. `film_kodak_e200.png`, lowercase, stock family prefix_

Match the existing LUTs bit-for-bit on dimensions and layout — the shader samples them at fixed coordinates, so an off-size strip will read garbage.

---

## 2. Color space & pipeline stage (read this one)

The film emulation is **not** a plain post-process sRGB grade. It runs in an HDR/scRGB path, so a LUT baked in the wrong space will sit on the wrong side of the tone map and look crushed, blown, or desaturated even if it looks perfect in a standard LUT previewer.

> ⚠️ **Fill in (repo-specific):**
> - **Working space the LUT is sampled in:** _e.g. linear / a specific log encoding / display-gamma_
> - **Pipeline stage:** _e.g. applied before the HDR tone-map, after grain/halation, on the linearized signal_

**Practical takeaway for contributors:** author/grade your LUT in the working space above, not in sRGB gamma. If you build it against a standard sRGB reference, convert it into the correct space before submitting, or flag that it still needs converting.

Include at least one **neutral ramp / grey-patch test frame** so the maintainer can verify neutrals stay neutral through the correct stage.

---

## 3. Reversal vs negative stocks

E200 (and other slide/reversal stocks) behave differently from the negative films that dominate most LUT packs:

- Higher contrast, denser blacks, more saturation
- **Narrower latitude** — highlights clip harder and sooner
- Don't "correct" it toward the flatter, low-contrast look of a negative stock; the punch *is* the stock

The thing to watch in HDR: because reversal stocks are already high-contrast, confirm the LUT doesn't push highlights into clipping once it's on the correct side of the tone map.

---

## 4. What to include in the PR

- **The LUT file(s)** in the format/location from section 1.
- **Provenance note:** how the LUT was created (own profiling of a scanned reference, hand-graded, derived from a public dataset, etc.).
- **Licensing:** LUT data derived from someone else's commercial film-emulation product can't be merged into a public repo without clear permission. Self-authored / open-source-derived is clean.
  > ⚠️ **Fill in (repo-specific):** _license the project accepts LUT contributions under._
- **Before/after screenshots** on 2–3 reference frames — ideally one neutral/grey, one with skin tones, one with saturated color.
- **Which shader version** you tested against.

---

## 5. Testing checklist

- [ ] Loads without errors and appears in the menu
- [ ] Neutral input stays neutral where expected
- [ ] Verified in **both** the SDR and HDR output paths
- [ ] No new clipping or banding introduced
- [ ] Screenshots and provenance/license note included

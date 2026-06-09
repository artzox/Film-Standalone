# Film-Standalone Changelog

## [1.0.2] — 2026-06

### New Features

- **Gamut expansion** (`ENABLE_GAMUT_EXPAND=1`) — same implementation as CRT-Standalone. Expands Rec.709 chrominance toward Rec.2020 within the existing HDR container. Three methods: Oklab, ICtCp (recommended), darktable UCS 2022. All three pipelines supported. Neutral and skin tone protection sliders. Runs as a final pass after all film processing

---

## [1.0.1] — 2026-05

### Improvements

- **Catmull-Rom bicubic resampling** — new default lens resampling (`LENS_QUALITY=1`). Sharp bicubic quality via 9 bilinear hardware samples, significantly cheaper than the previous Lanczos2 default. Lanczos2 still available at `LENS_QUALITY=2`
- **`LENS_QUALITY` preprocessor** — three-level quality gate: `0`=bilinear (fastest), `1`=Catmull-Rom default, `2`=Lanczos2 (maximum quality)
- **Edge softness optimised** — precomputed separable weights replace per-tap `exp()` calls; early exit at screen centre pixels where effect is zero
- **Performance** — Lens pass cost substantially reduced at 4K from the above changes

### Bug Fixes

- **CA on Highlights restored** — `film_lens_ca_highlight` slider was missing from stable build. Chromatic aberration now scales correctly with pixel luminance, independent of the base CA slider. Works with base CA at zero

---

## [1.0.0] — 2026-05

Initial release.

### Features

- **14 film stock profiles** — Kodak Vision3 500T+2383, 250D+2383, 2383 Print, Fuji Velvia 50, Kodak Portra 400, Kodachrome 25, Fuji Eterna 500, Kodak Vision3 200T+2383, Fuji Eterna Vivid 160T, Fuji Eterna 250D, Kodak Ektachrome 100, Kodak Double-X, Cinestill 800T, plus Neutral
- **Acutance** — chemical edge enhancement modelling development adjacency effects. Makes film look simultaneously sharp and organic
- **Halation** — red-biased Gaussian spread from bright areas, physically motivated by anti-halation backing layer physics
- **Black lift control** — per-profile shadow density. Set to 0.0 for OLED displays to preserve deep blacks
- **Anamorphic grain aspect ratio** — horizontal grain stretch for anamorphic lens character
- **Hex lens flare ghosts** — direct port of HexLensFlare algorithm at reduced resolution. Ghost squeeze slider for crescent/oval shapes
- **Anamorphic streak** — horizontal blue streak from cylindrical anamorphic lens elements
- **Ambient bloom with adaptation** — port of AmbientLight `PS_AL_DetectHigh` colour treatment and scene luminance adaptation. Reduces bloom in bright scenes, boosts in dark
- **Bokeh highlight spreading** — 19-tap hexagonal kernel on bright pixels above threshold
- **Depth of Field** — independent `ENABLE_DOF` gate, requires depth buffer. Petzval swirl on bokeh kernel
- **Lens presets** — 8 lens distortion profiles (35mm, 50mm, 85mm, 28mm, Anamorphic 2x, Petzval, Vintage 58mm)
- **Gate weave and film breathing**
- **VHS artefacts** — chroma smear, tracking, head switch, dropout, noise
- **Composite transfer artefacts**
- **Full colour grading** — lift/gain/gamma (RGB + master), colour temperature, saturation, exposure, contrast
- **HDR pipeline support**
- **All features independently gated** via preprocessor defines — only enabled features cost GPU time

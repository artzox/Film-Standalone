# Film-Standalone

**Version 1.0.0**

A cinematic film emulation shader for ReShade. Simulates the full photochemical film pipeline — colour negative response, print stock grading, optical grain, halation, lens optics, and camera artefacts. Designed for use across a broad game library with per-game presets.

---

## Requirements

- ReShade 5.0 or later
- DirectX 10/11/12, Vulkan, or OpenGL

---

## Installation

1. Copy `Film-Standalone.fx` to your ReShade `Shaders` folder
2. Enable the technique in the ReShade overlay
3. Enable features via **Preprocessor Definitions** (see below)

---

## Preprocessor Definitions

All features are disabled by default. Enable only what you need to keep the UI clean and avoid unused passes.

| Define | Values | Description |
|---|---|---|
| `ENABLE_FILM_STOCK` | 0 / 1 | Film colour profiles, halation, film curve, acutance |
| `ENABLE_GRAIN` | 0 / 1 | Resolution-independent film grain |
| `ENABLE_LENS` | 0 / 1 | Lens distortion, vignette, chromatic aberration, bokeh |
| `ENABLE_DOF` | 0 / 1 | Depth of Field — independent of ENABLE_LENS, requires depth buffer |
| `ENABLE_FLARE` | 0 / 1 | Hex lens flare ghosts and ambient bloom |
| `ENABLE_GATE` | 0 / 1 | Gate weave and film breathing |
| `ENABLE_TRANSFER` | 0 / 1 | Composite artefacts and edge enhancement |
| `ENABLE_VHS` | 0 / 1 | VHS chroma smear, tracking noise, dropout |

**Flare quality preprocessors** (when `ENABLE_FLARE=1`):

| Define | Default | Description |
|---|---|---|
| `FLARE_DOWNSCALE` | 4 | Resolution divisor for flare passes (2=half, 4=quarter res) |
| `FLARE_BLUR_SAMPLES` | 16 | Blur taps per pass — more = smoother hexagon |

**Depth of Field preprocessors** (when `ENABLE_DOF=1`):

| Define | Description |
|---|---|
| `FILM_DEPTH_REVERSED` | Define if your game uses a reversed depth buffer |

---

## Settings Reference

### Pipeline

| Setting | Description |
|---|---|
| Display Peak Brightness (nits) | Set to your display's peak brightness for correct HDR scaling |
| Shadow Gamma | Shadow curve adjustment for HDR displays |

---

### Film Stock (`ENABLE_FILM_STOCK=1`)

**Colour controls:**

| Setting | Description |
|---|---|
| Exposure | Overall exposure in stops |
| Film Contrast | S-curve contrast characteristic of film stocks |
| Saturation | Colour saturation |
| Brightness | Linear brightness |
| Shadow Lift | Lift dark areas |
| Highlight Roll-off | Compress highlights, simulates film shoulder |

**Profile:**

| Setting | Description |
|---|---|
| Film Stock | Select from 14 stock profiles (see below) |
| Profile Strength | Blend between neutral and selected stock (0=off, 1=full) |
| Black Lift Amount | Controls shadow density of film print stock. Set to 0 for OLED displays to preserve deep blacks |
| Acutance | Chemical edge enhancement from development adjacency effects — makes film look simultaneously sharp and organic. 0.1–0.2 = fine grain stocks, 0.3–0.5 = faster stocks |
| Film Base Density | Minimum density of the film base (orange/grey tint) |
| Colour Process | Additional colour space treatment |

**Halation:**

| Setting | Description |
|---|---|
| Halation | Red-biased glow from bright areas scattering back through the emulsion layers. Characteristic of film, especially fast stocks |
| Halation Radius | Spread radius of halation glow |

#### Film Stock Profiles

| # | Stock | Character |
|---|---|---|
| 0 | Neutral | No colour transform |
| 1 | Kodak Vision3 500T + 2383 | Tungsten cinema negative + Hollywood print stock. Warm shadows, rich midtones |
| 2 | Kodak Vision3 250D + 2383 | Daylight cinema negative + print. Cooler, modern blockbuster look |
| 3 | Kodak 2383 Print only | Pure print stock grading — warm, slightly desaturated |
| 4 | Fuji Velvia 50 | Vivid saturated slide film. Punchy colours, deep blues |
| 5 | Kodak Portra 400 | Pastel portrait negative. Flattering skin tones, lifted shadows |
| 6 | Kodachrome 25 | Warm vintage slide. Red/orange push, high contrast |
| 7 | Fuji Eterna 500 | Desaturated cool cinema. Clinical, analytical |
| 8 | Kodak Vision3 200T + 2383 | Clean modern tungsten cinema. Less grain than 500T |
| 9 | Fuji Eterna Vivid 160T | Painterly soft highlights, mid-saturation boost. Discontinued 2013 |
| 10 | Fuji Eterna 250D | Cool clean daylight cinema. Neutral with slight blue cast |
| 11 | Kodak Ektachrome 100 | Punchy blues and cyans. Vivid greens, slide film character |
| 12 | Kodak Double-X | B&W noir emulation. High contrast, warm sepia tint |
| 13 | Cinestill 800T | Vision3 500T with remjet removed. Extreme halation — raise Halation to 0.6+ for full character |

---

### Film Grain (`ENABLE_GRAIN=1`)

| Setting | Description |
|---|---|
| Grain Intensity | Overall grain strength |
| Grain Aspect Ratio | Horizontal stretch for anamorphic grain character. 1.0 = spherical, 1.5–2.0 = anamorphic |
| Grain Size | Size of grain clusters |
| Grain in Shadows | Grain presence in dark areas |
| Grain Colour | Colour vs monochrome grain |
| Animate Grain | Frame-to-frame variation |

---

### Lens (`ENABLE_LENS=1`)

**Distortion:**

| Setting | Description |
|---|---|
| Lens Distortion | Barrel/pincushion distortion amount. Positive = barrel, negative = pincushion |
| Lens Preset | Preset lens profiles with characteristic distortion curves |
| Zoom | Scale image after distortion to fill screen. 1.005 typically hides edge artefacts at moderate distortion |
| Edge Fill Mode | How to fill areas exposed by barrel distortion: Clamp, Mirror, or Stretch |

**Optics:**

| Setting | Description |
|---|---|
| Chromatic Aberration | Lateral colour fringing — R/B channel separation |
| CA on Highlights | Additional CA boost on bright areas |
| Vignette | Optical corner darkening |
| Edge Softness | Optical field curvature — centre sharp, edges soft |

**Bokeh:**

| Setting | Description |
|---|---|
| Bokeh Highlight Threshold | Luminance above which pixels receive bokeh spreading. 0.7 = bright highlights only |
| Bokeh / Edge Blur Radius | 19-tap hexagonal kernel blur on bright highlights above threshold. Simulates fast lens out-of-focus character |

---

### Depth of Field (`ENABLE_DOF=1`)

Requires a working depth buffer. Verify with the **Show Depth Debug** option — one side should show a depth gradient. Most games expose depth to ReShade; some do not.

**Setup:**
1. Enable **Show Depth Debug** — the left half shows raw depth (dark = near, bright = far)
2. Read the depth value at your subject's distance
3. Set **Focus Depth** to that value
4. Disable debug, tune Focus Range and Max Blur

| Setting | Description |
|---|---|
| Focus Depth | Depth value of the sharp plane (0=near, 1=far) |
| Focus Range | Depth band that stays sharp. 0.01 = very shallow, 0.3 = deep |
| Max Blur (pixels) | Blur radius for fully out-of-focus areas |
| Near Blur Multiplier | Foreground blur strength relative to background |
| Petzval Swirl Strength | Rotates the DOF blur kernel radially — swirls only the bokeh, not the sharp image |
| Show Depth Debug | Split-screen depth visualisation for setup |

---

### Lens Flare (`ENABLE_FLARE=1`)

Implements the HexLensFlare algorithm — hexagonal ghost blobs at reflected positions through screen centre, formed by three directional blur passes. All flare passes run at reduced resolution (`FLARE_DOWNSCALE`) for minimal performance cost.

**Hex Ghost:**

| Setting | Description |
|---|---|
| Flare Intensity | Overall ghost intensity. Screen blend — cannot overexpose |
| Brightness Threshold | Luminance above which sources generate ghosts. 0.99 = sun disc only, 0.80 = bright highlights |
| Flare Scale | Size of the hexagonal ghost pattern. Match to HexLensFlare `uScale` for reference |
| Ghost Squeeze | Squeezes X axis of blur directions — turns symmetric hexagon into oval or crescent shape. 1.0 = hex, 0.3–0.5 = crescent |
| Ghost Colour 1–4 | Tint for each of the four ghost elements at different reflection distances and scales |

**Anamorphic Streak:**

| Setting | Description |
|---|---|
| Anamorphic Streak | Horizontal blue streak from cylindrical anamorphic lens elements. 0 = spherical lens only |

**Ambient Bloom:**

| Setting | Description |
|---|---|
| Bloom Intensity | Intensity of the ambient bloom. Uses AmbientLight's colour-preserving algorithm |
| Bloom Threshold | Suppresses bloom from darker areas |
| Bloom Adaptation | Scene luminance adaptation — reduces bloom in bright scenes, boosts in dark. Matches AmbientLight's adaptation behaviour |

---

### Gate (`ENABLE_GATE=1`)

| Setting | Description |
|---|---|
| Gate Weave | Frame position jitter simulating film gate instability |
| Film Breathing | Subtle periodic zoom variation from gate pressure changes |

---

### Transfer (`ENABLE_TRANSFER=1`)

| Setting | Description |
|---|---|
| Edge Enhancement | Simulates the sharpening characteristic of certain transfer processes |
| Composite Artefacts | Colour bleeding and bandwidth limiting of composite video transfer |

---

### VHS (`ENABLE_VHS=1`)

| Setting | Description |
|---|---|
| Chroma Smear | Horizontal colour bleeding from VHS chroma bandwidth limitation |
| Tracking | Horizontal displacement noise from VHS tracking errors |
| Head Switch | Bottom-of-frame disturbance from VHS head switching |
| Dropout | Random pixel dropouts from tape degradation |
| Noise | Overall tape noise level |

---

## Colour Grading Controls

Available regardless of which features are enabled:

| Category | Setting | Description |
|---|---|---|
| Colour Grading | Lift | Shadow colour offset (RGB + master) |
| Colour Grading | Gain | Highlight colour multiplier (RGB + master) |
| Colour Grading | Gamma | Midtone gamma (RGB + master) |
| Colour Grading | Colour Temperature | Warm/cool shift |
| Colour Grading | Film Aspect | Aspect ratio override |

---

## Performance Notes

- All features are off by default — only enabled features cost GPU time
- ENABLE_FLARE: flare passes run at 1/FLARE_DOWNSCALE² resolution (default 1/16th pixel count)
- ENABLE_GRAIN: two passes at full resolution
- ENABLE_LENS: single pass at full resolution; bokeh 19-tap kernel only fires on pixels above threshold
- ENABLE_DOF: requires depth buffer; adds two passes
- ENABLE_FLARE bloom: 8 passes at 1/256th resolution + one full-res blend — very low cost

---

## Known Limitations

- `ENABLE_DOF` requires a working depth buffer. Not all games expose the depth buffer to ReShade
- VRR (variable refresh rate) may affect gate weave timing
- Film stock colour matrices are artistic approximations based on published technical data, not spectrophotometric measurements
- Cinestill 800T halation character requires `Halation` slider set to 0.6+ manually

---

## Algorithms and References

- **Film stock profiles** — colour matrices derived from published Kodak and Fujifilm technical datasheets
- **Acutance** — Laplacian edge enhancement modelling chemical development adjacency effects
- **Halation** — red-biased Gaussian spread, physically motivated by anti-halation backing layer physics
- **Hex lens flare** — direct port of HexLensFlare by its original author, operating at reduced resolution
- **Ambient bloom** — port of AmbientLight (Ganossa), specifically the `PS_AL_DetectHigh` colour treatment and 5-tap separable Gaussian, without external texture dependencies. Scene luminance adaptation ported from the AL adaptation algorithm

---

## Changelog

### 1.0.0 — 2026-05
Initial release.

- 14 film stock profiles (Kodak Vision3, Fuji Eterna, Kodachrome, Double-X, Cinestill and more)
- Acutance (chemical edge enhancement)
- Anamorphic grain aspect ratio
- Black lift control (set to 0 for OLED)
- Halation with red-biased physics
- Hex lens flare ghosts with ghost squeeze for crescent/oval shapes
- Ambient bloom with scene luminance adaptation (AmbientLight algorithm)
- Anamorphic streak
- Bokeh highlight spreading (19-tap hex kernel)
- Depth of Field with Petzval swirl (independent ENABLE_DOF gate)
- Gate weave, film breathing
- VHS artefacts
- Composite transfer artefacts
- Full colour grading (lift/gain/gamma, colour temperature)
- HDR pipeline support

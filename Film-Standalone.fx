#include "ReShade.fxh"

/*
╔══════════════════════════════════════════════════════════════════╗
║  Film-Standalone.fx                                              ║
║  Cinematic film medium emulation shader for ReShade              ║
║                                                                  ║
║  Three-layer architecture:                                       ║
║    Layer 1 — Film Stock  (colour profile, halation, film curve)  ║
║    Layer 2 — Lens        (distortion, vignette, CA, aberration)  ║
║    Layer 3 — Transfer    (composite, VHS, tracking, dropout)     ║
║                                                                  ║
║  All features default off. Enable via preprocessor defines.      ║
║  Compatible with HDR pipeline (PIPELINE=1/2).                    ║
║                                                                  ║
║  Copyright (C) 2025 Artzox                                       ║
║  Grain system inspired by Marty McModding METEOR (independent    ║
║  reimplementation using Box-Muller / Poisson variance approach)  ║
║  Licensed under GPL v2+                                          ║
╚══════════════════════════════════════════════════════════════════╝

    Preprocessor gates (set in ReShade UI → Preprocessor Definitions):

    ENABLE_FILM_STOCK   0/1   Film colour profile, halation, film curve
    ENABLE_GRAIN        0/1   Film grain (resolution-independent)
    ENABLE_LENS         0/1   Lens distortion, vignette, CA
    ENABLE_DOF          0/1   Depth of Field (independent -- requires depth buffer)
    ENABLE_GATE         0/1   Gate weave, film breathing
    ENABLE_TRANSFER     0/1   Composite artefacts, edge enhancement
    ENABLE_VHS          0/1   VHS chroma smear, tracking, dropout
    PIPELINE            0/1/2 0=SDR, 1=scRGB HDR, 2=ST.2084 HDR

    Film stock profiles (FILM_STOCK_PROFILE):
      0 = Neutral (no colour transform)
      1 = Kodak Vision3 500T  (warm tungsten cinema)
      2 = Kodak Vision3 250D  (neutral daylight cinema)
      3 = Kodak 2383 Print    (Hollywood warm print stock)
      4 = Fuji Velvia 50      (vivid saturated slide)
      5 = Fuji Eterna 500     (desaturated cool cinema)
      6 = Kodachrome 25       (classic punchy vintage)

    Lens presets (LENS_PRESET):
      0 = Custom (use manual sliders)
      1 = 35mm Spherical
      2 = 50mm Standard
      3 = 85mm Portrait
      4 = 28mm Wide
      5 = Anamorphic 2x
      6 = Petzval Swirl
      7 = Vintage 58mm
*/

// ============================================================
// Preprocessor gates
// ============================================================

// HDR peak brightness in scRGB units (nits / 80)
// 1400 nits = 17.5, 1000 nits = 12.5, 400 nits = 5.0
// Only used when PIPELINE >= 1
#ifndef FILM_HDR_PEAK_NITS
    #define FILM_HDR_PEAK_NITS 1400
#endif

#ifndef ENABLE_FILM_STOCK
    #define ENABLE_FILM_STOCK 0
#endif
#ifndef FILM_STOCK_PROFILE
    #define FILM_STOCK_PROFILE 1
#endif

#ifndef ENABLE_GRAIN
    #define ENABLE_GRAIN 0
#endif

#ifndef ENABLE_LENS
    #define ENABLE_LENS 0
#endif

// Depth of Field -- independent of ENABLE_LENS, requires depth buffer.
// Most games don't expose the depth buffer to ReShade -- verify with debug view.
#ifndef ENABLE_DOF
    #define ENABLE_DOF 0
#endif

// Lens Flare -- fully independent.
// Integrates HexLensFlare algorithm (hexagonal bokeh ghosts via directional blur)
// operating at reduced resolution for performance.
// Optionally with anamorphic streak from the same threshold detection.
#ifndef ENABLE_FLARE
    #define ENABLE_FLARE 0
#endif

// Flare resolution divisor -- higher = faster but coarser (2=half, 4=quarter res)
#ifndef FLARE_DOWNSCALE
    #define FLARE_DOWNSCALE 4
#endif

// Blur samples per pass -- more = smoother hexagon (8 is good, 16 is high quality)
#ifndef FLARE_BLUR_SAMPLES
    #define FLARE_BLUR_SAMPLES 16
#endif
#ifndef LENS_PRESET
    #define LENS_PRESET 1
#endif

#ifndef ENABLE_GATE
    #define ENABLE_GATE 0
#endif

#ifndef ENABLE_TRANSFER
    #define ENABLE_TRANSFER 0
#endif

#ifndef ENABLE_VHS
    #define ENABLE_VHS 0
#endif

#ifndef PIPELINE
    #define PIPELINE 0
#endif

// Set to 1 if depth appears inverted (near=1, far=0) in your game
// Common in UE4, some DX12 titles -- enable if debug shows inverted depth
#ifndef FILM_DEPTH_REVERSED
    #define FILM_DEPTH_REVERSED 0
#endif

// ============================================================
// Pipeline uniforms -- must be declared before helper functions
// ============================================================

#if PIPELINE >= 1
uniform float film_hdr_peak_nits <
    ui_type     = "drag"; ui_label = "Display Peak Brightness (nits)";
    ui_category = "Pipeline";
    ui_tooltip  = "Peak luminance of your display in nits.\n"
                  "Sony A95L 77\": 1400 nits\n"
                  "Used to set the Reinhard white point for scRGB compression.\n"
                  "Only active when PIPELINE=1.";
    ui_min = 100.0; ui_max = 4000.0; ui_step = 10.0;
> = 1400.0;

uniform float film_hdr_shadow_gamma <
    ui_type     = "drag"; ui_label = "Shadow Gamma";
    ui_category = "Pipeline";
    ui_tooltip  = "Gamma lift applied before Reinhard compression.\n"
                  "1.0 = linear (shadows compressed more).\n"
                  "1.4 = moderate default, good balance for QD-OLED.\n"
                  "2.0 = shadows better preserved.\n"
                  "Only active when PIPELINE=1.";
    ui_min = 1.0; ui_max = 2.4; ui_step = 0.05;
> = 1.4;
#endif

// ============================================================
// Shared math helpers
// ============================================================

// -- Pipeline-aware encode/decode helpers --------------------
// PIPELINE 0 = SDR sRGB
// PIPELINE 1 = scRGB HDR (linear, values can exceed 1.0)
//              Uses Reinhard compression to bring into 0-1 for processing
// PIPELINE 2 = HDR10 PQ (not yet implemented, treated as PIPELINE 1)

#if PIPELINE == 0
float3 film_lin(float3 c)
{
    // sRGB to linear
    return (c <= 0.04045) ? c / 12.92 : pow(max((c + 0.055) / 1.055, 0.0), 2.4);
}
float3 film_enc(float3 c)
{
    // Linear to sRGB
    return (c <= 0.0031308) ? c * 12.92 : 1.055 * pow(max(c, 0.0), 1.0/2.4) - 0.055;
}
#else
// scRGB: values are already linear, no sRGB conversion needed
// Reinhard compression maps HDR range to 0-1 for processing
// White point = 17.5 scRGB units = 1400 nits (A95L peak)
#define FILM_HDR_PEAK (FILM_HDR_PEAK_NITS / 80.0)

float3 film_lin(float3 c)
{
    // scRGB: Reinhard compress with shadow gamma lift
    // Matches CRT shader soop_reinhard approach
    float W = film_hdr_peak_nits / 80.0;
    c = pow(max(c, 0.0), 1.0 / film_hdr_shadow_gamma);
    return (c * (1.0 + c / (W * W))) / (1.0 + c);
}
float3 film_enc(float3 c)
{
    // Inverse Reinhard + inverse shadow gamma
    c = clamp(c, 0.0, 1.0);
    float maxCh = max(max(c.r, c.g), c.b);
    if (maxCh >= 1.0) c *= (0.9999 / maxCh);
    c = c / max(1.0 - c, 1e-5);
    return pow(max(c, 0.0), film_hdr_shadow_gamma);
}
#endif

// -- Hash / noise --------------------------------------------
uint film_uhash(uint x)
{
    x ^= x >> 16; x *= 0x45D9F3Bu;
    x ^= x >> 16; x *= 0x45D9F3Bu;
    x ^= x >> 16;
    return x;
}

float film_unorm(uint x)
{
    return float(x & 0x00FFFFFFu) / float(0x01000000u);
}

uint film_next(inout uint rng)
{
    rng = film_uhash(rng + 1u);
    return rng;
}

// Box-Muller: uniform pair -> Gaussian pair
float2 film_boxmuller(float2 u)
{
    float r   = sqrt(max(-2.0 * log(max(u.x, 1e-7)), 0.0));
    float phi = 6.28318530718 * u.y;
    return float2(r * cos(phi), r * sin(phi));
}

// 3-component Gaussian noise from 3 uniform values
float3 film_gaussian3(float3 u)
{
    float2 g01 = film_boxmuller(u.xy);
    float2 g23 = film_boxmuller(float2(u.z, film_unorm(film_uhash(uint(u.z * 16777215.0)))));
    return float3(g01.x, g01.y, g23.x);
}

// ============================================================
// Uniforms -- Film Stock
// ============================================================

// Declared outside gate so apply_film_profile can always access it
uniform float film_profile_black_lift <
    ui_type = "drag"; ui_label = "Black Lift Amount";
    ui_category = "Film Stock";
    ui_tooltip  = "Controls the black lift applied by film stock profiles.\n"
                  "Real print stocks have a minimum density -- true black is never\n"
                  "zero on film. This lifts shadows to simulate that characteristic.\n"
                  "\n"
                  "1.0 = full lift as designed per profile (default).\n"
                  "0.0 = no lift -- blacks stay at zero (recommended for OLED).\n"
                  "0.3-0.7 = partial lift for subtle film character without\n"
                  "          significantly affecting deep blacks.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 1.0;

#if ENABLE_FILM_STOCK
uniform float film_exposure <
    ui_type     = "drag"; ui_label = "Exposure";
    ui_category = "Film Stock";
    ui_tooltip  = "Overall exposure adjustment in stops.\\n"
                  "0.0 = no change. Positive = brighter. Negative = darker.";
    ui_min = -2.0; ui_max = 2.0; ui_step = 0.05;
> = 0.0;

uniform float film_contrast <
    ui_type     = "drag"; ui_label = "Film Contrast";
    ui_category = "Film Stock";
    ui_tooltip  = "S-curve contrast with toe and shoulder.\\n"
                  "0.0 = linear. 1.0 = full filmic S-curve.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.5;

uniform float film_saturation <
    ui_type     = "drag"; ui_label = "Saturation";
    ui_category = "Film Stock";
    ui_tooltip  = "Overall colour saturation. 1.0 = stock default.";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
> = 1.0;

uniform float film_brightness <
    ui_type     = "drag"; ui_label = "Brightness";
    ui_category = "Film Stock";
    ui_tooltip  = "Overall brightness adjustment.\n"
                  "0.0 = no change. Positive = brighter. Negative = darker.";
    ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

uniform float film_shadows <
    ui_type     = "drag"; ui_label = "Shadow Lift";
    ui_category = "Film Stock";
    ui_tooltip  = "Lift or crush shadows independently.\n"
                  "Positive = raised, faded shadows. Negative = deeper blacks.";
    ui_min = -0.5; ui_max = 0.5; ui_step = 0.001;
> = 0.0;

uniform float film_highlights <
    ui_type     = "drag"; ui_label = "Highlight Roll-off";
    ui_category = "Film Stock";
    ui_tooltip  = "Compress highlights to simulate film shoulder.\n"
                  "0.0 = no roll-off (linear). 1.0 = strong shoulder compression.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

uniform float film_profile_strength <
    ui_type     = "drag"; ui_label = "Profile Strength";
    ui_category = "Film Stock";
    ui_tooltip  = "Blend between neutral and the selected film stock profile.\\n"
                  "0.0 = no colour transform. 1.0 = full stock character.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 1.0;

uniform float film_acutance <
    ui_type = "drag"; ui_label = "Acutance (Film Edge Enhancement)";
    ui_category = "Film Stock";
    ui_tooltip = "Simulates chemical acutance -- edge contrast enhancement that\n"
                 "occurs during film development (Mackie lines / adjacency effects).\n"
                 "Unlike digital sharpening, acutance is a Laplacian-of-Gaussian\n"
                 "edge boost that makes film look simultaneously sharp and organic.\n"
                 "The enhancement is local and confined to transitions, not texture.\n"
                 "\n"
                 "0.0 = disabled (default).\n"
                 "0.1-0.2 = subtle acutance matching fine-grain stocks (Portra, 250D).\n"
                 "0.3-0.5 = moderate, matching faster stocks (500T, 800T).\n"
                 "Avoid values above 0.6 -- excessive acutance looks artificial.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

uniform int film_stock_select <
    ui_type     = "combo"; ui_label = "Film Stock";
    ui_category = "Film Stock";
    ui_tooltip  = "Select the film stock colour profile.\n"
                  "Blended with Profile Strength slider.";
    ui_items    = "Neutral\0"
                  "Kodak Vision3 500T + 2383 (tungsten cinema, graded)\0"
                  "Kodak Vision3 250D + 2383 (daylight cinema, graded)\0"
                  "Kodak 2383 Print only (warm Hollywood print stock)\0"
                  "Fuji Velvia 50 (vivid saturated slide film)\0"
                  "Kodak Portra 400 (pastel portrait negative)\0"
                  "Kodachrome 25 (punchy warm vintage slide)\0"
                  "Fuji Eterna 500 (desaturated cool cinema)\0"
                  "Kodak Vision3 200T + 2383 (clean modern blockbuster)\0"
                  "Fuji Eterna Vivid 160T (painterly soft highlights)\0"
                  "Fuji Eterna 250D (cool clean daylight cinema)\0"
                  "Kodak Ektachrome 100 (punchy blues/cyans, slide)\0"
                  "Kodak Double-X (B&W noir emulation)\0"
                  "Cinestill 800T (Vision3 remjet-removed, strong halation)\0";
> = 1;

uniform float film_base_density <
    ui_type     = "drag"; ui_label = "Film Base Density";
    ui_category = "Film Stock";
    ui_tooltip  = "Lifts shadows with a slight colour cast, simulating the\\n"
                  "unexposed film base. Negative film has a warm orange base.\\n"
                  "0.0 = pure black shadows. 0.05-0.08 = authentic film base.";
    ui_min = 0.0; ui_max = 0.15; ui_step = 0.005;
> = 0.0;

uniform int film_colour_process <
    ui_type     = "combo"; ui_label = "Colour Process";
    ui_category = "Film Stock";
    ui_tooltip  = "Additional colour process on top of the film stock profile.\n"
                  "Technicolor 2-strip and 3-strip simulate early cinema processes.\n"
                  "Bleach bypass retains silver in development -- desaturated, high contrast.";
    ui_items    = "None\0"
                  "Technicolor 3-strip (1930s-50s, vivid primaries)\0"
                  "Technicolor 2-strip (1920s-30s, red/cyan split)\0"
                  "Bleach Bypass (desaturated, high contrast, gritty)\0";
> = 0;

uniform float film_colour_process_strength <
    ui_type     = "drag"; ui_label = "Colour Process Strength";
    ui_category = "Film Stock";
    ui_tooltip  = "Blend between original and colour process. 1.0 = full effect.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 1.0;

uniform float film_halation <
    ui_type     = "drag"; ui_label = "Halation";
    ui_category = "Film Stock";
    ui_tooltip  = "Light scatter through the film base from bright elements.\\n"
                  "Affects the red channel primarily -- gives highlights a\\n"
                  "warm red/orange halo. Physically distinct from lens halation.\\n"
                  "0.0 = disabled. 0.05-0.15 = authentic. 0.3+ = heavy.";
    ui_min = 0.0; ui_max = 0.5; ui_step = 0.01;
> = 0.0;

uniform float film_halation_radius <
    ui_type     = "drag"; ui_label = "Halation Radius";
    ui_category = "Film Stock";
    ui_tooltip  = "Scatter radius of the film halation effect.\\n"
                  "Larger = softer, wider red glow.";
    ui_min = 1.0; ui_max = 16.0; ui_step = 0.5;
> = 4.0;
#endif // ENABLE_FILM_STOCK

// ============================================================
// Uniforms -- Film Grain
// ============================================================

#if ENABLE_GRAIN
uniform float film_grain_intensity <
    ui_type     = "drag"; ui_label = "Grain Intensity";
    ui_category = "Film Grain";
    ui_tooltip  = "Film grain intensity. Scaled by ISO-equivalent:\\n"
                  "0.1-0.2 = fine grain (ISO 100-200, e.g. Kodak 50D)\\n"
                  "0.2-0.4 = medium grain (ISO 400-500, e.g. Vision3 500T)\\n"
                  "0.4-0.7 = coarse grain (ISO 800+, pushed film)\\n"
                  "0.0 = disabled.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

uniform float film_grain_aspect <
    ui_type = "drag"; ui_label = "Grain Aspect Ratio (Anamorphic)";
    ui_category = "Film Grain";
    ui_tooltip = "Horizontally stretches grain to simulate anamorphic lens character.\n"
                 "Anamorphic lenses desqueeze the image, stretching grain horizontally.\n"
                 "1.0 = isotropic grain (spherical lens, default).\n"
                 "1.5-2.0 = horizontal stretch for 1.5x or 2x anamorphic.\n"
                 "Only affects grain structure, not image geometry.";
    ui_min = 1.0; ui_max = 3.0; ui_step = 0.05;
> = 1.0;

uniform float film_grain_size <
    ui_type     = "drag"; ui_label = "Grain Size";
    ui_category = "Film Grain";
    ui_tooltip  = "Physical grain cluster size in pixels.\\n"
                  "1.0 = single pixel (sharp). 2.0-3.0 = realistic film cluster.\\n"
                  "Larger values simulate lower-resolution film scans.";
    ui_min = 0.5; ui_max = 6.0; ui_step = 0.1;
> = 1.5;

uniform float film_grain_shadows <
    ui_type     = "drag"; ui_label = "Shadow Grain Boost";
    ui_category = "Film Grain";
    ui_tooltip  = "Film grain is larger and more visible in dark areas.\\n"
                  "0.0 = uniform grain across all tones.\\n"
                  "1.0 = heavy grain boost in shadows (authentic film).";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.7;

uniform bool film_grain_colour <
    ui_type     = "input"; ui_label = "Colour Grain";
    ui_category = "Film Grain";
    ui_tooltip  = "Colour grain: each channel has independent grain (authentic).\\n"
                  "Monochrome grain: single luma channel (cleaner look).";
> = true;

uniform bool film_grain_animate <
    ui_type     = "input"; ui_label = "Animate";
    ui_category = "Film Grain";
    ui_tooltip  = "Each frame gets independent grain (authentic film behaviour).\\n"
                  "Disable for a frozen grain pattern.";
> = true;
#endif // ENABLE_GRAIN

// ============================================================
// Uniforms -- Lens
// ============================================================

#if ENABLE_LENS
uniform float film_lens_distortion <
    ui_type     = "drag"; ui_label = "Distortion";
    ui_category = "Lens";
    ui_tooltip  = "Barrel (negative) or pincushion (positive) distortion.\\n"
                  "Based on PTLens model used by Adobe/LensFun.\\n"
                  "Overridden by LENS_PRESET unless LENS_PRESET=0.\\n"
                  "-0.1 = moderate barrel (wide angle). +0.05 = pincushion (telephoto).";
    ui_min = -0.3; ui_max = 0.3; ui_step = 0.005;
> = 0.0;

uniform float film_lens_vignette <
    ui_type     = "drag"; ui_label = "Lens Vignette";
    ui_category = "Lens";
    ui_tooltip  = "Optical vignette following the cos⁴ falloff law.\\n"
                  "Darker corners simulate light falloff through the lens.\\n"
                  "0.0 = no vignette. 0.5 = moderate. 1.0 = heavy.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

uniform float film_lens_ca <
    ui_type     = "drag"; ui_label = "Chromatic Aberration";
    ui_category = "Lens";
    ui_tooltip  = "Lateral chromatic aberration -- colour fringing at edges.\\n"
                  "Increases radially from centre. Red/blue channels separate.\\n"
                  "0.0 = disabled. 0.002-0.005 = subtle. 0.01+ = visible fringing.";
    ui_min = 0.0; ui_max = 0.02; ui_step = 0.0005;
> = 0.0;

uniform float film_lens_softness <
    ui_type     = "drag"; ui_label = "Edge Softness";
    ui_category = "Lens";
    ui_tooltip  = "Optical blur increasing toward the frame edges, simulating\\n"
                  "field curvature and focus falloff. Centre stays sharp.\\n"
                  "0.0 = uniform sharpness. 0.5+ = visible edge softening.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

uniform int film_lens_preset_rt <
    ui_type     = "combo"; ui_label = "Lens Preset";
    ui_category = "Lens";
    ui_tooltip  = "Select predefined lens character.\n"
                  "Custom = use Distortion slider directly.";
    ui_items    = "Custom (manual sliders)\0"
                  "35mm Spherical\0"
                  "50mm Standard\0"
                  "85mm Portrait\0"
                  "28mm Wide\0"
                  "Anamorphic 2x\0"
                  "Petzval Swirl\0"
                  "Vintage 58mm\0";
> = 0;

uniform float film_bokeh_threshold <
    ui_type     = "drag"; ui_label = "Bokeh Highlight Threshold";
    ui_category = "Lens";
    ui_tooltip  = "Luminance above which pixels receive bokeh highlight spreading.\n"
                  "0.7 = bright highlights only (default). Lower = more of image affected.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.7;

uniform float film_bokeh_radius <
    ui_type     = "drag"; ui_label = "Bokeh / Edge Blur Radius";
    ui_category = "Lens";
    ui_tooltip  = "Simulates shallow depth of field -- soft blur that increases\n"
                  "toward the frame edges, as if the centre subject is in focus\n"
                  "but the periphery falls off.\n"
                  "0.0 = disabled. 1.0-3.0 = subtle. 5.0+ = strong bokeh feel.";
    ui_min = 0.0; ui_max = 8.0; ui_step = 0.1;
> = 0.0;

uniform float film_lens_zoom <
    ui_type     = "drag"; ui_label = "Zoom";
    ui_category = "Lens";
    ui_tooltip  = "Zooms into the image after lens distortion.\n"
                  "1.0 = no zoom. >1.0 zooms in (crops edges).\n"
                  "Useful to fill screen after barrel distortion pulls corners in.\n"
                  "1.05-1.1 typically hides edge clamping from distortion.";
    ui_min = 0.5; ui_max = 2.0; ui_step = 0.005;
> = 1.0;

#endif // ENABLE_LENS

// ============================================================
// Uniforms -- Depth of Field (independent of ENABLE_LENS)
// ============================================================
#if ENABLE_DOF
uniform float film_petzval_swirl <
    ui_type     = "drag"; ui_label = "Petzval Swirl Strength";
    ui_category = "Depth of Field";
    ui_tooltip  = "Rotates the DOF blur kernel radially -- swirls only the\n"
                  "out-of-focus bokeh, not the sharp image content.\n"
                  "Simulates the iconic Petzval portrait lens effect.\n"
                  "0.0 = disabled. 0.05-0.1 = subtle. 0.2+ = strong.";
    ui_min = 0.0; ui_max = 0.3; ui_step = 0.005;
> = 0.0;

// Step 1: Enable debug, find depth value of your subject
// Step 2: Set Focus Depth to that value, disable debug
// Step 3: Tune Focus Range and Max Blur

uniform float film_dof_focus_depth <
    ui_type     = "drag"; ui_label = "Focus Depth";
    ui_category = "Depth of Field";
    ui_tooltip  = "Depth value of the focus plane (0=near, 1=far).\n"
                  "Enable debug to see depth values in your scene.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.001;
> = 0.5;

uniform float film_dof_range <
    ui_type     = "drag"; ui_label = "Focus Range";
    ui_category = "Depth of Field";
    ui_tooltip  = "Depth range around focus plane that stays sharp.\n"
                  "0.01 = very shallow. 0.1 = moderate. 0.3 = deep.";
    ui_min = 0.001; ui_max = 0.5; ui_step = 0.001;
> = 0.05;

uniform float film_dof_max_blur <
    ui_type     = "drag"; ui_label = "Max Blur (pixels)";
    ui_category = "Depth of Field";
    ui_tooltip  = "Maximum blur radius for fully out-of-focus areas.\n"
                  "2-4 = subtle. 6-10 = visible bokeh. 12+ = cinematic.";
    ui_min = 0.0; ui_max = 20.0; ui_step = 0.5;
> = 0.0;

uniform float film_dof_near_blur <
    ui_type     = "drag"; ui_label = "Near Blur Multiplier";
    ui_category = "Depth of Field";
    ui_tooltip  = "Multiplier for foreground blur (closer than focus plane).\n"
                  "1.0 = symmetric. 1.5-2.0 = stronger foreground blur.";
    ui_min = 0.0; ui_max = 1.5; ui_step = 0.05;
> = 1.0;

uniform bool film_dof_debug <
    ui_type     = "input"; ui_label = "Show Depth Debug";
    ui_category = "Depth of Field";
    ui_tooltip  = "Left half: raw depth. Right half: inverted.\n"
                  "Use to find Focus Depth value for your subject.";
> = false;
#endif // ENABLE_DOF

// ============================================================
// Uniforms -- Lens Flare
// ============================================================
#if ENABLE_FLARE
uniform float film_flare_intensity <
    ui_type     = "drag"; ui_label = "Flare Intensity";
    ui_category = "Lens Flare";
    ui_tooltip  = "Overall intensity of the lens flare effect.\n"
                  "Uses a hexagonal bokeh algorithm at reduced resolution\n"
                  "for high quality with minimal performance cost.\n"
                  "0.0 = disabled. 0.5-1.5 = natural. 2.0+ = stylised.";
    ui_min = 0.0; ui_max = 3.0; ui_step = 0.01;
> = 1.0;

uniform float film_flare_threshold <
    ui_type     = "drag"; ui_label = "Brightness Threshold";
    ui_category = "Lens Flare";
    ui_tooltip  = "Luminance threshold above which pixels generate flares.\n"
                  "0.95+ = only very bright highlights (sun, lamps).\n"
                  "0.80-0.90 = bright highlights.\n"
                  "Lower values create more widespread flare.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.005;
> = 0.99;

uniform float film_flare_scale <
    ui_type     = "drag"; ui_label = "Flare Scale";
    ui_category = "Lens Flare";
    ui_tooltip  = "Size of the flare hexagon pattern.\n"
                  "1.0 = default. Larger = wider spread.";
    ui_min = 0.1; ui_max = 5.0; ui_step = 0.05;
> = 1.0;

uniform float film_flare_squeeze <
    ui_type     = "drag"; ui_label = "Ghost Squeeze";
    ui_category = "Lens Flare";
    ui_tooltip  = "Squeezes the blur directions horizontally, turning the\n"
                  "hexagonal ghost into an oval or crescent moon shape.\n"
                  "Simulates anamorphic lens bokeh or off-axis lens geometry.\n"
                  "1.0 = symmetric hexagon (default).\n"
                  "0.3-0.7 = oval/crescent, wider than tall.\n"
                  "0.1 = very elongated horizontal crescent.";
    ui_min = 0.1; ui_max = 2.0; ui_step = 0.05;
> = 1.0;

uniform float3 film_flare_color0 <
    ui_type     = "color"; ui_label = "Ghost Colour 1";
    ui_category = "Lens Flare";
    ui_tooltip  = "Tint for the primary ghost element (reflected image).";
> = float3(0.576, 1.0, 0.0);

uniform float3 film_flare_color1 <
    ui_type     = "color"; ui_label = "Ghost Colour 2";
    ui_category = "Lens Flare";
    ui_tooltip  = "Tint for the secondary ghost element (scaled).";
> = float3(0.259, 0.592, 1.0);

uniform float3 film_flare_color2 <
    ui_type     = "color"; ui_label = "Ghost Colour 3";
    ui_category = "Lens Flare";
    ui_tooltip  = "Tint for the tertiary ghost element (further scaled).";
> = float3(1.0, 0.576, 0.0);

uniform float3 film_flare_color3 <
    ui_type     = "color"; ui_label = "Ghost Colour 4";
    ui_category = "Lens Flare";
    ui_tooltip  = "Tint for the quaternary ghost element (closest scaled).";
> = float3(0.392, 0.925, 1.0);

// --- Ambient Bloom (AmbientLight algorithm, no textures) ---
uniform float film_bloom_intensity <
    ui_type     = "drag"; ui_label = "Bloom Intensity";
    ui_category = "Lens Flare";
    ui_tooltip  = "Intensity of the ambient bloom effect.\n"
                  "Boosts bright areas and spreads light across the scene,\n"
                  "creating a natural glow that follows the image brightness.\n"
                  "Screen blend so it never overexposes.\n"
                  "0.0 = disabled. 0.1-0.5 = subtle. 1.0+ = strong.";
    ui_min = 0.0; ui_max = 5.0; ui_step = 0.05;
> = 0.0;

uniform float film_bloom_threshold <
    ui_type     = "drag"; ui_label = "Bloom Threshold";
    ui_category = "Lens Flare";
    ui_tooltip  = "Reduces bloom contribution from darker areas.\n"
                  "0.0 = all areas bloom. Higher = only bright areas bloom.";
    ui_min = 0.0; ui_max = 50.0; ui_step = 0.5;
> = 15.0;

uniform float film_bloom_adapt <
    ui_type     = "drag"; ui_label = "Bloom Adaptation";
    ui_category = "Lens Flare";
    ui_tooltip  = "Scene luminance adaptation (from AmbientLight).\n"
                  "Reduces bloom in bright scenes, boosts in dark ones.\n"
                  "0.0 = disabled (static bloom). 0.5-1.0 = natural adaptation.";
    ui_min = 0.0; ui_max = 4.0; ui_step = 0.05;
> = 0.7;
#endif // ENABLE_FLARE

// ============================================================
// Uniforms -- Gate
// ============================================================

#if ENABLE_GATE
uniform float film_gate_weave <
    ui_type     = "drag"; ui_label = "Gate Weave";
    ui_category = "Gate";
    ui_tooltip  = "Horizontal frame instability from film movement through the gate.\\n"
                  "Slow random horizontal drift frame-to-frame.\\n"
                  "0.0 = disabled. 0.001-0.003 = subtle. 0.005+ = noticeable.";
    ui_min = 0.0; ui_max = 0.01; ui_step = 0.0002;
> = 0.0;

uniform float film_gate_bounce <
    ui_type     = "drag"; ui_label = "Gate Bounce";
    ui_category = "Gate";
    ui_tooltip  = "Vertical frame bounce from film transport irregularity.\\n"
                  "0.0 = disabled. 0.001-0.002 = subtle.";
    ui_min = 0.0; ui_max = 0.005; ui_step = 0.0001;
> = 0.0;

uniform float film_breathing <
    ui_type     = "drag"; ui_label = "Focus Breathing";
    ui_category = "Gate";
    ui_tooltip  = "Subtle zoom pulse as the film moves through the gate.\\n"
                  "Each frame scales very slightly. Barely perceptible but adds\\n"
                  "organic instability.\\n"
                  "0.0 = disabled. 0.002-0.005 = authentic.";
    ui_min = 0.0; ui_max = 0.01; ui_step = 0.0002;
> = 0.0;
#endif // ENABLE_GATE

// ============================================================
// Uniforms -- Transfer
// ============================================================

// Aspect ratio is independent of ENABLE_TRANSFER
uniform int film_aspect <
    ui_type     = "combo"; ui_label = "Aspect Ratio / Crop";
    ui_category = "Transfer";
    ui_tooltip  = "Crop frame to a cinematic aspect ratio.\n"
                  "Wider than 16:9: adds top/bottom bars.\n"
                  "Narrower than 16:9: adds left/right bars (e.g. 4:3 Academy).";
    ui_items    = "None (full frame)\0"
                  "2.39:1 Anamorphic\0"
                  "1.85:1 Flat\0"
                  "1.78:1 HDTV 16:9\0"
                  "1.43:1 IMAX\0"
                  "1.33:1 Academy (4:3)\0";
> = 0;

#if ENABLE_TRANSFER
uniform float film_composite_blur <
    ui_type     = "drag"; ui_label = "Composite Chroma Blur";
    ui_category = "Transfer";
    ui_tooltip  = "Horizontal chroma bandwidth reduction simulating composite\\n"
                  "or telecine transfer. Colours bleed while luma stays sharp.\\n"
                  "0.0 = disabled. 1.0-3.0 = authentic composite.";
    ui_min = 0.0; ui_max = 8.0; ui_step = 0.25;
> = 0.0;

uniform float film_edge_enhance <
    ui_type     = "drag"; ui_label = "Edge Enhancement";
    ui_category = "Transfer";
    ui_tooltip  = "Luma edge boost applied during telecine transfer.\\n"
                  "Characteristic of 70s-90s broadcast and VHS dubbing.\\n"
                  "0.0 = disabled. 0.2-0.5 = subtle.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

#endif // ENABLE_TRANSFER

// ============================================================
// Uniforms -- VHS
// ============================================================

#if ENABLE_VHS
uniform float film_vhs_chroma_smear <
    ui_type     = "drag"; ui_label = "Chroma Smear";
    ui_category = "VHS";
    ui_tooltip  = "Horizontal colour smearing from VHS chroma demodulation.\\n"
                  "Reds and blues bleed rightward. Stronger than composite blur.\\n"
                  "0.0 = disabled. 0.5-1.5 = authentic VHS.";
    ui_min = 0.0; ui_max = 3.0; ui_step = 0.05;
> = 0.0;

uniform float film_vhs_noise <
    ui_type     = "drag"; ui_label = "VHS Noise";
    ui_category = "VHS";
    ui_tooltip  = "Luminance noise characteristic of VHS tape degradation.\\n"
                  "0.0 = disabled. 0.02-0.06 = worn tape. 0.1+ = heavily degraded.";
    ui_min = 0.0; ui_max = 0.2; ui_step = 0.005;
> = 0.0;

uniform float film_vhs_tracking <
    ui_type     = "drag"; ui_label = "Tracking Error";
    ui_category = "VHS";
    ui_tooltip  = "Horizontal displacement bands from poor VHS head tracking.\\n"
                  "Fires probabilistically on random scanlines.\\n"
                  "0.0 = disabled. 0.005-0.02 = occasional glitch.";
    ui_min = 0.0; ui_max = 0.05; ui_step = 0.001;
> = 0.0;

uniform float film_vhs_dropout <
    ui_type     = "drag"; ui_label = "Dropout";
    ui_category = "VHS";
    ui_tooltip  = "White horizontal dropout streaks from tape oxide loss.\\n"
                  "0.0 = disabled. 0.005-0.02 = occasional. 0.05+ = heavy wear.";
    ui_min = 0.0; ui_max = 0.1; ui_step = 0.002;
> = 0.0;

uniform float film_vhs_head_switch <
    ui_type     = "drag"; ui_label = "Head Switch Noise";
    ui_category = "VHS";
    ui_tooltip  = "Horizontal noise band at bottom of frame from VHS head switching.\\n"
                  "0.0 = disabled. 0.02-0.05 = authentic.";
    ui_min = 0.0; ui_max = 0.1; ui_step = 0.005;
> = 0.0;
#endif // ENABLE_VHS

// ============================================================
// ReShade built-in uniforms
// ============================================================

uniform uint  FRAMECOUNT  < source = "framecount"; >;
uniform float FILM_TIMER  < source = "timer"; >;  // milliseconds since start

// ============================================================
// Textures and samplers
// ============================================================

// Depth of field CoC texture (requires ENABLE_LENS + depth buffer)
#if ENABLE_LENS
texture2D film_coc_tex < pooled = false; >
{ Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R16F; };
sampler2D film_coc_samp { Texture = film_coc_tex;
                           AddressU = CLAMP; AddressV = CLAMP; };
#endif

#if ENABLE_DOF
texture2D film_dof_tex  < pooled = false; >
{ Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
sampler2D film_dof_samp { Texture = film_dof_tex;
                           AddressU = CLAMP; AddressV = CLAMP; };
#endif // ENABLE_DOF

#if ENABLE_FLARE
// All flare textures at reduced resolution for performance
texture2D film_flare_prepare_tex < pooled = false; >
{ Width = BUFFER_WIDTH/FLARE_DOWNSCALE; Height = BUFFER_HEIGHT/FLARE_DOWNSCALE; Format = RGBA16F; };
sampler2D film_flare_prepare_samp { Texture = film_flare_prepare_tex; AddressU = BORDER; AddressV = BORDER; };

// Backbuffer sampler with BORDER addressing for flare -- out-of-bounds = black
// This matches HexLensFlare's sColor sampler (AddressU/V = BORDER)
texture2D film_flare_src_tex : COLOR;
sampler2D film_flare_src_samp
{
    Texture  = film_flare_src_tex;
    AddressU = BORDER;
    AddressV = BORDER;
    SRGBTexture = true;
};

texture2D film_flare_vblur_tex < pooled = false; >
{ Width = BUFFER_WIDTH/FLARE_DOWNSCALE; Height = BUFFER_HEIGHT/FLARE_DOWNSCALE; Format = RGBA16F; };
sampler2D film_flare_vblur_samp { Texture = film_flare_vblur_tex; };

texture2D film_flare_dblur_tex < pooled = false; >
{ Width = BUFFER_WIDTH/FLARE_DOWNSCALE; Height = BUFFER_HEIGHT/FLARE_DOWNSCALE; Format = RGBA16F; };
sampler2D film_flare_dblur_samp { Texture = film_flare_dblur_tex; };

texture2D film_flare_rblur_tex < pooled = false; >
{ Width = BUFFER_WIDTH/FLARE_DOWNSCALE; Height = BUFFER_HEIGHT/FLARE_DOWNSCALE; Format = RGBA16F; };
sampler2D film_flare_rblur_samp { Texture = film_flare_rblur_tex; };

// Ambient bloom textures (AmbientLight approach)
// Downsample chain: 32x32 for adaptation detection, 1x1 for average luma
texture2D film_bloom_ds_tex < pooled = false; >
{ Width = 32; Height = 32; Format = RGBA8; };
sampler2D film_bloom_ds_samp { Texture = film_bloom_ds_tex; };

texture2D film_bloom_luma_tex < pooled = false; >
{ Width = 1; Height = 1; Format = RGBA8; };
sampler2D film_bloom_luma_samp { Texture = film_bloom_luma_tex; };

// Ping-pong textures at 1/16 resolution for H/V blur
texture2D film_bloom_h_tex < pooled = false; >
{ Width = BUFFER_WIDTH/16; Height = BUFFER_HEIGHT/16; Format = RGBA16F; };
sampler2D film_bloom_h_samp { Texture = film_bloom_h_tex; };

texture2D film_bloom_v_tex < pooled = false; >
{ Width = BUFFER_WIDTH/16; Height = BUFFER_HEIGHT/16; Format = RGBA16F; };
sampler2D film_bloom_v_samp { Texture = film_bloom_v_tex; };
#endif // ENABLE_FLARE

#if ENABLE_GRAIN
texture2D film_grain_raw_tex  < pooled = false; >
{ Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
sampler2D film_grain_raw_samp { Texture = film_grain_raw_tex; };

texture2D film_clean_tex      < pooled = false; >
{ Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
sampler2D film_clean_samp     { Texture = film_clean_tex; };
#endif

#if ENABLE_FILM_STOCK
// Two-pass separable Gaussian for halation -- avoids banding from single-pass blur
texture2D film_halation_tex   < pooled = false; >
{ Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RGBA16F; };
sampler2D film_halation_samp  { Texture = film_halation_tex;
                                 AddressU = CLAMP; AddressV = CLAMP; };
texture2D film_halation_hblur < pooled = false; >
{ Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RGBA16F; };
sampler2D film_halation_hblur_samp { Texture = film_halation_hblur;
                                      AddressU = CLAMP; AddressV = CLAMP; };
#endif

// ============================================================
// Film stock colour profiles
// Encoded as: colour matrix (3x3) + film S-curve parameters
// All matrices operate in linear light
// ============================================================

// Film S-curve: toe + shoulder characteristic
// params: float4(toe_strength, shoulder_strength, toe_width, shoulder_start)
float film_scurve(float x, float toe, float shoulder, float toe_w, float sh_start)
{
    // Toe: soft lift of shadows
    float t = toe * pow(max(1.0 - x / max(toe_w, 0.001), 0.0), 2.0) * toe_w;
    // Shoulder: soft roll-off of highlights
    float s = (1.0 - shoulder) + shoulder * (1.0 - pow(max(1.0 - (x - sh_start) / max(1.0 - sh_start, 0.001), 0.0), 2.0));
    return lerp(x, lerp(x + t, s, saturate((x - sh_start) / max(1.0 - sh_start, 0.001))), saturate(x / max(toe_w, 0.001)));
}

float3 apply_film_scurve(float3 c, float strength)
{
    // Film S-curve -- stronger toe and shoulder than before
    float toe      = lerp(0.0, 0.12, strength);
    float shoulder = lerp(0.0, 0.22, strength);
    float toe_w    = 0.20;
    float sh_start = 0.65;
    c.r = film_scurve(c.r, toe, shoulder, toe_w, sh_start);
    c.g = film_scurve(c.g, toe, shoulder, toe_w, sh_start);
    c.b = film_scurve(c.b, toe, shoulder, toe_w, sh_start);
    return c;
}

// Film stock profiles
// Motion picture negatives (V3 500T, 250D) are low-contrast by design --
// they include the Kodak 2383 print stock transform to look "graded"
// Photographic stocks (Velvia, Portra, Kodachrome) are direct-view,
// full character baked in
float3 apply_film_profile(float3 c_lin, int profile)
{
    float3 c = c_lin;
    float  luma = dot(c, float3(0.2126, 0.7152, 0.0722));

    if (profile == 1)
    {
        // Kodak Vision3 500T + 2383 print
        // 500T: tungsten balanced (slight blue suppression), low contrast negative
        // 2383: warm print stock adds orange/teal, lifts shadows, shoulder roll-off
        // Combined: warm mids/highlights, teal shadows, filmic S-curve
        float3x3 neg = float3x3(
             1.0200, -0.0100,  0.0050,   // slight red boost (tungsten compensation)
            -0.0050,  0.9950,  0.0050,
            -0.0800,  0.0050,  0.9600);  // blue suppression (tungsten->daylight)
        float3x3 print = float3x3(
             1.0400, -0.0300,  0.0050,   // warm print: boost red
            -0.0100,  0.9950,  0.0050,
            -0.0700, -0.0200,  0.9300);  // teal shadows: reduce blue/green in blacks
        c = mul(neg, c);
        c = mul(print, c);
        // Lifted blacks (print stock characteristic)
        c = c * (1.0 - 0.06 * film_profile_black_lift) + 0.035 * film_profile_black_lift;
        // Shoulder compression on highlights
        c = 1.0 - (1.0-c) * (1.0 - smoothstep(0.7, 1.0, c) * 0.15);
    }
    else if (profile == 2)
    {
        // Kodak Vision3 250D + 2383 print
        // 250D: daylight balanced, very neutral, slightly warm highlights
        float3x3 neg = float3x3(
             1.0100, -0.0050,  0.0020,
            -0.0050,  1.0050, -0.0030,
            -0.0200, -0.0050,  0.9800);
        float3x3 print = float3x3(
             1.0350, -0.0250,  0.0040,
            -0.0100,  0.9970,  0.0080,
            -0.0600, -0.0200,  0.9500);
        c = mul(neg, c);
        c = mul(print, c);
        c = c * (1.0 - 0.05 * film_profile_black_lift) + 0.028 * film_profile_black_lift;
        c = 1.0 - (1.0-c) * (1.0 - smoothstep(0.75, 1.0, c) * 0.12);
    }
    else if (profile == 3)
    {
        // Kodak 2383 Print stock only (applied to already-graded digital)
        // Warm orange/amber mids, teal shadows, compressed highlights
        float3x3 print = float3x3(
             1.0550, -0.0350,  0.0060,
            -0.0150,  0.9920,  0.0080,
            -0.0750, -0.0230,  0.9250);
        c = mul(print, c);
        // Characteristic 2383 black lift
        c = c * (1.0 - 0.08 * film_profile_black_lift) + 0.038 * film_profile_black_lift;
        // Strong shoulder
        c = 1.0 - (1.0-c) * (1.0 - smoothstep(0.65, 1.0, c) * 0.18);
    }
    else if (profile == 4)
    {
        // Fuji Velvia 50 (slide/reversal film)
        // Extreme saturation, deep blacks, boosted greens/blues, warm reds
        // Very high contrast -- no black lift, aggressive shoulder
        float3x3 m = float3x3(
             1.0500,  0.0100, -0.0150,   // punch reds
            -0.0350,  1.0700, -0.0200,   // strong green boost
             0.0200, -0.0500,  1.0800);  // vivid blues
        c = mul(m, c);
        // Boost saturation strongly
        float sat_luma = dot(c, float3(0.2126, 0.7152, 0.0722));
        c = lerp(sat_luma.xxx, c, 1.35);
        // Deep blacks, no lift
        c = pow(max(c, 0.0), 1.08);
        // Hard shoulder
        c = 1.0 - (1.0-c) * (1.0 - smoothstep(0.80, 1.0, c) * 0.25);
    }
    else if (profile == 5)
    {
        // Kodak Portra 400 (portrait negative)
        // Pastel colours, lifted shadows, warm skin tones, soft contrast
        float3x3 m = float3x3(
             1.0250,  0.0050, -0.0100,   // slightly warm
            -0.0100,  0.9900,  0.0150,   // slight green push
            -0.0150,  0.0050,  0.9700);
        c = mul(m, c);
        // Pastel quality: reduce saturation slightly, lift shadows
        float sat_luma2 = dot(c, float3(0.2126, 0.7152, 0.0722));
        c = lerp(sat_luma2.xxx, c, 0.88);  // slightly desaturated
        c = c * (1.0 - 0.05 * film_profile_black_lift) + 0.032 * film_profile_black_lift; // lifted shadows
        // Soft highlight roll-off
        c = 1.0 - (1.0-c) * (1.0 - smoothstep(0.78, 1.0, c) * 0.10);
    }
    else if (profile == 6)
    {
        // Kodachrome 25 (slide film, discontinued 2010)
        // Warm reds/oranges, punchy contrast, slight cyan shadows, fine grain
        float3x3 m = float3x3(
             1.0900, -0.0450,  0.0100,   // strong red/warm push
            -0.0300,  1.0100, -0.0050,
            -0.0600, -0.0100,  0.9200);  // suppress blue
        c = mul(m, c);
        // Boost saturation moderately
        float sat_luma3 = dot(c, float3(0.2126, 0.7152, 0.0722));
        c = lerp(sat_luma3.xxx, c, 1.15);
        // Crushed shadows (characteristic Kodachrome look)
        c = pow(max(c, 0.0), 1.06);
    }
    else if (profile == 7)
    {
        // Fuji Eterna 500 (cinema negative, flat/desaturated)
        // Cool, desaturated, low contrast -- designed for heavy grading
        float3x3 m = float3x3(
             0.9700,  0.0150, -0.0050,
             0.0050,  0.9650,  0.0100,
             0.0250,  0.0150,  1.0200);  // slight cool/blue push
        c = mul(m, c);
        float sat_luma4 = dot(c, float3(0.2126, 0.7152, 0.0722));
        c = lerp(sat_luma4.xxx, c, 0.80);  // noticeably desaturated
        c = c * (1.0 - 0.03 * film_profile_black_lift) + 0.020 * film_profile_black_lift; // subtle shadow lift
    }

    else if (profile == 8)
    {
        // Kodak Vision3 200T + 2383 print
        // Cleaner and more clinical than 500T, less grain, modern blockbuster look
        // Slightly cooler than 500T, excellent shadow detail
        float3x3 neg = float3x3(
             1.0050, -0.0050,  0.0020,
            -0.0030,  0.9980,  0.0030,
            -0.0400,  0.0030,  0.9700); // mild tungsten correction
        float3x3 print = float3x3(
             1.0300, -0.0200,  0.0040,
            -0.0080,  0.9970,  0.0060,
            -0.0500, -0.0150,  0.9450);
        c = mul(neg, c);
        c = mul(print, c);
        c = c * (1.0 - 0.04 * film_profile_black_lift) + 0.025 * film_profile_black_lift;
        // Moderate shoulder
        c = 1.0 - (1.0-c) * (1.0 - smoothstep(0.78, 1.0, c) * 0.10);
    }
    else if (profile == 9)
    {
        // Fuji Eterna Vivid 160T (discontinued 2013)
        // Bold contrast, soft highlights blending painterly into midtones
        // Natural skin tones, slight cool/green cast in shadows
        float3x3 m = float3x3(
             1.0200, -0.0100, -0.0050,
            -0.0200,  1.0300, -0.0100, // slight green bias
             0.0100, -0.0200,  0.9900);
        c = mul(m, c);
        // Characteristic Eterna Vivid: boost saturation in mids, soft in highlights
        float sat_luma_ev = dot(c, float3(0.2126, 0.7152, 0.0722));
        float sat_boost = lerp(1.15, 1.0, smoothstep(0.5, 0.9, sat_luma_ev));
        c = lerp(sat_luma_ev.xxx, c, sat_boost);
        c = c * (1.0 - 0.04 * film_profile_black_lift) + 0.022 * film_profile_black_lift;
        // Very soft painterly shoulder
        c = 1.0 - (1.0-c) * (1.0 - smoothstep(0.60, 1.0, c) * 0.20);
    }
    else if (profile == 10)
    {
        // Fuji Eterna 250D (daylight cinema negative)
        // Cooler and cleaner than Eterna 500, excellent colour accuracy
        // Used for daylight exterior scenes, neutral with slight cool cast
        float3x3 m = float3x3(
             0.9900,  0.0100, -0.0030,
            -0.0050,  0.9950,  0.0080,
             0.0200,  0.0100,  1.0300); // clean cool push
        c = mul(m, c);
        float sat_luma_ed = dot(c, float3(0.2126, 0.7152, 0.0722));
        c = lerp(sat_luma_ed.xxx, c, 0.92); // slightly desaturated
        c = c * (1.0 - 0.025 * film_profile_black_lift) + 0.018 * film_profile_black_lift;
        c = 1.0 - (1.0-c) * (1.0 - smoothstep(0.80, 1.0, c) * 0.08);
    }
    else if (profile == 11)
    {
        // Kodak Ektachrome 100 (slide/reversal film)
        // Punchy blues and cyans, cooler than Kodachrome, vivid greens
        // Very different from Kodachrome -- cooler, more clinical, cyan shadows
        float3x3 m = float3x3(
             0.9800,  0.0050, -0.0100,
            -0.0150,  1.0300,  0.0050, // vivid green
             0.0300, -0.0200,  1.0900); // strong blue/cyan boost
        c = mul(m, c);
        float sat_luma_ek = dot(c, float3(0.2126, 0.7152, 0.0722));
        c = lerp(sat_luma_ek.xxx, c, 1.20); // vivid saturation
        // Deep blacks, slide film characteristic
        c = pow(max(c, 0.0), 1.05);
        c = 1.0 - (1.0-c) * (1.0 - smoothstep(0.82, 1.0, c) * 0.15);
    }
    else if (profile == 12)
    {
        // Kodak Double-X (black and white cinema film)
        // High contrast, grain, classic noir look
        // Convert to luma then apply B&W contrast curve
        float bw = dot(c, float3(0.2126, 0.7152, 0.0722));
        // Slight warm tint (sepia-adjacent, as B&W prints often had)
        c = float3(bw * 1.02, bw * 0.98, bw * 0.90);
        // High contrast S-curve
        c = c * (1.0 - 0.06 * film_profile_black_lift) + 0.010 * film_profile_black_lift;
        c = 1.0 - (1.0-c) * (1.0 - smoothstep(0.55, 0.95, c) * 0.22); // hard shoulder
    }
    else if (profile == 13)
    {
        // Cinestill 800T (Vision3 500T with remjet removed)
        // Same colour response as 500T but with extreme halation character
        // Slightly more pushed/contrasty, famous for neon city scenes
        float3x3 neg = float3x3(
             1.0200, -0.0100,  0.0050,
            -0.0050,  0.9950,  0.0050,
            -0.0800,  0.0050,  0.9600);
        float3x3 print = float3x3(
             1.0500, -0.0400,  0.0060,
            -0.0120,  0.9940,  0.0080,
            -0.0800, -0.0250,  0.9200); // slightly more pushed than 500T
        c = mul(neg, c);
        c = mul(print, c);
        c = c * (1.0 - 0.07 * film_profile_black_lift) + 0.040 * film_profile_black_lift;
        // Stronger shoulder -- pushed stock
        c = 1.0 - (1.0-c) * (1.0 - smoothstep(0.60, 0.95, c) * 0.20);
        // Note: Cinestill's defining trait is extreme halation (remjet removed).
        // Set film_halation high (0.6+) with warm/red tint for full effect.
    }

    return max(c, 0.0);
}

// ============================================================
// Lanczos2 reconstruction sampler
// Suppresses moiré/aliasing from non-integer UV sampling
// Used for lens distortion and CA sampling
// ============================================================

float film_lanczos2_w(float x)
{
    const float PI = 3.14159265359;
    if (abs(x) < 0.0001) return 1.0;
    if (abs(x) >= 2.0)   return 0.0;
    float px  = PI * x;
    float px2 = PI * x * 0.5;
    return (sin(px) / px) * (sin(px2) / px2);
}

float3 film_lanczos2(sampler2D tex, float2 uv)
{
    float2 px      = ReShade::PixelSize;
    float2 uv_px   = uv / px;
    float2 uv_floor = floor(uv_px - 0.5) + 0.5;
    float3 result  = 0.0;
    float  wsum    = 0.0;
    [unroll] for (int j = -1; j <= 2; j++)
    [unroll] for (int i = -1; i <= 2; i++)
    {
        float wx = film_lanczos2_w(uv_px.x - (uv_floor.x + float(i)));
        float wy = film_lanczos2_w(uv_px.y - (uv_floor.y + float(j)));
        float w  = wx * wy;
        result  += tex2D(tex, (uv_floor + float2(i,j)) * px).rgb * w;
        wsum    += w;
    }
    return result / max(wsum, 0.0001);
}

// ============================================================
// Lens distortion helpers (PTLens model, applied in reverse)
// Only compiled when ENABLE_LENS=1
#if ENABLE_LENS
// PTLens correction: r_c = r * (1 + a*r^2 + b*r^4 + c*r^6)
// Applied forward (adding distortion, not correcting it)
// ============================================================

float2 apply_lens_distortion(float2 uv, float a, float b, float c_coeff)
{
    float2 d    = uv - 0.5;
    float  ar   = float(BUFFER_WIDTH) / float(BUFFER_HEIGHT);
    d.x        *= ar;
    float  r2   = dot(d, d);
    float  r4   = r2 * r2;
    float  r6   = r4 * r2;
    float  warp = 1.0 + a*r2 + b*r4 + c_coeff*r6;
    d          *= warp;
    d.x        /= ar;
    return d + 0.5;
}

float2 get_lens_uv(float2 uv)
{
    // Apply zoom first -- same approach as CRT shader geom_warp
    uv = (uv - 0.5) / film_lens_zoom + 0.5;

    int preset = film_lens_preset_rt;
    float ar   = float(BUFFER_WIDTH) / float(BUFFER_HEIGHT);

    if (preset == 0)
    {   // Custom: use distortion slider directly
        return apply_lens_distortion(uv, film_lens_distortion,
                                        film_lens_distortion * 0.3, 0.0);
    }
    else if (preset == 1)
    {   // 35mm Spherical
        return apply_lens_distortion(uv, 0.008, -0.006, 0.001);
    }
    else if (preset == 2)
    {   // 50mm Standard
        return apply_lens_distortion(uv, 0.002, -0.002, 0.001);
    }
    else if (preset == 3)
    {   // 85mm Portrait
        return apply_lens_distortion(uv, 0.001, -0.001, 0.0);
    }
    else if (preset == 4)
    {   // 28mm Wide
        return apply_lens_distortion(uv, 0.017, -0.025, -0.005);
    }
    else if (preset == 5)
    {   // Anamorphic 2x -- horizontal barrel with vertical squeeze
        float2 d = uv - 0.5;
        d.x *= ar;
        float r2 = dot(d * float2(0.5, 1.0), d * float2(0.5, 1.0));
        d *= 1.0 + 0.012 * r2 - 0.008 * r2 * r2;
        d.x /= ar;
        return d + 0.5;
    }
    else if (preset == 6)
    {   // Petzval lens -- slight barrel distortion
        // Bokeh swirl via Petzval Swirl Strength in Depth of Field (ENABLE_DOF)
        return apply_lens_distortion(uv, -0.004, 0.008, -0.002);
    }
    else if (preset == 7)
    {   // Vintage 58mm -- slight pincushion
        return apply_lens_distortion(uv, -0.008, 0.012, -0.003);
    }
    return uv;
}

// cos^4 vignette
float lens_vignette(float2 uv, float strength)
{
    float2 d  = uv - 0.5;
    float  ar = float(BUFFER_WIDTH) / float(BUFFER_HEIGHT);
    d.x      *= ar;
    float  r  = length(d) * 1.41421356;  // normalise to corner = 1
    return 1.0 - strength * (1.0 - pow(cos(r * 1.5707963 * 0.7), 4.0));
}

#endif // ENABLE_LENS (lens distortion helpers)

// ============================================================
// Aspect ratio / letterbox
// ============================================================

float4 apply_letterbox(float4 c, float2 uv)
{
    if (film_aspect == 0) return c;

    float src_ar = float(BUFFER_WIDTH) / float(BUFFER_HEIGHT);
    float tgt_ar = 1.0;
    if      (film_aspect == 1) tgt_ar = 2.39;  // anamorphic
    else if (film_aspect == 2) tgt_ar = 1.85;  // flat
    else if (film_aspect == 3) tgt_ar = 1.78;  // HDTV 16:9
    else if (film_aspect == 4) tgt_ar = 1.43;  // IMAX
    else if (film_aspect == 5) tgt_ar = 1.33;  // Academy 4:3

    if (tgt_ar > src_ar)
    {
        // Target wider than source: top/bottom bars
        float bar = (1.0 - src_ar / tgt_ar) * 0.5;
        if (uv.y < bar || uv.y > 1.0 - bar)
            return float4(0.0, 0.0, 0.0, 1.0);
    }
    else if (tgt_ar < src_ar)
    {
        // Target narrower than source: left/right bars
        float bar = (1.0 - tgt_ar / src_ar) * 0.5;
        if (uv.x < bar || uv.x > 1.0 - bar)
            return float4(0.0, 0.0, 0.0, 1.0);
    }

    return c;
}

// ============================================================
// Pixel shaders
// ============================================================

// ── Pass 1a: Halation source extract (downsample + threshold) ─
#if ENABLE_FILM_STOCK
void film_halation_extract_PS(
    in  float4 pos      : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    // Smooth threshold -- avoids hard edge banding
    float3 c    = tex2D(ReShade::BackBuffer, texcoord).rgb;
    float  luma = dot(c, float3(0.2126, 0.7152, 0.0722));
    // Soft knee threshold: smooth transition above 0.5
    float  bright = smoothstep(0.45, 0.95, luma);
    // Red-biased extraction (halation is predominantly in the red dye layer)
    color = float4(c.r * bright, c.g * bright * 0.35, c.b * bright * 0.08, bright);
}

// ── Pass 1b: Halation horizontal Gaussian blur ────────────────
void film_halation_hblur_PS(
    in  float4 pos      : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    float2 px  = ReShade::PixelSize * 2.0; // half-res
    float  rad = max(film_halation_radius, 0.5);
    // 9-tap Gaussian kernel
    static const float w[5] = { 0.2270, 0.1945, 0.1216, 0.0540, 0.0162 };
    float4 acc = tex2D(film_halation_samp, texcoord) * w[0];
    for (int i = 1; i < 5; i++)
    {
        float2 off = float2(float(i) * rad * px.x, 0.0);
        acc += (tex2D(film_halation_samp, texcoord + off)
              + tex2D(film_halation_samp, texcoord - off)) * w[i];
    }
    color = acc;
}

// ── Pass 1c: Halation vertical Gaussian blur + film stock ─────
// (vertical blur result is read in film_stock_PS via film_halation_hblur_samp)
void film_halation_vblur_PS(
    in  float4 pos      : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    float2 px  = ReShade::PixelSize * 2.0;
    float  rad = max(film_halation_radius, 0.5);
    static const float w[5] = { 0.2270, 0.1945, 0.1216, 0.0540, 0.0162 };
    float4 acc = tex2D(film_halation_hblur_samp, texcoord) * w[0];
    for (int i = 1; i < 5; i++)
    {
        float2 off = float2(0.0, float(i) * rad * px.y);
        acc += (tex2D(film_halation_hblur_samp, texcoord + off)
              + tex2D(film_halation_hblur_samp, texcoord - off)) * w[i];
    }
    color = acc;
}

void film_stock_PS(
    in  float4 pos      : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    float3 c = tex2D(ReShade::BackBuffer, texcoord).rgb;

    // Decode to linear
    float3 c_lin = film_lin(c);

    // Exposure
    c_lin *= pow(2.0, film_exposure);

    // Film stock colour profile
    float3 profiled = apply_film_profile(c_lin, film_stock_select);
    c_lin = lerp(c_lin, profiled, film_profile_strength);

    // Film S-curve
    c_lin = apply_film_scurve(saturate(c_lin), film_contrast);

    // Acutance: chemical edge enhancement from development adjacency effects.
    // Computed entirely on the source backbuffer for consistency -- centre and
    // neighbours must be in the same colour space to avoid bias/darkening.
    // The edge signal is then scaled relative to c_lin for a neutral boost.
    if (film_acutance > 0.001)
    {
        float2 px  = ReShade::PixelSize;
        // Sample centre and neighbours from source (consistent signal)
        float3 src_c  = tex2D(ReShade::BackBuffer, texcoord).rgb;
        float3 src_lap =
            tex2D(ReShade::BackBuffer, texcoord + float2(-px.x,-px.y)).rgb +
            tex2D(ReShade::BackBuffer, texcoord + float2( 0.0, -px.y)).rgb +
            tex2D(ReShade::BackBuffer, texcoord + float2( px.x,-px.y)).rgb +
            tex2D(ReShade::BackBuffer, texcoord + float2(-px.x, 0.0)).rgb +
            tex2D(ReShade::BackBuffer, texcoord + float2( px.x, 0.0)).rgb +
            tex2D(ReShade::BackBuffer, texcoord + float2(-px.x, px.y)).rgb +
            tex2D(ReShade::BackBuffer, texcoord + float2( 0.0,  px.y)).rgb +
            tex2D(ReShade::BackBuffer, texcoord + float2( px.x, px.y)).rgb;
        // Normalised Laplacian -- edge signal relative to local contrast
        float3 laplacian = src_c * 8.0 - src_lap;
        float3 src_luma  = dot(src_c, float3(0.2126, 0.7152, 0.0722)).xxx;
        // Scale edge by source luma so dark and bright edges get proportional boost
        float3 edge_norm = laplacian / max(src_luma + 0.05, 0.05);
        // Add to post-profile c_lin -- clamped to prevent ringing
        float3 acutance_signal = clamp(edge_norm * film_acutance * 0.08, -0.15, 0.15);
        c_lin = max(c_lin + acutance_signal, 0.0);
    }

    // Brightness
    c_lin *= pow(2.0, film_brightness);

    // Shadow lift / crush
    c_lin = c_lin + film_shadows * (1.0 - c_lin) * (1.0 - saturate(c_lin * 3.0));

    // Highlight roll-off (film shoulder simulation)
    if (film_highlights > 0.001)
    {
        float3 hl = 1.0 - (1.0-c_lin) * (1.0 - smoothstep(0.6, 1.0, c_lin) * film_highlights * 0.4);
        c_lin = lerp(c_lin, hl, film_highlights);
    }

    // Saturation
    float luma = dot(c_lin, float3(0.2126, 0.7152, 0.0722));
    c_lin = lerp(float3(luma,luma,luma), c_lin, film_saturation);

    // Film base density: lifts the absolute black floor of the image
    // Real film never reaches true zero -- the unexposed base has slight opacity
    // This is a simple black lift, NOT a colour overlay
    c_lin = c_lin + film_base_density * (1.0 - c_lin) * (1.0 - saturate(luma * 8.0));

    // Halation: properly blurred red-biased scatter from film base
    // Samples the two-pass Gaussian result (via film_halation_hblur_samp)
    if (film_halation > 0.001)
    {
        float3 halo = tex2D(film_halation_hblur_samp, texcoord).rgb;
        c_lin += halo * film_halation;
    }

    // Colour process (Technicolor / bleach bypass)
    if (film_colour_process > 0 && film_colour_process_strength > 0.001)
    {
        float3 c_proc = c_lin;
        if (film_colour_process == 1)
        {
            // Technicolor 3-strip: separate RGB channels through dye-transfer simulation
            // (based on Technicolor2 algorithm by Prod80/CeeJay)
            float3 temp    = 1.0 - c_proc;
            float3 target  = temp.grg;
            float3 target2 = temp.bbr;
            float3 temp2   = c_proc * target * target2;
            float3 col_str = float3(0.18, 0.18, 0.18);
            float3 temp3   = temp2 * col_str;
            temp2 *= 1.0; // brightness=1
            float3 tgt3  = temp3.grg;
            float3 tgt4  = temp3.bbr;
            float3 tc    = c_proc - tgt3 + temp2;
            tc           = tc - tgt4;
            // Saturation pass
            float tc_luma = dot(tc, float3(0.2126,0.7152,0.0722));
            c_proc = lerp(tc_luma.xxx, tc, 1.0);
        }
        else if (film_colour_process == 2)
        {
            // Technicolor 2-strip: red/cyan dye transfer (1920s-30s look)
            // Strong red-green separation, blue tinted shadows
            float3 tc2;
            tc2.r = c_proc.r * 0.9 + c_proc.g * 0.1;
            tc2.g = c_proc.g * 0.8 + c_proc.b * 0.2;
            tc2.b = c_proc.r * 0.1 + c_proc.b * 0.7 + c_proc.g * 0.05;
            // Boost contrast and push saturation
            float tc2_luma = dot(tc2, float3(0.2126,0.7152,0.0722));
            tc2 = lerp(tc2_luma.xxx, tc2, 1.2);
            tc2 = pow(max(tc2, 0.0), 1.1);
            c_proc = tc2;
        }
        else if (film_colour_process == 3)
        {
            // Bleach bypass: retain silver halide in development
            // Result: desaturated, high contrast, lifted blacks, crushed highlights
            float bp_luma  = dot(c_proc, float3(0.2126, 0.7152, 0.0722));
            float3 bp_grey = bp_luma.xxx;
            // Screen blend of colour with luma (bleach bypass screen formula)
            float3 bp = 1.0 - (1.0-c_proc) * (1.0-bp_grey);
            // Blend desaturated result
            float bp_luma2 = dot(bp, float3(0.2126,0.7152,0.0722));
            c_proc = lerp(bp_luma2.xxx, bp, 0.5); // partial desaturation
            // Contrast boost
            c_proc = (c_proc - 0.5) * 1.3 + 0.5;
        }
        c_lin = lerp(c_lin, max(c_proc, 0.0), film_colour_process_strength);
    }

    c_lin = max(c_lin, 0.0);
    color = float4(film_enc(c_lin), 1.0);
}
#endif // ENABLE_FILM_STOCK

// ── Pass 2: Lens distortion, CA, vignette, DoF, flare ────────
#if ENABLE_LENS
void film_lens_PS(
    in  float4 pos      : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    float2 px = ReShade::PixelSize;

    // Distortion UV
    float2 uv_d = get_lens_uv(texcoord);

    // Chromatic aberration: red/blue shift radially from centre
    float2 ca_offs = (texcoord - 0.5) * film_lens_ca;
    float2 uv_r   = get_lens_uv(texcoord + ca_offs);
    float2 uv_b   = get_lens_uv(texcoord - ca_offs);

    // Sample with Lanczos2 + additional anti-aliasing filter
    // The Lanczos2 alone doesn't suppress low-frequency moire from lens warp
    // We add a 3-tap box pre-filter perpendicular to the distortion gradient
    // to break up horizontal banding patterns

    // Compute distortion gradient to find banding direction
    float2 uv_dx = get_lens_uv(texcoord + float2(px.x, 0.0));
    float2 uv_dy = get_lens_uv(texcoord + float2(0.0, px.y));
    float  warp_h = abs(uv_dy.x - uv_d.x); // horizontal stretch from vertical warp
    float  aa_amt = saturate(warp_h * 200.0); // scale to [0,1] -- stronger at edges

    float3 c;
    if (aa_amt > 0.01)
    {
        // Blend 3 vertical samples at distorted UV to suppress horizontal bands
        float2 off = float2(0.0, px.y * 0.5);
        float3 c0 = film_lanczos2(ReShade::BackBuffer, uv_d);
        float3 c1 = film_lanczos2(ReShade::BackBuffer, uv_d + off);
        float3 c2 = film_lanczos2(ReShade::BackBuffer, uv_d - off);
        float3 c_aa = (c0 * 2.0 + c1 + c2) * 0.25;

        float3 c0r = film_lanczos2(ReShade::BackBuffer, uv_r);
        float3 c1r = film_lanczos2(ReShade::BackBuffer, uv_r + off);
        float3 c2r = film_lanczos2(ReShade::BackBuffer, uv_r - off);
        float3 c_r = (c0r * 2.0 + c1r + c2r) * 0.25;

        float3 c0b = film_lanczos2(ReShade::BackBuffer, uv_b);
        float3 c1b = film_lanczos2(ReShade::BackBuffer, uv_b + off);
        float3 c2b = film_lanczos2(ReShade::BackBuffer, uv_b - off);
        float3 c_b = (c0b * 2.0 + c1b + c2b) * 0.25;

        c.r = lerp(film_lanczos2(ReShade::BackBuffer, uv_r).r, c_r.r, aa_amt);
        c.g = lerp(film_lanczos2(ReShade::BackBuffer, uv_d).g, c_aa.g, aa_amt);
        c.b = lerp(film_lanczos2(ReShade::BackBuffer, uv_b).b, c_b.b, aa_amt);
    }
    else
    {
        c.r = film_lanczos2(ReShade::BackBuffer, uv_r).r;
        c.g = film_lanczos2(ReShade::BackBuffer, uv_d).g;
        c.b = film_lanczos2(ReShade::BackBuffer, uv_b).b;
    }

    // Edge softness: optical field curvature -- centre stays sharp
    if (film_lens_softness > 0.001)
    {
        float r = length((texcoord - 0.5) * float2(float(BUFFER_WIDTH)/float(BUFFER_HEIGHT), 1.0));
        float blur_amt = r * r * film_lens_softness;
        float3 soft = 0.0;
        float  w_s = 0.0;
        for (int dy = -2; dy <= 2; dy++)
        for (int dx = -2; dx <= 2; dx++)
        {
            float wt = exp(-(float(dx*dx + dy*dy)) * 0.5);
            soft += tex2D(ReShade::BackBuffer, uv_d + float2(dx,dy) * px * blur_amt * 4.0).rgb * wt;
            w_s += wt;
        }
        c = lerp(c, soft / max(w_s, 0.001), saturate(blur_amt * 2.0));
    }

    // Debug: raw depth split-screen -- always runs when enabled, no other gates
    // Left half = raw depth, right half = 1-raw (inverted)
    // One side should show a proper depth gradient if depth buffer is working
    // Depth-based DoF: direct depth comparison
#if ENABLE_DOF
    if (film_dof_max_blur > 0.5 && !film_dof_debug)
    {
        float depth_raw = ReShade::GetLinearizedDepth(texcoord);
#if FILM_DEPTH_REVERSED
        float depth_01  = 1.0 - depth_raw;
#else
        float depth_01  = depth_raw;
#endif
        // Depth validity check: sample a few neighbours to see if depth varies
        // If depth is flat (no buffer), skip blur entirely to avoid blurring everything
        float d_check1  = ReShade::GetLinearizedDepth(texcoord + float2( 0.1,  0.0));
        float d_check2  = ReShade::GetLinearizedDepth(texcoord + float2(-0.1,  0.0));
        float d_check3  = ReShade::GetLinearizedDepth(texcoord + float2( 0.0,  0.1));
        float depth_var = abs(d_check1 - d_check2) + abs(d_check2 - d_check3);
        bool  depth_ok  = (depth_var > 0.0001);

        bool  is_sky    = (depth_01 >= 0.999);
        float coc_px    = 0.0;

        if (!depth_ok) is_sky = true; // treat as sky = no blur when depth invalid

        if (!is_sky)
        {
            float dist = depth_01 - film_dof_focus_depth;
            // Separate near/far blur
            float blur_amt;
            if (dist < 0.0)
            {
                // Foreground (closer than focus)
                blur_amt = saturate((-dist - film_dof_range)
                         / max(film_dof_range, 0.001))
                         * film_dof_near_blur;
            }
            else
            {
                // Background (further than focus)
                blur_amt = saturate((dist - film_dof_range)
                         / max(film_dof_range, 0.001));
            }
            coc_px = blur_amt * film_dof_max_blur;
        }

        if (coc_px > 0.5)
        {
            // Poisson disc blur scaled by coc_px
            static const float2 kernel[17] = {
                float2( 0.000,  0.000),
                float2( 0.000,  1.000), float2( 0.000, -1.000),
                float2( 1.000,  0.000), float2(-1.000,  0.000),
                float2( 0.707,  0.707), float2(-0.707,  0.707),
                float2( 0.707, -0.707), float2(-0.707, -0.707),
                float2( 0.000,  2.000), float2( 0.000, -2.000),
                float2( 2.000,  0.000), float2(-2.000,  0.000),
                float2( 1.500,  1.500), float2(-1.500,  1.500),
                float2( 1.500, -1.500), float2(-1.500, -1.500)
            };

            float3 acc = 0.0;
            float  w   = 0.0;

            for (int di = 0; di < 17; di++)
            {
                float2 koff = kernel[di];

                // Petzval: rotate kernel in OOF regions only
                if (film_lens_preset_rt == 6 && film_petzval_swirl > 0.001)
                {
                    float2 tc_c  = texcoord - 0.5;
                    float  ar_p  = float(BUFFER_WIDTH) / float(BUFFER_HEIGHT);
                    tc_c.x      *= ar_p;
                    float  rp    = length(tc_c);
                    float  coc_n = saturate(coc_px / max(film_dof_max_blur, 1.0));
                    float  ang   = film_petzval_swirl * rp * rp * 6.28318 * coc_n;
                    float  sp = sin(ang), cp2 = cos(ang);
                    koff = float2(cp2*koff.x - sp*koff.y, sp*koff.x + cp2*koff.y);
                }

                float2 samp_uv  = texcoord + koff * px * coc_px;
                float  s_depth  = ReShade::GetLinearizedDepth(samp_uv);
                float  s_dist2   = s_depth - film_dof_focus_depth;
                float  s_blur;
                if (s_dist2 < 0.0)
                    s_blur = saturate((-s_dist2 - film_dof_range) / max(film_dof_range, 0.001)) * film_dof_near_blur;
                else
                    s_blur = saturate((s_dist2 - film_dof_range) / max(film_dof_range, 0.001));
                float  s_coc = s_blur * film_dof_max_blur;
                // Weight: prefer samples from equally or more OOF regions
                float  wt = (s_coc >= coc_px * 0.7) ? 1.0 : 0.25;
                acc += tex2D(ReShade::BackBuffer, samp_uv).rgb * wt;
                w   += wt;
            }

            float blend = saturate(coc_px / max(film_dof_max_blur * 0.5, 1.0));
            c = lerp(c, acc / max(w, 0.001), blend);
        }
    }

#endif // ENABLE_DOF

    // Bokeh highlight: luminance-weighted hex kernel blur on bright areas.
    // Simulates the out-of-focus bright spot spreading of fast lenses.
    // Only affects pixels above film_bokeh_threshold.
    if (film_bokeh_radius > 0.1)
    {
        float luma_c = dot(c, float3(0.2126, 0.7152, 0.0722));
        float bokeh_above = max(luma_c - film_bokeh_threshold, 0.0)
                          / max(1.0 - film_bokeh_threshold, 0.001);

        if (bokeh_above > 0.001)
        {
            static const float2 hex[19] = {
                float2( 0.000,  0.000),
                float2( 1.000,  0.000), float2(-1.000,  0.000),
                float2( 0.000,  1.000), float2( 0.000, -1.000),
                float2( 0.500,  0.866), float2(-0.500,  0.866),
                float2( 0.500, -0.866), float2(-0.500, -0.866),
                float2( 1.500,  0.866), float2(-1.500,  0.866),
                float2( 1.500, -0.866), float2(-1.500, -0.866),
                float2( 2.000,  0.000), float2(-2.000,  0.000),
                float2( 1.000,  1.732), float2(-1.000,  1.732),
                float2( 1.000, -1.732), float2(-1.000, -1.732)
            };

            float3 bokeh_acc = 0.0;
            float  bokeh_w   = 0.0;
            [unroll] for (int bi = 0; bi < 19; bi++)
            {
                float2 b_uv  = uv_d + hex[bi] * px * film_bokeh_radius;
                float3 b_col = tex2D(ReShade::BackBuffer, b_uv).rgb;
                float  b_lum = dot(b_col, float3(0.2126, 0.7152, 0.0722));
                float  b_w   = max(b_lum - film_bokeh_threshold, 0.0) + 0.001;
                bokeh_acc += b_col * b_w;
                bokeh_w   += b_w;
            }
            float3 bokeh_result = bokeh_acc / max(bokeh_w, 0.001);
            c = lerp(c, bokeh_result, saturate(bokeh_above * 2.0));
        }
    }

    // Optical vignette (cos^4 falloff)
    c *= lens_vignette(texcoord, film_lens_vignette);

    // Border fill for distorted edges
    if (any(uv_d < 0.001) || any(uv_d > 0.999))
        c = float3(0.0, 0.0, 0.0);



    color = float4(c, 1.0);
}
#endif // ENABLE_LENS

// ── Pass 3: Gate ─────────────────────────────────────────────
#if ENABLE_GATE
void film_gate_PS(
    in  float4 pos      : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    // Gate weave: slow hash-based horizontal drift
    uint  t_weave = (FRAMECOUNT / 2u) * 0x9E3779B9u;
    float weave_x = (film_unorm(film_uhash(t_weave)) - 0.5) * film_gate_weave;
    float weave_y = (film_unorm(film_uhash(t_weave + 1u)) - 0.5) * film_gate_bounce;

    // Film breathing: subtle zoom pulse
    float breath = 1.0 + (film_unorm(film_uhash(FRAMECOUNT * 0x6C62272Eu)) - 0.5)
                       * film_breathing;
    float2 uv = (texcoord - 0.5) * breath + 0.5;
    uv += float2(weave_x, weave_y);

    color = float4(tex2D(ReShade::BackBuffer, uv).rgb, 1.0);
}
#endif // ENABLE_GATE

// ── Pass 4: Transfer / VHS ───────────────────────────────────
#if ENABLE_TRANSFER || ENABLE_VHS
void film_transfer_PS(
    in  float4 pos      : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    float2 px = ReShade::PixelSize;
    float3 c  = tex2D(ReShade::BackBuffer, texcoord).rgb;

#if ENABLE_TRANSFER
    // Composite chroma blur
    if (film_composite_blur > 0.001)
    {
        float luma = dot(c, float3(0.299, 0.587, 0.114));
        int   taps = int(ceil(film_composite_blur * 2.0));
        float3 chroma_sum = 0.0;
        for (int i = -taps; i <= taps; i++)
            chroma_sum += tex2D(ReShade::BackBuffer, texcoord + float2(float(i)*px.x, 0.0)).rgb;
        float3 c_blurred    = chroma_sum / float(2*taps+1);
        float  luma_blurred = dot(c_blurred, float3(0.299, 0.587, 0.114));
        c = c_blurred * (luma_blurred > 0.0001 ? luma / luma_blurred : 1.0);
    }

    // Edge enhancement (luma unsharp mask)
    if (film_edge_enhance > 0.001)
    {
        float3 l = tex2D(ReShade::BackBuffer, texcoord - float2(px.x*2.0, 0.0)).rgb;
        float3 r = tex2D(ReShade::BackBuffer, texcoord + float2(px.x*2.0, 0.0)).rgb;
        float luma   = dot(c, float3(0.299,0.587,0.114));
        float luma_l = dot(l, float3(0.299,0.587,0.114));
        float luma_r = dot(r, float3(0.299,0.587,0.114));
        float edge   = luma - 0.5*(luma_l+luma_r);
        float luma_s = max(luma + edge * film_edge_enhance, 0.0001);
        c *= luma_s / max(luma, 0.0001);
        c  = max(c, 0.0);
    }
#endif // ENABLE_TRANSFER

#if ENABLE_VHS
    // VHS chroma smear: colour trails to the right (red bleeds most)
    if (film_vhs_chroma_smear > 0.001)
    {
        int taps = int(ceil(film_vhs_chroma_smear * 8.0));
        float3 smear = 0.0;
        for (int i = 1; i <= taps; i++)
        {
            float w = float(taps - i + 1) / float(taps + 1);
            smear += tex2D(ReShade::BackBuffer, texcoord - float2(float(i)*px.x, 0.0)).rgb * w;
        }
        float w_sum = float(taps) * 0.5;
        smear /= max(w_sum, 0.001);
        // Smear only affects chroma (preserve luma)
        float luma_c = dot(c, float3(0.299,0.587,0.114));
        float luma_s = dot(smear, float3(0.299,0.587,0.114));
        float3 c_smeared = smear + (luma_c - luma_s);
        c = lerp(c, c_smeared, saturate(film_vhs_chroma_smear * 0.5));
    }

    // VHS luminance noise
    if (film_vhs_noise > 0.001)
    {
        uint2  fc   = uint2(texcoord * float2(BUFFER_WIDTH, BUFFER_HEIGHT));
        uint   rng  = film_uhash(fc.x * 7919u + fc.y * 6271u + FRAMECOUNT * 0x1B873593u);
        float  n    = (film_unorm(rng) - 0.5) * 2.0;
        c += n * film_vhs_noise;
        c  = max(c, 0.0);
    }

    // VHS tracking error: horizontal displacement bands
    if (film_vhs_tracking > 0.001)
    {
        uint row  = uint(texcoord.y * float(BUFFER_HEIGHT));
        uint seed = film_uhash(row * 3761u + FRAMECOUNT * 0x45D9F3Bu);
        if (film_unorm(seed) < 0.02) // 2% of rows affected per frame
        {
            float disp = (film_unorm(film_uhash(seed + 1u)) - 0.5) * film_vhs_tracking;
            c = tex2D(ReShade::BackBuffer, texcoord + float2(disp, 0.0)).rgb;
        }
    }

    // VHS dropout: bright horizontal streaks
    if (film_vhs_dropout > 0.001)
    {
        uint row  = uint(texcoord.y * float(BUFFER_HEIGHT));
        uint seed = film_uhash(row * 9277u + (FRAMECOUNT / 2u) * 0x6C62272Eu);
        if (film_unorm(seed) < film_vhs_dropout * 0.2)
        {
            float streak_len  = film_unorm(film_uhash(seed+1u)) * 0.3 + 0.05;
            float streak_start = film_unorm(film_uhash(seed+2u));
            if (texcoord.x >= streak_start && texcoord.x < streak_start + streak_len)
                c = lerp(c, float3(1.0,1.0,1.0), 0.7);
        }
    }

    // VHS head switch: noise band at bottom ~5% of frame
    if (film_vhs_head_switch > 0.001 && texcoord.y > 0.93)
    {
        float  depth = (texcoord.y - 0.93) / 0.07;
        uint2  fc    = uint2(texcoord * float2(BUFFER_WIDTH, BUFFER_HEIGHT));
        uint   rng   = film_uhash(fc.x * 1447u + FRAMECOUNT * 0xB5297A4Du);
        float  n     = (film_unorm(rng) - 0.5) * 2.0;
        c += n * film_vhs_head_switch * depth;
        c  = max(c, 0.0);
    }
#endif // ENABLE_VHS

    color = float4(c, 1.0);
}
#endif // ENABLE_TRANSFER || ENABLE_VHS

// ── Pass: Letterbox (always runs, applies aspect crop) ───────
void film_letterbox_PS(
    in  float4 pos      : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    float3 c = tex2D(ReShade::BackBuffer, texcoord).rgb;
    color = apply_letterbox(float4(c, 1.0), texcoord);
}

// ── Pass: Depth debug (standalone, only active when debug enabled) ──
#if ENABLE_DOF
void film_depth_debug_PS(
    in  float4 pos      : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    if (!film_dof_debug)
    {
        color = float4(tex2D(ReShade::BackBuffer, texcoord).rgb, 1.0);
        return;
    }

    float raw  = ReShade::GetLinearizedDepth(texcoord);

    // Left half: raw depth (dark=near, bright=far)
    // Right half: inverted depth (bright=near, dark=far)
    // One side should show a meaningful gradient -- use that side
    // to read off the depth value of your subject for Focus Depth
    float grey = (texcoord.x < 0.5) ? raw : (1.0 - raw);

    // Pure greyscale -- ReShade menu renders on top automatically
    color = float4(grey, grey, grey, 1.0);
}
#endif // ENABLE_DOF

// ── Pass 5: Grain merged ─────────────────────────────────────
#if ENABLE_GRAIN
void film_grain_PS(
    in  float4 pos      : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 out_clean : SV_Target0,
    out float4 out_delta : SV_Target1)
{
    float3 c  = tex2D(ReShade::BackBuffer, texcoord).rgb;
    out_clean = float4(c, 1.0);

    float3 delta = float3(0.5, 0.5, 0.5); // neutral

    if (film_grain_intensity > 0.001)
    {
        // Grain coordinates -- scale by grain size for cluster effect
        // Aspect ratio > 1 stretches grain horizontally (anamorphic character)
        float2 grain_scale = float2(max(film_grain_size, 0.5) * max(film_grain_aspect, 1.0),
                                    max(film_grain_size, 0.5));
        float2 fc_grain = texcoord * float2(BUFFER_WIDTH, BUFFER_HEIGHT) / grain_scale;
        uint2  p   = uint2(fc_grain);
        uint   rng = film_uhash(film_uhash(p.y) + p.x);
        if (film_grain_animate) rng += FRAMECOUNT;

        float3 u3 = float3(film_unorm(film_next(rng)),
                            film_unorm(film_next(rng)),
                            film_unorm(film_next(rng)));
        float3 gn = film_gaussian3(u3);

        // Shadow gate: more grain in dark areas (authentic film behaviour)
        float3 c_lin  = film_lin(c);
        float  luma_g = dot(c_lin, float3(0.2126, 0.7152, 0.0722));
        float  shadow = lerp(film_grain_shadows, 1.0, saturate(luma_g * 6.0));

        float  intensity = film_grain_intensity * film_grain_intensity * 0.35;

        float3 cl_grained;
        if (film_grain_colour)
        {
            // Independent per-channel grain (authentic -- dye layers misregister)
            float3 cl = c_lin;
            cl += gn * intensity * shadow;
            cl = max(cl, 0.0);
            cl_grained = film_enc(cl);
        }
        else
        {
            // Luma-only grain
            float grey = dot(c_lin, float3(0.2126, 0.7152, 0.0722));
            grey += gn.x * intensity * shadow;
            grey = max(grey, 0.0);
            float orig = dot(c_lin, float3(0.2126, 0.7152, 0.0722));
            float3 cl = (orig > 0.0001) ? c_lin * (grey / orig) : c_lin;
            cl_grained = film_enc(cl);
        }

        delta = (cl_grained - c) * 0.5 + 0.5;
    }

    out_delta = float4(delta, 1.0);
}

void film_grain_composite_PS(
    in  float4 pos      : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    float3 clean = tex2D(film_clean_samp,     texcoord).rgb;
    float3 delta = tex2D(film_grain_raw_samp, texcoord).rgb;
    float3 grain = (delta - 0.5) * 2.0;

    // Diffuse grain slightly for cluster softness
    float2 px = ReShade::PixelSize * film_grain_size;
    float3 d_blur = 0.0;
    d_blur += tex2D(film_grain_raw_samp, texcoord + float2(-px.x,  0.0)).rgb;
    d_blur += tex2D(film_grain_raw_samp, texcoord + float2( px.x,  0.0)).rgb;
    d_blur += tex2D(film_grain_raw_samp, texcoord + float2( 0.0, -px.y)).rgb;
    d_blur += tex2D(film_grain_raw_samp, texcoord + float2( 0.0,  px.y)).rgb;
    d_blur  = (d_blur / 4.0 - 0.5) * 2.0;
    grain   = lerp(grain, d_blur, 0.4);

    color = float4(clean + grain, 1.0);
}
#endif // ENABLE_GRAIN

// ============================================================
// Lens Flare PS (exact HexLensFlare port)
// ============================================================
#if ENABLE_FLARE

// Scale UV around centre point -- exact copy of HexLensFlare scale()
float2 film_flare_scale_uv(float2 uv, float s)
{
    return (uv - 0.5) * s + 0.5;
}

// Exact port of HexLensFlare get_light() -- uses BORDER sampler
float film_flare_get_light(float2 uv)
{
    return step(film_flare_threshold, dot(tex2D(film_flare_src_samp, uv).rgb, 0.333));
}

// Pass 1: Prepare -- exact port of HexLensFlare PS_Prepare
void film_flare_prepare_PS(
    in  float4 pos   : SV_POSITION,
    in  float2 uv    : TEXCOORD,
    out float4 color : SV_TARGET)
{
    uv = 1.0 - uv; // mirror both axes through screen centre

    float3 c = 0.0;
    c += film_flare_get_light(uv)                                   * film_flare_color0;
    c += film_flare_get_light(film_flare_scale_uv(uv, 3.0))         * film_flare_color1;
    c += film_flare_get_light(film_flare_scale_uv(uv, 9.0))         * film_flare_color2;
    c += film_flare_get_light(film_flare_scale_uv(1.0 - uv, 0.666)) * film_flare_color3;

    color = float4(c, 1.0);
}

// Directional blur -- exact port of HexLensFlare blur()
// film_flare_squeeze squeezes the X component of the direction,
// turning the symmetric hexagon into an oval or crescent shape.
float3 film_flare_blur(sampler2D sp, float2 uv, float2 dir)
{
    float4 acc = 0.0;
    dir.x *= film_flare_squeeze; // squeeze X axis for crescent/oval effect
    dir   *= float(FLARE_DOWNSCALE) * film_flare_scale;
    uv    += dir * 0.5;
    [unroll] for (int i = 0; i < FLARE_BLUR_SAMPLES; i++)
        acc += float4(tex2D(sp, uv + dir * float(i)).rgb, 1.0);
    return acc.rgb / acc.a;
}

static const float film_c2PI = 3.14159265 * 2.0;

// Pass 2: Vertical blur
void film_flare_vblur_PS(
    in  float4 pos   : SV_POSITION,
    in  float2 uv    : TEXCOORD,
    out float4 color : SV_TARGET)
{
    float2 dir = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT)
               * float2(cos(film_c2PI / 2.0), sin(film_c2PI / 2.0));
    color = float4(film_flare_blur(film_flare_prepare_samp, uv, dir), 1.0);
}

// Pass 3: Diagonal blur + accumulate vertical
void film_flare_dblur_PS(
    in  float4 pos   : SV_POSITION,
    in  float2 uv    : TEXCOORD,
    out float4 color : SV_TARGET)
{
    float2 dir = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT)
               * float2(cos(-film_c2PI / 6.0), sin(-film_c2PI / 6.0));
    float3 c = film_flare_blur(film_flare_prepare_samp, uv, dir)
             + tex2D(film_flare_vblur_samp, uv).rgb;
    color = float4(c, 1.0);
}

// Pass 4: Rhomboid blur
void film_flare_rblur_PS(
    in  float4 pos   : SV_POSITION,
    in  float2 uv    : TEXCOORD,
    out float4 color : SV_TARGET)
{
    float2 px = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
    float2 d1 = px * float2(cos(-film_c2PI / 6.0),     sin(-film_c2PI / 6.0));
    float2 d2 = px * float2(cos(-5.0*film_c2PI / 6.0), sin(-5.0*film_c2PI / 6.0));
    float3 c1 = film_flare_blur(film_flare_vblur_samp, uv, d1);
    float3 c2 = film_flare_blur(film_flare_dblur_samp, uv, d2);
    color = float4((c1 + c2) * 0.5, 1.0);
}

// Pass 5: Screen blend
void film_flare_blend_PS(
    in  float4 pos   : SV_POSITION,
    in  float2 uv    : TEXCOORD,
    out float4 color : SV_TARGET)
{
    float3 base  = tex2D(ReShade::BackBuffer, uv).rgb;
    float3 flare = tex2D(film_flare_rblur_samp, uv).rgb;
    color = float4(1.0 - (1.0 - base) * (1.0 - flare * film_flare_intensity), 1.0);
}

#endif // ENABLE_FLARE

// ============================================================
// Ambient Bloom PS (AmbientLight algorithm, no external textures)
// ============================================================
#if ENABLE_FLARE

// Pass A: Downsample to 32x32 for adaptation detection
void film_bloom_ds_PS(
    in  float4 pos   : SV_POSITION,
    in  float2 uv    : TEXCOORD,
    out float4 color : SV_TARGET)
{
    color = tex2D(ReShade::BackBuffer, uv);
}

// Pass B: Average 32x32 to 1x1 scene luma
void film_bloom_luma_PS(
    in  float4 pos   : SV_POSITION,
    in  float2 uv    : TEXCOORD,
    out float4 color : SV_TARGET)
{
    color = 0.0;
    if (uv.x != 0.5 || uv.y != 0.5) { discard; }
    [loop] for (float i = 0.0; i <= 1.0; i += 0.03125)
    [loop] for (float j = 0.0; j <= 1.0; j += 0.03125)
        color.rgb += tex2D(film_bloom_ds_samp, float2(i, j)).rgb;
    color.rgb /= 32.0 * 32.0;
    color.a = 1.0;
}

// DetectHigh: exact AL PS_AL_DetectHigh -- boosts by max^2, redistributes colour
void film_bloom_detect_PS(
    in  float4 pos   : SV_POSITION,
    in  float2 uv    : TEXCOORD,
    out float4 color : SV_TARGET)
{
    float4 x = tex2D(ReShade::BackBuffer, uv);
    x = float4(x.rgb * pow(abs(max(x.r, max(x.g, x.b))), 2.0), 1.0);

    float base = (x.r + x.g + x.b) / 3.0;
    float nR = x.r * 2.0 - base;
    float nG = x.g * 2.0 - base;
    float nB = x.b * 2.0 - base;

    if (nR < 0.0) { nG += nR*0.5; nB += nR*0.5; nR = 0.0; }
    if (nG < 0.0) { nB += nG*0.5; nR = max(nR+nG*0.5, 0.0); nG = 0.0; }
    if (nB < 0.0) { nR = max(nR+nB*0.5, 0.0); nG = max(nG+nB*0.5, 0.0); nB = 0.0; }
    if (nR > 1.0) { nG += (nR-1.0)*0.5; nB += (nR-1.0)*0.5; nR = 1.0; }
    if (nG > 1.0) { nB += (nG-1.0)*0.5; nR = min(nR+(nG-1.0)*0.5, 1.0); nG = 1.0; }
    if (nB > 1.0) { nR = min(nR+(nB-1.0)*0.5, 1.0); nG = min(nG+(nB-1.0)*0.5, 1.0); nB = 1.0; }

    color = float4(nR, nG, nB, 1.0);
}

// H blur -- reads from h_tex (detect output or previous V output), writes to v_tex
void film_bloom_hblur_PS(
    in  float4 pos   : SV_POSITION,
    in  float2 uv    : TEXCOORD,
    out float4 color : SV_TARGET)
{
    static const float offsets[5] = { 0.0, 2.4347826, 4.3478260, 6.2608695, 8.1739130 };
    static const float weights[5] = { 0.16818994, 0.27276957, 0.111690125, 0.024067905, 0.0021112196 };
    float2 px = float2(16.0 * BUFFER_RCP_WIDTH, 0.0);
    float4 c = tex2D(film_bloom_h_samp, uv) * weights[0];
    c = float4(max(c.rgb - film_bloom_threshold * 0.01, 0.0), c.a);
    [unroll] for (int i = 1; i < 5; i++)
    {
        c += tex2D(film_bloom_h_samp, uv + px * offsets[i]) * weights[i];
        c += tex2D(film_bloom_h_samp, uv - px * offsets[i]) * weights[i];
    }
    color = c;
}

// V blur -- reads from v_tex (H output), writes to h_tex
void film_bloom_vblur_PS(
    in  float4 pos   : SV_POSITION,
    in  float2 uv    : TEXCOORD,
    out float4 color : SV_TARGET)
{
    static const float offsets[5] = { 0.0, 2.4347826, 4.3478260, 6.2608695, 8.1739130 };
    static const float weights[5] = { 0.16818994, 0.27276957, 0.111690125, 0.024067905, 0.0021112196 };
    float2 px = float2(0.0, 16.0 * BUFFER_RCP_HEIGHT);
    float4 c = tex2D(film_bloom_v_samp, uv) * weights[0];
    c = float4(max(c.rgb - film_bloom_threshold * 0.01, 0.0), c.a);
    [unroll] for (int i = 1; i < 5; i++)
    {
        c += tex2D(film_bloom_v_samp, uv + px * offsets[i]) * weights[i];
        c += tex2D(film_bloom_v_samp, uv - px * offsets[i]) * weights[i];
    }
    color = c;
}

// Final blend with AL adaptation
void film_bloom_blend_PS(
    in  float4 pos   : SV_POSITION,
    in  float2 uv    : TEXCOORD,
    out float4 color : SV_TARGET)
{
    float3 base  = tex2D(ReShade::BackBuffer, uv).rgb;
    float3 bloom = tex2D(film_bloom_h_samp, uv).rgb; // last written is h_tex after V pass

    // AL adaptation: compute scene luma, back off bloom in bright scenes
    float adapt = 0.0;
    if (film_bloom_adapt > 0.001)
    {
        float4 luma4 = tex2D(film_bloom_luma_samp, 0.5) / 4.215;
        float  low   = sqrt(0.241*luma4.r*luma4.r + 0.691*luma4.g*luma4.g + 0.068*luma4.b*luma4.b);
        low   = pow(low * 1.25, 2.0);
        adapt = low * (low + 1.0) * film_bloom_adapt * film_bloom_intensity * 5.0;
    }

    float3 result = 1.0 - (1.0 - base) * (1.0 - bloom * max(0.0, film_bloom_intensity - adapt));

    // Dither
    float dither = 0.15 * (1.0 / 1023.0);
    dither = lerp(2.0*dither, -2.0*dither,
                  frac(dot(uv, float2(BUFFER_WIDTH, BUFFER_HEIGHT) * float2(1.0/16.0, 10.0/36.0)) + 0.25));
    color = float4(result + dither, 1.0);
}

#endif // ENABLE_FLARE


// ============================================================
// Technique
// ============================================================

technique Film_Standalone
<
    ui_label   = "Film Standalone";
    ui_tooltip = "Cinematic film medium emulation.\n"
                 "Layer 1: Film Stock  (ENABLE_FILM_STOCK)\n"
                 "Layer 2: Lens        (ENABLE_LENS)\n"
                 "Layer 3: Gate        (ENABLE_GATE)\n"
                 "Layer 4: Transfer    (ENABLE_TRANSFER)\n"
                 "Layer 5: VHS         (ENABLE_VHS)\n"
                 "Layer 6: Film Grain  (ENABLE_GRAIN)";
>
{
#if ENABLE_FILM_STOCK
    pass HalationExtract
    {
        VertexShader = PostProcessVS;
        PixelShader  = film_halation_extract_PS;
        RenderTarget = film_halation_tex;
    }
    pass HalationHBlur
    {
        VertexShader = PostProcessVS;
        PixelShader  = film_halation_hblur_PS;
        RenderTarget = film_halation_hblur;
    }
    pass HalationVBlur
    {
        VertexShader = PostProcessVS;
        PixelShader  = film_halation_vblur_PS;
        RenderTarget = film_halation_tex;
    }
    pass FilmStock
    {
        VertexShader = PostProcessVS;
        PixelShader  = film_stock_PS;
    }
#endif

#if ENABLE_LENS
    pass Lens
    {
        VertexShader = PostProcessVS;
        PixelShader  = film_lens_PS;
    }
#endif

#if ENABLE_GATE
    pass Gate
    {
        VertexShader = PostProcessVS;
        PixelShader  = film_gate_PS;
    }
#endif

#if ENABLE_TRANSFER || ENABLE_VHS
    pass Transfer
    {
        VertexShader = PostProcessVS;
        PixelShader  = film_transfer_PS;
    }
#endif

    // Letterbox always runs last before grain
    pass Letterbox
    {
        VertexShader = PostProcessVS;
        PixelShader  = film_letterbox_PS;
    }

#if ENABLE_DOF
    pass DepthDebug
    {
        VertexShader = PostProcessVS;
        PixelShader  = film_depth_debug_PS;
    }
#endif

#if ENABLE_GRAIN
    pass GrainCapture
    {
        VertexShader = PostProcessVS;
        PixelShader  = film_grain_PS;
        RenderTarget0 = film_clean_tex;
        RenderTarget1 = film_grain_raw_tex;
    }
    pass GrainComposite
    {
        VertexShader = PostProcessVS;
        PixelShader  = film_grain_composite_PS;
    }
#endif
#if ENABLE_FLARE
    // --- Ambient Bloom passes (AmbientLight approach) ---
    // Downsample + average for adaptation detection
    pass BloomDS { VertexShader = PostProcessVS; PixelShader = film_bloom_ds_PS;     RenderTarget = film_bloom_ds_tex; }
    pass BloomLuma { VertexShader = PostProcessVS; PixelShader = film_bloom_luma_PS; RenderTarget = film_bloom_luma_tex; }
    // Detect: writes to h_tex
    pass BloomDetect { VertexShader = PostProcessVS; PixelShader = film_bloom_detect_PS; RenderTarget = film_bloom_h_tex; }
    // Ping-pong H/V: H reads h writes v, V reads v writes h
    pass BloomH1 { VertexShader = PostProcessVS; PixelShader = film_bloom_hblur_PS; RenderTarget = film_bloom_v_tex; }
    pass BloomV1 { VertexShader = PostProcessVS; PixelShader = film_bloom_vblur_PS; RenderTarget = film_bloom_h_tex; }
    pass BloomH2 { VertexShader = PostProcessVS; PixelShader = film_bloom_hblur_PS; RenderTarget = film_bloom_v_tex; }
    pass BloomV2 { VertexShader = PostProcessVS; PixelShader = film_bloom_vblur_PS; RenderTarget = film_bloom_h_tex; }
    pass BloomH3 { VertexShader = PostProcessVS; PixelShader = film_bloom_hblur_PS; RenderTarget = film_bloom_v_tex; }
    pass BloomV3 { VertexShader = PostProcessVS; PixelShader = film_bloom_vblur_PS; RenderTarget = film_bloom_h_tex; }
    // Blend reads h_tex (last V wrote there)
    pass BloomBlend { VertexShader = PostProcessVS; PixelShader = film_bloom_blend_PS; }
    // --- HexLensFlare passes ---
    pass FlarePrep
    {
        VertexShader = PostProcessVS;
        PixelShader  = film_flare_prepare_PS;
        RenderTarget = film_flare_prepare_tex;
    }
    pass FlareVBlur
    {
        VertexShader = PostProcessVS;
        PixelShader  = film_flare_vblur_PS;
        RenderTarget = film_flare_vblur_tex;
    }
    pass FlareDBlur
    {
        VertexShader = PostProcessVS;
        PixelShader  = film_flare_dblur_PS;
        RenderTarget = film_flare_dblur_tex;
    }
    pass FlareRBlur
    {
        VertexShader = PostProcessVS;
        PixelShader  = film_flare_rblur_PS;
        RenderTarget = film_flare_rblur_tex;
    }
    pass FlareBlend
    {
        VertexShader = PostProcessVS;
        PixelShader  = film_flare_blend_PS;
    }
#endif
}

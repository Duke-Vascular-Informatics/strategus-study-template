# Manuscript figures — greyscale-safe by construction

## Where figures come from in a Strategus study

Strategus produces **no manuscript figures**. Its outputs are result tables in
a results schema, browsed through the OHDSI Shiny viewer
(`docs/UsingThisTemplate.md`). That viewer is an exploration tool built from
`OhdsiShinyModules`; it is not the journal submission path and is not something
this template restyles.

Manuscript figures come from an **optional custom step / Word report** layered
on top of the Strategus run — the `pad-amp-ed-desc` hybrid pattern. Most
studies never add one. If yours does, every figure it draws goes through
`R/figure_style.R`.

If your study has no custom report step, nothing sources `R/figure_style.R` and
it costs you nothing.

## The rule

> **A figure must never encode a series by colour alone.**

Journals commonly print in greyscale, and hues chosen to look distinct on
screen usually have near-identical *luminance* — desaturated, they collapse
into one grey. This is not a hypothetical: a four-curve calibration overlay
using navy / red / green / orange became a single indistinguishable line in
greyscale, and its `dotted` reference diagonal shared a linetype with one model
curve, hiding that curve even before conversion.

`R/figure_style.R` enforces the fix: colour, linetype **and** shape all come
from one fixed table, giving three independent channels.

## Using it

```r
source("R/figure_style.R")   # self-guarding; safe to source repeatedly

# 1. Build the plotting frame with a STABLE factor order.
df$series <- factor(df$series, levels = series_levels)

# 2. Pull the greyscale scales for those levels.
gs <- .gs_scales(series_levels)

# 3. Map colour, linetype AND shape to the same variable.
p <- ggplot2::ggplot(df, ggplot2::aes(x, y,
       colour = series, linetype = series, shape = series)) +
  ggplot2::geom_line() +
  ggplot2::geom_point(size = 2) +
  gs$colour + gs$linetype + gs$shape +
  theme_manuscript()

# 4. Save. Writes 600 dpi LZW TIFF + vector PDF + screen PNG; returns the PNG
#    path, which is what officer::body_add_img() needs.
png_path <- save_figure(p, output_folder, "figure_2.png", width = 6, height = 5)
```

### Embedding in a Word report

Derive the embed height from the file, never from a restated ratio — figure
dimensions change and a hardcoded ratio silently stretches the image:

```r
aspect <- .png_aspect(png_path)                       # NA-safe
doc <- officer::body_add_img(doc, src = png_path,
                             width = 5.5,
                             height = 5.5 * (if (is.na(aspect)) 0.75 else aspect))
```

## The encoding table

| Slot | Colour | Linetype | Shape | Reads as |
|---|---|---|---|---|
| 1 | black | solid | filled circle | primary |
| 2 | black | longdash | filled triangle | primary |
| 3 | grey45 | dotdash | open square | secondary |
| 4 | grey45 | dotted | open diamond | secondary |
| 5 | grey70 | solid | open circle | reference |
| 6 | grey70 | dashed | open triangle | reference |

Only **two** grey levels are used for data series, plus a lighter one for
references. More grey steps than that stop being separable after a photocopy.

**Slots 5–6 are reserved for subordinate reference series** — a decision
curve's "Treat all" / "Treat none", a null line. Pin them explicitly:

```r
gs <- .gs_scales(all_series, slots = c(seq_along(model_names), 5L, 6L))
```

Without this the default numbering gives them slots 2–3, and with a single
model `"Treat all"` renders as a **black filled triangle — more prominent than
the model curve it is supposed to sit behind.** A four-series figure happens to
work by coincidence (4 models + 2 references = exactly 6 slots), which is
precisely why this is easy to miss.

Asking for a 7th series **errors** rather than silently recycling a colour. If
you genuinely need one, add a row to `.gs_series_palette` — do not fall back to
hue.

## Traps worth knowing

**Reference lines must not share a linetype with a data series.** Slots 3 and 4
use `dotdash` and `dotted`, so a reference line must not. Use
`.calibration_reference_line()` (thin `grey80` solid) rather than inventing one.

**Axis limits must cover every value drawn.** `.calibration_axis_limits()`
takes a vector — pass *all* of it. If a marginal distribution strip plots
per-patient values beneath a panel showing binned means, the individual values
routinely fall outside the bin-mean range; because the panels share an axis,
ggplot silently drops them, from the one panel whose job is showing where
patients are. The symptom is a `Removed N rows containing missing values`
warning, which is easy to miss in a long log.

**`coord_equal()` breaks patchwork alignment.** It pins panel width to panel
height, so a stacked marginal panel cannot be stretched to match and the two
x-axes end up at different scales — actively misleading. Use
`theme(aspect.ratio = 1)` instead, which constrains height from the
layout-assigned width.

**Fills cannot use shape or linetype.** For histograms and areas, two grey
levels far apart (`grey25` / `grey80`) is the limit. Beyond two categories,
convert to faceted small multiples rather than hunting for a third grey.

**`ragg` is optional.** It is the preferred TIFF device but compiles against
system libraries (libpng, libtiff, freetype, harfbuzz, fribidi) that a
protected analytic space may not have. `figure_style.R` loads it softly and
`save_figure()` falls back to `grDevices::tiff()` — still 600 dpi LZW. If you
add it to a deployment bundle's installer, put it in an **optional** list:
an installer that `stop()`s on it will abort before the fallback can help.

## Verifying

Do not judge greyscale-safety from the colour render. Convert and look:

```bash
magick output/figures/figure_2.tiff -colorspace Gray /tmp/check.png
```

Then confirm every series is still separable and that no series has merged
with a reference line. A clean exit code says nothing about whether a figure
is readable — several real defects here were found only by looking at output,
including two patients silently dropped from a distribution panel.

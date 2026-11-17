# Colour grading

Log footage (Sony S-Log3, DJI D-Log M) looks flat until it is converted for a normal display. Camera Toolkit grades it **non-destructively**: a grade is a few numbers stored in the catalog, applied while tiles decode, while the preview plays and while a copy renders. The original clip is only ever read.

## How a picture is built

Always in this order, never mixed:

1. **Camera adjustments** — exposure and white balance, in scene-linear light through the clip's own log curve.
2. **Conversion** — log → Rec.709. For Sony S-Log3 this is Sony's conversion: Sony's own s709 LUT once it is imported (Settings › Color › Get Sony's Official Conversion LUTs…), and until then the built-in conversion computed from Sony's published math, labelled "Built-in (Sony math)". D-Log M uses DJI's LUT once imported; there is no built-in D-Log M conversion.
3. **Look** — optional creative colour on top of the Rec.709 picture, mixed by its own intensity.
4. **Contrast and saturation.**

So a LUT is applied *after* the conversion when it is a look, and *instead of* the conversion when it expects log footage. Every imported LUT says which it is (guessed from its name — `SLog3`, `SGamut3`, `D-Log M`… mean a conversion — and editable in Settings). A creative LUT that takes log in ("S-Log3 to film") counts as a conversion. Conversion LUTs never appear among the looks, and a look never goes on log footage that is not converted, so a log-in LUT can never be stacked on a converted picture.

The panel shows the two stages as **1 Conversion** (with its source, e.g. "Sony S-Log3 → Rec.709 · Built-in (Sony math)") and **2 Look**, under one line that says the order. "Original (log)" is the before/after reference, not a look.

## What a grade is

`ClipGrade` (`Sources/CameraToolkitCore/Color/ClipGrade.swift`):

| Field | Range | Stage |
|---|---|---|
| exposure | −4…+4 stops | 1 |
| temperature, tint | −100…+100 | 1 |
| conversion | default · built-in · a conversion LUT · off | 2 |
| look | none · a built-in look · a look LUT | 3 |
| intensity | 0–100 % | 3 (how much of the look) |
| contrast, saturation | −100…+100 | 4 |
| profile mark | camera metadata · marked profile · not log | which conversion applies |

Grades are keyed by file identity (`DisplayRotation.fileKey`: name, bytes, modification second), exactly like saved rotations, so a grade follows the clip from card to Buffer to NAS. They live in the catalog's `color_grades` table (`file_key`, the grade as JSON, `updated_at`). The schema change only adds that table, and every later field is an optional JSON key (a grade saved before the conversion stage existed reads as default conversion, no look). Every grade change is one Undo step (`UndoConfigChange.colorGrades`); a slider drag is saved once it settles.

Settings › Color holds, per log profile, the **default conversion** and the **default look** (`config.json`). A log clip with no grade of its own is drawn with them, so S-Log3 clips show converted the moment they appear. `GradeResolver` turns a stored grade into what is drawn; the app and the before-sync renderer both use it.

## Built-in looks

Six looks designed in code (`BuiltInLooks.swift`), each Rec.709 in → Rec.709 out, tuned on real S-Log3 clips: **Soft Film** (lifted warm blacks, gentle S, restrained colour), **Bright & Airy** (open mids, soft contrast, light colour), **Teal & Orange** (teal shadows and blues, warm highlights), **Moody Matte** (darker, matte blacks, muted), **Rich & Vivid** (deeper contrast, vibrance) and **Black & White** (red-filtered mono, faint warm tone). Hue shifts are weighted away from the skin band and saturation pushes are vibrance, so skin stays natural; each starts at 70–75 % (black and white at 100 %).

## Finding log footage

- **Sony**: the clip's `…M01.XML` sidecar names `CaptureGammaEquation` and `CaptureColorPrimaries`. `s-log3-cine` / `s-log3` with `s-gamut3-cine` or `s-gamut3` is detected. Rec.709, HLG, S-Cinetone and S-Log2 are not treated as log.
- **DJI**: D-Log M is not announced reliably in DJI files, so it is never guessed. Mark clips with **Color › Footage Is › D-Log M** on the board, or from the grade panel's profile menu.

Detection reads the sidecar (a couple of kilobytes) off the main actor, a screenful at a time. A log clip without a look wears a quiet `S-Log3` tag on its tile; a graded clip draws graded with a small filter glyph.

## The built-in conversion

The fallback until Sony's own LUT is imported. All maths is in `GradePipeline.swift` and `ColorMath.swift`, from published references; no vendor LUT files are in the repository.

1. **Decode S-Log3** to scene-linear reflectance with Sony's formula ("Technical Summary for S-Gamut3.Cine/S-Log3 and S-Gamut3/S-Log3"): 18 % grey ↔ 10-bit code 420, 0 % ↔ 95, 90 % ↔ 598, linear toe below code 171.21. Sony's log clips are full-range; for a video-range clip the decoded value is mapped back to the full code value first (`VideoSignalRange`).
2. **Gamut**: S-Gamut3.Cine (or S-Gamut3) → Rec.709 through XYZ, from the published primaries and D65 (the normalized primary matrices match Sony's to 1e-7; tests check them).
3. **Display rendering**: a 1.12 system gamma around mid grey (grey stays at the Rec.709 value 0.409), then a rational highlight shoulder from 60 % that approaches but never reaches 100 %, so S-Log3's top stops roll off instead of clipping. Out-of-gamut negatives are pulled to the gamut edge. Then the BT.709 OETF.
4. Exposure and white balance run before step 1's conversion, in linear light. Contrast and saturation run on the result.

The whole grade is per pixel, so it is baked into one 3D cube (33³ for tiles and preview, 64³ for renders) and applied by Core Image (`CIColorCube`) on the GPU. Colour management is off for that pass: a log curve is defined on code values, and the decoded frame's values are fed in untouched. The output is tagged the way AVFoundation tags Rec.709 video, so a graded still and graded playback match (the opt-in sample test checks the two paths agree to within 0.1 %).

## Sony's conversion LUTs

Sony lists its LUTs on its cinematography site (`https://sony-cinematography.com/resources/luts/`); the "Sony Collection" there offers `Slog3-S-Gamut3.Cine To s709 V200`. s709 is the Rec.709 look Sony's current cameras use, and it is the LUT an A7V's own clip metadata names (`SL3SG3Ctos709.cube`), so it is the default once imported. Settings › Color › **Get Sony's Official Conversion LUTs…** shows the address and, when asked, downloads the archive (about 230 KB) from the host that page links and imports it as the S-Log3 conversion, making s709 the default. The download is HTTPS only, redirects included; its size is checked against a 20 MB cap while it streams; the file must match the archive's pinned SHA-256 (`SonyConversionLUTs.s709SHA256`) before anything is extracted; and the zip's directory must promise no more than 64 entries and 64 MB unpacked. If Sony republishes the file and the hash no longer matches, nothing is opened and the message points to Sony's page.

Checked on real S-Log3 clips: s709 renders mid grey slightly brighter, contrast a little softer and colour a little calmer than the built-in math, with natural skin and clean blacks, which confirms the LUT reads the clips' full-range code values the way the app feeds them. Sony's page asks for a few details before its own download button; **Open Sony's LUT Page** goes there instead, and the downloaded file can be imported by hand.

## Imported LUTs

Settings › Color › Import LUTs… copies `.cube` files (after they parse) into `~/Library/Application Support/CameraToolkit/LUTs`, named by a hash of their contents, with an `index.json` for display names. Sony's official LUTs, DJI's D-Log M LUT and creative looks all work. The parser (`CubeLUT.swift`) reads 1D and 3D tables, `DOMAIN_MIN`/`DOMAIN_MAX`, Resolve's `LUT_1D_INPUT_RANGE`/`LUT_3D_INPUT_RANGE`, a 1D shaper followed by a 3D table, comments and CRLF, and samples 3D tables with tetrahedral interpolation.

## Grading

- **One by one**: open a clip, press **G** (or the filter button). The panel shows a histogram, Graded / Split / Original (drag the line on the picture; **B** flips before/after), the look, intensity and the controls, Copy/Paste, and Render. A strip of every look, rendered from the frame under the playhead, sits under the video: choosing a look is clicking a picture. Playback, scrubbing and a paused frame all show the grade live.
- **Blanket**: right-click › **Color › Apply Look to Log Clips…** (the selection) or **…to All Log Clips in <event or folder>…**. A sheet shows every affected clip split before/after, the count, and what is left alone, then applies it as one Undo step. It can also make the look the default for that profile.

## Rendered copies

**Render Graded Copy** (panel) or **Color › Render Graded Copies** queues a job in the Jobs window. Each copy is hardware HEVC Main 10 (VideoToolbox), 4:2:0, tagged Rec.709 (primaries, transfer, matrix), same size and frame rate, audio passed through untouched, at 75 % of the original's video data rate (8–150 Mb/s). It goes to `<event>/Edited/Rec709/<clip>_709.mov`.

- **Partials** are written as `Edited/Rec709/.TemporaryItems/<UUID>.ctsync-render.partial.mov`. Sync to NAS, the NAS listings and the edit-tag scan skip both the `.TemporaryItems` folder and the `.ctsync-` marker, so a partial a crash leaves can never be copied to the NAS. Every render clears stale partials (only names of exactly that form) in the folders it touches before it starts; the temporary folder is removed only when empty (`rmdir`).
- A finished partial is checked (opens, one video track, same length, decodes a frame), then renamed into place with `NASFileIO.renameExclusive`, which claims the name first and so never replaces a file, on smbfs and exFAT too.
- **Identity**: the copy carries the grade's fingerprint and the original's identity. A copy with the same grade already there — on the drive, or at the NAS mirror of the folder (where Sync already carried it) — is skipped. A NAS name is never reused for a different render on the drive. If a taken name's tags cannot be read in time, nothing is rendered beside it.
- **Another grade**: a changed grade gets `_709 (2).mov`; the older copy is kept and the job's summary says so. Nothing is deleted.
- Both the manual render and the before-sync render read the signal range from the clip's own format, so they agree on the fingerprint.
- **Stop** in the Jobs window ends the job after the frame being written; the copy in progress is discarded, finished copies stay.
- **Free space**: before each clip the job estimates the copy's size and stops, with a message, if that would leave less than 5 GB free where the copy goes.

The copy carries the capture time (`com.apple.quicktime.creationdate`, `©day`) and camera, and the original's modification time. The original shows **Edited · Rec709** on its tile. Copies sync to the NAS with the normal Sync.

## Immich

Immich reads the NAS library as an external library (see `IMMICH.md`), and each event's `Edited` folder is imported. **Settings › Color › Send graded versions of log videos to Immich** (off by default) renders the Rec.709 copy of every graded log clip in the events being synced before Sync to NAS:

- It works from the catalog, so no board needs to be open, and counts only copies not already made (on the drive or the NAS). Clips are checked eight at a time within a 30-second budget, with progress in the status line; a clip whose existing copy does not answer in time (a sleeping NAS) stays in the plan as unchecked, and its render looks again and never makes a second copy.
- The first time, and whenever more than five copies are due, it shows the count, the estimated size and the free space, and asks: render and sync, sync without rendering, or cancel.
- The render is queued, and the Sync is queued as its own job right behind it. The Sync keeps its place whatever happens to the render — finished, failed, stopped, or taken off the queue.
- Copies are written at their final name on the drive, so Immich imports each once and never sees it renamed. Nothing is uploaded and no Immich API is called by this feature.

Send to Immich also checks for log clips without a copy, every time, and offers to render them first. Clips that are only on the NAS get their copy written straight into the NAS event's `Edited/Rec709`. The copies then take their originals' places in the event albums, and are stacked on top with **Stack bursts and edits** on. See `IMMICH.md` › Send to Immich.

## Not covered

- D-Log M has no built-in conversion (DJI publishes no formula); import DJI's LUT and set it as the D-Log M default.
- The layout migrations copy saved rotations to a renamed file's new key but not grades; a clip renamed with `(N)` by a migration shows ungraded until it is graded again.
- 360° originals (`.OSV`, `.INSV`) are not graded.

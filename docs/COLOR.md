# Colour grading

Log footage (Sony S-Log3, DJI D-Log M) looks flat until it is converted for a normal display. Camera Toolkit grades it **non-destructively**: a grade is a few numbers stored in the catalog, applied while tiles decode, while the preview plays and while a copy renders. The original clip is only ever read.

## What a grade is

`ClipGrade` (`Sources/CameraToolkitCore/Color/ClipGrade.swift`):

| Field | Range | Applied |
|---|---|---|
| look | none · built-in Rec.709 · an imported LUT | after exposure and white balance |
| intensity | 0–100 % | mixes the look over the adjusted picture |
| exposure | −4…+4 stops | scene-linear, through the clip's own log curve |
| temperature, tint | −100…+100 | scene-linear channel gains, luminance kept |
| contrast | −100…+100 | S-curve around mid grey, after the look |
| saturation | −100…+100 | after the look |
| profile mark | camera metadata · marked profile · not log | which conversion applies |

Grades are keyed by file identity (`DisplayRotation.fileKey`: name, bytes, modification second), exactly like saved rotations, so a grade follows the clip from card to Buffer to NAS. They live in the catalog's `color_grades` table (`file_key`, the grade as JSON, `updated_at`). The schema change only adds that table. Every grade change is one Undo step (`UndoConfigChange.colorGrades`); a slider drag is saved once it settles, so a drag is one step too.

The **default look per log profile** (Settings › Color) is a setting in `config.json`. A log clip with no grade of its own is shown, played and rendered with its profile's default, so new clips get it as soon as they appear without anything being written per clip.

## Finding log footage

- **Sony**: the clip's `…M01.XML` sidecar names `CaptureGammaEquation` and `CaptureColorPrimaries`. `s-log3-cine` / `s-log3` with `s-gamut3-cine` or `s-gamut3` is detected. Rec.709, HLG, S-Cinetone and S-Log2 are not treated as log.
- **DJI**: D-Log M is not announced reliably in DJI files, so it is never guessed. Mark clips with **Color › Footage Is › D-Log M** on the board, or from the grade panel's profile menu.

Detection reads the sidecar (a couple of kilobytes) off the main actor, a screenful at a time. A log clip without a look wears a quiet `S-Log3` tag on its tile; a graded clip draws graded with a small filter glyph.

## The colour math

All maths is in `GradePipeline.swift` and `ColorMath.swift`, from published references; no vendor LUT files are in the repository.

1. **Decode S-Log3** to scene-linear reflectance with Sony's formula ("Technical Summary for S-Gamut3.Cine/S-Log3 and S-Gamut3/S-Log3"): 18 % grey ↔ 10-bit code 420, 0 % ↔ 95, 90 % ↔ 598, linear toe below code 171.21. Sony's log clips are full-range; for a video-range clip the decoded value is mapped back to the full code value first (`VideoSignalRange`).
2. **Gamut**: S-Gamut3.Cine (or S-Gamut3) → Rec.709 through XYZ, from the published primaries and D65 (the normalized primary matrices match Sony's to 1e-7; tests check them).
3. **Display rendering**: a 1.12 system gamma around mid grey (grey stays at the Rec.709 value 0.409), then a rational highlight shoulder from 60 % that approaches but never reaches 100 %, so S-Log3's top stops roll off instead of clipping. Out-of-gamut negatives are pulled to the gamut edge. Then the BT.709 OETF.
4. Exposure and white balance run before step 1's conversion, in linear light. Contrast and saturation run on the result.

The whole grade is per pixel, so it is baked into one 3D cube (33³ for tiles and preview, 64³ for renders) and applied by Core Image (`CIColorCube`) on the GPU. Colour management is off for that pass: a log curve is defined on code values, and the decoded frame's values are fed in untouched. The output is tagged the way AVFoundation tags Rec.709 video, so a graded still and graded playback match (the opt-in sample test checks the two paths agree to within 0.1 %).

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

- It works from the catalog, so no board needs to be open, and counts only copies not already made (on the drive or the NAS).
- The first time, and whenever more than five copies are due, it shows the count, the estimated size and the free space, and asks: render and sync, sync without rendering, or cancel.
- The render is queued, and the Sync is queued as its own job right behind it. The Sync keeps its place whatever happens to the render — finished, failed, stopped, or taken off the queue.
- Copies are written at their final name on the drive, so Immich imports each once and never sees it renamed. Nothing is uploaded and no Immich API is called by this feature.

Graded copies are not stacked with their originals in Immich. Stacking would need both assets' ids after Immich's scan, writes to Immich state the app otherwise never makes, and it would break whenever a rename makes Immich treat a file as new. The copy sits next to the original by capture time instead.

## Not covered

- D-Log M has no built-in conversion (DJI publishes no formula); import DJI's LUT and set it as the D-Log M default.
- The layout migrations copy saved rotations to a renamed file's new key but not grades; a clip renamed with `(N)` by a migration shows ungraded until it is graded again.
- 360° originals (`.OSV`, `.INSV`) are not graded.

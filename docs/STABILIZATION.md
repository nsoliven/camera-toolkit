# Stabilization

Camera Toolkit stabilizes video clips from the camera's own motion data
(gyroscope, accelerometer, lens and IBIS metadata). It drives an installed
copy of [Gyroflow](https://gyroflow.xyz), the free (GPL) stabilizer, from
its command line. Gyroflow is never bundled or downloaded by the app.

## What it needs

- **Gyroflow, downloaded from gyroflow.xyz.** The Mac App Store build is
  sandboxed: its command line cannot open any file it was not handed through
  its own window, so it cannot render in the background (Gyroflow issue
  #1190, closed as "expected"). The app tells the two apart by the bundle's
  `_MASReceipt` and says which one is needed. "Open in Gyroflow" keeps
  working with either.
- **Motion data in the clip.** A cheap probe reads only the movie header
  (`moov`) and looks for a metadata track Gyroflow reads: Sony `rtmd`
  (A7-series), DJI `djmd`/`dbgi` (Osmo Action, Osmo Nano), GoPro `gpmd`,
  `camm`. A clip without one shows the toggle disabled with "No motion data
  in this file".

## Where things go

| Asked for | File |
| --- | --- |
| Stabilize only | `<event>/Edited/Stabilized/<name>_stab.mov` (ProRes 422 HQ, 10-bit 4:2:2; still log when shot in log) |
| Stabilize + grade | `<event>/Edited/Rec709/<name>_709.mov` (one file) |

For stabilize + grade, the clip is stabilized first, while it is still log,
into an intermediate ProRes in `Edited/Rec709/.TemporaryItems/` (same
volume, skipped by Sync and the edit-tag scan). The graded copy is drawn
from it, and the intermediate is deleted once the graded copy is in place,
or on Stop or failure. Only the graded copy was asked for, so only it is
kept.

Copies go next to the clip's event: on the drive when the clip is on the
drive, in the NAS event folder when the clip is only on the NAS. A copy
never replaces a file; a taken name moves the new copy to `… (2)`.

The graded copy's grade tag includes the stabilization
(`<recipe>|stab1|medium|h0`), so a stabilized copy is never taken for an
unstabilized one, and changing the smoothing makes a new copy beside the
old. A stabilized-only copy carries the same identity in its comment
(`org.cameratoolkit.stab source=<key> stab=<fingerprint>`).

## The Gyroflow run

```
gyroflow <clip> -f -t _ctk-stabilizing --stdout-progress --preset <file>.gyroflow
```

Everything that decides the render is in the preset file (Gyroflow rewrites
`'` to `"` in inline JSON, which would break paths with apostrophes):
"Default" smoothing (Low 0.25, Medium 0.5, High 0.8), horizon lock off,
dynamic crop (adaptive zoom, 4 s window), lens correction from the camera's
data, the clip's own size and frame rate, ProRes 422 HQ through
VideoToolbox, PCM audio. The preview uses ProRes Proxy and a 3-second
`trim_ranges_ms`.

Gyroflow writes to a partial name in the destination's temporary folder.
Progress comes from its `Rendering progress: n/N frames` lines. Gyroflow's
command line does not quit after an error, so an `[ERROR]` line with no
render under way ends the run after a few seconds. Stop ends the process
(SIGTERM, then SIGKILL) and deletes the partial. A finished partial must
open, have one video track, decode a frame and last as long as the clip
before it is renamed in with an exclusive rename.

## Settings

Stabilization is saved per clip like a grade, in the catalog table
`clip_stabilization (file_key, settings, updated_at)`. The table is new:
nothing existing is altered, and an older catalog gains it on first use.
Every change is one Undo step.

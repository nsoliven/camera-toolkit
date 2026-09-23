# Cable & Enclosure Stability Testing

A negotiated 10 Gb/s link proves a cable can *talk* fast — not that it stays
connected under sustained load. A marginal cable or enclosure can look fine
for an hour of light use and then drop the drive mid-write. This test is the
standard, repeatable way to grade a **cable + enclosure + port** combination
before trusting it with Buffer work.

Open it from **Storage Speed Tests → Stability…** on any drive row.

## What the test does

Every run moves data in fixed phases while watching macOS's USB port counters
about once a second. Writes go into a hidden temporary file inside the drive's
configured Buffer or library folder — never near your media — and the file
cycles through a bounded area (at most 8 GB, less when free space is short)
instead of growing. It is removed when the run ends, whatever the outcome,
and swept on the next launch if a crash ever strands it. Read-only drives
(camera cards) are never written to: their runs sample existing media.

### Profiles

| Profile | Length | Phases |
| --- | --- | --- |
| Quick | 2 min | sustained write, sustained read, mixed burst |
| **Standard** | 10 min | 3 min write, 3 min uncached read-back, 2 min mixed burst, 2 min idle watch |
| Soak | 30 min | the Standard cycle repeated three times |

- **Sustained write** — sequential 8 MB chunks through the bounded temp area.
  This is the load that made the bad cable drop.
- **Sustained read** — the written area read back uncached (`F_NOCACHE`), so
  the figure is device truth, not page cache.
- **Mixed burst** — several parallel readers plus one writer mixing small
  (64 KB) and large (4 MB) requests. This mimics the app's own launch burst —
  a drive walk, stats, header reads, and thumbnail decodes at once — which
  was one of the real-world drop triggers.
- **Idle watch** — no I/O by design. A weak link sometimes drops *after* the
  load stops, when power management kicks in.

Run **Standard** on every new cable or enclosure before trusting it with
Buffer work. Use Quick for a smoke check, Soak when you suspect heat.

## The verdict

- **Fail** — the volume unmounted or disappeared, the port logged new
  connects or any failure counter rose, over-current appeared, link errors
  rose, or an I/O error occurred. The report says plainly which one.
- **Warning** — the drive stayed connected but something was off:
  - a *stall* (no data moved for 2 s or more),
  - typical throughput under about half of the negotiated link's usual range,
  - or a large mid-run slowdown. A slowdown alone is **not** a fault: a long
    sustained write can outrun an SSD's fast cache, and a warm enclosure can
    throttle. It is only a clue if drops or stalls come with it.
- **Pass** — none of the above. The report lists min / typical / max MB/s
  per phase.

When a run fails, the advice is always the same order: **replace the cable
first** — it is the cheapest part and the most common cause — then try a
different port; only then suspect the enclosure.

## Reading the counters

On Apple Silicon the drive's USB port publishes a `port-statistics`
dictionary (Intel Macs expose the same counters on their XHCI port objects).
They count **since boot** and are **shared per port**, so the test reports
*deltas from the start of the run* — a "+4" during your test is yours.

- **Connects** — how many times the device connected. Any rise during a run
  means the link dropped and renegotiated.
- **Enumeration failures** — macOS saw something plug in but could not get
  it to identify itself. The classic bad-cable signature.
- **Address failures** — enumeration got as far as address assignment and
  failed. Follows bad enumerations.
- **EOF2 violations** — packet-framing errors on the wire; corrupted signal.
- **Link errors** — the port's own link-level error count.
- **Over-current** — the enclosure tried to draw more power than the port
  allows. Try a powered hub or a cable rated for the draw.

Volumes that are not USB-attached (internal SSD, network share, Thunderbolt
storage whose registry tree differs) report "USB counters not available on
this connection" and the test still grades drops, stalls, and throughput.

## History and comparing

Before each run you can label the cable ("Anker 1 m") and pick the port —
the port is detected from the USB registry path when possible. Results are
stored in a small JSON file the feature owns (`stability-tests.json` under
the app's Application Support folder) with the date, profile, verdict,
per-phase throughput, counter deltas, link speed, power allocation, and the
enclosure identity (vendor, product, `bcdDevice`, serial, and the volume
UUID — cheap bridges can share a placeholder serial, so the UUID keeps
different units apart). The drive's sheet shows its history so two cables
on the same enclosure compare directly, and **Copy Report** produces a
plain-text summary.

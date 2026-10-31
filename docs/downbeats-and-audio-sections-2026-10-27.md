# Downbeat alignment and audio-informed section suggestions

27 October 2026. Commander Axiom (`commander-axiom`).
Quest task `c12d7a9b-7447-4dcb-aa75-aa79324386cc`, work session
`b7e52413-2d95-497a-afa9-b99290ebb9d5`.

The owner confirmed that bar lines start on the wrong beat and that a pickup
must be chosen manually each time. The prior model only detected beat times;
the app grouped them in fours from an assumed offset. Section splitting used
exact repeated four/eight-bar chord strings, without acoustic evidence.

## Changes

- Backend beat detection uses madmom's joint beat/downbeat model. It returns
  one-based beat positions, downbeat timestamps and a suggested pickup. Requested
  metre stays explicit; this is not automatic time-signature identification.
- New jobs adopt a validated detected pickup. Existing saved offsets, including
  zero, are preserved. Tuning offers **Use detected pickup** after re-detection;
  its live preview and explicit Apply flow remain the September interface.
- Versioned beat caches include all decoder options, so custom BPM limits or
  stability settings cannot pollute ordinary analysis results. Bad parameters
  receive clear errors. Sustained half/double-rate ambiguity is reported.
- A new optional structure endpoint finds sustained changes in MFCC timbre,
  harmonic chroma, dynamics and percussive texture at two/four-bar scales.
  Peaks are separated by at least four bars. It never invents verse/chorus roles.
- New analysis can initialise generic sections from acoustic boundaries. Repeated
  chord patterns remain available as fallback evidence. Saved section files and
  edits made while an acoustic request is in flight are preserved.
- Existing songs have **Refresh audio suggestions** under Bar → All sections.
  It reads the downloaded WAV and writes separate evidence/candidate files.
  It does not rewrite the owner's chart, beat grid, chart configuration or section
  file. Applying a new section split remains an explicit replacement action.
- Boundary times are re-snapped when pickup/grid settings change. Stored old bar
  numbers cannot quietly shift suggestions onto the wrong passage.

The helper preflight now loads downbeat models and advertises acoustic-structure
capability. Existing backends remain compatible through a capability check.
No extra neural model or installation is required for this pass.

## Validation and measured limits

- **424/424 Swift pipeline checks pass**, including 21 alignment checks, 12 pure
  structure/store checks and 25 actual JobManager/HTTP integration checks.
  Integration verifies inferred pickup persistence across job/grid/config/tuning,
  manual override preservation, an owner rename/split during a delayed structure
  request, and saved-file preservation on refresh success/failure.
- **20/20 backend tests pass** for downbeat formatting, metrical warnings, option
  validation/cache identity, acoustic transitions, repeating harmony, short
  phrase rejection, invalid input and upload cleanup.
- **17/17 helper/window lifecycle checks pass** with the rebuilt signed helper.
- Full Swift typecheck clean; normal signed Xcode build succeeds. Light/dark
  renders complete; tuning and section controls visually inspected. The build
  emits only the usual unused AppIntents metadata notice.
- The actual frozen helper analysed an isolated copy of As The Deer's WAV:
  bounded 50–90 BPM preview produced **65.22 BPM, 438 beats**, first decoded
  downbeat **0.92 s**, 109 complete bar intervals for the structure probe and
  **six acoustic boundaries**. Input SHA-256 was unchanged. This is a comparison
  candidate, not accepted musical ground truth.
- Unconstrained downbeat inference on the same source proposes first downbeat
  **1.25 s** and 66.67 median BPM, but still switches beat level late in the song.
  It now warns about that ambiguity. Higher stability alone chose about 130 BPM;
  that metrical interpretation was not silently made the default. The bounded
  and unconstrained proposals need listening against the owner's intended bar one.
- A separate acoustic preview on the original 138-bar grid found ten boundaries;
  differing grids produce differing section proposals. No boundary count is
  presented as accuracy evidence without owner-marked references.

No owner timing/section file was rewritten by the experiments, no recording was
downloaded, and no song was exported/published. Experimental outputs reside in
`/tmp/chordadmin-structure-preview/` and the verification output referenced by
`/tmp/chordadmin-packaged-timing-preview.log`. Durable copies accompany delivery.

## Delivery and source state

Separate development application:
`/Users/fkbcald/Applications/ChordAdmin Timing Preview.app` (~823.7 MiB).
It preserves the September interface and prior import-review integration.
The existing application remains running: the owner has an unapplied pickup
preview open for Bless My People. No app switch was performed, so that in-memory
preview is preserved. Finish or revert it before closing the old app and opening
the timing preview build. Owner listening acceptance remains pending.
Source changes are uncommitted in both the application checkout on
`codex/import-review-redesign` and the backend checkout. The embedded manifest
records the dirty source state and Python-file hashes, rather than implying the
backend's old HEAD commit completely identifies the package.

The existing development-signing, model licensing and Python redistribution
limits in `local-runtime-and-sidebar-2026-10-27.md` still apply. This is not a
notarised public release. Musical acceptance remains outstanding.

## Vocal separation

Vocal activity can be useful additional evidence for instrumental/vocal
transitions. That is a hypothesis to test against marked boundaries, not proof
that separation will identify verses/choruses. This pass uses harmonic/percussive
decomposition and full-mix features; HPSS is not vocal separation.

[madmom's downbeat documentation](https://madmom.readthedocs.io/en/v0.16.1/modules/features/downbeats.html)
describes joint beat/downbeat activations and decoder bar positions.
[librosa's segmentation example](https://librosa.org/doc/0.11.0/auto_examples/plot_segmentation.html)
combines harmonic recurrence with timbral continuity, supporting acoustic evidence
beyond chord labels. A later optional separator needs an isolated compatibility
and packaging pass: [Demucs](https://github.com/facebookresearch/demucs) is archived,
and two-stem output still performs the full separation. Its older torchaudio
requirements should not be installed into the working torch 2.8 runtime casually.

## Follow-up — 28 October 2026

The owner reported that section detection and bar 1 where the music starts
were still wrong.

**Bar 1.** Every saved job had been analysed before the joint downbeat model,
and two paths reapplied the saved pickup *count* to a new beat track: re-analysis
and **Re-detect beats**. A new track can start on a different beat (As The Deer:
old track 0.23 s, new 1.25 s), so the count put bar 1 on the wrong beat. Now
`pickupChosenManually` is set only when Tuning applies a changed pickup. A
replaced beat track re-anchors that choice by its bar 1 *time*
(`manualBarOneTime`); otherwise the new detection decides. Legacy jobs have no
flag, so their saved counts (mostly the old default 0) give way to detection.
On the five songs where the owner set the pickup by hand, the joint model chose
the same bar phase in every 8-bar window, including the opening. In a partial
survey, 24 of 55 saved charts started bar 1 on a different beat from the model.
Seventeen of those were repeat analyses of one recording, so about eight distinct
songs disagree.

**Sections.** The v1 detector only saw acoustic change, but most owner boundaries
are repetition boundaries (Verse 1 → Verse 2, Chorus → Chorus 2). Backend
`structure_service` v2 (`bar-repetition-novelty`) combines:

- circular time-lag repetition novelty over centred 3-bar chroma phrases
- Foote × 4-bar median-contrast timbre/energy novelty
- a dynamic programme with an 8/16-bar phrase prior

On the three owner-sectioned songs (28 boundaries), it found 25 within one bar
(v1: 8) and 16 exact (v1: 8), with 9 extra boundaries (v1: 3). It is calibrated
on only three songs, so it is a suggestion engine, not a measured accuracy claim.
The app accepts both v1 and v2 responses. Backend 21/21 and Swift 435/435 checks
pass. The rebuilt app is `~/Applications/ChordAdmin Sections Preview.app` (signed,
deep strict verification passes, not notarised). Its frozen helper reports
`bar-repetition-novelty` v2. On an isolated copy of the first owner-sectioned
song, it found all 10 owner boundaries within one bar (9 exact) and its first
downbeat was 1.12 s (owner: 1.13 s). The input WAV was unchanged. The earlier
Timing Preview and Local Analysis apps still contain v1.

**Same day, after owner testing.** Re-analysing Friend in the new app produced 16
sections lettered A–P. The owner has 11, with the verses, pre-choruses and
choruses each sharing a name. Changes:
- 4-bar sections now get a −0.2 length penalty. On the three owner-sectioned
  songs, exact-bar F rose from 0.52 to 0.62 and ±1-bar F from 0.81 to 0.83.
- Sections whose sub-bar chroma matches at a mean cosine of at least 0.85 share a
  letter. Each boundary carries the letter as `label`, and the app uses it when
  every section has one. The packaged helper labels Friend
  `A B B C D E C D D D E A F`.
Backend 21/21 and Swift 437/437 checks pass. The rebuilt Sections Preview app
replaced the earlier copy; its signature verifies.

**Role names, at the owner's request.** The suggestions now name sections
instead of lettering them, reversing the earlier no-roles rule:
- **Chorus:** the most repeated letter, with loudness as the tie-break.
- **Pre-Chorus:** the letter that leads into most choruses.
- **Verse:** the earliest other repeated letter, plus any one-off section that
  leads into a pre-chorus or chorus.
- **Intro:** the first section.
- **Outro / Ending:** sections after the last chorus.
- **Instrumental** or **Bridge:** the rest.

Repeated roles are numbered. When no letter repeats, the generic "Section A…"
names stay. On Friend the names closely match the owner's. On the other two
songs, roles inherit the boundary errors, so they remain suggestions to rename.

**Vocal evidence (owner request: "separate vocal from song to do a double analysis").**
Songs that open with singing were named "Intro". The structure endpoint now
separates the vocals with htdemucs (Demucs 4, MIT; core inference code vendored
in `ChordAdminBackend/vendor/demucs`, without torchaudio/dora/omegaconf). It then
reads the vocal stem as IPA phonemes with `facebook/wav2vec2-xlsr-53-espeak-cv-ft`
(Apache-2.0). Phonemes rather than words, so Karen-language songs work too.
Both models ship as safetensors (84 MB; 631 MB at float16), so nothing is
unpickled at runtime. Results are cached per recording. It costs about 20 s per
song on Apple-silicon GPU.

What the evidence decides, on owner songs plus Angel Baby and Grace Kelly:
- A section is **sung** when its vocals carry words: at least 0.8 phonemes per
  second and at least 30% consonants. On owner songs lyrics measured 48–64%
  consonants and "aaah" vocalise 11–23%. Detected vocal entries were within
  0.3 s of the owner's Verse starts.
- Sections without words before the first sung section are Intro. Sections
  between the first sung section and the last chorus are Instrumental. Sections
  after the last chorus are Outro / Ending. A sung opening section is a Verse,
  never Intro.
- Phoneme-trigram similarity separates repeated lyrics (≥ 0.23) from unrelated
  sections (≤ 0.12) on both owner-named songs. Using it to pick the chorus made
  names worse, because pre-choruses repeat their words even more exactly. So
  it is measured but not yet used for naming.
- Using the backing stem for beats did not move bar 1 on any of the four songs,
  so beats still come from the full mix.

When the models are missing or vocal analysis fails, names fall back to
music-only rules with a warning. The response gains `vocals` and a per-boundary
`sung`. Backend 24/24.

**Manual check of လီယၤတဂ့ၤ (AAD10326), owner reported wrong.** Read bar by bar
from chords, vocal presence and phonemes, the song is:

| Bars | Section |
|---|---|
| 1–21 | Intro (no vocals) |
| 22 | Verse 1 |
| 30–31 | 2-bar pre-chorus |
| 32 | Chorus 1 |
| 44 | Instrumental (no vocals; chorus chords) |
| 52 | Verse 2 (same words) |
| 60 | Pre-chorus |
| 62 | Chorus 2 |
| 74 | Chorus 3 |
| 86 | Tag |
| 90 | Outro |

The app gave Intro / Verse / Pre-Chorus 30 / Chorus 36 / … / Outro 1–3 from bar 74.
Changes:
- **Repeated-line rule:** no cut where the next 4 bars repeat the previous 4
  bars' words (phoneme-trigram cosine ≥ 0.2). This removed the mid-chorus cut at
  36, and the result held across thresholds 0.15–0.3. Owner songs and
  music-only boundaries are unchanged.
- **Chorus by words:** a sung section whose words match the chorus is a Chorus
  even when its chords match the instrumental. Lyrics extend the chorus the
  music found; they still do not choose it.
- **Tie-break:** when repeat counts tie, the chorus is the part each cycle builds
  to (it first appears last), then the loudest.
- **Verse fallback:** if the only material leading into the chorus is unique
  repeated material, it is the Verse, not a Pre-Chorus.
- **Merging:** consecutive wordless sections with one role merge (the 21-bar
  intro is one section).

Result: Intro, Verse 1, Chorus 1 (30, pre-chorus folded in), Instrumental,
Verse 2, Chorus 2 (60), Chorus 3 (66, extra split), Chorus 4 (74), Outro (82),
Ending (90). The Karen owner song improved (36 Verse, 57 Chorus, as owned).
Friend and Grace Kelly are unchanged. Backend 26/26.

### Manual check: လၢအယံၤ လၢယဟံၣ် (D446A96A), 2026-10-28

A 64-bar ballad (65 BPM) that modulates up a tone at bar 49 (Eb Bb/D C D, then
the last chorus in G). Bar-by-bar reading from chords and the transcribed vocal
phonemes:

| Bars | Section |
|---|---|
| 1–4 | Intro (no vocals) |
| 5 | Verse 1 |
| 17 | Chorus 1 (pickup in bar 16) |
| 25 | Instrumental (intro chords) |
| 29 | Verse 2 (same words as Verse 1) |
| 41 | Chorus 2 |
| 49 | Modulation (2 bars), Chorus 3 in G from 51 |
| 59 | Outro / tag |

The app gave Verse 1 5–20, Chorus 1 21, Bridge 29, Verse 2 37, Chorus 2 45,
Chorus 3 49–64. The first half of the chorus (F C | Dm F/C | Bb F/A | Gm C)
shares its descending bass with the second half of the verse, so the chords
change four bars late, where the chorus repeats its own progression.

Change: **snap to lyric runs.** Long runs of repeated lyrics (2-bar windows,
phoneme-trigram cosine ≥ 0.2, ≥ 5 windows, one per lag) mark where repeated
material starts (the bar after the run's first window, because of pickups).
A chosen boundary that sits inside a lyric repeat (the words carry on across
it) and has no run start within 2 bars moves to a run start 3–4 bars away.

Rejected first: adding lyric-run starts to the boundary score, alone or gated
by musical evidence. Every weight moved Friend's boundaries a bar early
(exact 8/10 → 5/10). Key-shift-tolerant chord matching (±2 semitones) found
the outro, but lost Karen boundaries and left no repeated letters to name from.

Result: Intro, Verse 1 (5), Chorus 1 (17), Instrumental (25), Verse 2 (29),
Chorus 2 (41), Chorus 3 (49–64; the outro is not split off). Across the six
evaluated songs boundary F (±1 bar) went 0.754 → 0.848 and exact 0.667 → 0.758.
လီယၤတဂ့ၤ lost its extra split at 66 and Friend its split at 71. Angel Baby and
Karen are unchanged. Backend 27/27.

## Manual check: ဆ်ုအဲလင်မိင် (24FDD209), 2026-10-30

75 bars at 78 BPM, music from 8.07 s (bar 1 is right). Read from the vocal stem
(loudness and pitch per bar), the chords and the phonemes:

| Bars | Section |
|---|---|
| 1–8 | Intro, no singing (pickup into the verse in bar 8) |
| 9–24 | Verse: one 4-bar melody, 9–16 and 17–24 have different words; the band fills out at 17 |
| 25–32 | Chorus 1 (last note held through 32) |
| 33–35 | Link on the intro chords (verse pickup in 35) |
| 36–43 | Verse 3, same melody as 9–16 |
| 44–51 | Instrumental on the chorus chords |
| 52–59 | Chorus 2 |
| 60–67 | Chorus 3 (last note held through 67) |
| 68–75 | Outro, sung over the intro chords |

The app had the groups right (intro/link, verses, choruses) but named them
Verse 1 / Pre-Chorus / Chorus: the intro counted as sung. wav2vec2 read 21
phonemes into bars 1–4, where the vocal stem is bleed at −68 to −79 dB
(singing is about −16 dB). Across seven songs every sung phoneme sits within
25 dB of the stem's loud level (95th percentile of 20 ms frames); bleed sits
50 dB or more below it. `vocal_service._audible` now drops phonemes more than
40 dB below that level (vocal cache version 2, so songs re-separate once).
Result: Intro, Verse 1 (9), Verse 2 (17), Chorus 1 (25), Instrumental 1 (32),
Verse 3 (36), Instrumental 2 (44), Chorus 2 (52), Chorus 3 (59), Outro (67).
The other six songs are unchanged.

Still one bar early: Chorus 3 (59, should be 60) and Outro (67, should be 68).
Both bars hold the previous line's last note. A rule that moves a cut past a
held note fixed both but also moved Grace Kelly's bridge from 55 to 56, which
looks the same in the signal. The chorus words should settle 59/60, but the
phoneme guesses differ too much between the three choruses here (best lag-27
run is 4 bars, below the 5 needed). The 33–35 link is shorter than the
4-bar minimum section, so the app's 32 is the closest it can get.

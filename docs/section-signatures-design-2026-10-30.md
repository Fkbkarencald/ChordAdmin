# Song form from section signatures (design)

30 October 2026.

## Status (31 October 2026)

- **Where the code is:**
  - Steps 1–6 are implemented in `ChordAdmin/SongForm.swift`, and
    `ChordAdmin/SongFormIntegration.swift` wires them in.
  - The chart stage writes `song.form.json`, a variable-length
    `beat.grid.json` and `chord.form.json`. Sections come from the form.
  - Export writes `key`, plus each bar's own time signature and chord
    spacing.
  - Manual retuning drops the form's bar lines but keeps its key.
- **Tests:**
  - The corrected နမၤနၢၤယဝံကလၤ chart (fixture `song-form-namanaw`) is
    reproduced exactly: section names and boundaries, every bar length
    including all 6/4 bars, chord spacing, every chord after the intro, and
    the key.
  - All 466 pipeline checks pass.
- **Not yet built:**
  - the colours and half-bar audio check. The intro still reads
    `Em | D | Em | Asus4`.
  - per-section keys, which wait on TheStageBee;
  - the review screen's letter strip.
- **Unverified on other songs:**
  - The other six songs in the session are not ground truth. Their keys all
    match the corrected ones; their structures are plausible but uneven.
  - Known weak spots:
    - repeated 16-beat lines come out as separate sections (Ya Gaw Thoolei);
    - phase in songs with long held chords (khon ka taw);
    - a long verse+instrumental block treated as one section (Kaw Thoo Lei
      Poe).
  - Each needs a corrected chart before the rules are tuned further.
- **No end-to-end run against a real backend yet.**

## Why

Correcting နမၤနၢၤယဝံကလၤ (`songs/IJLPJEzRfcyjdzuuaKbQ`) by hand took a dozen
rounds. Every mistake came from deciding locally: one bar, one boundary, one
acoustic peak at a time. The song's form only became clear when whole
sections were compared:

- the four verses are one 34-beat signature, with a 6/4 bar in the same
  place and a held Em closing each one;
- the three choruses open the same way, and each ends where the next section
  begins;
- the intro, the prelude and the instrumental are the only material that
  doesn't repeat.

Today's pipeline does the opposite. Bars are fixed 4/4 before any analysis.
`detectSectionCandidates` matches exact 4/8-bar strings on that grid, so a
single 6/4 bar breaks every later match. Boundaries come from acoustic
novelty, and names come from a lyric-similarity rule that labelled every sung
section "Chorus". The key is never computed or exported.

## Principle

**Form first, bars last.** Find which passages are the same music, decide
where each section starts and ends from that, and only then lay out bars
inside each section. Bars are an output of the analysis, not an input to it.

## Prototype results

`signatures.py`, a scratch script that is not in the repo, ran on the seven
songs in session `IYy1TzZCLvUYCucLjuYt`. It turns the raw chord recognition
into a list of (chord, beats) on the detected beats, then marks the longest
exactly repeated stretches.

| Song | What it got right | What broke it |
|---|---|---|
| နမၤနၢၤယဝံကလၤ | 96-beat block ×2 starting exactly at Verse 1 / Verse 3; 6/4 bar visible as `D(2) G(4)`; held Em spanning the boundary | Block = verse+verse+chorus head, not split further |
| နံၣ်ထီၣ်သီ | 36-beat verse ×2, 64-beat chorus ×2 | `F#m(5) B(3)` vs `F#m(4) B(4)` jitter split a repeat |
| Ya Gaw Thoolei | 72-beat block ×2; a repeated 16-beat phrase late in the song | That late phrase is in a new key (a final modulation), and exact chord names can't see that it's the same music |
| Beautiful Day #5 | 32-beat phrase ×4 (B), 100-beat block ×2 | `C#m(3) B(5)` jitter; `A(1) B(3)` fragments |
| Kaw Thoo Lei Poe | 80-beat block ×2 | Intro full of `N` (no chord) fragments |
| khon ka taw | 128-beat block ×2 | 72 beats of `N` at the start; block not decomposed into its 40-beat unit |
| ဆ်ုအဲလင်မိင် | 48-beat chorus ×2, 32-beat verse ×2, 20-beat tag at start and end | `D(4)` vs `Dm(4)` quality noise |

Repetition at the beat level clearly carries the form. Exact matching,
however, is too brittle, and longest-first matching stops at the largest
block.

## Design

### 1. Beat-level chord tokens

From the chord recognition and the detected beats, produce tokens
`(chord, startBeat, beats)`. This happens before any bar grid exists.

- **Matching form:** for comparison, reduce each chord to a pitch-class root
  plus a triad quality (maj/min/dim/aug/sus). So `Ab7` = `Ab/b7` = `G#`, and
  `Em7` ≈ `Em`. Keep the full chord name for display.
- **Short fragments:** absorb fragments of 1 beat or less into their
  neighbours (`A(1) B(3)` → `B(4)`) unless they recur in the same place in
  every repeat.
- **No chord:** treat `N` as a gap and never as harmony. A long `N` run at
  the start becomes the pre-intro.

### 2. Key and relative signatures

- **Key:** estimate it from all tokens, weighted by beats. Fit each of the 24
  keys, add a tonic bonus at the start and end, and prefer the minor key when
  its V chord is major. This value is also exported.
- **Relative form:** express each token relative to the key (Em in E minor
  becomes `i`). Matching on these relative signatures catches a final chorus
  that changes key (Ya Gaw Thoolei), which is common in this repertoire.

### 3. Hierarchical repeat finding (tolerant)

- **Fuzzy alignment:** compare stretches with a local alignment over
  beat-weighted tokens instead of exact matching.
  - **Substitution costs:** 0 for the same root and quality; small for
    `x`/`x7` or a relative major/minor; large otherwise.
  - **Timing:** a ±1-beat timing difference costs a little.
  - **Splitting:** a token can be split across a boundary, as with the held
    Em at 0:56.5.
- **Recurse:** find large repeats first, then repeats inside them, then
  inside those. In နမၤနၢၤယဝံကလၤ the 96-beat block splits into verse ×2 and
  the head of the chorus.
- **Smallest unit:** stop at the smallest unit that still repeats and is at
  least about 4 bars long. That unit is a section. Bigger blocks are recorded
  as groups, for example a "Verse–Verse–Chorus" cycle.
- **Letters:** sections that align within tolerance share a letter.
  Non-repeating gaps get their own letters.

### 4. Boundaries from musical rules

Within the boundary positions the repeats allow, choose the one that best
satisfies these rules, in this order:

1. **Siblings line up.** Every section with the same letter has the same
   length, chords and bar layout as its siblings. Lining up Verse 1 with
   Verse 2 fixed most of today's errors.
2. **Sections end on a cadence.** That means a resolution to the tonic
   (`C D → Em`), a held tonic, or a half cadence on V (the chorus ends on
   `B`). A held chord that crosses a boundary is split so that both sections
   match their siblings.
3. **Phrase lengths are regular.** Phrases are usually 4, 8 or 16 bars,
   measured in beats with room for odd-meter bars.
4. **Arrangement and energy break ties only.** Drums entering, a texture
   change or vocals starting can choose between boundaries the chords already
   support. A drum dropout inside a repeated pattern is dynamics, not a
   boundary.

### 5. Bars laid out per section

Inside each section, lay bars so that chord changes fall on beat 1 (or
beat 3 in 4/4). Allow an occasional odd-length bar (6/4, 2/4) where the
harmonic rhythm needs one, and charge a cost for each so they stay rare.
Same-letter sections get one shared layout, so a 6/4 bar lands in the same
place in every repeat. In practice this is mixed meter. Bars carry their
own `timeSignature`, which StageBee already stores.

### 6. Names

Roles come from the letter sequence:

- **Intro and Outro:** the first and last non-repeating material.
- **Verse:** the first sung letter that repeats in the cycle.
- **Chorus:** the letter each cycle builds to, which usually repeats most.
- **Instrumental:** unsung material between cycles.
- **Prelude and Pre-Chorus:** short non-repeating material before a verse
  or chorus.
- **Tag:** a short phrase that repeats at the start and end
  (ဆ်ုအဲလင်မိင်'s 20-beat `A Dm G A`).

Names are applied automatically and stay editable; the letters are the fact. The lyric-similarity
override in `structure_service.py` `_section_roles` goes. For Karen it
merged every sung section into "Chorus".

### 7. Output and review

- **`form.json`:** a new pipeline stage, between chord recognition and chart
  building, writes:
  - the tokens and the key;
  - the sections, each with letter, name, start and end beat, bar layout
    and signature;
  - the evidence and a confidence score for each boundary.
- **Chart:** the chart is built from the bar layouts in `form.json`, not
  from a uniform grid.
- **Review screen:** shows the form as a strip of letters
  (`Intro · Prelude · A A B · Inst · A A B B · Outro`). It also flags
  same-letter sections that don't match ("Verse 3 bar 5 differs from
  Verse 1") and lets the user rename sections.
- **Export:** adds `key`.

## Where it lives

- **Swift, in ChordAdmin:** steps 1–6 are pure functions over data the app
  already has (beat detection and chord recognition JSON), so they live in a
  new `SongForm.swift` beside `ChartGeneration.swift`. They are tested in
  `Tools/PipelineTests` with fixtures.
- **Backend:** the acoustic-novelty endpoint stays as the tiebreak input for
  step 4.4. Its role naming is no longer used.

## Validation

- **Ground truth:** the corrected chart of နမၤနၢၤယဝံကလၤ in Firestore, plus
  the job's local beat and chord files, is fixture 1. Its sections, bar
  lengths, 6/4 placement and key must be reproduced exactly.
- **More songs:** correct one or two more songs from this session with
  Frankie and add them as fixtures. Good candidates are Ya Gaw Thoolei, for
  the key change, and khon ka taw, for the long no-chord intro.
- **Metrics:**
  - boundary hit rate within ±1 beat;
  - same-letter consistency;
  - bar layout agreement;
  - key accuracy (the 7 keys corrected today are labels already).

## Decisions

- **Section names are applied automatically** (Frankie, 30 October 2026).
  The review screen still shows the letter strip and mismatch flags, and
  names stay editable, but no confirmation step is needed.
- **Key changes are stored per section** (Frankie, 30 October 2026).
  - **ChordAdmin:** the song's `key` is the opening key. Each section whose
    key differs gets its own `key`, written in StageBee spelling (`Em`,
    `Db`). Key estimation runs per section on top of the relative signatures
    from step 2. A section is only given its own key when its chords fit the
    new key clearly better for at least one whole section, not one stray
    chord.
  - **StageBee needs work first.** `SongSection` and `PublicSongSection` in
    `web/src/types/firebase.ts` have no `key`. StageBee needs:
    - an optional `key?: string` on both types;
    - the key shown in the section header;
    - section keys used wherever the song key drives behaviour, including
      flat/sharp spelling (`pdf-generation.ts`, `songEditor.ts`), the
      diatonic chord suggestions in `songEditor.ts`, and transposition, which
      must shift section keys too;
    - a check that saving from the StageBee editor keeps the field and
      doesn't rebuild sections without it.
  - **Order:** until StageBee ships those changes, ChordAdmin must not
    write section keys. An editor that drops unknown fields would erase them
    silently, and the PDF would spell the new key's chords with the opening
    key's flats and sharps.

- **Chord colours are kept** (Frankie, 30 October 2026).
  - **Detection:** for each chord, ChordAdmin checks the notes and the bass
    in each half-bar of audio. It keeps a colour (add9, sus2, sus4, maj7, 7,
    m7, 6) only when the extra note is clearly present for most of the chord.
  - **Same in every repeat:** a colour found in most repeats of a section
    is written into all of them; one found in a single repeat is dropped. So
    Gmaj7 in bar 4 appears in all four verses or in none.
  - **Bass decides look-alikes:** chords that share notes are told apart by
    the bass, so a D-bass `A D E` is `Dsus2`, not `Asus4`. A colour never
    replaces the chord's root.
  - **Matching ignores colours:** signatures compare simplified chords, so a
    colour never stops two sections from matching.
  - **Spelling:** StageBee's own (`EMadd9`, `Dsus2`, `Gmaj7`).

All decisions are settled.

## Addendum, 31 October: a trained structure model

Chord repeats and vocal timing plateaued at about 82 boundary errors across the
eight corrected songs, because many of these songs use one progression for
verse, pre-chorus and chorus. All-In-One (`allin1` 1.1.0, Taejun Kim, MIT;
trained on the Harmonix pop set) hears the arrangement from separated stems
instead. Measured with the corpus test's rule (a start within 0.6 s counts;
each miss or extra start is one error):

| | Errors, 8 songs |
|---|---|
| SongForm, chords and vocals | 82 |
| Model as extra evidence in SongForm's free search | 78 |
| Model alone, merged by label, snapped to downbeats | 67 |
| **Model's starts as the boundaries, on bar lines; SongForm may only remove them** | **58** |

The last is what ships. The model marks sections a median of one beat early,
so each start is moved a beat later before it goes to the nearest bar line,
and nothing may add a section the model did not mark. It is better on six
songs; it is worse on နမၤနၢၤယဝံကလၤ (3 against 0) and on khon ka taw (10
against 4), whose male and female sections are not a pop form. Its labels are
not yet used for names.

- **Backend:** `services/structure_model_service.py` separates the four stems at
  44.1 kHz as 16-bit, as the model was trained, and runs the eight-fold
  ensemble. `/api/detect-structure` returns `modelSegments`.
- **Weights:** converted once to safetensors by `scripts/convert_allinone.py`
  (PyTorch's restricted loader), so the runtime never unpickles.
- **Attention:** NATTEN no longer ships the interface allin1 uses, so
  `vendor/allin1/models/natten.py` implements it in plain PyTorch, tested
  against a brute-force reference. Its output on a real song is identical to
  allin1's own.
- **App:** the sections stage passes `modelSegments` to `SongForm.analyse`.
  Without them, the form is read from chords and vocals as before.

# Transcripty

Offline, on-device audio transcription for macOS with multi-speaker
diarization, word-level playback sync, and a transcript editor that lets you
correct who-said-what without ever sending your audio to a server.

Everything runs locally via Apple's `SpeechTranscriber` (macOS 26+) for
text and FluidAudio's offline VBx pipeline (pyannote-style segmentation →
WeSpeaker embeddings → VBx clustering) for speaker separation. The only
network access is the one-time download of the on-device speech and
diarization models.

## Capabilities

### Transcription pipeline

- **Concurrent diarization + transcription.** Apple's speech model and
  FluidAudio's diarizer run in parallel against the same audio source; the
  pipeline merges them at word granularity so every transcribed word knows
  which speaker said it.
- **Conditional audio enhancement.** Quiet recordings get a normalized,
  compressed, 16 kHz mono pre-pass for better model accuracy; loud recordings
  go straight to the model untouched, avoiding pointless disk writes for
  hour-long files.
- **Per-word speaker assignment.** Diarization labels are projected onto each
  word's audio time range, then run through a flicker filter that suppresses
  short same-speaker bursts sandwiched between a single other speaker — the
  classic "uh-huh" / "right" backchannel case.
- **Text-aware boundary refinement.** After the per-word assignment, a pass
  uses sentence punctuation and turn-opener words ("yeah", "okay", "well",
  "so", "but"…) to slide diarizer boundaries onto natural sentence breaks.
  Speaker rows in the editor read as complete thoughts rather than
  fragments.
- **Speaker-count constraint at import.** A "How many speakers?" picker lets
  you pin VBx clustering to the known count — by far the highest-leverage
  knob the diarizer has.

### Editor

- **Word-by-word playback highlight.** Every word in the transcript is a
  click target that seeks the player. The active word is tinted as audio
  plays, with a throttled scroll that stays smooth through long monologues
  instead of fighting per-word animations.
- **Interactive split.** Click any word to set a split point (a tinted caret
  appears on the word), press **Return**, and the segment splits at that
  word into two — the second half gets a fresh `Speaker_N` ID you can
  rename. Cuts land at silence midpoints to keep playback contiguous.
- **Right-click merge.** Each segment row offers "Merge with Previous" and
  "Merge with Next" — useful when the diarizer over-fragments a single
  speaker. The earlier segment's identity is preserved; the merged
  embedding is the average of both halves.
- **Speaker rename.** Click any speaker name to rename them. The chosen
  display name is stored per-speaker-ID, so it propagates to every segment
  attributed to that speaker.
- **Animated, dynamic-range-aware waveform.** A proper RMS+peak waveform
  with 95th-percentile normalization and gamma expansion — silences read as
  quiet, transients pop. Cached on first render at 800 buckets per project,
  downsampled per view (140 thumbnail / 400 playback).

### Revision history & undo

- **Persistent edit log.** Every edit you make — title rename, speaker
  rename, label add/remove, segment split, segment merge — is recorded as a
  reversible `ProjectEdit` in SwiftData. The trail survives app restarts.
- **⌘Z Undo + Revision History panel.** Toolbar button + popover lists
  every edit newest-first with relative timestamps and per-kind icons.
  Most-recent edit is one click away.
- **Inspection-context tracking.** Renames remember which segment row was
  on screen when you committed them. This becomes training data for the
  voice-print enrollment described below.

### Re-Transcribe with your labels (voice-print enrollment)

Once you've split / renamed enough that the project has at least one named
speaker, a "Re-Transcribe with Labels" toolbar button appears. It re-runs
the full pipeline using your work as supervision:

1. **Speaker count** is pinned to the count of distinct named speakers —
   resolves most over-/under-clustering errors on its own.
2. **Reference embeddings** are built per name from the previous run's
   per-segment WeSpeaker embeddings. The revision history grades each
   labelled segment's confidence:
   - **Tier A (×3)** — segments born of a `.segmentSplit` edit (you
     asserted a boundary).
   - **Tier B (×2)** — the segment you actually inspected when committing
     a rename.
   - **Tier C (×1)** — segments that inherited the rename transitively.
3. **Outlier filter.** Each tier-C segment is scored against the initial
   weighted reference; segments below an absolute floor or sharply below
   the verified core are dropped before the final average is computed.
   Tier A/B segments are immune — they're ground truth.
4. **Anchor + absorb assignment.** After the new run, each new
   `Speaker_N` is matched to a user-named display via two stages:
   - **Anchor** — highest cumulative time-overlap with the user's labelled
     ranges (≥ 1 s minimum) wins.
   - **Absorb** — leftover IDs whose centroid embedding is close enough to
     a user reference (cosine sim ≥ 0.42, margin ≥ 0.05 over runner-up)
     get the same name. This is what catches the "diarizer split one
     person across multiple cluster IDs" failure mode.

### Library

- **Projects grid** with searchable transcript text, label filtering, and
  per-project waveform thumbnails.
- **Labels.** Tag projects with colored labels; sidebar offers per-label
  filtering. Labels survive across import / re-transcription.
- **Search.** Free text against project title and transcript content, plus
  `#labelname` syntax for label-only filters. Results rank by hit count
  with snippet previews in the sidebar.

## Privacy

No audio leaves your Mac. The pipeline is entirely on-device:

- Apple's `SpeechTranscriber` runs locally via the on-device speech model
  (one-time download per locale).
- FluidAudio's diarizer runs entirely through Core ML on the Apple Neural
  Engine (one-time download of `.mlmodelc` bundles).
- Project audio is copied into the app sandbox; original files on disk are
  never modified.
- The app sandbox has hardened runtime + app sandbox entitlements; only
  user-selected files are read.

## Requirements

- **macOS 26.0** or later (this is a hard requirement — the pipeline uses
  `SpeechTranscriber` APIs and SwiftUI features only available in macOS 26).
- **Apple Silicon strongly recommended.** The diarizer's WeSpeaker and
  segmentation models target the Neural Engine.
- **~1 GB of free space** for cached on-device models on first run.
- **Xcode 17** with the macOS 26 SDK (only needed if you're building
  from source).

## Building from source

The project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to keep
`project.yml` as the source of truth and generate `Transcripty.xcodeproj`
on demand.

```sh
# One-time: install XcodeGen
brew install xcodegen

# Clone and build
git clone https://gitlab.com/stoicswe/transcripty.git
cd transcripty
xcodegen generate

# Open in Xcode and run
open Transcripty.xcodeproj

# Or build from CLI
xcodebuild -project Transcripty.xcodeproj \
           -scheme Transcripty \
           -configuration Debug \
           -destination 'platform=macOS' \
           build
```

The Swift Package Manager dependency on FluidAudio is declared in
`project.yml` and will be resolved automatically by Xcode on first open.

### Code-signing

The project uses Apple's automatic code-signing pinned to development team
`<YOUR_TEAM_ID>`. To build with your own team, edit `project.yml` and replace
`DEVELOPMENT_TEAM`:

```yaml
settings:
  base:
    DEVELOPMENT_TEAM: YOUR_TEAM_ID
```

…then re-run `xcodegen generate`.

## Building a signed, notarized release

`make-release.sh` performs the full Developer ID workflow — archive, export,
sign, notarize, staple, and produce a distributable zip. Before the first
run:

1. In **Xcode → Settings → Accounts**, sign in with an Apple ID on team
   `<YOUR_TEAM_ID>` (or your own — see above) and verify a **Developer ID
   Application** certificate is installed.
2. Create an [app-specific password](https://appleid.apple.com) for
   notarization.
3. Stash credentials in your login keychain:

   ```sh
   xcrun notarytool store-credentials transcripty-notary \
     --apple-id you@example.com \
     --team-id <YOUR_TEAM_ID> \
     --password <app-specific-password>
   ```

Then:

```sh
./make-release.sh
```

The final notarized zip lands at `build/Transcripty.zip` and opens with a
double-click on any macOS 26 machine.

## Project layout

```
Sources/
├── App/                    SwiftUI App entry, RootView, navigation
├── Core/
│   ├── Audio/              Enhancer, waveform extractor, project cache
│   ├── Diarization/        Diarizer protocol + FluidAudio adapter
│   ├── Models/             SwiftData models (Project, Segment, Label, Edit)
│   ├── Pipeline/           Concurrent diarize+transcribe+merge orchestration
│   ├── Services/           TranscriptionService coordinator
│   └── Transcription/      Transcriber protocol + Apple Speech adapter
├── Features/
│   ├── Editor/             Transcript editor + waveform playback bar
│   ├── Import/             New-project sheet
│   ├── Labels/             Label management UI
│   └── Library/            Projects grid + thumbnails
└── Resources/              Info.plist, entitlements, asset catalog
```

## License

Released under the MIT License. See [`LICENSE`](LICENSE) for the full text.

Third-party components retain their own licenses:

- **FluidAudio** — Apache-2.0 ([github.com/FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio))
- **Apple SpeechTranscriber** model assets — distributed by Apple under
  their on-device-model terms.

# Terminal Attention Classifier Lab

Cherry can collect terminal-grid observations for developing a small local
classifier that recognizes when an agent needs attention. Collection is off by
default because visible terminal grids can contain source code, prompts, paths,
credentials, and other sensitive text.

## Labels

The classifier target is deliberately small:

- `attention_needed`: the user needs to review a result, provide input, approve an action, or resolve a problem.
- `no_attention_needed`: the harness is actively working and needs no user action.
- `unknown`: the screen is ambiguous, out of distribution, or should be handled by abstention. This is an abstention/review state rather than a positive model target.

`attention_needed` observations keep one reason as annotation metadata:

- `result_ready`
- `waiting_for_input`
- `waiting_for_approval`
- `blocked_or_error`

Older schema-1 labels (`approval_required`, `waiting_for_input`, and
`ready_for_review`) remain importable and are normalized to
`attention_needed` plus the corresponding reason in the dashboard.

Raw automatic observations are deliberately unlabeled. The review-bundle
sampler can add provisional labels to useful transitions. Reviews keep their
provenance as either `human` or `assistant_audit`; assistant-audited decisions
are useful pseudo-labels, but only human decisions count as independent
evaluation truth. Cherry's current heuristic state is stored as diagnostic
evidence, never as a model input.

## Week-Long Study Mode

On the laptop, open **Settings → Terminal → Attention Study** and enable
**Collect agent observations**, then restart Cherry. Collection begins
immediately, but the restart selects the color-preserving terminal path for new
sessions. After that, styled capture is automatic whenever study mode is enabled.

Recordings are stored in:

```text
~/Library/Application Support/Cherry/Attention Study/Recordings
```

Cherry keeps the directory private and trims older session files to 500 MB
when the app next starts recording. Content snapshots are
deduplicated and limited to one per second; state changes and notifications are
captured immediately. Automatic observations are deliberately unlabeled; they
become useful through later review, weak labels, and session-level outcomes.

## Development Override

The environment variable remains available for isolated experiments:

```bash
CHERRY_ATTENTION_RECORDING_DIR=/tmp/cherry-attention-observations swift run Cherry
```

Cherry lazily creates one private (`0600`) JSONL file per recorded agent
session. Each record contains a schema version, terminal viewport text and
optional styled runs, dimensions, cursor state, screen mode, timing signals,
output/content counters, heuristic evidence, optional scenario metadata, and
an optional interaction block recording whether input was left unsubmitted,
time since the last editing keystroke, and whether the terminal was focused.
It does not record submitted input separately, working directories,
notification bodies, or command lines.

Existing schema-1 observations without `terminal.styledGrid` remain valid and
display as plain text in the dashboard.

Cherry's default native Ghostty PTY currently exposes flattened text only, so
Attention Study automatically selects Cherry's supported host-managed terminal
path at launch. To select it explicitly during an isolated experiment, use:

```bash
CHERRY_NATIVE_PTY=0 swift run Cherry
```

Set `CHERRY_NATIVE_PTY=1` to override study mode and use the native path; those
observations will be plain text until native Ghostty exposes styled cells.

Use a dedicated directory outside the repository. Review every file before
sharing it; opt-in collection makes no attempt to redact text already visible
in the terminal grid.

## Transfer Laptop Data to the Mini

Check the laptop's current collection:

```bash
Scripts/attention-study-data status
```

Create a plain directory bundle:

```bash
Scripts/attention-study-data export \
  --output ~/Desktop/cherry-attention-week-1
```

The bundle contains JSONL files plus a manifest with checksums and counts. It is
not encrypted. Transfer the whole directory with AirDrop, a shared folder,
`rsync`, or `scp`.

On the Mini, validate and import it:

```bash
Scripts/attention-study-data import \
  --bundle ~/Downloads/cherry-attention-week-1
```

The default Mini dataset lives at:

```text
~/Library/Application Support/Cherry/Attention Study/Dataset
```

Import verifies every checksum and JSONL record. Re-importing the same bundle,
or an overlapping later export, skips observations already present by UUID.
Neither export nor import deletes the laptop recordings.

For a dashboard review drop, create a separate bundle that labels only useful
transition frames while retaining every raw observation:

```bash
Scripts/attention-provisional-labels \
  --source-host patrick-laptop \
  --output ~/Downloads/cherry-attention-review-week-1 \
  ~/Downloads/202607*.jsonl
```

The original JSONL files are not changed. The generated bundle labels activity
transitions, submissions, notifications, process exits, and representative
unfinished drafts. Adjacent content-change frames remain unlabeled so they do
not overwhelm the review queue. A visible unsubmitted draft is treated as a
`no_attention_needed` example because the user is already composing. Equivalent
transition captures within five seconds are collapsed into one review episode,
keeping the latest snapshot.

### Private Cloud Dashboard

The tiny Astro/Cloudflare viewer in `attention-web/` can store an exported
bundle in D1 and show the observation counts, labels, harness filters, terminal
grids, and complete stored payloads. The static login shell is public, while
every data API requires a separately configured dashboard token.

```bash
cd attention-web
cp .dev.vars.example .dev.vars
npx wrangler d1 migrations apply cherry-attention-lab --local
npm run dev
```

For the local review workflow, `npm run local` applies pending D1 migrations
and starts the dashboard in one command. Import a provisional review bundle,
then accept, correct, or skip one observation at a time. Review decisions and
their provenance are stored separately from the immutable provisional label in
the local Wrangler D1 state. Any manual edit becomes a `human` review. The
dashboard supports `A` to accept, `C` to save a correction, and `S` to skip
whenever a form control is not focused.

### Tag a Screen While Using Cherry

Right-click any terminal tab and open **Tag Current Screen**. Choose the state
that is actually visible:

- Result is ready
- Waiting for my input
- Waiting for my approval
- Blocked or errored
- No attention needed

For example, if the user is still typing, choose **No attention needed**. Cherry
writes the current terminal snapshot as a `human_corrected` labeled checkpoint
with `cherry_in_app_human_correction` provenance. The context menu shows the
active manual tag as the current label and checkmarks it. The tag clears when
terminal content or input changes, so it cannot describe a later screen. Agent
sessions also show the model inference separately.

With bulk collection enabled, the correction stays in the normal private JSONL
recording. With collection disabled, Cherry writes only the clicked snapshot to
`~/Library/Application Support/Cherry/Attention Study/Corrections`. A later
provisional bundle preserves its label and annotation, and the dashboard
presents it for review before it enters a training export.

Select the whole exported directory in the browser. Uploads are chunked,
schema-validated, and de-duplicated by observation UUID. Unlike the local
import command, the browser uploader does not re-check the manifest's file
checksums. The full terminal text is stored in D1, so use a strong token and
treat the deployment as private research infrastructure.

The current private deployment is
<https://cherry-attention-lab.patrick-arminio.workers.dev>.

## Train the Tiny Baseline

With the local dashboard running, export accepted and corrected reviews and
train the dependency-free logistic-regression baseline:

```bash
run_root="$HOME/Library/Application Support/Cherry/Attention Study/Model Runs/my-run"

Scripts/attention-reviewed-dataset \
  --output "$run_root/dataset"

Scripts/attention-train-baseline \
  --dataset "$run_root/dataset" \
  --output "$run_root/model"
```

The exporter removes provisional labels, annotations, scenario/checkpoint
names, and session identifiers from the observation payload used for features.
It creates a deterministic whole-session train/test split and records a SHA-256
checksum in `manifest.json`. `unknown` reviews remain in the dataset but are
excluded from binary model fitting.

The model uses activity, event, interaction, timing, cursor, screen-mode, and a
few terminal-state marker flags. It does not use arbitrary terminal text,
harness identity, review metadata, or provisional labels. The output contains:

- `model.json`: weights, feature names, scaling statistics, and threshold.
- `metrics.json`: fixed session-split metrics plus human leave-one-session-out
  evaluation.
- `predictions.jsonl`: predictions from the final fixed-split model.
- `human-loso-predictions.jsonl`: out-of-session predictions for every
  human-reviewed binary example.

Treat the human leave-one-session-out result as the headline measurement.
Metrics over `assistant_audit` examples are diagnostic because those labels
were produced by rules similar to the model inputs.

### Final Reviewed Baseline (30 July 2026)

The completed local review produced 1,110 examples across 32 whole terminal
sessions: 493 `attention_needed`, 616 `no_attention_needed`, and one retained
`unknown`. Of these, 34 were directly human-reviewed and 1,076 were
assistant-audited.

The final dependency-free logistic regressor has 55 parameters. Its fixed
eight-session test split scored 97.5% balanced accuracy on 279 binary examples.
The more meaningful human leave-one-session-out evaluation scored 96.7%
balanced accuracy on 33 examples: 18 true positives, 14 true negatives, one
false positive, and no false negatives.

This closes the initial collection pass. The result is strong enough to
prototype integration and collect targeted corrections, but the human sample
still comes from one user and is too small to call production-ready.

### Runtime Test Integration

Cherry embeds the final weights and reproduces the Python feature extractor in
Swift. The classifier runs locally for every agent session even when bulk study
collection is disabled, so the standard native Ghostty path remains available.
No MLX dependency is needed for the 55-parameter logistic regression.

The sidebar uses the model only for its attention state:

- a pink exclamation means the model predicts `attention_needed`;
- the existing hand remains the native permission indicator;
- the existing spinner remains the native working indicator when the model does
  not request attention.

Native harness notifications are unchanged. The classifier does not create
system notifications during this test phase.

The agent-tab context menu shows the current prediction and probability. Choose
**Show Attention Debug...** to inspect the input event, native activity
state/evidence, composition/focus state, and strongest weighted feature
contributions. The report can be copied for comparison with a correction.

## Run Controlled Scenarios

First add a disposable Git repository to Cherry. Then point the interactive
runner at that configured project and the desired agents:

```bash
Scripts/attention-scenario-runner \
  --project-dir /path/to/disposable-repository \
  --harness Codex \
  --harness Claude
```

The runner:

1. Opens the configured disposable Git repository in Cherry.
2. Verifies each requested harness is launchable.
3. Starts one configured agent per scenario.
4. Shows the startup screen and waits for a human to confirm the harness is ready.
5. Sends a controlled, harmless prompt where the scenario requires one.
6. Shows the rendered output and asks a human to capture, refresh, skip, or quit.
7. Writes the selected label into the exact captured observation.
8. Closes the agent and leaves the disposable repository intact.

The runner invokes real AI harnesses and may consume paid tokens. It never
assigns a label based on Cherry's current idle detector.

The runner has no harness-specific capture logic: any launchable agent configured
in Cherry can be passed with `--harness`, including future tools.

If more than one Cherry instance is open, pass the socket shown at launch:

```bash
Scripts/attention-scenario-runner \
  --socket /tmp/cherry-$UID/cherry-dev-.../control.sock \
  --project-dir /path/to/disposable-repository \
  --harness Pi \
  --scenario waiting-for-input
```

### Approval Profiles

Cherry's normal Codex and Claude presets may bypass approvals with `--yolo` or
`--dangerously-skip-permissions`. Those profiles cannot produce a genuine
`approval_required` screen. Add safe duplicate agent profiles without those
arguments and pass their configured names to the runner for that scenario.

## Generalization Protocol

Do not randomly split individual frames. Neighboring frames from one terminal
session are near duplicates and would leak into evaluation.

For the first experiment:

- Train and tune on whole Codex and Claude sessions.
- Hold out every Pi and Gemini session for blind, zero-shot evaluation.
- Keep harness name and version as evaluation metadata; do not provide them to
  the classifier.
- After that result is frozen, run the same scenario suite against OpenCode and
  Amp as a second unseen-harness test.

When a future harness appears, first run it through the unchanged scenario
suite. Retrain only if the blind result exposes a real coverage gap.

## Dataset Hygiene

- Use only disposable repositories without real secrets or customer data.
- Keep harness versions and run IDs so observations can be grouped by session.
- Manually verify every labeled evaluation checkpoint.
- Split by run/session and preferably by harness version.
- Preserve `unknown` examples, including authentication screens, startup
  screens, errors, ordinary shells, and prose containing misleading keywords.
- Never commit captured JSONL files to the repository.

The baseline is suitable for testing the pipeline, not yet for production
notifications. Expand the human-reviewed, unseen-session and unseen-harness
evaluation set before integrating it into Cherry or converting it to Core ML.

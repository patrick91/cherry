# Terminal Attention Classifier Lab

Cherry can collect terminal-grid observations for developing a small local
classifier that recognizes when an agent needs attention. Collection is off by
default because visible terminal grids can contain source code, prompts, paths,
credentials, and other sensitive text. The one exception is the continuous
attention samples of the user's own local install (below, "Continuous Samples
and Auto-Labelling"), which stay on that Mac.

## Labels

The classifier target is deliberately small:

- `attention_needed`: an outstanding user action exists: review a result, provide input, approve an action, or resolve a problem.
- `no_attention_needed`: there is no outstanding user action because the harness is working, the user is already responding, or there is no active task.
- `unknown`: the screen is ambiguous, out of distribution, or should be handled by abstention. This is an abstention/review state rather than a positive model target.

`attention_needed` observations keep one reason as annotation metadata:

- `result_ready`
- `waiting_for_input`
- `waiting_for_approval`
- `blocked_or_error`

`no_attention_needed` observations can likewise keep the reason:

- `agent_working`
- `user_responding`
- `idle_no_active_task`

Historical negative observations without a reason remain valid. Whether an
action alert has been seen is tracked independently; acknowledging a result
does not relabel its screen state.

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

Cherry's native Ghostty PTY currently exposes flattened text only, so recordings
from running sessions contain the plain terminal grid without `styledGrid`.
Shell-less renderer fixtures can still produce styled observations. Existing
schema-1 observations with or without styled runs remain valid.

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

- **Needs action from me**: Result ready for review, Needs my input, Needs my
  approval, or Blocked or errored.
- **No action from me**: Agent is working, I'm already responding, or Idle / no
  active task.
- **Not sure** for an ambiguous screen. This is retained as `unknown` and is
  excluded from binary model fitting.

For example, if the user is still typing, choose **I'm already responding**. Cherry
writes the current terminal snapshot as a `human_corrected` labeled checkpoint
with `cherry_in_app_human_correction` provenance. The context menu shows the
active manual tag as the current label and checkmarks it. The tag clears when
terminal content or input changes, so it cannot describe a later screen. Agent
sessions also show the model inference separately. Each correction preserves a
fresh prediction for that exact screen (source event, model ID, model label,
probability, and threshold) together with the observed turn lifecycle. Choosing
another label before the screen changes explicitly supersedes the earlier tag.
Escape and Control-C during an active turn are recorded as `turn_interrupted`;
that user action never creates a fresh attention alert by itself.

With bulk collection enabled, the correction stays in the normal private JSONL
recording. With collection disabled, Cherry writes only the clicked snapshot to
`~/Library/Application Support/Cherry/Attention Study/Corrections`. A later
provisional bundle preserves its label and annotation, and the dashboard
accepts it directly as a human review. Dataset export keeps only the latest
correction for an identical screen, including legacy corrections that predate
the explicit supersession link.

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

To add exported in-app corrections to an existing reviewed dataset while
preserving its test sessions for a comparable before/after evaluation:

```bash
Scripts/attention-augment-dataset \
  --dataset "$existing_run/dataset" \
  --correction-bundle /path/to/cherry-attention-corrections \
  --output "$run_root/dataset"
```

New corrections are training-only. A separately collected future bundle is
still required for an unbiased evaluation.

The exporter removes provisional labels, annotations, scenario/checkpoint
names, and session identifiers from the observation payload used for features.
It creates a deterministic whole-session train/test split and records a SHA-256
checksum in `manifest.json`. `unknown` reviews remain in the dataset but are
excluded from binary model fitting.

The model uses activity, runtime event, interaction, turn lifecycle, timing,
cursor, and screen-mode fields. It does not use terminal text, harness identity,
review metadata, source prediction metadata, or provisional labels. Legacy
corrections with no captured runtime event omit that feature instead of learning
the synthetic `labeled_checkpoint` value. Terminal phrases remain available only to the provisional
review sampler, which abstains on user-interrupted turns rather than treating
them as failures. The output contains:

- `model.json`: weights, feature names, scaling statistics, and threshold.
- `metrics.json`: fixed session-split metrics plus human leave-one-session-out
  evaluation.
- `predictions.jsonl`: predictions from the final fixed-split model.
- `human-loso-predictions.jsonl`: out-of-session predictions for every
  human-reviewed binary example.

Treat the human leave-one-session-out result as the headline measurement.
Metrics over `assistant_audit` examples are diagnostic because those labels
were produced by rules similar to the model inputs.

### Structured-Only Baseline (3 August 2026)

The completed local review produced 1,110 examples across 32 whole terminal
sessions: 493 `attention_needed`, 616 `no_attention_needed`, and one retained
`unknown`. Of these, 34 were directly human-reviewed and 1,076 were
assistant-audited.

The reviewed dataset was retrained without terminal-text marker features after
those features proved redundant and conflated user interruptions with errors.
The resulting dependency-free logistic regressor has 45 parameters. Its fixed
eight-session test split scored 97.1% balanced accuracy on 279 binary examples
(97.5% overall accuracy), unchanged from the marker-based model.
The more meaningful human leave-one-session-out evaluation scored 96.7%
balanced accuracy on 33 examples: 18 true positives, 14 true negatives, one
false positive, and no false negatives.

This closes the initial collection pass. The result is strong enough to
prototype integration and collect targeted corrections, but the human sample
still comes from one user and is too small to call production-ready.

The `20260810-corrections-v1` update added 30 usable in-app corrections (three
attention-needed and 27 no-attention-needed) to training while preserving the
original test sessions. Its fixed-test confusion matrix is unchanged from the
previous 45-parameter structured model. On the deliberately selected correction
challenge set, false positives fell from eight to five; all three positive
corrections still need the newly captured runtime-event and turn context before
they can be learned reliably. This challenge-set result is diagnostic, not an
unbiased accuracy estimate.

The `20260813-corrections-v2` update rebuilt from the original frozen dataset
and the latest cumulative correction export. It contains 34 usable corrections
(three attention-needed and 31 no-attention-needed), adding four records beyond
v1 after superseded and duplicate observations are removed. The new records add
captured `completed` and `not_started` turn-state features, producing a
47-parameter model. The fixed 279-example test confusion matrix remains exactly
unchanged at 111 true positives, 161 true negatives, six false negatives, and
one false positive. The two newest false-positive corrections move in the right
direction but remain above the 0.5 threshold; weighting the small correction set
enough to flip them caused held-out regressions, so the embedded model uses the
conservative unweighted fit. More newly captured positive and negative examples
are required to move that boundary safely.

The `20261004-corrections-v4` update rebuilt from the original frozen dataset
and the 2 October cumulative export (70 corrections, 31 July to 1 October). It
contains 68 usable corrections from 42 sessions (eight attention-needed: seven
results and one input request; 60 no-attention-needed), 34 beyond v2, after a
relabel of an identical screen and a duplicate are removed. The new `active`
and `user_interrupted` turn states enter through the existing `turn.state`
category, which Swift already emits, making 49 parameters. The corrections
carry no other field the model ignores, and the newer signals (question
menus, `needs_input`, self-resumed turns) have no training examples, so no
feature was added. The unweighted fit is worse on the fixed 279-example test,
with 111 true positives, 160 true negatives, six false negatives and two false
positives (one borderline screen crosses 0.5). Its human leave-one-session-out
over the 33 original reviews falls from v2's 93.9% to 90.6% balanced accuracy
(the 96.7% above is the July model). Over all 101 human examples it rises from
64.5% to 72.5%, but only on the corrections' recorded activity, which the old
screen rules produced: six of the eight positives were recorded as working, and
all 23 negatives labelled agent working were recorded as idle at a prompt. The
fit therefore learns a positive weight for an `active` turn and a strongly
negative one for `completed`, both backwards at runtime.

Correction weights raise the in-sample replay but not the held-out results.
Weight two keeps the fixed-test regression, and weight three scores
107/159/10/3. Replacing the corrections' activity with what the current screen
rules report removes the inversion. It still only trades a false negative for
a false positive on the fixed test (110/162/7/0, the same matrix v2 gives once
the live-work rule applies) and keeps the original-33 leave-one-session-out at
93.9%. At weight two its correction replay reaches 63 of 70 against v2's 61
with the rule overrides, and 63 against 58 without them. That gain is in
sample only. When each correction is scored by a model that never saw its
session, the variants replay 61 of 70, as v2 does, except fits that lose
fixed-test positives (replayed activity at weight three, 109/162/8/0, reaches
63). The unembedded 27 August v3 candidate (54 corrections) failed the same
way, at 111/160/6/2 and 90.6% on the original 33. v2 stays embedded.
Moving the boundary safely needs corrections captured under the current rules,
and a separate bundle of them held out for evaluation.

The `20261005-autolabel-v1` candidate extended v2's dataset (the July data
plus its 34 corrections, with the same 279-example fixed test) with
auto-labelled samples from the first two days of continuous sampling (4 and
5 October, 18 tab runs of Claude and Codex), `Scripts/attention-autolabel
--base-dataset … --teacher-keep negatives`. Hindsight resolved 1,809 of the
1,943 samples:

- working: 898 by live lines and 75 by output;
- 623 user responding;
- 170 results ready;
- 27 idle without a task;
- 16 waiting at a menu.

Once identical examples were dropped, 1,793 of them entered the dataset.
The teacher labelled 61 more (21 Haiku calls, about 171,000 input tokens);
60 of its positives were dropped and 4 answers abstained. Left out: 423
samples of the 43 tabs with in-app corrections, and the 35 corrections made
after v2, which are the held-out human set. 405 samples of tabs the hash
split held out became the `autolabel_holdout`, leaving 2,313 binary
training examples. `Scripts/attention-compare-models`, with the runtime
rules on top:

| Set | v2 TP/FP/TN/FN | Balanced | Candidate TP/FP/TN/FN | Balanced |
| --- | --- | --- | --- | --- |
| Fixed test (279) | 110/0/162/7 | 97.0% | 110/12/150/7 | 93.3% |
| Auto-label holdout (405) | 2/2/400/1 | 83.1% | 2/4/398/1 | 82.8% |
| Corrections after v2 (35) | 2/24/6/3 | 30.0% | 2/24/6/3 | 30.0% |

The candidate is worse, so v2 stays embedded. All 12 new fixed-test false
positives are July idle prompt screens (activity `idle`, evidence
`prompt_marker`, event `activity_state_changed`). Those observations predate
turn tracking, so they have no `turn.state` feature. The auto-labelled data
tells a waiting result from an idle prompt mostly by turn state, so the fit
raised the bias from -2.58 to -1.54, gave `completed` +0.24 (from -0.10),
`active` -0.43 and `not_started` -0.36. Screens without a turn state fall to
that higher bias. Every observation Cherry records now carries a turn state,
so the fixed test penalises the candidate on screens the runtime no longer
produces, but the rule above holds. The corrections made after v2 do not
separate the models at all: both alert on 24 of the 30 no-attention
corrections, which carry the old screen rules' activity, as corrections-v4
found. Judging a model trained on current samples needs a fixed test of
current observations, with turn states, frozen before it is used.

### Runtime Test Integration

Cherry embeds the final weights and reproduces the Python feature extractor in
Swift. The classifier runs locally for every agent session even when bulk study
collection is disabled, so the standard native Ghostty path remains available.
No MLX dependency is needed for the 47-parameter logistic regression.

The sidebar uses the model for the agent's turn presentation:

- a pink exclamation means the model predicts `attention_needed`;
- the existing hand remains the native permission indicator;
- the spinner appears when the model predicts `no_attention_needed` during an
  active turn: a submitted one, or one the agent resumed by itself (below).

High-confidence action predictions can create fallback system notifications for
top-level agents that do not notify on their own. A native harness notification
owns the episode and is delivered first, so the classifier does not send a
duplicate. Notification acknowledgement remains separate from classification.

The agent-tab context menu shows the current prediction and probability. Choose
**Show Attention Debug...** to inspect the input event, native activity
state/evidence, composition/focus state, and strongest weighted feature
contributions. The report can be copied for comparison with a correction.

Two rules from human corrections sit on top of the model's score. A
session with no submitted turn (`turn.state == not_started`: a fresh composer, a
folder-trust or resume dialog) never needs action. A screen with direct working
evidence (`working_marker` or `title_spinner`) never needs action either. The
debug report names the rule when one applies.

A third rule raises attention: a turn paused on a menu at the bottom of the
screen, a permission prompt (`AgentPermissionPrompt`) or a question with a
choice menu (`AgentQuestionPrompt`: Claude Code's AskUserQuestion, Codex's
request_user_input), always needs action. The session's state follows the menu
(`permission` or `needs_input`, evidence `answer_menu`, the same recognizers
MCP uses): the sidebar shows a hand or a question bubble, the menu bar counts
it as attention, and a top-level agent's alert notifies like any other episode.
Keys typed into the menu answer it rather than start a draft or a turn; when
the menu goes the paused turn is working again. A menu before the first turn
(a folder-trust dialog) is still gated as a startup screen.

The model's strongest input is the native activity state, so most corrections
are fixed in the screen rules (`AgentScreenActivity`: working markers, composer
prompts and harness-specific screens), not in the weights.

### Turns the Agent Resumes by Itself

An agent can go back to work after its turn ended without anyone submitting
anything: Claude answers a background agent's or task's result, a scheduled
wake-up or loop iteration fires, a workflow notifies it, or a hook continues
it. Cherry takes that as a new turn (`turn.state` is `active` again): the
sidebar shows the spinner, MCP counts it in `agent_turn` (a monitor's `done`
fires again when it ends), and its end is a new attention episode, which can
alert once.

A working marker alone cannot say so: a completed turn's screen can briefly
show one again when it is repainted or reflowed, and the episode logic
deliberately treats that as wobble so the finished result does not alert
twice (`acknowledgedAlertStaysConsumedThroughCompletedTurnClassifierWobble`).
A stale frame is frozen, while real work advances, so the turn restarts only
on a fresh working episode (`AgentResumedWorkDetector`, fed by the session):

- the screen's live-work lines (`AgentScreenActivity.workingLines`: Claude's
  newest status line and live task rows, an `esc to interrupt` hint, Pi's and
  Amp's statuses) changed twice within 4 s, the first and last change at
  least 1 s apart, each time in place (the same rows from the bottom of the
  screen, as a status line is redrawn; scrolling moves lines) and to text
  never shown since the turn ended: lines of the finished screen, or of a
  screen redrawn by a resize or a switch between the surface and the host,
  never count, nor does a frame shown before, nor a change within 1 s of a
  key or input sent to the agent; or
- the title's braille spinner changed twice within 4 s, at least 1 s apart.

So a repaint of the finished screen, a resize, a scroll, the user moving the
cursor, or one frozen working frame never starts a turn, and work shorter
than about a second is not seen. Only a completed turn, or an interrupted one
once its agent settled at the composer, is watched. A monitor or task wake
line Cherry types is a submitted turn already. Single recorded observations
cannot show the heartbeat, so the corrections replay keeps the recorded turn
state.

### Replay Corrections

`AttentionCorrectionsReplayTests` replays a corrections export through the
current screen rules and model, and reports each observation's replayed state
against the human label, per harness and for older and recent captures:

```bash
CHERRY_ATTENTION_CORRECTIONS_DIR=~/Desktop/cherry-attention-corrections \
CHERRY_ATTENTION_REPLAY_OUT=/tmp/replay.txt \
  swift test --filter replayHumanCorrections
```

The report contains IDs, dates, labels and verdicts, never screen text. Title
text is not recorded, so a recorded `title_spinner` state is replayed as a fresh
spinner. Turn state is replayed as recorded, and observations from before turn
tracking have none. Turn each new pattern into a synthetic fixture in
`AgentScreenActivityTests` rather than copying recorded screens into the repo.

## Continuous Samples and Auto-Labelling

Collecting corrections by hand is slow, and corrections-v4 showed what goes
wrong when labels and features come from different screen rules. Cherry
therefore samples every agent tab continuously, with the features its current
rules compute, and `Scripts/attention-autolabel` labels the samples from what
happened next, so no screen has to be tagged by hand.

### What Cherry Samples

`TerminalAttentionSampler` (`Sources/Cherry/TerminalAttentionSampling.swift`)
samples every agent tab (persistent, native, device and attached tabs; never
plain shells):

- every 30 s, from the screen as the tab last read it (no surface read, no
  classifier state change), while the tab's program runs;
- at once when Cherry's view of the tab changes: its activity state, the
  state's evidence, the turn state or count, or the prediction's label.

A sample whose screen and features repeat the tab's previous one is skipped.
The comparison ignores the elapsed-time numbers, which always advance, and
the event that made the tab's last observation, which a periodic sample
reuses. A periodic sample is also skipped:

- while the last sample is under 5 minutes old, when its screen differs only
  in animation: the live lines, each line's leading symbols and spaces (a
  spinner, Claude's blinking `⏺`), digits (clocks, token counts), trailing
  spaces and the cursor's column (`TerminalAttentionSampler.animationKey`);
- while the last sample is under 2 minutes old, when the tab works: live
  lines in it and in the last sample, with the same turn state and counts,
  activity state and prediction (`workKey`).

A skipped periodic sample may write an `unchanged` heartbeat naming the
sample that still describes the tab. It writes one at once when the live
lines read differently from the tab's previous record, and the heartbeat
carries them (`liveLines`). Otherwise heartbeats back off: one at the first
check, then gaps of 30 s, 1, 2 and 4 minutes, then one every 5 minutes.
Before these rules, over the first two days of samples (4 and 5 October
2026), 834 of the 1,586 periodic samples that differed from their tab's
previous one differed only in live lines and digits (6.7 MB). An idle tab
wrote a heartbeat every 30 s: by the evening of 5 October that day had
11,524 heartbeats (3 MB) against 1,628 samples (8.4 KB on average).
Replayed through the rules, the 5 October file (18.2 MB by then) comes to
6.6 MB (697 samples, 2,637 heartbeats). It
keeps every distinct waiting screen hindsight labels (70 result-ready
screens over 68 turns, 8 menus) and every working turn. What goes are
repeat copies of the same screen and the scrolling screens between a
working turn's samples. Each sample holds:

- `recordedAt`, the pseudonymous `tab` and `run` (the first 16 hex digits of
  the SHA-256 of the tab's UUID and of the launch's; a restart is a new run),
  `hostSession` (the persistent or attached session, hashed), `agent` (the
  screen rules' key) and `backend`;
- `observation`: exactly the classifier's input, with `terminal.grid` cut to
  the last 60 lines up to the last line with text (the cursor row is relative
  to that tail; `scrollbackLinesOmitted` and every other feature field are
  the full screen's), so `features` (`TerminalAttentionClassifier.features`,
  the trainer's `observation_features`) can be recomputed from it;
- `prediction` (model id, probability, threshold, label and the runtime rule
  that decided, if any) for that observation, and `shownPrediction`, what the
  tab shows now;
- `lifecycle`: turn state, submitted and self-resumed turn counts, and the
  last submit, output, content change, strong working evidence, keystroke
  and input times, the alert generation and whether an alert is unread;
- `screen`: the tail's live lines (`AgentScreenActivity.workingLines`) and
  verdict;
- `changes` since the tab's previous record, sample or heartbeat (schema 2;
  schema 1 counted from the previous sample, and its heartbeats from the
  last sample): how often the screen changed, how often by itself (no key,
  input or resize in the 1.5 s before), and the times of those self-driven
  changes, at most one a second. Heartbeats carry the same.

Interaction events go in between as their kind and time only, never content:
`typed` (at most one every 2 s), `submitted`, `menu_key` (detail
`permission` or `question`), `interrupted`, `focused` (selected or viewed, at
most one every 5 s), `closed` (detail: the close intent), `bell`,
`notification` and `exited` (detail: the status).

Records are appended to
`~/Library/Application Support/<identity>/Attention Study/Samples/<yyyy-mm-dd>.jsonl`
(local date), by a background queue in batches (every 5 s, or 64 KiB, and at
quit). The directory is `0700` and each file `0600`, opened without following
links. The directory is capped at 200 MB: the oldest day files go first, and
a day that alone outgrows the cap drops records until the next day. Each day
file takes samples and heartbeats up to 16 MB, about twice the busiest day
measured (6.6 MB with the rules above, ten agent tabs). Past that, only
events are written until the next day: they are small and rate-limited, and
hindsight labels need them. On the
main thread a sample costs one classifier pass over state the tab already
holds; with sampling off, or no agent tab running, there is no timer and no
work.

The setting is **Settings › Terminal › Attention Study › Collect attention
samples** (`attention.collectSamples`). Its default is on only for the
identity whose user agreed to collection, the local install
(`Scripts/install-local-app`, bundle identifier `dev.patrick.cherry.local`);
every other identity (tests, CherryDev, packaged builds, `swift run`)
defaults off. The default is computed, never written: only toggling the
setting stores a value. A blanket default-on would start writing screen text
for anyone who installs another build, which the study's opt-in rule above
forbids.

### Where the Data Lives and What Leaves the Mac

- Samples, recordings and corrections: the identity's
  `Application Support/<identity>/Attention Study/` (`Samples`, `Recordings`,
  `Corrections`). Never in the repository.
- Auto-label and evaluation runs: by default
  `Attention Study/Model Runs/<yyyymmdd-hhmmss>-autolabel` (or
  `-teacher-eval`), next to the earlier runs. The script refuses an
  `--output` inside a git work tree unless `--allow-in-repo` is given, writes
  a `.gitignore` of `*` into every run folder, and the repository's
  `.gitignore` also ignores `Model Runs/`, `Attention Study/`,
  `*-autolabel/`, `*-teacher-eval/` and `cherry-attention-*/`. Test fixtures
  are synthetic; nothing derived from real samples or corrections is
  committed.
- What leaves the machine: only the masked screen excerpts in teacher
  prompts, and only when the teacher runs (not with `--no-teacher` or
  `--dry-run`). Hindsight labelling, training and comparison are local. The
  script prints counts and ids, never screen text, and writes screens only
  into the run's own folder (the dataset's observations).

### Hindsight Labels

`Scripts/attention-autolabel` reads the day files, keeps each record once,
builds one timeline per tab run, and labels each sample from the samples and
events after it, with these rules in order (`hindsight_label`):

| Fine label | Rule | Binary label / reason |
| --- | --- | --- |
| `user_responding` | the sample shows an unsent draft, or the user typed within 5 s before it and has not submitted since | no / `user_responding` |
| `idle_no_task` | no turn was submitted or resumed in this run | no / `idle_no_active_task` |
| `working` | the screen changed by itself within 20 s, before the user acted, and either the sample's live lines read differently in the next sample, or the next heartbeat carrying live lines (within 45 s), or the program changed its screen in 3 or more separate seconds of those 20 and the next sample shows 2 or more new lines | no / `agent_working` |
| `needs_approval`, `needs_input` | the user's next action was a key into a menu (`menu_key`), and the screen did not change by itself from 2 s after the sample until then | yes / `waiting_for_approval`, `waiting_for_input` |
| `result_ready` | a turn ran in this run, the sample shows no live lines, the user's next action was typing or submitting, the screen did not change by itself from 2 s after the sample until then, and it had stood still at least 10 s when they did | yes / `result_ready` |

Everything else stays unresolved for the teacher: a tab closed, detached or
exited without the user typing (closing is a response to a result the user
may or may not have read already), an interrupt, a still screen that shows
live lines, a return within 10 s, or too little future. A one-line animation
(a clock, a spinner on an idle screen) is not work: it adds no new lines.
The run prints each rule's coverage. Identical examples (same tab run,
screen, categorical features and label) are kept once.

These labels come from what happened after the screen, not from the screen
rules that produce the features, so they cannot repeat the corrections-v4
mistake of learning the rules' old verdicts back.

### The Teacher

Samples hindsight cannot resolve go to a cheap model in batches (6 per call),
each with its masked 60-line screen, the last 12 lines of the previous and
next samples, whether a turn was submitted, whether a draft is open, and
what happened next in words ("the screen changed by itself 3 s later", "the
user typed 45 s later"). The default teacher is

```bash
claude -p --model haiku --output-format json --json-schema {schema} \
  --tools '' --strict-mcp-config --restricted --no-session-persistence \
  --disable-slash-commands
```

run with the prompt on stdin, in an empty temporary directory, from an
environment without `CLAUDECODE`, `CLAUDE_*` (but `CLAUDE_CONFIG_DIR`),
`CHERRY_*`, `CODEX_*`, `MCP_*` and `GHOSTTY_*`: a Claude started inside an
agent tab otherwise acts as that session's child, and Cherry's variables
name the tab and its MCP socket. `--restricted` skips the user's settings
(plugins and their hooks), `--strict-mcp-config` every MCP server, `--tools
''` every tool, and `--no-session-persistence` the transcript. Another
teacher takes the same stdin prompt, for example `--teacher "codex exec -m
gpt-6-luna -c model_reasoning_effort=low --skip-git-repo-check --output-schema
{schema_file} -"`. Calls are capped (`--max-calls`, default 300, with a
deterministic spread of items when the budget is short), the item, call and
token estimate is printed first, and `--dry-run` stops there.

Masking runs over every line sent: private-key blocks, Anthropic, OpenAI,
GitHub, GitLab, Slack, AWS, Google, Stripe, npm, PyPI and Tailscale keys,
JWTs, bearer tokens, URL passwords, `password=`/`token:`/`api_key=`-style
assignments (any key naming a password, secret, token, API or access key,
client secret or credential; numbers are left alone), and long mixed-case
alphanumeric strings with digits. Git hashes, UUIDs, paths and token counts
stay readable.

The teacher answers a label, a reason and a confidence; the reason decides
the label, and answers under 0.7 confidence or `unknown` are dropped.
`--teacher-keep negatives` keeps only its `no_attention_needed` labels.

#### Teacher Agreement With the Human Corrections

`--evaluate-on` runs the teacher over a corrections bundle and reports
agreement per label, reason and agent. The corrections carry no future
context, so the teacher sees present-only screens there; sampled screens
also get the screens and events around them, so this is a pessimistic
measure for the auto-labeller. On the 2 October bundle (68 usable
corrections: 8 attention-needed, 60 not), with Haiku through `claude -p`
(37 calls over four runs, 4 October 2026):

| Run | Teacher answer | Agree (of 68) | Balanced | Precision of kept labels |
| --- | --- | --- | --- | --- |
| 1 | label + reason, contradictions dropped | 57 (84%) | 80.0% | 57/60 (95%) |
| 1, rescored | label + reason, the reason decides | 64 (94%) | 85.8% | 64/67 (96%) |
| 2 | one state, no label | 59 (87%) | 81.7% | 59/67 (88%) |
| 3 | label + reason, the reason decides | 62 (91%) | 84.2% | 62/67 (93%) |

Run 1 (one smoke-test call before it) showed seven answers whose label
contradicted a correct reason (six Pi screens: `attention_needed` because
`agent_working`), so the reason now decides. Asking for the state alone (run
2) did worse, so the label stays in the answer, apparently as a step that
makes the model look twice. Run 3 replicates the shipped prompt and schema:
6 of 8 attention-needed and 56 of 60 no-attention corrections agree, Pi 15/15
and Codex 27/28. The teacher's `no_attention_needed` labels were 56/57
right; its `attention_needed` ones only 6/10 (two idle startup screens
called menus, a working screen called a result, a finished one called an
error), and confidence did not separate those errors. The prompt was
revised after run 1 on these same 68 corrections, so runs 2 and 3 are
optimistic; future in-app corrections are the unbiased check.

On 5 October 2026 the shipped prompt ran over the 35 corrections made after
v2's dataset was built (15 August to 4 October; 6 calls, about 36,000 input
tokens). It agreed on 32 (91%, balanced 95.0%). All 5 attention-needed
corrections agreed, and 27 of the 30 no-attention ones: Pi 15/15, Claude
16/17, Amp 1/3 (two idle Amp screens called results). Its `attention_needed`
answers were again the less precise (5 of 8 right), so the retrain below
kept only its negatives (`--teacher-keep negatives`). These 35 overlap the
68 the prompt was tuned on, so this is still optimistic.

### Dataset and Workflow

The output is a dataset directory `attention-train-baseline` and
`attention-augment-dataset` read (`dataset.jsonl` and a checksummed
`manifest.json`). Each record keeps its provenance: `review.source` is
`autolabel_hindsight` or `autolabel_teacher`, `review.provenance` names the
rule (`hindsight:result_ready:static_until_user`) or the teacher model, and
`autolabel` holds the fine label, teacher confidence, agent, trigger and
Cherry's own prediction. The split is by whole tab (a hash of the tab id,
`--test-fraction`, default 0.2). With `--base-dataset` the base records are
kept as they are, so the frozen test split stays the fixed comparison, and
the auto-labelled test tabs become `autolabel_holdout` (scored separately,
never fitted).

Held-out human set: every tab with an in-app human correction in the
identity's `Corrections` or `Recordings` (and any `--holdout-corrections`
bundle) is left out of the auto-labelled data entirely, matched by hashing
the correction's `session.id` as Cherry hashes the tab. Future corrections
are never trained on; they are the evaluation set.

1. **Collect.** Use the local install with *Collect attention samples* on.
   Keep tagging a screen now and then (**Tag Current Screen**): those
   corrections are the held-out evaluation set.
2. **Auto-label.**
   ```bash
   Scripts/attention-autolabel --dry-run                      # coverage and teacher estimate
   Scripts/attention-autolabel --base-dataset "$frozen/dataset"
   ```
   `--evaluate-on` a new corrections bundle first if the teacher, its prompt
   or the harnesses changed.
3. **Train.**
   ```bash
   Scripts/attention-train-baseline --dataset "$run/dataset" --output "$run/model"
   ```
4. **Compare with the embedded model** on the fixed test and the held-out
   corrections, with Cherry's runtime rules on top:
   ```bash
   Scripts/attention-study-data export --source ".../Attention Study/Corrections" \
     --output ~/Desktop/cherry-attention-heldout
   Scripts/attention-compare-models --candidate "$run/model/model.json" \
     --dataset "$run/dataset" --corrections ~/Desktop/cherry-attention-heldout
   ```
   It reads the embedded weights from `TerminalAttentionClassifier.swift`
   (its probabilities match Cherry's) and calls the candidate "not worse"
   only when no set gains a false positive or a false negative.
5. **Embed only if nothing gets worse**: copy the weights, feature names and
   statistics into `TerminalAttentionClassifier.swift`, bump `modelID`, and
   record the run here.

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

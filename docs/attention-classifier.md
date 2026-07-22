# Terminal Attention Classifier Lab

Cherry can collect terminal-grid observations for developing a small local
classifier that recognizes when an agent needs attention. Collection is off by
default because visible terminal grids can contain source code, prompts, paths,
credentials, and other sensitive text.

## Labels

The version 1 dataset uses five labels:

- `approval_required`: the harness is waiting for a permission or confirmation.
- `waiting_for_input`: the harness asked a question and cannot continue without an answer.
- `ready_for_review`: the harness completed a useful turn and returned control to the user.
- `no_attention_needed`: the harness is actively working and needs no user action.
- `unknown`: the screen is ambiguous, out of distribution, or should be handled by abstention.

Automatic observations are deliberately unlabeled. Only a human-triggered
checkpoint receives a label; Cherry's current heuristic state is stored as
diagnostic evidence, never as training truth.

## Week-Long Study Mode

On the laptop, open **Settings → Terminal → Attention Study** and enable
**Collect agent observations**. The setting applies to active and future agent
sessions without requiring an app restart.

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
session. Each record contains a schema version, terminal viewport text,
dimensions, cursor state, screen mode, timing signals, output/content counters,
heuristic evidence, and optional scenario metadata. It does not record submitted
input separately, working directories, notification bodies, or command lines.

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

Select the whole exported directory in the browser. Uploads are chunked,
schema-validated, and de-duplicated by observation UUID. Unlike the local
import command, the browser uploader does not re-check the manifest's file
checksums. The full terminal text is stored in D1, so use a strong token and
treat the deployment as private research infrastructure.

The current private deployment is
<https://cherry-attention-lab.patrick-arminio.workers.dev>.

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

The model and Core ML integration should be built only after this capture path
has produced a representative, trustworthy evaluation set.

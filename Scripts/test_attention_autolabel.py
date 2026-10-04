"""Tests for Scripts/attention-autolabel. Every fixture is synthetic."""

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from typing import Any


def load_script(name: str) -> Any:
    path = Path(__file__).with_name(name)
    module_name = name.replace("-", "_")
    loader = importlib.machinery.SourceFileLoader(module_name, str(path))
    specification = importlib.util.spec_from_loader(loader.name, loader)
    assert specification is not None
    module = importlib.util.module_from_spec(specification)
    sys.modules[module_name] = module
    loader.exec_module(module)
    return module


AUTOLABEL = load_script("attention-autolabel")
TRAINER = load_script("attention-train-baseline")
COMPARE = load_script("attention-compare-models")

T0 = 1_791_200_000.0
TAB = "0123456789abcdef"
RUN = "fedcba9876543210"


def iso(t: float) -> str:
    from datetime import datetime, timezone
    return datetime.fromtimestamp(t, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def sample(
    t: float,
    grid: list[str],
    *,
    live: list[str] | None = None,
    changes: list[float] | None = None,
    submitted: int = 1,
    turn: str = "active",
    draft: bool = False,
    tab: str = TAB,
    run: str = RUN,
    activity: str = "working",
    evidence: str = "working_marker",
) -> dict[str, Any]:
    identifier = str(uuid.uuid5(uuid.NAMESPACE_URL, f"{tab}{run}{t}"))
    observation = {
        "activity": {"evidence": evidence, "hasUnreadNotification": False, "processState": "live", "state": activity},
        "contentVersion": 1,
        "event": "content_changed",
        "id": str(uuid.uuid4()),
        "interaction": {"hasUnsubmittedInput": draft, "millisecondsSinceLastKeystroke": 4000, "terminalFocused": True},
        "outputVersion": 1,
        "recordedAt": iso(t),
        "schemaVersion": 1,
        "session": {"harness": "Claude", "id": tab, "kind": "agent", "runID": run},
        "terminal": {
            "columns": 80, "rows": 24, "usesAlternateScreen": True, "scrollbackLinesOmitted": 0,
            "cursor": {"column": 2, "isVisible": True, "row": len(grid) - 1, "shape": "block"},
            "grid": grid,
        },
        "timing": {"millisecondsSinceLastContentChange": 500, "millisecondsSinceLastOutput": 500,
                   "millisecondsSinceStarted": 60000, "millisecondsSinceLastHumanInput": 4000},
        "turn": {"state": turn},
    }
    return {
        "type": "sample",
        "schemaVersion": 1,
        "id": identifier,
        "recordedAt": iso(t),
        "trigger": "periodic",
        "tab": tab,
        "run": run,
        "agent": "claude",
        "backend": "persistent",
        "observation": observation,
        "features": TRAINER.observation_features({"observation": observation}),
        "prediction": {"modelID": "m", "attentionProbability": 0.2, "threshold": 0.5, "label": "no_attention_needed"},
        "lifecycle": {"turnState": turn, "submittedTurns": submitted, "selfResumedTurns": 0,
                      "alertGeneration": 0, "hasUnacknowledgedAttention": False},
        "screen": {"tailStartRow": 0, "viewportGridRows": len(grid), "liveLines": live or [], "verdict": "none"},
        "changes": {"contentChanges": len(changes or []), "selfDrivenChanges": len(changes or []),
                    "selfDrivenChangeTimes": changes or []},
    }


def event(t: float, kind: str, detail: str | None = None, tab: str = TAB, run: str = RUN) -> dict[str, Any]:
    record = {"type": "event", "schemaVersion": 1, "recordedAt": iso(t), "tab": tab, "run": run, "kind": kind}
    if detail:
        record["detail"] = detail
    return record


def heartbeat(t: float, sample_id: str, changes: list[float] | None = None) -> dict[str, Any]:
    return {
        "type": "unchanged", "schemaVersion": 1, "recordedAt": iso(t), "tab": TAB, "run": RUN,
        "sample": sample_id,
        "changes": {"contentChanges": 0, "selfDrivenChanges": 0, "selfDrivenChangeTimes": changes or []},
    }


WORKING = ["❯ fix the bug", "", "⏺ Reading files", "", "✻ Frosting… (12s · esc to interrupt)", "", "❯ "]
WORKING_LATER = ["❯ fix the bug", "", "⏺ Reading files", "⏺ Edited main.rs", "", "✻ Frosting… (40s · esc to interrupt)", "", "❯ "]
DONE = ["❯ fix the bug", "", "⏺ Fixed the off-by-one in main.rs.", "", "✻ Worked for 52s", "", "❯ "]


def label(records: list[dict[str, Any]], index: int = 0) -> Any:
    timelines = AUTOLABEL.build_timelines(records)
    assert len(timelines) == 1
    return AUTOLABEL.hindsight_label(timelines[0], index)


class HindsightRuleTests(unittest.TestCase):
    def test_live_lines_that_advance_are_work(self) -> None:
        first = sample(T0, WORKING, live=["✻ Frosting… (12s · esc to interrupt)"])
        second = sample(T0 + 30, WORKING_LATER, live=["✻ Frosting… (40s · esc to interrupt)"],
                        changes=[T0 + 1, T0 + 2, T0 + 3])
        verdict = label([first, second])
        self.assertEqual((verdict.fine, verdict.rule), ("working", "live_lines_advanced"))
        self.assertEqual((verdict.target, verdict.reason), ("no_attention_needed", "agent_working"))

    def test_sustained_new_output_is_work_without_live_lines(self) -> None:
        first = sample(T0, ["$ amp", "> refactor", "thinking"])
        second = sample(T0 + 30, ["$ amp", "> refactor", "changed a.py", "changed b.py", "changed c.py"],
                        changes=[T0 + 2, T0 + 5, T0 + 9])
        verdict = label([first, second])
        self.assertEqual((verdict.fine, verdict.rule), ("working", "output_continued"))

    def test_one_line_animation_is_not_work(self) -> None:
        first = sample(T0, ["> idle", "◌ 12:00:01"])
        second = sample(T0 + 30, ["> idle", "◌ 12:00:31"], changes=[T0 + 1, T0 + 2, T0 + 3, T0 + 4])
        self.assertIsNone(label([first, second]))

    def test_static_result_until_the_user_types_is_result_ready(self) -> None:
        done = sample(T0, DONE, activity="idle", evidence="prompt_marker", turn="completed",
                      changes=[T0 - 3, T0 - 1])
        records = [done, heartbeat(T0 + 30, done["id"]), heartbeat(T0 + 60, done["id"]), event(T0 + 75, "typed")]
        verdict = label(records)
        self.assertEqual((verdict.fine, verdict.target, verdict.reason),
                         ("result_ready", "attention_needed", "result_ready"))

    def test_the_finished_screens_last_repaint_still_counts_as_static(self) -> None:
        done = sample(T0, DONE, activity="idle", evidence="prompt_marker", turn="completed")
        records = [done, heartbeat(T0 + 30, done["id"], changes=[T0 + 0.8]), event(T0 + 40, "submitted")]
        self.assertEqual(label(records).fine, "result_ready")

    def test_a_quick_return_is_left_to_the_teacher(self) -> None:
        done = sample(T0, DONE, activity="idle", evidence="prompt_marker", turn="completed", changes=[T0 - 1])
        self.assertIsNone(label([done, event(T0 + 4, "typed")]))

    def test_a_change_before_the_user_came_back_is_not_a_result(self) -> None:
        done = sample(T0, DONE, activity="idle", evidence="prompt_marker", turn="completed")
        records = [done, heartbeat(T0 + 60, done["id"], changes=[T0 + 45]), event(T0 + 90, "typed")]
        self.assertIsNone(label(records))

    def test_a_menu_answered_by_the_user_needs_input_or_approval(self) -> None:
        menu = sample(T0, ["Do you want to proceed?", "❯ 1. Yes", "  2. No"], activity="permission",
                      evidence="answer_menu")
        verdict = label([menu, event(T0 + 20, "menu_key", "permission")])
        self.assertEqual((verdict.fine, verdict.reason), ("needs_approval", "waiting_for_approval"))
        verdict = label([menu, event(T0 + 20, "menu_key", "question")])
        self.assertEqual((verdict.fine, verdict.reason), ("needs_input", "waiting_for_input"))

    def test_an_unsent_draft_or_recent_typing_is_user_responding(self) -> None:
        self.assertEqual(label([sample(T0, DONE, draft=True)]).fine, "user_responding")
        records = [event(T0 - 2, "typed"), sample(T0, DONE, turn="completed")]
        self.assertEqual(label(records).rule, "typed_just_before")
        # Typing that was submitted since is not a draft.
        records = [event(T0 - 3, "typed"), event(T0 - 2, "submitted"), sample(T0, DONE, turn="completed")]
        self.assertIsNone(label(records))

    def test_no_turn_this_run_is_idle_without_a_task(self) -> None:
        fresh = sample(T0, ["Claude Code", "", "❯ Try \"fix lint\""], submitted=0, turn="not_started",
                       activity="idle", evidence="prompt_marker")
        verdict = label([fresh, event(T0 + 600, "typed")])
        self.assertEqual((verdict.fine, verdict.reason), ("idle_no_task", "idle_no_active_task"))

    def test_closing_without_typing_stays_unresolved(self) -> None:
        done = sample(T0, DONE, activity="idle", evidence="prompt_marker", turn="completed")
        self.assertIsNone(label([done, heartbeat(T0 + 30, done["id"]), event(T0 + 50, "closed", "userClosedTab")]))

    def test_output_after_the_user_submits_is_not_the_samples_work(self) -> None:
        done = sample(T0, DONE, activity="idle", evidence="prompt_marker", turn="completed")
        reply = sample(T0 + 20, WORKING, live=["✻ Frosting… (2s · esc to interrupt)"],
                       changes=[T0 + 12, T0 + 13, T0 + 14])
        records = [done, event(T0 + 11, "submitted"), reply]
        verdict = label(records)
        self.assertEqual(verdict.fine, "result_ready")

    def test_heartbeats_after_the_last_sample_carry_its_changes(self) -> None:
        first = sample(T0, WORKING, live=["✻ Frosting… (12s · esc to interrupt)"])
        timeline = AUTOLABEL.build_timelines([first, heartbeat(T0 + 30, first["id"], changes=[T0 + 4, T0 + 6])])[0]
        self.assertEqual(timeline.self_change_times_after(0), [T0 + 4, T0 + 6])

    def test_rules_cover_every_fine_label(self) -> None:
        self.assertEqual(set(AUTOLABEL.FINE_LABELS), {
            "working", "user_responding", "idle_no_task", "result_ready", "needs_input", "needs_approval",
        })


class ReadingTests(unittest.TestCase):
    def test_records_are_read_once_and_bad_lines_counted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            first = sample(T0, DONE)
            path = Path(directory) / "2026-10-04.jsonl"
            lines = [json.dumps(first), json.dumps(first), "{not json", json.dumps(event(T0 + 1, "bell"))]
            path.write_text("\n".join(lines) + "\n", encoding="utf-8")
            (Path(directory) / "notes.jsonl").write_text(json.dumps(first) + "\n", encoding="utf-8")
            records, stats = AUTOLABEL.load_records(AUTOLABEL.sample_files([Path(directory)], None))
        self.assertEqual(len(records), 2)
        self.assertEqual((stats["duplicate"], stats["malformed"]), (1, 1))

    def test_near_duplicate_samples_keep_one_example(self) -> None:
        records = [sample(T0, DONE, draft=True), sample(T0 + 30, DONE, draft=True)]
        timelines = AUTOLABEL.build_timelines(records)
        labelled, _ = AUTOLABEL.label_timelines(timelines, AUTOLABEL.HindsightConfig(), set())
        kept, dropped = AUTOLABEL.deduplicate(labelled)
        self.assertEqual((len(kept), dropped), (1, 1))

    def test_corrected_tabs_are_held_out(self) -> None:
        tab_uuid = "8E038110-E7F3-48E9-BC21-AD9431A8274B"
        correction = {
            "id": "C1", "recordedAt": iso(T0), "label": "attention_needed",
            "annotation": {"provenance": "cherry_in_app_human_correction", "reason": "result_ready"},
            "session": {"id": tab_uuid, "harness": "Claude", "kind": "agent"},
            "terminal": {"grid": ["done"]},
        }
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "corrections.jsonl").write_text(json.dumps(correction) + "\n", encoding="utf-8")
            tabs = AUTOLABEL.held_out_tabs(AUTOLABEL.correction_payloads([Path(directory)]))
        held_tab = AUTOLABEL.stable_id(tab_uuid)
        self.assertEqual(tabs, {held_tab})
        timelines = AUTOLABEL.build_timelines([sample(T0, DONE, tab=held_tab), sample(T0, DONE, tab="other0123456789a")])
        labelled, stats = AUTOLABEL.label_timelines(timelines, AUTOLABEL.HindsightConfig(), tabs)
        self.assertEqual(stats["excluded_holdout"], 1)
        self.assertTrue(all(item.sample.tab != held_tab for item in labelled))

    def test_swift_samples_features_match_the_trainers(self) -> None:
        # A sample Cherry wrote in a unit test (synthetic screen): the
        # features it recorded are the ones the trainer computes.
        recorded = json.loads(SWIFT_SAMPLE)
        self.assertEqual(TRAINER.observation_features({"observation": recorded["observation"]}), recorded["features"])


class TeacherTests(unittest.TestCase):
    def items(self, count: int) -> list[dict[str, Any]]:
        return [{"id": f"item-{index}", "agent": "claude", "turn_submitted": "yes", "user_draft": "no",
                 "screen": ["❯ "]} for index in range(count)]

    def test_batches_and_the_call_cap(self) -> None:
        plan = AUTOLABEL.plan_teacher(self.items(25), batch_size=4, max_calls=3)
        self.assertEqual(plan.calls, 3)
        self.assertEqual([len(batch) for batch in plan.batches], [4, 4, 4])
        self.assertEqual(plan.skipped_items, 13)
        again = AUTOLABEL.plan_teacher(self.items(25), batch_size=4, max_calls=3)
        self.assertEqual([[item["id"] for item in batch] for batch in plan.batches],
                         [[item["id"] for item in batch] for batch in again.batches])
        self.assertEqual(AUTOLABEL.plan_teacher(self.items(5), batch_size=4, max_calls=0).calls, 0)
        self.assertEqual(AUTOLABEL.plan_teacher(self.items(9), batch_size=4, max_calls=300).calls, 3)

    def test_the_teacher_runs_scrubbed_never_over_its_plan(self) -> None:
        calls: list[dict[str, Any]] = []

        def runner(arguments: list[str], prompt: str, environment: dict[str, str], cwd: Path, timeout: float):
            calls.append({"arguments": arguments, "prompt": prompt, "environment": environment, "cwd": cwd})
            ids = [line.split()[-1] for line in prompt.splitlines() if line.startswith("### item ")]
            envelope = {"type": "result", "is_error": False, "structured_output": {"labels": [
                {"id": identifier, "label": "no_attention_needed", "reason": "agent_working", "confidence": 0.9}
                for identifier in ids
            ]}}
            return 0, json.dumps(envelope), ""

        secret_env = {"CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli", "CHERRY_SESSION_ID": "x",
                      "CHERRY_MCP_TOKEN": "y", "CODEX_THREAD_ID": "z"}
        items = self.items(7)
        items[0]["screen"] = ["export GITHUB_TOKEN=ghp_" + "a1B2" * 9]
        items[0]["screen"], _ = AUTOLABEL.mask_lines(items[0]["screen"])
        plan = AUTOLABEL.plan_teacher(items, batch_size=3, max_calls=2)
        original = dict(os.environ)
        os.environ.update(secret_env)
        try:
            answers, log = AUTOLABEL.run_teacher(plan, AUTOLABEL.DEFAULT_TEACHER, jobs=2, runner=runner, log=lambda _: None)
        finally:
            os.environ.clear()
            os.environ.update(original)
        self.assertEqual(len(calls), 2)
        self.assertEqual(len(answers), 6)
        self.assertEqual([entry["answered"] for entry in log], [3, 3])
        for call in calls:
            self.assertFalse(set(secret_env) & set(call["environment"]))
            self.assertNotIn("ghp_", call["prompt"])
            self.assertEqual(call["arguments"][0], "claude")
            self.assertIn("--strict-mcp-config", call["arguments"])
            schema = call["arguments"][call["arguments"].index("--json-schema") + 1]
            self.assertEqual(json.loads(schema), AUTOLABEL.TEACHER_SCHEMA)
            self.assertNotEqual(Path(call["cwd"]).resolve(), Path.cwd().resolve())
        self.assertFalse(any("prompt" in entry or "screen" in entry for entry in log))

    def test_environment_scrubbing(self) -> None:
        environment = {
            "PATH": "/usr/bin", "HOME": "/Users/u", "CLAUDECODE": "1", "CLAUDE_CODE_SSE_PORT": "1",
            "CLAUDE_CONFIG_DIR": "/c", "CLAUDE_PROJECT_DIR": "/p", "CHERRY_CONTROL_SOCKET": "/s",
            "CHERRY_PROCESS_ID": "1", "CODEX_SANDBOX": "seatbelt", "MCP_SERVER": "x", "ANTHROPIC_API_KEY": "k",
        }
        self.assertEqual(AUTOLABEL.scrubbed_environment(environment), {
            "PATH": "/usr/bin", "HOME": "/Users/u", "CLAUDE_CONFIG_DIR": "/c", "ANTHROPIC_API_KEY": "k",
        })

    def test_secret_masking(self) -> None:
        secrets = [
            "ANTHROPIC_API_KEY=sk-ant-api03-" + "x" * 30,
            "key sk-proj-" + "Ab1" * 10,
            "token ghp_" + "Z9y" * 12,
            "AWS AKIAIOSFODNN7EXAMPLE",
            "slack xoxb-1234567890-abcdefghij",
            "Authorization: Bearer abc.def.ghi123456789",
            "jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
            "postgres://admin:hunter2pass@db.local/app",
            "password=hunter2pass",
            'DASHBOARD_TOKEN: "s3cr3t-value"',
            "client_secret = 'abcdef123'",
            "blob Q2hlcnJ5U2VjcmV0S2V5Rm9yVGVzdHMxMjM0NTY3OA",
        ]
        for line in secrets:
            masked, count = AUTOLABEL.mask_line(line)
            self.assertGreater(count, 0, line)
            for fragment in ("hunter2", "s3cr3t", "abcdef123", "AKIAIOSF", "Z9yZ9y", "Ab1Ab1", "xxxxxxxx",
                             "eyJzdWIi", "abc.def", "Q2hlcnJ5", "1234567890-abc"):
                if fragment in line:
                    self.assertNotIn(fragment, masked, line)
        block, count = AUTOLABEL.mask_lines([
            "before",
            "-----BEGIN OPENSSH PRIVATE KEY-----",
            "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ",
            "-----END OPENSSH PRIVATE KEY-----",
            "after",
        ])
        self.assertEqual(block[0], "before")
        self.assertEqual(block[-1], "after")
        self.assertTrue(all(line == "[MASKED:private_key]" for line in block[1:4]))
        harmless = [
            "✻ Frosting… (1m 2s · ↓ 585 tokens)",
            "commit 3f7b2471c9a0d5e6b8f1a2c3d4e5f60718293a4b",
            "session 8E038110-E7F3-48E9-BC21-AD9431A8274B",
            "/Users/patrick/github/patrick91/cherry/Sources/Cherry/TerminalSession.swift",
            "TerminalAttentionSampleHeartbeat",
            "max_tokens: 4096",
        ]
        for line in harmless:
            self.assertEqual(AUTOLABEL.mask_line(line), (line, 0), line)

    def test_labels_come_out_of_claude_and_plain_output(self) -> None:
        labels = [{"id": "a", "label": "attention_needed", "reason": "result_ready", "confidence": 0.8}]
        structured = json.dumps({"type": "result", "result": "", "structured_output": {"labels": labels}})
        self.assertEqual(AUTOLABEL.extract_labels(structured), labels)
        texted = json.dumps({"type": "result", "result": "```json\n" + json.dumps({"labels": labels}) + "\n```"})
        self.assertEqual(AUTOLABEL.extract_labels(texted), labels)
        self.assertEqual(AUTOLABEL.extract_labels("codex says\n" + json.dumps({"labels": labels}) + "\n"), labels)
        with self.assertRaises(AUTOLABEL.AutolabelError):
            AUTOLABEL.extract_labels(json.dumps({"type": "result", "is_error": True, "result": "overloaded"}))

    def test_only_confident_known_reasons_count_and_set_the_label(self) -> None:
        good = {"label": "attention_needed", "reason": "result_ready", "confidence": 0.9}
        self.assertEqual(AUTOLABEL.valid_teacher_label(good, 0.7), ("attention_needed", "result_ready"))
        # The reason decides when the label contradicts it.
        contradicting = {**good, "reason": "agent_working"}
        self.assertTrue(AUTOLABEL.contradicts_itself(contradicting))
        self.assertEqual(AUTOLABEL.valid_teacher_label(contradicting, 0.7), ("no_attention_needed", "agent_working"))
        self.assertFalse(AUTOLABEL.contradicts_itself(good))
        self.assertIsNone(AUTOLABEL.valid_teacher_label({**good, "confidence": 0.5}, 0.7))
        self.assertIsNone(AUTOLABEL.valid_teacher_label({**good, "label": "unknown", "reason": "none"}, 0.7))
        self.assertIsNone(AUTOLABEL.valid_teacher_label({**good, "reason": "bored"}, 0.7))
        self.assertEqual(set(AUTOLABEL.TEACHER_SCHEMA["properties"]["labels"]["items"]["required"]),
                         {"id", "label", "reason", "confidence"})

    def test_evaluation_report_counts_agreement_per_label(self) -> None:
        truth = {
            "a": ("attention_needed", "result_ready", "claude"),
            "b": ("no_attention_needed", "agent_working", "codex"),
            "c": ("no_attention_needed", None, "codex"),
            "d": ("attention_needed", "waiting_for_input", "pi"),
        }
        answers = {
            "a": {"label": "attention_needed", "reason": "result_ready", "confidence": 0.9},
            "b": {"label": "no_attention_needed", "reason": "result_ready", "confidence": 0.9},
            "c": {"label": "no_attention_needed", "reason": "agent_working", "confidence": 0.4},
        }
        report = AUTOLABEL.evaluation_report(truth, answers, 0.7)
        self.assertEqual(report["byLabel"]["attention_needed"]["agree"], 1)
        self.assertEqual(report["byLabel"]["attention_needed"]["missing"], 1)
        self.assertEqual(report["byLabel"]["no_attention_needed"]["disagree"], 1)
        self.assertEqual(report["byLabel"]["no_attention_needed"]["abstained"], 1)
        self.assertEqual(report["byLabel"]["no_attention_needed"]["rawAgree"], 1)
        self.assertAlmostEqual(report["balancedAgreement"], 0.25)
        self.assertEqual(report["labelsContradictingTheirReason"], 1)


class OutputTests(unittest.TestCase):
    def test_output_inside_a_git_work_tree_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory) / "repo"
            (repository / ".git").mkdir(parents=True)
            with self.assertRaises(AUTOLABEL.AutolabelError):
                AUTOLABEL.prepare_output_directory(repository / "runs" / "one", allow_in_repo=False)
            output = AUTOLABEL.prepare_output_directory(repository / "runs" / "two", allow_in_repo=True)
            self.assertEqual((output / ".gitignore").read_text(), "*\n")
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)

    def test_the_repository_itself_is_a_work_tree(self) -> None:
        self.assertTrue(AUTOLABEL.inside_git_work_tree(Path(__file__).parent / "some-run"))

    def test_the_default_output_is_in_application_support(self) -> None:
        output = AUTOLABEL.default_output("Cherry", "autolabel")
        self.assertEqual(output.parent, Path.home() / "Library/Application Support/Cherry/Attention Study/Model Runs")

    def test_split_is_deterministic_by_whole_session(self) -> None:
        splits = {AUTOLABEL.session_split(f"sample-tab:{index:016x}", 0.2) for index in range(200)}
        self.assertEqual(splits, {"train", "test"})
        self.assertEqual(AUTOLABEL.session_split("sample-tab:a", 0.2), AUTOLABEL.session_split("sample-tab:a", 0.2))

    def write_samples(self, directory: Path) -> None:
        records: list[dict[str, Any]] = []
        for number in range(12):
            tab = f"{number:016x}"
            start = T0 + number * 1_000
            done = sample(start + 30, DONE, tab=tab, activity="idle", evidence="prompt_marker", turn="completed")
            records += [
                sample(start, WORKING, tab=tab, live=["✻ Frosting… (12s · esc to interrupt)"]),
                done,
                heartbeat(start + 60, done["id"]) | {"tab": tab},
                event(start + 80, "typed", tab=tab),
                sample(start + 90, DONE, tab=tab, draft=True, turn="completed"),
            ]
            records[-4]["changes"] = {"contentChanges": 3, "selfDrivenChanges": 3,
                                      "selfDrivenChangeTimes": [start + 2, start + 5, start + 28]}
        (directory / "2026-10-04.jsonl").write_text(
            "".join(json.dumps(record) + "\n" for record in records), encoding="utf-8"
        )

    def test_the_dataset_trains_with_provenance_per_example(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            samples = root / "Samples"
            samples.mkdir()
            self.write_samples(samples)
            output = root / "run"
            code = AUTOLABEL.main([
                "--samples", str(samples), "--output", str(output), "--no-teacher",
                "--no-default-holdout", "--test-fraction", "0.3",
            ])
            self.assertEqual(code, 0)
            records = TRAINER.read_dataset(output / "dataset")
            self.assertEqual({record["target"] for record in records}, {"attention_needed", "no_attention_needed"})
            for record in records:
                self.assertEqual(record["review"]["source"], "autolabel_hindsight")
                self.assertTrue(record["review"]["provenance"].startswith("hindsight:"))
                self.assertIn(record["split"], {"train", "test"})
                self.assertNotIn("id", record["observation"])
                self.assertEqual(set(record["observation"]["session"]), {"harness", "kind"})
                TRAINER.observation_features(record)
            by_session: dict[str, set[str]] = {}
            for record in records:
                by_session.setdefault(record["sessionID"], set()).add(record["split"])
            self.assertTrue(all(len(splits) == 1 for splits in by_session.values()))
            report = json.loads((output / "report.json").read_text())
            self.assertIn("rule:result_ready:static_until_user", report["hindsight"])
            for path in (output / "dataset" / "dataset.jsonl", output / "report.json"):
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)

            model = root / "model"
            TRAINER.train_baseline(type("Args", (), {"dataset": output / "dataset", "output": model})())
            self.assertTrue((model / "model.json").exists())

    def test_a_base_dataset_keeps_its_fixed_test_split(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            samples = root / "Samples"
            samples.mkdir()
            self.write_samples(samples)
            base = root / "base"
            base.mkdir()
            base_record = {
                "datasetSchemaVersion": 1, "observationID": "base-1", "recordedAt": iso(T0), "sessionID": "S-base",
                "harness": "Codex", "split": "test", "target": "attention_needed", "attentionReason": "result_ready",
                "review": {"source": "human", "status": "accepted"},
                "observation": sample(T0, DONE)["observation"],
            }
            (base / "dataset.jsonl").write_text(json.dumps(base_record) + "\n", encoding="utf-8")
            (base / "manifest.json").write_text(json.dumps({
                "datasetFile": {"sha256": AUTOLABEL.sha256_file(base / "dataset.jsonl")},
                "sessions": {"test": ["S-base"], "train": []},
            }), encoding="utf-8")
            output = root / "run"
            self.assertEqual(AUTOLABEL.main([
                "--samples", str(samples), "--output", str(output), "--no-teacher", "--no-default-holdout",
                "--base-dataset", str(base), "--test-fraction", "0.5",
            ]), 0)
            records = TRAINER.read_dataset(output / "dataset")
            test = [record for record in records if record["split"] == "test"]
            self.assertEqual([record["observationID"] for record in test], ["base-1"])
            self.assertIn("autolabel_holdout", {record["split"] for record in records})

    def test_a_dry_run_writes_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            samples = root / "Samples"
            samples.mkdir()
            self.write_samples(samples)
            self.assertEqual(AUTOLABEL.main([
                "--samples", str(samples), "--output", str(root / "run"), "--dry-run", "--no-default-holdout",
            ]), 0)
            self.assertFalse((root / "run").exists())


class CompareModelsTests(unittest.TestCase):
    def test_the_embedded_model_scores_as_cherry_does(self) -> None:
        model = COMPARE.embedded_model()
        self.assertEqual(len(model["featureNames"]), len(model["weights"]))
        self.assertTrue(model["id"])
        observation = json.loads(SWIFT_SAMPLE)["observation"]
        # Cherry's own probability for this sample (TerminalAttentionClassifier).
        self.assertAlmostEqual(COMPARE.probability(model, observation), SWIFT_PROBABILITY, places=12)
        # The live-work rule keeps it from needing action.
        self.assertFalse(COMPARE.needs_attention(model, observation))

    def test_runtime_rules(self) -> None:
        model = {"id": "m", "bias": 5.0, "threshold": 0.5, "featureNames": [], "weights": [], "numericStatistics": {}}
        observation = sample(T0, DONE, activity="idle", evidence="prompt_marker", turn="completed")["observation"]
        self.assertTrue(COMPARE.needs_attention(model, observation))
        observation["turn"]["state"] = "not_started"
        self.assertFalse(COMPARE.needs_attention(model, observation))
        self.assertTrue(COMPARE.needs_attention(model, observation, gates=False))
        low = {**model, "bias": -5.0}
        menu = sample(T0, DONE, activity="permission", evidence="answer_menu")["observation"]
        self.assertTrue(COMPARE.needs_attention(low, menu))

    def test_a_candidate_with_more_errors_anywhere_is_worse(self) -> None:
        always = {"id": "always", "bias": 5.0, "threshold": 0.5, "featureNames": [], "weights": [], "numericStatistics": {}}
        never = {**always, "id": "never", "bias": -5.0}
        idle = sample(T0, DONE, activity="idle", evidence="prompt_marker", turn="completed")["observation"]
        sets = {
            "results": [("attention_needed", idle)] * 3,
            "quiet": [("no_attention_needed", idle)],
        }
        result = COMPARE.compare(always, never, sets)
        self.assertFalse(result["notWorse"])
        self.assertFalse(result["sets"]["results"]["notWorse"])
        self.assertTrue(result["sets"]["quiet"]["notWorse"])
        self.assertTrue(COMPARE.compare(always, always, sets)["notWorse"])


SWIFT_PROBABILITY = 0.10405626693999176
SWIFT_SAMPLE = r'''{"features": {"boolean.activity.hasUnreadNotification=false": 1, "boolean.interaction.hasUnsubmittedInput=false": 1, "boolean.interaction.terminalFocused=false": 1, "boolean.millisecondsSinceLastContentChange.missing=false": 1, "boolean.millisecondsSinceLastHumanInput.missing=false": 1, "boolean.millisecondsSinceLastKeystroke.missing=false": 1, "boolean.millisecondsSinceLastOutput.missing=false": 1, "boolean.millisecondsSinceStarted.missing=true": 1, "boolean.terminal.cursorVisible=true": 1, "boolean.terminal.scrollbackOmitted=false": 1, "boolean.terminal.usesAlternateScreen=true": 1, "category.activity.evidence=working_marker": 1, "category.activity.processState=exit 0": 1, "category.activity.state=working": 1, "category.event=content_changed": 1, "category.turn.state=active": 1, "numeric.millisecondsSinceLastContentChange": 6.9726062513017535, "numeric.millisecondsSinceLastHumanInput": 7.005789019253503, "numeric.millisecondsSinceLastKeystroke": 7.005789019253503, "numeric.millisecondsSinceLastOutput": 7.005789019253503}, "observation": {"activity": {"evidence": "working_marker", "hasUnreadNotification": false, "processState": "exit 0", "state": "working"}, "contentVersion": 2, "event": "content_changed", "id": "B8535626-B1C9-423B-950D-8B38B987A4C1", "interaction": {"hasUnsubmittedInput": false, "millisecondsSinceLastKeystroke": 1102, "terminalFocused": false}, "outputVersion": 2, "recordedAt": "2026-10-04T18:01:51.540Z", "schemaVersion": 1, "session": {"harness": "Claude", "id": "d3aa7a02c6dc8024", "kind": "agent", "runID": "f4bf59b5cba93a75"}, "terminal": {"columns": 60, "cursor": {"column": 2, "isVisible": true, "row": 4, "shape": "block"}, "grid": ["❯ abc", "", "✻ Frosting… (3s · esc to interrupt)", "", "❯ "], "rows": 10, "scrollbackLinesOmitted": 0, "usesAlternateScreen": true}, "timing": {"millisecondsSinceLastContentChange": 1066, "millisecondsSinceLastHumanInput": 1102, "millisecondsSinceLastOutput": 1102}, "turn": {"state": "active"}}}'''


if __name__ == "__main__":
    unittest.main()

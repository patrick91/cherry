from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from typing import Any


SCRIPT = Path(__file__).with_name("attention-provisional-labels")
LOADER = importlib.machinery.SourceFileLoader("attention_provisional_labels", str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
assert SPEC is not None
MODULE = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(MODULE)


def observation(
    identifier: str,
    recorded_at: str,
    state: str,
    *,
    event: str = "activity_state_changed",
    draft: bool = False,
    grid: list[str] | None = None,
) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "id": identifier,
        "recordedAt": recorded_at,
        "event": event,
        "session": {"id": "test-session", "harness": "Codex"},
        "activity": {"state": state, "evidence": "test"},
        "interaction": {
            "hasUnsubmittedInput": draft,
            "millisecondsSinceLastKeystroke": 100 if draft else None,
            "terminalFocused": True,
        },
        "terminal": {"grid": grid or ["› draft"], "columns": 80, "rows": 24},
    }


class ProvisionalLabelTests(unittest.TestCase):
    def write(self, observations: list[dict[str, Any]]) -> list[dict[str, Any]]:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source.jsonl"
            destination = Path(directory) / "destination.jsonl"
            source.write_text(
                "".join(json.dumps(item) + "\n" for item in observations),
                encoding="utf-8",
            )
            MODULE.write_observations(source, destination)
            return [
                json.loads(line)
                for line in destination.read_text(encoding="utf-8").splitlines()
            ]

    def test_user_composing_suppresses_attention_and_collapses_transitions(self) -> None:
        result = self.write([
            observation(
                "00000000-0000-4000-8000-000000000001",
                "2026-07-27T10:31:40Z",
                "working",
                draft=True,
                grid=["› Find and fix a bug"],
            ),
            observation(
                "00000000-0000-4000-8000-000000000002",
                "2026-07-27T10:31:42Z",
                "idle",
                draft=True,
                grid=["startup warning", "› Find and fix a bug"],
            ),
        ])

        self.assertNotIn("label", result[0])
        self.assertEqual(result[1]["label"], "no_attention_needed")
        self.assertEqual(
            result[1]["annotation"]["rationale"],
            "user_composing_at_prompt",
        )
        self.assertNotIn("reason", result[1]["annotation"])

    def test_identical_short_window_notifications_collapse_to_latest(self) -> None:
        result = self.write([
            observation(
                "00000000-0000-4000-8000-000000000003",
                "2026-07-27T10:31:40Z",
                "idle",
                event="notification",
                grid=["Worked for 2m", "›"],
            ),
            observation(
                "00000000-0000-4000-8000-000000000007",
                "2026-07-27T10:31:41Z",
                "idle",
                event="content_changed",
                grid=["Worked for 2m", "›"],
            ),
            observation(
                "00000000-0000-4000-8000-000000000004",
                "2026-07-27T10:31:42Z",
                "idle",
                event="notification",
                grid=["Worked for 2m", "›"],
            ),
        ])

        self.assertNotIn("label", result[0])
        self.assertNotIn("label", result[1])
        self.assertEqual(result[2]["label"], "attention_needed")
        self.assertEqual(result[2]["annotation"]["reason"], "result_ready")

    def test_separate_episodes_remain_labeled(self) -> None:
        result = self.write([
            observation(
                "00000000-0000-4000-8000-000000000005",
                "2026-07-27T10:31:40Z",
                "working",
                draft=True,
            ),
            observation(
                "00000000-0000-4000-8000-000000000006",
                "2026-07-27T10:31:46Z",
                "idle",
                draft=True,
            ),
        ])

        self.assertEqual(
            [item.get("label") for item in result],
            ["no_attention_needed", "no_attention_needed"],
        )


if __name__ == "__main__":
    unittest.main()

from __future__ import annotations

import argparse
import importlib.machinery
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from typing import Any


def load_script(name: str) -> Any:
    path = Path(__file__).with_name(name)
    module_name = name.replace("-", "_")
    loader = importlib.machinery.SourceFileLoader(module_name, str(path))
    specification = importlib.util.spec_from_loader(loader.name, loader)
    assert specification is not None
    module = importlib.util.module_from_spec(specification)
    loader.exec_module(module)
    return module


EXPORTER = load_script("attention-reviewed-dataset")
TRAINER = load_script("attention-train-baseline")


def summary(
    identifier: str,
    session_id: str,
    label: str,
    source: str,
) -> dict[str, Any]:
    return {
        "id": identifier,
        "recordedAt": "2026-07-27T12:00:00Z",
        "sessionID": session_id,
        "reviewLabel": label,
        "reviewSource": source,
        "reviewReason": "result_ready" if label == "attention_needed" else None,
        "reviewStatus": "accepted",
        "reviewedAt": "2026-07-27T13:00:00Z",
        "harness": "Codex",
    }


def dataset_record(
    identifier: str,
    session_id: str,
    split: str,
    label: str,
    source: str,
) -> dict[str, Any]:
    attention = label == "attention_needed"
    return {
        "datasetSchemaVersion": 1,
        "observationID": identifier,
        "recordedAt": "2026-07-27T12:00:00Z",
        "sessionID": session_id,
        "harness": "Codex",
        "split": split,
        "target": label,
        "attentionReason": "result_ready" if attention else None,
        "review": {
            "status": "accepted",
            "source": source,
            "reviewedAt": "2026-07-27T13:00:00Z",
        },
        "observation": {
            "schemaVersion": 1,
            "recordedAt": "2026-07-27T12:00:00Z",
            "event": "activity_state_changed" if attention else "input_submitted",
            "session": {"harness": "Codex", "kind": "agent"},
            "terminal": {
                "columns": 100,
                "rows": 30,
                "usesAlternateScreen": False,
                "cursor": {"isVisible": True},
                "grid": ["Worked for 2m", "›"] if attention else ["• Working (1s • esc to interrupt)"],
                "scrollbackLinesOmitted": 0,
            },
            "activity": {
                "state": "idle" if attention else "working",
                "evidence": "prompt_marker" if attention else "input_submit",
                "processState": "live",
                "hasUnreadNotification": attention,
            },
            "interaction": {
                "hasUnsubmittedInput": False,
                "terminalFocused": not attention,
            },
            "timing": {
                "millisecondsSinceLastContentChange": 2_000 if attention else 20,
                "millisecondsSinceLastOutput": 2_000 if attention else 20,
                "millisecondsSinceStarted": 30_000,
            },
        },
    }


class AttentionModelPipelineTests(unittest.TestCase):
    def test_session_split_keeps_sessions_disjoint_and_both_labels_present(self) -> None:
        records = []
        for session_index in range(6):
            session_id = f"session-{session_index}"
            records.append(summary(
                f"{session_id}-positive",
                session_id,
                "attention_needed",
                "human" if session_index % 2 == 0 else "assistant_audit",
            ))
            records.append(summary(
                f"{session_id}-negative",
                session_id,
                "no_attention_needed",
                "human" if session_index % 2 == 0 else "assistant_audit",
            ))

        test_sessions = EXPORTER.choose_test_sessions(records)
        train = [record for record in records if record["sessionID"] not in test_sessions]
        test = [record for record in records if record["sessionID"] in test_sessions]

        self.assertTrue(test_sessions)
        self.assertFalse({record["sessionID"] for record in train} & test_sessions)
        self.assertEqual(set(EXPORTER.binary_counts(train)), EXPORTER.BINARY_LABELS)
        self.assertEqual(set(EXPORTER.binary_counts(test)), EXPORTER.BINARY_LABELS)

    def test_session_split_scales_beyond_exhaustive_search(self) -> None:
        records = []
        for session_index in range(24):
            session_id = f"session-{session_index:02d}"
            records.append(summary(
                f"{session_id}-positive",
                session_id,
                "attention_needed",
                "human" if session_index % 4 == 0 else "assistant_audit",
            ))
            records.append(summary(
                f"{session_id}-negative",
                session_id,
                "no_attention_needed",
                "human" if session_index % 4 == 0 else "assistant_audit",
            ))

        first = EXPORTER.choose_test_sessions(records)
        second = EXPORTER.choose_test_sessions(records)
        test = [record for record in records if record["sessionID"] in first]

        self.assertEqual(first, second)
        self.assertGreater(len(first), 1)
        self.assertLess(len(first), 24)
        self.assertEqual(set(EXPORTER.binary_counts(test)), EXPORTER.BINARY_LABELS)

    def test_sanitizer_removes_training_truth_and_identifiers(self) -> None:
        payload = {
            "id": "observation-id",
            "label": "attention_needed",
            "annotation": {"reason": "result_ready"},
            "checkpoint": "human_verified",
            "scenarioID": "result-ready",
            "session": {
                "id": "session-id",
                "runID": "run-id",
                "harness": "Codex",
                "kind": "agent",
            },
            "event": "notification",
            "correction": {
                "sourceEvent": "content_changed",
                "modelID": "fixture-model",
                "modelLabel": "no_attention_needed",
                "attentionProbability": 0.1,
                "threshold": 0.5,
            },
        }

        sanitized = EXPORTER.sanitized_observation(payload)

        for key in ("id", "label", "annotation", "checkpoint", "scenarioID"):
            self.assertNotIn(key, sanitized)
        self.assertNotIn("correction", sanitized)
        self.assertEqual(sanitized["session"], {"harness": "Codex", "kind": "agent"})

    def test_sanitizer_restores_runtime_event_for_new_corrections(self) -> None:
        payload = {
            "event": "labeled_checkpoint",
            "correction": {"sourceEvent": "input_changed", "modelID": "fixture"},
            "session": {"id": "session", "kind": "agent"},
        }

        sanitized = EXPORTER.sanitized_observation(payload)

        self.assertEqual(sanitized["event"], "input_changed")
        self.assertNotIn("correction", sanitized)

    def test_sanitizer_omits_unknown_runtime_event_for_legacy_corrections(self) -> None:
        payload = {
            "event": "labeled_checkpoint",
            "session": {"id": "session", "kind": "agent"},
        }

        sanitized = EXPORTER.sanitized_observation(payload)
        record = {"observation": sanitized}

        self.assertNotIn("event", sanitized)
        self.assertFalse(any(
            feature.startswith("category.event=")
            for feature in TRAINER.observation_features(record)
        ))

    def test_latest_human_correction_wins_for_identical_screen(self) -> None:
        terminal = {"columns": 80, "rows": 24, "grid": ["same screen"]}
        first_payload = {
            "id": "first",
            "session": {"id": "session-one"},
            "terminal": terminal,
            "annotation": {"provenance": "cherry_in_app_human_correction"},
        }
        latest_payload = {
            **first_payload,
            "id": "latest",
            "correction": {"supersedesObservationID": "first"},
        }
        first_summary = summary("first", "session-one", "attention_needed", "human")
        first_summary["recordedAt"] = "2026-07-27T12:00:00Z"
        latest_summary = summary("latest", "session-one", "no_attention_needed", "human")
        latest_summary["recordedAt"] = "2026-07-27T12:00:07Z"

        summaries, payloads = EXPORTER.deduplicate_reviewed_observations(
            [first_summary, latest_summary],
            [first_payload, latest_payload],
        )

        self.assertEqual([value["id"] for value in summaries], ["latest"])
        self.assertEqual([value["id"] for value in payloads], ["latest"])

    def test_feature_extractor_ignores_review_and_provisional_fields(self) -> None:
        record = dataset_record(
            "one",
            "session-one",
            "train",
            "attention_needed",
            "human",
        )
        altered = json.loads(json.dumps(record))
        altered["target"] = "no_attention_needed"
        altered["review"]["source"] = "assistant_audit"
        altered["observation"]["label"] = "no_attention_needed"
        altered["observation"]["annotation"] = {"reason": "waiting_for_input"}

        self.assertEqual(
            TRAINER.observation_features(record),
            TRAINER.observation_features(altered),
        )

    def test_dataset_preserves_correction_provenance_as_review_metadata(self) -> None:
        review = summary(
            "correction-one",
            "session-one",
            "no_attention_needed",
            "human",
        )
        review["reviewProvenance"] = "cherry_in_app_human_correction"

        record = EXPORTER.dataset_record(
            review,
            {"event": "content_changed", "session": {"id": "session-one"}},
            set(),
        )

        self.assertEqual(
            record["review"]["provenance"],
            "cherry_in_app_human_correction",
        )
        without_review = json.loads(json.dumps(record))
        without_review.pop("review")
        self.assertEqual(
            TRAINER.observation_features(record),
            TRAINER.observation_features(without_review),
        )

    def test_end_to_end_training_writes_a_working_model(self) -> None:
        records = [
            dataset_record("train-positive-1", "train-one", "train", "attention_needed", "human"),
            dataset_record("train-negative-1", "train-one", "train", "no_attention_needed", "human"),
            dataset_record("train-positive-2", "train-two", "train", "attention_needed", "assistant_audit"),
            dataset_record("train-negative-2", "train-two", "train", "no_attention_needed", "assistant_audit"),
            dataset_record("test-positive-1", "test-one", "test", "attention_needed", "human"),
            dataset_record("test-negative-1", "test-one", "test", "no_attention_needed", "human"),
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dataset_directory = root / "dataset"
            dataset_directory.mkdir()
            dataset_path = dataset_directory / "dataset.jsonl"
            dataset_path.write_text(
                "".join(json.dumps(record) + "\n" for record in records),
                encoding="utf-8",
            )
            (dataset_directory / "manifest.json").write_text(
                json.dumps({
                    "datasetFile": {"sha256": TRAINER.sha256(dataset_path)},
                }),
                encoding="utf-8",
            )
            output = root / "model"

            TRAINER.train_baseline(argparse.Namespace(
                dataset=dataset_directory,
                output=output,
            ))

            metrics = json.loads((output / "metrics.json").read_text(encoding="utf-8"))
            self.assertEqual(metrics["evaluations"]["testAll"]["accuracy"], 1.0)
            self.assertEqual(
                metrics["evaluations"]["humanLeaveOneSessionOut"]["count"],
                4,
            )
            self.assertEqual(len(metrics["humanLeaveOneSessionOutFolds"]), 2)
            self.assertEqual(
                len((output / "human-loso-predictions.jsonl").read_text().splitlines()),
                4,
            )
            model = json.loads((output / "model.json").read_text(encoding="utf-8"))
            self.assertFalse(model["featurePolicy"]["provisionalLabelIncluded"])
            self.assertFalse(any(
                "terminal.marker" in name
                for name in model["featureNames"]
            ))
            self.assertLess(model["parameters"], 100)


if __name__ == "__main__":
    unittest.main()

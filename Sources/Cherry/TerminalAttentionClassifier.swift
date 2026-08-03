import Foundation

struct TerminalAttentionPrediction: Equatable, Sendable {
    struct FeatureContribution: Equatable, Sendable {
        let name: String
        let value: Double
        let contribution: Double
    }

    let modelID: String
    let parameterCount: Int
    let event: TerminalAttentionObservationEvent
    let attentionProbability: Double
    let threshold: Double
    let nativeActivityState: String
    let activityEvidence: String
    let hasUnsubmittedInput: Bool?
    let terminalFocused: Bool?
    let contributions: [FeatureContribution]

    var needsAttention: Bool {
        attentionProbability >= threshold
    }

    var label: TerminalAttentionLabel {
        needsAttention ? .attentionNeeded : .noAttentionNeeded
    }

    var confidence: Double {
        needsAttention ? attentionProbability : 1 - attentionProbability
    }

    var confidenceDescription: String {
        confidence.formatted(
            .percent.precision(.fractionLength(0))
        ) + " confidence"
    }

    var displayName: String {
        needsAttention ? "Attention needed" : "No attention needed"
    }

    var debugReport: String {
        let probability = attentionProbability.formatted(
            .percent.precision(.fractionLength(1))
        )
        let confidence = confidence.formatted(
            .percent.precision(.fractionLength(1))
        )
        let draft = hasUnsubmittedInput.map(String.init) ?? "missing"
        let focused = terminalFocused.map(String.init) ?? "missing"
        let strongest = contributions.prefix(12).map { feature in
            let sign = feature.contribution >= 0 ? "+" : ""
            let value = feature.value.formatted(.number.precision(.fractionLength(3)))
            return "\(sign)\(feature.contribution.formatted(.number.precision(.fractionLength(4))))  \(feature.name)  [x=\(value)]"
        }

        return (
            [
                "Model: \(modelID)",
                "Parameters: \(parameterCount)",
                "Prediction: \(displayName)",
                "Attention probability: \(probability)",
                "Prediction confidence: \(confidence)",
                "Threshold: \(threshold.formatted(.number.precision(.fractionLength(2))))",
                "",
                "Event: \(event.rawValue)",
                "Native activity: \(nativeActivityState)",
                "Native evidence: \(activityEvidence)",
                "Unsubmitted input: \(draft)",
                "Terminal focused: \(focused)",
                "",
                "Strongest feature contributions",
                "(positive pushes toward attention needed)",
            ]
            + strongest
        ).joined(separator: "\n")
    }
}

struct TerminalAttentionClassifier: Sendable {
    static let shared = TerminalAttentionClassifier()
    static let modelID = "20260730-final-baseline"
    static var parameterCount: Int { featureNames.count + 1 }

    private static let threshold = 0.5
    private static let bias = -2.5390182062907654

    private static let numericStatistics: [String: (mean: Double, scale: Double)] = [
        "numeric.millisecondsSinceLastContentChange": (5.934888450592341, 2.693580642266454),
        "numeric.millisecondsSinceLastHumanInput": (6.7075317875411615, 5.609627094132668),
        "numeric.millisecondsSinceLastKeystroke": (6.406990223703139, 5.467575289822395),
        "numeric.millisecondsSinceLastOutput": (4.701582169231236, 2.4783547622237125),
        "numeric.millisecondsSinceStarted": (15.023260048715446, 3.0631514048224164),
    ]

    private static let featureNames = [
        "boolean.activity.hasUnreadNotification=false",
        "boolean.activity.hasUnreadNotification=true",
        "boolean.interaction.hasUnsubmittedInput=false",
        "boolean.interaction.hasUnsubmittedInput=missing",
        "boolean.interaction.hasUnsubmittedInput=true",
        "boolean.interaction.terminalFocused=false",
        "boolean.interaction.terminalFocused=missing",
        "boolean.interaction.terminalFocused=true",
        "boolean.millisecondsSinceLastContentChange.missing=false",
        "boolean.millisecondsSinceLastHumanInput.missing=false",
        "boolean.millisecondsSinceLastHumanInput.missing=true",
        "boolean.millisecondsSinceLastKeystroke.missing=false",
        "boolean.millisecondsSinceLastKeystroke.missing=true",
        "boolean.millisecondsSinceLastOutput.missing=false",
        "boolean.millisecondsSinceLastOutput.missing=true",
        "boolean.millisecondsSinceStarted.missing=false",
        "boolean.terminal.cursorVisible=false",
        "boolean.terminal.cursorVisible=true",
        "boolean.terminal.marker.approval=false",
        "boolean.terminal.marker.approval=true",
        "boolean.terminal.marker.blocked=false",
        "boolean.terminal.marker.blocked=true",
        "boolean.terminal.marker.prompt=false",
        "boolean.terminal.marker.prompt=true",
        "boolean.terminal.marker.result=false",
        "boolean.terminal.marker.result=true",
        "boolean.terminal.marker.working=false",
        "boolean.terminal.marker.working=true",
        "boolean.terminal.scrollbackOmitted=false",
        "boolean.terminal.scrollbackOmitted=true",
        "boolean.terminal.usesAlternateScreen=false",
        "boolean.terminal.usesAlternateScreen=true",
        "category.activity.evidence=input_submit",
        "category.activity.evidence=output_activity",
        "category.activity.evidence=process_exit",
        "category.activity.evidence=prompt_marker",
        "category.activity.evidence=quiet_window",
        "category.activity.evidence=title_spinner",
        "category.activity.evidence=working_marker",
        "category.activity.processState=exit 0",
        "category.activity.processState=live",
        "category.activity.state=idle",
        "category.activity.state=working",
        "category.event=activity_state_changed",
        "category.event=content_changed",
        "category.event=input_changed",
        "category.event=input_submitted",
        "category.event=notification",
        "category.event=process_exited",
        "numeric.millisecondsSinceLastContentChange",
        "numeric.millisecondsSinceLastHumanInput",
        "numeric.millisecondsSinceLastKeystroke",
        "numeric.millisecondsSinceLastOutput",
        "numeric.millisecondsSinceStarted",
    ]

    private static let weights = [
        0.06093439869162162,
        -0.06095932064454138,
        1.7094761757208112,
        0.04351177689633125,
        -1.7530142269591826,
        0.028437287635296,
        0.04351177689633125,
        -0.07197542478563514,
        -0.000025096277250104485,
        0.10237042797273511,
        -0.10239515095070821,
        -0.14262777874574126,
        0.14260313607767108,
        0.1455656054627218,
        -0.14559048830242086,
        -0.000025096277250104485,
        0.15171666413562446,
        -0.15174152005899852,
        -0.005624226363867248,
        0.005599138270379968,
        -0.0024158704221098606,
        0.0023908222511238525,
        -0.16831388287935564,
        0.16828915917626608,
        -0.18833414876335858,
        0.18830950829250445,
        0.35888821714112823,
        -0.3589137832238593,
        -0.14694087687639473,
        0.14691616471360672,
        0.06569219195164377,
        -0.0657167424193383,
        -0.5956464485031974,
        -0.24159902376458503,
        0.02040730927707797,
        1.0148351579778165,
        0.14335753348940494,
        -0.36696793815471507,
        0.025585987378386174,
        0.02040730927707797,
        -0.020432340253771827,
        1.1785987918482834,
        -1.178630626237267,
        0.34864097084125134,
        -0.04143487955973126,
        -0.14338385607871706,
        -0.526080733393238,
        0.34182425776728576,
        0.02040730927707797,
        0.07393982752092502,
        0.24888395091147092,
        0.767602564573528,
        -0.22610882523091497,
        0.069501083519633,
    ]

    private static let featureWeights: [String: Double] = Dictionary(
        uniqueKeysWithValues: zip(featureNames, weights)
    )

    private static let resultMarkers = [
        "worked for",
        "baked for",
        "cooked for",
        "cogitated for",
        "crunched for",
        "churned for",
        "sautéed for",
        "sauteed for",
        "brewed for",
    ]

    private static let approvalMarkers = [
        "do you want to proceed",
        "would you like to proceed",
        "waiting for approval",
        "press enter to approve",
        "approve this action",
        "allow this command",
        "allow command",
        "allow computer use to use",
        "run the tool and continue",
    ]

    private static let blockedMarkers = [
        "conversation interrupted",
        "task interrupted",
        "process exited",
        "fatal error",
        "panic:",
    ]

    private init() {
        precondition(
            Self.featureNames.count == Self.weights.count,
            "Attention classifier feature and weight counts must match"
        )
    }

    func predict(_ observation: TerminalAttentionObservation) -> TerminalAttentionPrediction {
        let features = Self.features(for: observation)
        let contributions = features.compactMap { name, rawValue -> TerminalAttentionPrediction.FeatureContribution? in
            guard let weight = Self.featureWeights[name] else { return nil }
            let value: Double
            if let statistics = Self.numericStatistics[name] {
                value = (rawValue - statistics.mean) / statistics.scale
            } else {
                value = rawValue
            }
            return .init(name: name, value: value, contribution: weight * value)
        }
        .sorted {
            let left = abs($0.contribution)
            let right = abs($1.contribution)
            return left == right ? $0.name < $1.name : left > right
        }

        let score = Self.bias + contributions.reduce(0) { $0 + $1.contribution }
        let probability: Double
        if score >= 0 {
            probability = 1 / (1 + exp(-score))
        } else {
            let exponential = exp(score)
            probability = exponential / (1 + exponential)
        }

        return TerminalAttentionPrediction(
            modelID: Self.modelID,
            parameterCount: Self.parameterCount,
            event: observation.event,
            attentionProbability: probability,
            threshold: Self.threshold,
            nativeActivityState: observation.activity.state,
            activityEvidence: observation.activity.evidence,
            hasUnsubmittedInput: observation.interaction?.hasUnsubmittedInput,
            terminalFocused: observation.interaction?.terminalFocused,
            contributions: contributions
        )
    }

    private static func features(
        for observation: TerminalAttentionObservation
    ) -> [String: Double] {
        var features: [String: Double] = [:]

        addCategory(&features, name: "event", value: observation.event.rawValue)
        addCategory(&features, name: "activity.state", value: observation.activity.state)
        addCategory(&features, name: "activity.evidence", value: observation.activity.evidence)
        addCategory(&features, name: "activity.processState", value: observation.activity.processState)
        addBoolean(
            &features,
            name: "activity.hasUnreadNotification",
            value: observation.activity.hasUnreadNotification
        )
        addBoolean(
            &features,
            name: "interaction.hasUnsubmittedInput",
            value: observation.interaction?.hasUnsubmittedInput
        )
        addBoolean(
            &features,
            name: "interaction.terminalFocused",
            value: observation.interaction?.terminalFocused
        )
        addBoolean(
            &features,
            name: "terminal.usesAlternateScreen",
            value: observation.terminal.usesAlternateScreen
        )
        addBoolean(
            &features,
            name: "terminal.cursorVisible",
            value: observation.terminal.cursor.isVisible
        )
        addBoolean(
            &features,
            name: "terminal.scrollbackOmitted",
            value: observation.terminal.scrollbackLinesOmitted > 0
        )

        addLogMilliseconds(
            &features,
            name: "millisecondsSinceLastKeystroke",
            value: observation.interaction?.millisecondsSinceLastKeystroke
        )
        addLogMilliseconds(
            &features,
            name: "millisecondsSinceLastContentChange",
            value: observation.timing.millisecondsSinceLastContentChange
        )
        addLogMilliseconds(
            &features,
            name: "millisecondsSinceLastHumanInput",
            value: observation.timing.millisecondsSinceLastHumanInput
        )
        addLogMilliseconds(
            &features,
            name: "millisecondsSinceLastOutput",
            value: observation.timing.millisecondsSinceLastOutput
        )
        addLogMilliseconds(
            &features,
            name: "millisecondsSinceStarted",
            value: observation.timing.millisecondsSinceStarted
        )

        let lines = observation.terminal.grid.suffix(48)
        let text = lines.joined(separator: "\n").lowercased()
        let markers = [
            "result": resultMarkers.contains { text.contains($0) },
            "approval": approvalMarkers.contains { text.contains($0) },
            "blocked": blockedMarkers.contains { text.contains($0) },
            "working": text.contains("esc to interrupt") || text.contains("• working ("),
            "prompt": lines.contains { line in
                let trimmed = line.drop(while: \.isWhitespace)
                return trimmed.hasPrefix("›") || trimmed.hasPrefix("»") || trimmed.hasPrefix("❯")
            },
        ]
        for (name, value) in markers {
            addBoolean(&features, name: "terminal.marker.\(name)", value: value)
        }

        return features
    }

    private static func addCategory(
        _ features: inout [String: Double],
        name: String,
        value: String?
    ) {
        features["category.\(name)=\(value ?? "missing")"] = 1
    }

    private static func addBoolean(
        _ features: inout [String: Double],
        name: String,
        value: Bool?
    ) {
        let normalized = value.map { $0 ? "true" : "false" } ?? "missing"
        features["boolean.\(name)=\(normalized)"] = 1
    }

    private static func addLogMilliseconds(
        _ features: inout [String: Double],
        name: String,
        value: Int?
    ) {
        guard let value, value >= 0 else {
            features["boolean.\(name).missing=true"] = 1
            return
        }
        features["numeric.\(name)"] = log1p(Double(value))
        features["boolean.\(name).missing=false"] = 1
    }
}

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
    let turnState: TerminalAttentionTurnState?
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
        let turn = turnState?.rawValue ?? "missing"
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
                "Turn state: \(turn)",
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
    static let modelID = "20260810-corrections-v1"
    static var parameterCount: Int { featureNames.count + 1 }

    private static let threshold = 0.5
    private static let bias = -2.5780099945038755

    private static let numericStatistics: [String: (mean: Double, scale: Double)] = [
        "numeric.millisecondsSinceLastContentChange": (5.856312644987672, 2.7886622763217814),
        "numeric.millisecondsSinceLastHumanInput": (6.88397010624212, 5.593956020109614),
        "numeric.millisecondsSinceLastKeystroke": (6.5909711397997235, 5.464571210901379),
        "numeric.millisecondsSinceLastOutput": (4.66519280626549, 2.564484521474172),
        "numeric.millisecondsSinceStarted": (14.9968353948742, 3.0450746426384185),
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
        0.04275966180782377,
        -0.042760783629374674,
        1.6262219722404558,
        0.10550043897582519,
        -1.7317236130220877,
        0.08270230373956312,
        0.10550043897582519,
        -0.18820396393296068,
        -0.0000011328497544396936,
        0.18843379840588576,
        -0.1884349086817755,
        -0.11778669393603332,
        0.11778558974889046,
        0.13545032579602012,
        -0.13545144796927538,
        -0.0000011328497544396936,
        0.1534114058267969,
        -0.15341252359055,
        0.2107400525737042,
        -0.2107411546128735,
        -0.018653751286902102,
        0.01865264977141692,
        -0.504938383718847,
        -0.06582035103980498,
        0.03571764060207302,
        1.0314348889601745,
        0.12885360105590088,
        -0.5001094115971237,
        -0.12513928371116395,
        0.03571764060207302,
        -0.03571876827545788,
        1.196006043060003,
        -1.196007661646956,
        0.5949851979934365,
        -0.03730286847885025,
        -0.11444063275153649,
        -0.4385361329040176,
        0.4389891034872212,
        0.03571764060207302,
        0.07126408667905704,
        0.26038388526027106,
        0.7255270971260073,
        -0.3271618372088436,
        0.17675782780676788,
    ]

    private static let featureWeights: [String: Double] = Dictionary(
        uniqueKeysWithValues: zip(featureNames, weights)
    )

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
            turnState: observation.turn?.state,
            contributions: contributions
        )
    }

    private static func features(
        for observation: TerminalAttentionObservation
    ) -> [String: Double] {
        var features: [String: Double] = [:]

        addCategory(&features, name: "event", value: observation.event.rawValue)
        if let turn = observation.turn {
            addCategory(&features, name: "turn.state", value: turn.state.rawValue)
        }
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

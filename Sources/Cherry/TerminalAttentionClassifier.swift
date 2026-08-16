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

enum TerminalAttentionNotificationPolicy {
    /// Sidebar attention can remain exploratory at the model's normal threshold,
    /// while system notifications should be reserved for stronger predictions.
    static let minimumAttentionProbability = 0.80

    static func shouldNotify(
        prediction: TerminalAttentionPrediction,
        isTopLevelAgent: Bool,
        hasUnreadNativeNotification: Bool
    ) -> Bool {
        guard let turnState = prediction.turnState,
              turnState != .notStarted,
              turnState != .userInterrupted
        else {
            return false
        }

        return isTopLevelAgent
            && !hasUnreadNativeNotification
            && prediction.needsAttention
            && prediction.attentionProbability >= minimumAttentionProbability
    }
}

struct TerminalAttentionNotificationGate {
    private(set) var isEpisodeActive = false

    mutating func shouldNotify(
        prediction: TerminalAttentionPrediction,
        isTopLevelAgent: Bool,
        hasUnreadNativeNotification: Bool,
        hasUnacknowledgedAttention: Bool
    ) -> Bool {
        guard prediction.needsAttention else {
            isEpisodeActive = false
            return false
        }
        guard hasUnacknowledgedAttention else { return false }
        guard !isEpisodeActive else { return false }
        if hasUnreadNativeNotification {
            // The native notification owns this attention episode. Keep the
            // classifier from sending a duplicate after the unread flag clears.
            isEpisodeActive = true
            return false
        }
        guard TerminalAttentionNotificationPolicy.shouldNotify(
            prediction: prediction,
            isTopLevelAgent: isTopLevelAgent,
            hasUnreadNativeNotification: false
        ) else {
            return false
        }

        isEpisodeActive = true
        return true
    }

    mutating func acknowledge() {
        isEpisodeActive = false
    }
}

struct TerminalAttentionClassifier: Sendable {
    static let shared = TerminalAttentionClassifier()
    static let modelID = "20260813-corrections-v2"
    static var parameterCount: Int { featureNames.count + 1 }

    private static let threshold = 0.5
    private static let bias = -2.5784493172149396

    private static let numericStatistics: [String: (mean: Double, scale: Double)] = [
        "numeric.millisecondsSinceLastContentChange": (5.840704674547158, 2.8069158546401343),
        "numeric.millisecondsSinceLastHumanInput": (6.911353660494359, 5.601356090636346),
        "numeric.millisecondsSinceLastKeystroke": (6.619344566591142, 5.474089599320091),
        "numeric.millisecondsSinceLastOutput": (4.654860096424595, 2.579851087250358),
        "numeric.millisecondsSinceStarted": (14.990106703277494, 3.042828433686758),
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
        "category.turn.state=completed",
        "category.turn.state=not_started",
        "numeric.millisecondsSinceLastContentChange",
        "numeric.millisecondsSinceLastHumanInput",
        "numeric.millisecondsSinceLastKeystroke",
        "numeric.millisecondsSinceLastOutput",
        "numeric.millisecondsSinceStarted",
    ]

    private static let weights = [
        0.03686199833161565,
        -0.03686352576623807,
        1.5991214532291036,
        0.11783829564727555,
        -1.7169613772615555,
        0.07305822735679662,
        0.11783829564727555,
        -0.19089817950969204,
        -0.0000015427682608197466,
        0.20470520845712603,
        -0.2047067201637492,
        -0.10811486295609381,
        0.10811335975376532,
        0.12690842942061173,
        -0.12690995808165753,
        -0.0000015427682608197466,
        0.15797961605897387,
        -0.1579811379158553,
        0.2124074065860499,
        -0.21240890792362221,
        -0.042193090312125967,
        0.04219159077050905,
        -0.5207747422092024,
        -0.047284756580666984,
        0.03785054003651907,
        1.0188451484880023,
        0.12599885436334188,
        -0.4870342577355266,
        -0.12760254239265686,
        0.03785054003651907,
        -0.03785207547141327,
        1.1826944285397705,
        -1.1826965996938905,
        0.6559228934931316,
        -0.12885008587204222,
        -0.10907342131092983,
        -0.4481236380809174,
        0.4609309453996516,
        0.03785054003651907,
        -0.09741007807278308,
        -0.07188617956408755,
        0.09274031998686158,
        0.24001070971950766,
        0.6917862711718836,
        -0.3211312396001738,
        0.1861816227676863,
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

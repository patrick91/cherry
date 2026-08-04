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
    static let modelID = "20260803-structured-baseline"
    static var parameterCount: Int { featureNames.count + 1 }

    private static let threshold = 0.5
    private static let bias = -2.1903106646695054

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
        0.05158449421651377,
        -0.05158459147144902,
        1.7308150476569963,
        0.0383982392885871,
        -1.769213394331419,
        0.024903863632553338,
        0.0383982392885871,
        -0.06330221115989249,
        -0.0000000981382363672938,
        0.13686689348495934,
        -0.13686698993160204,
        -0.12816964079902302,
        0.1281695449582229,
        0.14515197808552308,
        -0.14515207529706356,
        -0.0000000981382363672938,
        0.1297411137836451,
        -0.12974121074151274,
        -0.13117404738735072,
        0.1311739513009173,
        0.03367363810137374,
        -0.03367373371050227,
        -0.5730535898936631,
        -0.24606788808829194,
        0.018350542297904945,
        1.0809950549344716,
        0.1169284110053821,
        -0.41902304812908336,
        0.02187039706888814,
        0.018350542297904945,
        -0.018350640126010197,
        1.2162739988012303,
        -1.2162741544077298,
        0.3115759374539151,
        -0.06771490012370816,
        -0.142297139010288,
        -0.5121340305280573,
        0.3922194771586905,
        0.018350542297904945,
        0.06706583500698673,
        0.27460334261075614,
        0.8111447593731007,
        -0.20370543554459603,
        0.15391221724553467,
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

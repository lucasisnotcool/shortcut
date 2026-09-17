import Foundation

/// The kinds of question a window check can answer.
enum AnswerKind: String, Codable, CaseIterable {
    /// One option (1-8 / A-H).
    case single
    /// Every correct option; can be just one (1-8 / A-H).
    case multiple
    /// T or F.
    case trueFalse = "true_false"
    /// One option of an open dropdown, numbered by its position in the list (1-20).
    case dropdown
    /// Every listed option, first to last.
    case ranking
    /// The choice for each item, in item order; a choice may repeat.
    case matching
    /// A single value.
    case numeric
    /// Free text for one or more blanks.
    case fillBlank = "fill_blank"
    /// No answer given.
    case none
}

/// Which option labels are acceptable for a question kind.
enum AnswerLabels {
    /// Choice questions: 1-8 or A-H.
    static let choiceNumbers = (1...8).map(String.init)
    static let choiceLetters = Array("ABCDEFGH").map(String.init)
    /// Lists (dropdowns, ranking, matching): 1-20 or A-T.
    static let listNumbers = (1...20).map(String.init)
    static let listLetters = Array("ABCDEFGHIJKLMNOPQRST").map(String.init)

    static func allowed(for kind: AnswerKind) -> (numbers: [String], letters: [String]) {
        switch kind {
        case .dropdown, .ranking, .matching: return (listNumbers, listLetters)
        default: return (choiceNumbers, choiceLetters)
        }
    }
}

/// What a chat message needs to show an answer: stored with the conversation.
struct AnswerTag: Codable, Equatable {
    var kind: AnswerKind
    /// Selected labels (choice kinds), the order (ranking), the choice per item
    /// (matching), the value (numeric) or the text per blank (fill_blank).
    var values: [String]
    /// Which question was answered ("Q4 What is the boiling point…"), when Claude says.
    var question: String? = nil

    var isNoAnswer: Bool { kind == .none || values.isEmpty }

    /// Text for the menu-bar badge; one character draws a ring, more a capsule.
    var badgeText: String {
        if isNoAnswer { return "!" }
        switch kind {
        case .fillBlank: return "✎"
        case .numeric:
            let value = values[0]
            return value.count > 10 ? String(value.prefix(9)) + "…" : value
        default: return values.joined(separator: " ")
        }
    }

    /// Circles in the chat header: one per selected option, or a single
    /// capsule for sequences and values.
    var headerTokens: [String] {
        if isNoAnswer { return ["!"] }
        switch kind {
        case .single, .multiple, .trueFalse, .dropdown: return values
        case .ranking, .matching, .numeric: return [badgeText]
        case .fillBlank: return ["✎"]
        case .none: return ["!"]
        }
    }

    var title: String {
        if isNoAnswer { return "No answer" }
        switch kind {
        case .single: return "Answer \(values[0])"
        case .multiple: return values.count == 1 ? "Answer \(values[0])" : "Answers \(values.joined(separator: ", "))"
        case .trueFalse: return "Answer: \(values.map(Self.trueFalseWord).joined(separator: ", "))"
        case .dropdown: return "Option \(values[0]) in the dropdown"
        case .ranking: return "Order \(values.joined(separator: " "))"
        case .matching: return "Matches \(values.joined(separator: " "))"
        case .numeric: return "Answer \(values[0])"
        case .fillBlank:
            return values.count == 1 ? "Fill in: \(values[0])" : "Fill in \(values.count) blanks"
        case .none: return "No answer"
        }
    }

    var subtitle: String {
        guard let question, !question.isEmpty, !isNoAnswer else { return kindDescription }
        let short = question.count > 48 ? String(question.prefix(47)) + "…" : question
        return "\(short) · \(kindDescription)"
    }

    private var kindDescription: String {
        if isNoAnswer { return "The model could not confirm a question and answer" }
        switch kind {
        case .single: return "From the active window"
        case .multiple:
            return values.count == 1
                ? "Multiple-response question · only this option is correct"
                : "Multiple-response question · select all \(values.count)"
        case .trueFalse: return "True/false question"
        case .dropdown: return "Dropdown blank · counted from the top of the list"
        case .ranking: return "Ranking question · options listed first to last"
        case .matching: return "Matching question · choice for each item, in item order"
        case .numeric: return "Number answer"
        case .fillBlank: return "Fill-in-the-blank · the text is below"
        case .none: return ""
        }
    }

    static func trueFalseWord(_ label: String) -> String {
        switch label {
        case "T": return "True"
        case "F": return "False"
        default: return label
        }
    }

    /// Reads the "B" / "1,3,4" / "NONE" strings saved by earlier versions.
    init(legacy value: String, isMultiple: Bool, isTrueFalse: Bool) {
        let labels = value == "NONE" ? [] : value.split(separator: ",").map(String.init)
        self.values = labels
        if labels.isEmpty { kind = .none }
        else if isTrueFalse { kind = .trueFalse }
        else if isMultiple || labels.count > 1 { kind = .multiple }
        else { kind = .single }
    }

    init(kind: AnswerKind, values: [String], question: String? = nil) {
        self.kind = kind
        self.values = values
        self.question = question
    }
}

struct WindowAnswer: Equatable {
    var tag: AnswerTag
    var explanation: String
    /// Markdown lines shown under the explanation: a verdict per option, the
    /// ranked list, the pairs, or the text per blank.
    var details: [String] = []

    var isNoAnswer: Bool { tag.isNoAnswer }

    /// Explanation followed by the details, for the chat and the badge menu.
    var chatText: String {
        details.isEmpty ? explanation : explanation + "\n\n" + details.joined(separator: "\n")
    }

    static func none(_ explanation: String) -> WindowAnswer {
        WindowAnswer(tag: AnswerTag(kind: .none, values: []), explanation: explanation)
    }
}

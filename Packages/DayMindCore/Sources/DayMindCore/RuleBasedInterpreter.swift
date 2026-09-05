import Foundation

/// A draft reminder produced by interpretation (AI or rule-based) — nothing is saved until the
/// app validates it and writes it to the database.
public struct ReminderDraft: Equatable, Sendable {
    public var title: String
    public var notes: String
    public var dueDate: Date?
    public var hasExplicitTime: Bool
    public var recurrence: RecurrenceRule?
    public var priority: ReminderPriority
    public var people: [String]
    public var projectName: String?
    /// Set when the request was understood but a detail is missing (e.g. "later").
    public var clarificationQuestion: String?

    public init(title: String, notes: String = "", dueDate: Date? = nil, hasExplicitTime: Bool = false,
                recurrence: RecurrenceRule? = nil, priority: ReminderPriority = .normal, people: [String] = [],
                projectName: String? = nil, clarificationQuestion: String? = nil) {
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.hasExplicitTime = hasExplicitTime
        self.recurrence = recurrence
        self.priority = priority
        self.people = people
        self.projectName = projectName
        self.clarificationQuestion = clarificationQuestion
    }
}

public struct MemoryDraft: Equatable, Sendable {
    public var title: String
    public var content: String
    public var category: MemoryCategory
    public var people: [String]
    public var projectName: String?
    public var tags: [String]
    public var importance: Importance

    public init(title: String, content: String, category: MemoryCategory = .fact, people: [String] = [],
                projectName: String? = nil, tags: [String] = [], importance: Importance = .normal) {
        self.title = title
        self.content = content
        self.category = category
        self.people = people
        self.projectName = projectName
        self.tags = tags
        self.importance = importance
    }
}

/// Describes which existing reminder the user is talking about.
public struct ReminderReference: Equatable, Sendable {
    /// Words that should appear in the title ("plumber", "call").
    public var titleHint: String?
    /// The day the reminder is currently due, when the user said "tomorrow's …".
    public var dayHint: Date?
    /// "that", "it", "this" — refers to the most recently discussed reminder.
    public var usesAnaphora: Bool

    public init(titleHint: String? = nil, dayHint: Date? = nil, usesAnaphora: Bool = false) {
        self.titleHint = titleHint
        self.dayHint = dayHint
        self.usesAnaphora = usesAnaphora
    }
}

public enum ReminderListScope: String, Equatable, Sendable, Codable, CaseIterable {
    case today, overdue, upcoming, tomorrow, thisWeek, forgottenYesterday, all
}

public enum InterpretedIntent: Equatable, Sendable {
    case createReminder(ReminderDraft)
    case saveMemory(MemoryDraft)
    case createReminderAndMemory(ReminderDraft, MemoryDraft)
    case searchMemories(query: String)
    case listReminders(ReminderListScope)
    case completeReminder(ReminderReference)
    case snoozeReminder(ReminderReference, duration: TimeInterval)
    case rescheduleReminder(ReminderReference, newDate: Date, hasExplicitTime: Bool)
    case deleteReminder(ReminderReference)
    /// "Remind me again tomorrow if I don't complete this."
    case followUpReminder(ReminderReference, date: Date)
    case deleteAllReminders
    case deleteAllMemories
    case assignToProject(projectName: String)
    case dailyBriefing
    case unknown
}

/// Deterministic, offline interpreter. It is the fallback when Apple Intelligence is
/// unavailable and it pre-fills the manual form so the user only has to confirm.
public struct RuleBasedInterpreter: Sendable {
    public var calendar: Calendar
    public var now: Date
    public var defaults: TimeDefaults

    public init(calendar: Calendar = .current, now: Date = Date(), defaults: TimeDefaults = .standard) {
        self.calendar = calendar
        self.now = now
        self.defaults = defaults
    }

    var dateParser: NaturalDateParser { NaturalDateParser(calendar: calendar, now: now, defaults: defaults) }
    var recurrenceParser: RecurrenceParser { RecurrenceParser(calendar: calendar, defaults: defaults) }

    // MARK: - Entry point

    public func interpret(_ rawText: String) -> InterpretedIntent {
        let text = NaturalDateParser.normalize(rawText)
        guard !text.isEmpty else { return .unknown }

        if matches(#"\b(delete|remove|clear|erase|wipe)\s+(all|every|each)(\s+of)?(\s+my)?\s+reminders?\b"#, text) { return .deleteAllReminders }
        if matches(#"\b(delete|remove|clear|erase|wipe)\s+(all|every|each)(\s+of)?(\s+my)?\s+(memories|notes)\b"#, text) { return .deleteAllMemories }

        if matches(#"\b(daily\s+)?(briefing|summary|rundown|agenda)\b"#, text) && matches(#"\b(give|what|my|today|read|tell|morning)\b"#, text) { return .dailyBriefing }
        if matches(#"^(good morning|morning|what('s| is| does) my day (look like|looking like)|how('s| is) my day( looking| look)?|start my day)\b"#, text) { return .dailyBriefing }

        if let intent = parseProjectAssignment(text) { return intent }
        if let intent = parseSnooze(text) { return intent }
        if let intent = parseReschedule(text) { return intent }
        if let intent = parseComplete(text) { return intent }
        if let intent = parseDeleteOne(text) { return intent }
        if let intent = parseSearch(text) { return intent }
        if let intent = parseList(text) { return intent }

        // Mixed: "John prefers texts, so remind me tomorrow to message him"
        if let intent = parseMixed(text) { return intent }
        if let draft = parseReminder(text) { return .createReminder(draft) }
        if let draft = parseMemory(text) { return .saveMemory(draft) }
        if let draft = parseStatementAsMemory(text) { return .saveMemory(draft) }
        return .unknown
    }

    /// Plain statements of fact without "remember": "John's birthday is March 3", "my car is a blue Civic",
    /// "the wifi password is hunter2". Saved as memories; questions and chatter are left alone.
    func parseStatementAsMemory(_ text: String) -> MemoryDraft? {
        guard text.split(separator: " ").count >= 3, !text.hasSuffix("?") else { return nil }
        guard !matches(#"^(what|when|where|who|why|how|is|are|do|does|did|can|could|would|should|will|hey|hi|hello|thanks|thank you|ok|okay|yes|no|yeah|nope)\b"#, text) else { return nil }
        guard !matches(#"\b(remind|reminder|snooze|delete|remove|cancel|show|list|move|change|schedule)\b"#, text) else { return nil }
        // Subject must look like a noun phrase: "my …", "the …", "our …", "<name>", or "<name>'s …".
        guard matches(#"^(my|our|the|his|her|their)\s+\w+(\s+\w+)?('s)?\s+(is|are|was|were|has|have|lives?|works?|prefers?|likes?|loves?|hates?|needs?|wants?|opens?|closes?|costs?)\b"#, text)
            || matches(#"^[a-z]+('s)?\s+(is|are|was|were|has|have|lives|works|prefers|likes|loves|hates|needs|wants|opens|closes|costs|birthday)\b"#, text) else { return nil }
        // Skip statements about DayMind itself or the immediate conversation.
        guard !matches(#"^(the|that|this|it)\s+(is|was)\s+(great|good|fine|wrong|right|it|all|done)\b"#, text) else { return nil }
        let content = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.!")))
        return MemoryDraft(title: Self.summaryTitle(content), content: SpokenFormatter.capitalizeFirst(content),
                           category: Self.classifyMemory(content), people: Self.extractPeople(from: content))
    }

    // MARK: - Reminders

    public func parseReminder(_ text: String) -> ReminderDraft? {
        // "Remember that the office is closed on Fridays" is a memory even though it contains a weekday.
        if matches(#"^(please\s+)?(remember|note|keep in mind|fyi)\b"#, text), !matches(#"\bremind me\b"#, text), !matches(#"^(please\s+)?note to self\b"#, text) { return nil }
        let isReminder = matches(#"\b(remind|reminder|reminded|don't forget|do not forget|dont forget|don't let me forget|i need to|i have to|i must|i gotta|i've got to|todo|to-do|task|note to self)\b"#, text)
        let recurrence = recurrenceParser.parse(text)
        var working = recurrence?.remainder ?? text
        let parsed = dateParser.parse(working)
        // Plain statements with a clear time are reminders too ("call michael tomorrow at 3").
        guard isReminder || recurrence != nil || (parsed != nil && matches(#"^(call|text|message|email|pay|buy|pick up|take|go|meet|send|book|schedule|submit|finish|water|feed|check)\b"#, text)) else { return nil }
        if let parsed { working = parsed.remainder }
        working = working.replacingOccurrences(of: #"\b(later|soon|sometime|at some point|eventually)\b"#, with: " ", options: .regularExpression)

        var title = stripReminderScaffolding(working)
        var clarification: String? = nil
        if title.isEmpty { title = stripReminderScaffolding(text) }
        if title.isEmpty { title = "Reminder" }

        var due = parsed?.date
        var explicitTime = parsed?.hasExplicitTime ?? false
        if let recurrence {
            // Anchor: the first upcoming occurrence at the implied/explicit time.
            let time: TimeOfDay
            if let parsed, parsed.hasExplicitTime {
                time = TimeOfDay(hour: calendar.component(.hour, from: parsed.date), minute: calendar.component(.minute, from: parsed.date))
                explicitTime = true
            } else if let implied = recurrence.impliedTime {
                time = implied
                explicitTime = true
            } else {
                time = defaults.morning
            }
            let anchorBase = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: calendar.startOfDay(for: now)) ?? now
            due = recurrence.rule.nextOccurrence(after: now.addingTimeInterval(-1), anchor: anchorBase, calendar: calendar) ?? anchorBase
        } else if due == nil {
            if matches(#"\b(later|soon|sometime|at some point|eventually)\b"#, text) {
                clarification = "When should I remind you? For example “tomorrow at 3 PM”."
            } else if isReminder {
                clarification = "When should I remind you?"
            }
        }

        let people = Self.extractPeople(from: title)
        for person in people {
            title = title.replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: person.lowercased()))\\b", with: person, options: .regularExpression)
        }
        let priority: ReminderPriority = matches(#"\b(urgent|important|asap|high priority|critical)\b"#, text) ? .high : .normal
        return ReminderDraft(title: SpokenFormatter.capitalizeFirst(title), dueDate: due, hasExplicitTime: explicitTime,
                             recurrence: recurrence?.rule, priority: priority, people: people, clarificationQuestion: clarification)
    }

    func stripReminderScaffolding(_ s: String) -> String {
        var t = s
        let leading = [
            #"^(hey\s+|ok\s+|okay\s+)?(daymind[,\s]+)?"#,
            #"^(please\s+)?(can you\s+|could you\s+|would you\s+|will you\s+)?(set|add|make|create|put|schedule)\s+(up\s+)?(a|an|another)\s+(quick\s+)?(reminder|alarm|task|todo|to-do)\s+(for me\s+)?(for\s+|to\s+|that\s+|about\s+)?"#,
            #"^(please\s+)?(can you\s+|could you\s+|would you\s+|will you\s+)?remind\s+me\s+(again\s+)?(please\s+)?(to\s+|that\s+|about\s+|of\s+)?"#,
            #"^(please\s+)?(i\s+(want|need|would like|'d like)\s+(to\s+be\s+reminded|a\s+reminder)\s+(to\s+|about\s+|that\s+|of\s+)?)"#,
            #"^(please\s+)?(don't|do not|dont)\s+(let\s+me\s+)?forget\s+(to\s+|that\s+|about\s+)?"#,
            #"^(please\s+)?(i\s+(need|have|gotta|got)\s+to|i\s+must|i\s+should|i\s+want\s+to|i've\s+got\s+to)\s+"#,
            #"^(please\s+)?(add\s+(a\s+)?(task|todo|to-do|reminder)\s+(to\s+)?)"#,
            #"^(please\s+)?(note\s+to\s+self\s*[:,]?\s*)"#,
            #"^(please\s+)?(reminder|task|todo|to-do)\s*(:|to)?\s+"#,
        ]
        for p in leading { t = t.replacingOccurrences(of: p, with: "", options: .regularExpression) }
        t = t.replacingOccurrences(of: #"\s+(again|please|for me)\s*$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^\s*(to|that|about|for)\s+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^\s*(to|that|about|for)\s+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+(if i don't complete (this|it)|if i haven't done (this|it))\s*$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.!?")))
    }

    // MARK: - Memories

    public func parseMemory(_ text: String) -> MemoryDraft? {
        let isMemory = matches(#"^(please\s+)?(hey\s+|ok\s+|okay\s+)?(daymind[,\s]+)?(remember|note|keep in mind|save|store|record|make a note|take a note|write down|jot down|log|fyi|just so you know|don't forget)\b"#, text)
            || matches(#"\b(remember that|remember this|note that|for the record|keep in mind that)\b"#, text)
        guard isMemory else { return nil }
        var content = text
        let leading = [
            #"^(please\s+)?(hey\s+|ok\s+|okay\s+)?(daymind[,\s]+)?"#,
            #"^(please\s+)?(can you\s+|could you\s+)?(remember|note to self|note|keep in mind|save|store|record|make a note|take a note|write down|jot down|log|fyi|just so you know)(\s+(that|this|down|of|about|for me|the fact that))*\s*[:,]?\s*"#,
            #"^(please\s+)?(don't|do not)\s+forget\s+(that\s+)?"#,
        ]
        for p in leading { content = content.replacingOccurrences(of: p, with: "", options: .regularExpression) }
        content = content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.!?")))
        guard !content.isEmpty else { return nil }

        let category = Self.classifyMemory(content)
        let people = Self.extractPeople(from: content)
        var projectName: String? = nil
        if let m = firstMatch(#"\b(?:under|for|in)\s+(?:the\s+)?(.+?)\s+project\b"#, in: content) { projectName = Self.titleCase(m) }
        return MemoryDraft(title: Self.summaryTitle(content), content: SpokenFormatter.capitalizeFirst(content), category: category, people: people, projectName: projectName)
    }

    public static func classifyMemory(_ content: String) -> MemoryCategory {
        if content.range(of: #"\b(prefers?|likes?|loves?|hates?|dislikes?|favou?rite|would rather|doesn't like|does not like|allergic)\b"#, options: .regularExpression) != nil { return .preference }
        if content.range(of: #"\b(decided|decision|we will|we'll go with|agreed|chose|going with)\b"#, options: .regularExpression) != nil { return .decision }
        if content.range(of: #"\b(idea|maybe we could|what if|could try)\b"#, options: .regularExpression) != nil { return .idea }
        if content.range(of: #"\b(is located|address|located at|closed on|opens at|closes at|open on|hours are)\b"#, options: .regularExpression) != nil { return .place }
        if content.range(of: #"\b(doctor|dentist|medication|meds|prescription|dose|blood pressure|allergy|symptom|appointment with dr)\b"#, options: .regularExpression) != nil { return .health }
        if content.range(of: #"\b(project|renovation|remodel|launch|campaign)\b"#, options: .regularExpression) != nil { return .project }
        if content.range(of: #"\b(birthday|phone number|email is|lives in|works at|is my|'s (wife|husband|son|daughter|boss|manager|sister|brother))\b"#, options: .regularExpression) != nil { return .person }
        return .fact
    }

    public static func summaryTitle(_ content: String) -> String {
        let words = content.split(separator: " ").map(String.init)
        let head = words.prefix(8).joined(separator: " ")
        let title = head.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:"))
        return SpokenFormatter.capitalizeFirst(words.count > 8 ? title + "…" : title)
    }

    // MARK: - Mixed

    func parseMixed(_ text: String) -> InterpretedIntent? {
        // "<fact>, so remind me <...>" or "<fact>. remind me <...>"
        guard let m = firstMatchRange(#"[,.;]\s*(?:so|and|then)?\s*(remind me\b.*)$"#, in: text) else { return nil }
        let reminderPart = String(text[m.captureRange ?? m.range]).trimmingCharacters(in: .whitespaces)
        let factPart = String(text[text.startIndex..<m.range.lowerBound]).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",.;")))
        guard !factPart.isEmpty, factPart.split(separator: " ").count >= 3, var reminder = parseReminder(reminderPart) else { return nil }
        guard factPart.range(of: #"\b(prefers?|likes?|hates?|is|are|has|have|wants?|needs?|said|told)\b"#, options: .regularExpression) != nil else { return nil }
        let memory = MemoryDraft(title: Self.summaryTitle(factPart), content: SpokenFormatter.capitalizeFirst(factPart), category: Self.classifyMemory(factPart), people: Self.extractPeople(from: factPart))
        if reminder.people.isEmpty { reminder.people = memory.people }
        // Replace pronouns in the reminder title with the person's name when unambiguous.
        if let person = memory.people.first, reminder.title.range(of: #"\b(him|her|them)\b"#, options: .regularExpression) != nil {
            reminder.title = reminder.title.replacingOccurrences(of: #"\b(him|her|them)\b"#, with: person, options: .regularExpression)
        }
        return .createReminderAndMemory(reminder, memory)
    }

    // MARK: - Queries

    func parseSearch(_ text: String) -> InterpretedIntent? {
        let patterns = [
            #"^what (?:did|have) i (?:tell|told|say|said) (?:to )?you about (.+?)\??$"#,
            #"^what do (?:you|i) (?:know|remember) about (.+?)\??$"#,
            #"^what (?:do you|did you) (?:have|remember) (?:on|about) (.+?)\??$"#,
            #"^(?:tell me|remind me) (?:what|about) (?:you know about |i said about |i told you about )?(.+?)\??$"#,
            #"^(?:search|look up|look for|find)(?: my)?(?: memories| notes)?(?: for| about)? (.+?)\??$"#,
            #"^(?:anything|what) (?:about|on) (.+?)\??$"#,
            #"^what(?:'s| is) (.+?)(?:'s)? (?:preference|preferences|number|address|birthday)\??$"#,
            #"^(?:do you|did i) (?:know|remember|have) anything (?:about|on) (.+?)\??$"#,
            #"^what (?:does|do) (.+?) (?:like|prefer|want|need)\??$"#,
            #"^(?:when|where) (?:is|are|was|does|do) (.+?)\??$"#,
            #"^remind me (?:what|which|when|where|how) (.+?)\??$"#,
            #"^(?:what|which) (?:did|do) (?:i|we) (?:decide|choose|pick|say) (?:about|on|for) (.+?)\??$"#,
        ]
        for p in patterns {
            if let q = firstMatch(p, in: text) {
                let cleaned = q.replacingOccurrences(of: #"^(my|the)\s+"#, with: "", options: .regularExpression)
                return .searchMemories(query: cleaned)
            }
        }
        return nil
    }

    func parseList(_ text: String) -> InterpretedIntent? {
        if matches(#"\b(what|which)\b.*\bforg(et|ot|otten)\b.*\byesterday\b"#, text) || matches(#"\byesterday\b.*\b(forg(et|ot)|miss(ed)?|skip(ped)?)\b"#, text) { return .listReminders(.forgottenYesterday) }
        if matches(#"\bwhat am i forgetting\b"#, text) || matches(#"\bwhat('s| is| am i) (missing|behind on)\b"#, text) { return .listReminders(.today) }
        if matches(#"\b(overdue|late|past due|behind)\b"#, text) && matches(#"\b(what|show|list|any|which)\b"#, text) { return .listReminders(.overdue) }
        if matches(#"\b(what|show|list|anything|read).*(due|do|planned|scheduled|on my (plate|list|schedule|agenda|calendar)|reminders?|tasks?)\b.*\btomorrow\b"#, text) { return .listReminders(.tomorrow) }
        if matches(#"\b(what|show|list|anything|read).*(due|do|planned|scheduled|reminders?|tasks?|coming up)\b.*\b(this week|next few days|upcoming)\b"#, text) || matches(#"\bwhat('s| is) coming up\b"#, text) { return .listReminders(.upcoming) }
        if matches(#"\b(what|show|list|anything|read).*(due|do|planned|scheduled|on my (plate|list|schedule|agenda|calendar)|reminders?|tasks?|to-?dos?)\b.*\btoday\b"#, text) { return .listReminders(.today) }
        if matches(#"^what('s| is) (due|next|on today|on my plate|on my list|on the agenda)\b"#, text) { return .listReminders(.today) }
        if matches(#"^(show|list|read|read me|tell me|give me)( me)?( all)?( of)?( my)? (reminders|tasks|to-?dos?|list)\b"#, text) { return .listReminders(.all) }
        if matches(#"^how many (reminders|tasks|things) do i have\b"#, text) { return .listReminders(.all) }
        if matches(#"^what('s| is) next\b"#, text) { return .listReminders(.upcoming) }
        // "what do I have tomorrow", "do I have anything today", "what's on my schedule", "what am I doing tomorrow", "anything due"
        let asksSchedule = matches(#"\b(what do i have|do i have anything|what('s| is) (on|left|happening|going on)|what am i doing|anything (due|planned|scheduled|on)|what('s| is) (my|the) (schedule|day|plan)|whats on)\b"#, text)
        if asksSchedule {
            if matches(#"\btomorrow\b"#, text) { return .listReminders(.tomorrow) }
            if matches(#"\b(this week|next few days|upcoming|coming up|the week)\b"#, text) { return .listReminders(.upcoming) }
            if matches(#"\b(overdue|late|behind)\b"#, text) { return .listReminders(.overdue) }
            return .listReminders(.today)
        }
        return nil
    }

    // MARK: - Edits

    func parseSnooze(_ text: String) -> InterpretedIntent? {
        let verbs = #"\b(snooze|postpone|delay|push back|push|put off|remind me again|remind me about (?:this|that|it) again)\b"#
        guard matches(verbs, text) else { return nil }
        let stripped = text.replacingOccurrences(of: verbs, with: " ", options: .regularExpression)
        let numberAlt = "\\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten|fifteen|twenty|thirty|forty-five|forty|sixty|a couple of|couple of|half an|half a"
        let durationPattern = "\\b(?:for|by|in)\\s+(\(numberAlt))\\s+(minutes?|mins?|hours?|hrs?|days?|weeks?)\\b"
        if let regex = try? Regex(durationPattern).ignoresCase(), let mm = text.firstMatch(of: regex) {
            let raw = (mm.output[1].substring.map(String.init) ?? "").lowercased()
            let unit = (mm.output[2].substring.map(String.init) ?? "").lowercased()
            var value: Double
            if raw.hasPrefix("half") { value = 0.5 } else if raw.contains("couple") { value = 2 } else { value = Double(NaturalDateParser.number(from: raw) ?? 1) }
            let seconds: Double
            if unit.hasPrefix("min") { seconds = 60 } else if unit.hasPrefix("h") { seconds = 3600 } else if unit.hasPrefix("day") { seconds = 86_400 } else { seconds = 604_800 }
            let reference = extractReference(stripped.replacingOccurrences(of: durationPattern, with: " ", options: [.regularExpression, .caseInsensitive]))
            return .snoozeReminder(reference, duration: value * seconds)
        }
        // "remind me again tomorrow if I don't complete this" → follow-up on the current reminder.
        if matches(#"\bremind me\b"#, text), let parsed = dateParser.parse(stripped) {
            let reference = extractReference(parsed.remainder.replacingOccurrences(of: #"\bif i (don't|do not|haven't|have not) (complete|finish|do) (this|it|that)\b"#, with: " ", options: .regularExpression))
            return .followUpReminder(reference, date: parsed.date)
        }
        if let parsed = dateParser.parse(stripped) {
            return .rescheduleReminder(extractReference(parsed.remainder), newDate: parsed.date, hasExplicitTime: parsed.hasExplicitTime)
        }
        if matches(#"\b(snooze|remind me again)\b"#, text) {
            // Default snooze when no duration was given.
            return .snoozeReminder(extractReference(stripped), duration: 3600)
        }
        return nil
    }

    func parseReschedule(_ text: String) -> InterpretedIntent? {
        if let regex = try? Regex(#"^(?:please\s+)?(?:can you\s+|actually\s+)?(move|change|reschedule|shift|switch|bump|push)\s+(.+?)\s+(?:back\s+)?(?:to|for|until|till)\s+(.+)$"#).ignoresCase(),
           let mm = text.firstMatch(of: regex) {
            let what = mm.output[2].substring.map(String.init) ?? ""
            let when = mm.output[3].substring.map(String.init) ?? ""
            if let parsed = dateParser.parse(when) {
                return .rescheduleReminder(extractReference(what), newDate: parsed.date, hasExplicitTime: parsed.hasExplicitTime)
            }
        }
        // "make it 5 pm", "actually make that tomorrow", "set it for friday", "do it tomorrow instead", "let's do 4 instead"
        if let regex = try? Regex(#"^(?:actually[,\s]+)?(?:make|set|do|let's do)\s+(?:it|that|this)?\s*(?:for|at|on|to)?\s*(.+?)(?:\s+instead)?\s*$"#).ignoresCase(),
           let mm = text.firstMatch(of: regex), matches(#"\b(make|set|do)\s+(it|that|this)\b|^let's do\b|\binstead\b"#, text) {
            let when = mm.output[1].substring.map(String.init) ?? ""
            if let parsed = dateParser.parse(when), parsed.remainder.split(separator: " ").count <= 1 {
                return .rescheduleReminder(ReminderReference(usesAnaphora: true), newDate: parsed.date, hasExplicitTime: parsed.hasExplicitTime)
            }
        }
        return nil
    }

    func parseComplete(_ text: String) -> InterpretedIntent? {
        let patterns = [
            #"^(?:please\s+)?(?:mark|check off|tick off|check)\s+(.+?)\s+(?:as\s+)?(?:done|complete|completed|finished|off)\s*$"#,
            #"^(?:please\s+)?(?:complete|finish|close)\s+(?:the\s+)?(.+?)(?:\s+reminder)?\s*$"#,
            #"^(?:i(?:'ve| have)?\s+)?(?:done|finished|completed)\s+(?:with\s+)?(?:the\s+)?(.+?)(?:\s+reminder)?\s*$"#,
            #"^(?:that's|that is|it's|it is|this is)\s+(?:done|finished|complete|completed|taken care of|handled)\s*$"#,
            #"^(?:done|finished|completed|did it|i did it|did that|i did that|got it done|all done|taken care of)\s*$"#,
        ]
        for p in patterns {
            guard let regex = try? Regex(p).ignoresCase(), let mm = text.firstMatch(of: regex) else { continue }
            let what = mm.output.count > 1 ? (mm.output[1].substring.map(String.init) ?? "") : ""
            return .completeReminder(what.isEmpty ? ReminderReference(usesAnaphora: true) : extractReference(what))
        }
        return nil
    }

    func parseDeleteOne(_ text: String) -> InterpretedIntent? {
        // "scratch that", "never mind, delete that", "undo that reminder", "cancel that"
        if matches(#"^(?:never\s*mind[,\s]+|actually[,\s]+)?(?:scratch|cancel|undo|drop|forget|delete|remove|trash)\s+(?:that|this|it|the last one|that one|that reminder|the last reminder)\s*(?:reminder)?\s*$"#, text) {
            return .deleteReminder(ReminderReference(usesAnaphora: true))
        }
        guard let regex = try? Regex(#"^(?:please\s+)?(?:can you\s+)?(?:delete|remove|cancel|forget about|get rid of|trash|erase)\s+(?:the\s+|my\s+)?(.+?)(?:\s+reminder)?\s*$"#).ignoresCase(),
              let mm = text.firstMatch(of: regex) else { return nil }
        let what = mm.output[1].substring.map(String.init) ?? ""
        guard !what.isEmpty else { return nil }
        return .deleteReminder(extractReference(what))
    }

    func parseProjectAssignment(_ text: String) -> InterpretedIntent? {
        let patterns = [
            #"^(?:please\s+)?(?:save|file|put|store|add)\s+(?:this|that|it)\s+(?:under|in|to|into)\s+(?:the\s+|my\s+)?(.+?)(?:\s+project)?\s*$"#,
            #"^(?:please\s+)?(?:save|file|put|store|add)\s+(?:this|that|it)\s+(?:idea|note|reminder)\s+(?:under|in|to|into)\s+(?:the\s+|my\s+)?(.+?)(?:\s+project)?\s*$"#,
        ]
        for p in patterns {
            guard let regex = try? Regex(p).ignoresCase(), let mm = text.firstMatch(of: regex) else { continue }
            let name = mm.output[1].substring.map(String.init) ?? ""
            guard !name.isEmpty else { continue }
            return .assignToProject(projectName: Self.titleCase(name))
        }
        return nil
    }

    // MARK: - References & people

    func extractReference(_ fragment: String) -> ReminderReference {
        var s = fragment.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        if matches(#"^(that|this|it|that one|the reminder|the last one)\s*(reminder|one)?\s*$"#, s) || s.isEmpty {
            return ReminderReference(usesAnaphora: true)
        }
        var dayHint: Date? = nil
        // "tomorrow's plumber reminder" / "friday's call"
        if let regex = try? Regex(#"^(today|tomorrow|yesterday|monday|tuesday|wednesday|thursday|friday|saturday|sunday)'?s?\s+"#).ignoresCase(), let m = s.firstMatch(of: regex) {
            let word = String(m.output[1].substring ?? "")
            dayHint = dateParser.parse(word)?.date
            s.removeSubrange(m.range)
        }
        s = s.replacingOccurrences(of: #"\b(the|my|that|this|it|one|reminder|reminders|task|about|for|to|at|on|until|till|by|from)\b"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return ReminderReference(titleHint: s.isEmpty ? nil : s, dayHint: dayHint, usesAnaphora: s.isEmpty && dayHint == nil)
    }

    static let personVerbs = "call|text|message|email|e-mail|phone|ring|meet|visit|pay|ask|tell|thank|invite|pick up|see|dm|ping|follow up with|check on"
    static let notNames: Set<String> = ["the", "my", "a", "an", "him", "her", "them", "me", "back", "in", "on", "at", "to", "about", "it", "this", "that", "and", "or", "for", "up", "out", "later", "again", "today", "tomorrow", "someone", "everyone", "work", "home", "school", "office", "rent", "bills", "bill", "taxes", "insurance", "landlord", "plumber", "electrician", "dentist", "doctor", "vet", "bank", "message", "messages", "text", "texts", "email", "emails", "mail", "phone", "calls", "call", "appointment", "appointments", "people", "friends", "family", "mom", "dad", "them", "us", "you", "myself", "that", "if", "when", "before", "after"]

    /// Best-effort person-name extraction for the offline path ("call Michael" → ["Michael"]).
    public static func extractPeople(from text: String) -> [String] {
        var names: [String] = []
        let pronouns: Set<String> = ["he", "she", "they", "i", "we", "you", "it", "there", "what", "who", "everything", "nothing", "this", "that"]
        // "<Name> prefers/likes/is/…" at the start of a statement takes priority.
        if let regex = try? Regex(#"^(?:my\s+)?([a-z][a-z'\-]+)\s+(?:prefers?|likes?|loves?|hates?|dislikes?|is|has|wants?|needs?|said|told|works|lives|always|never|usually)\b"#).ignoresCase(),
           let m = text.firstMatch(of: regex), let sub = m.output[1].substring {
            let word = String(sub)
            let lower = word.lowercased()
            if !notNames.contains(lower), !pronouns.contains(lower), !lower.hasSuffix("'s") {
                names.append(titleCase(word))
            }
        }
        // "call Michael", "text John and Mary"
        if let regex = try? Regex("\\b(?:\(personVerbs))\\s+([a-z][a-z'\\-]+)(?:\\s+(?:and|&)\\s+([a-z][a-z'\\-]+))?").ignoresCase() {
            for m in text.matches(of: regex) {
                for i in 1..<m.output.count {
                    if let sub = m.output[i].substring {
                        let word = String(sub)
                        let lower = word.lowercased()
                        if !notNames.contains(lower), !pronouns.contains(lower), !minorWords.contains(lower) { names.append(titleCase(word)) }
                    }
                }
            }
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }
    }

    static let minorWords: Set<String> = ["of", "the", "and", "a", "an", "for", "to", "in", "on"]

    public static func titleCase(_ s: String) -> String {
        s.split(separator: " ").enumerated().map { i, word -> String in
            let w = String(word)
            if i > 0, minorWords.contains(w.lowercased()) { return w.lowercased() }
            return SpokenFormatter.capitalizeFirst(w.lowercased())
        }.joined(separator: " ")
    }

    // MARK: - Regex helpers

    struct RangeMatch { var range: Range<String.Index>; var captureRange: Range<String.Index>? }

    func matches(_ pattern: String, _ text: String) -> Bool {
        guard let regex = try? Regex(pattern).ignoresCase() else { return false }
        return text.firstMatch(of: regex) != nil
    }

    /// First capture group of the first match, or nil.
    func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? Regex(pattern).ignoresCase(), let m = text.firstMatch(of: regex), m.output.count > 1, let sub = m.output[1].substring else { return nil }
        let s = String(sub).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "?.!,")))
        return s.isEmpty ? nil : s
    }

    func firstMatchRange(_ pattern: String, in text: String) -> RangeMatch? {
        guard let regex = try? Regex(pattern).ignoresCase(), let m = text.firstMatch(of: regex) else { return nil }
        let cap = m.output.count > 1 ? m.output[1].range : nil
        return RangeMatch(range: m.range, captureRange: cap)
    }
}

import Foundation

enum ProfileSearch {
    static func normalize(_ text: String) -> String {
        let aliases = ["мтс": "mts", "мегафон": "megafon", "билайн": "beeline", "вымпелком": "vimpelcom",
                       "т2": "t2", "теле2": "t2", "tele2": "t2", "йота": "yota"]
        return text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "ru_RU"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            .map { aliases[$0] ?? $0 }.joined(separator: " ")
    }
    static func matches(_ profile: CarrierProfile, query: String, research: ProfileResearch) -> Bool {
        let words = normalize(query).split(separator: " ")
        guard !words.isEmpty else { return true }
        let rules = research.rules(for: profile).filter(\.candidate)
        let operatorIDs = Set(rules.flatMap(\.operators))
        let aliases: [String: String] = ["mts": "мтс mts", "megafon": "мегафон megafon", "beeline": "билайн beeline",
            "t2": "t2 т2 tele2 теле2", "yota": "йота yota", "other": "виртуальные mvno"]
        let countries = ["ro": "Румыния Romania", "hu": "Венгрия Hungary", "dk": "Дания Denmark", "ua": "Украина Ukraine",
                         "az": "Азербайджан Azerbaijan", "ru": "Россия Russia", "tr": "Турция Turkey", "is": "Исландия Iceland"]
        let region = profile.identifier.split(separator: "_").last.map(String.init) ?? ""
        let operatorText = operatorIDs.compactMap { aliases[$0] }.joined(separator: " ")
        let haystack = normalize([profile.name, profile.identifier, profile.version, operatorText, countries[region] ?? ""].joined(separator: " "))
        return words.allSatisfy { haystack.contains($0) }
    }
}

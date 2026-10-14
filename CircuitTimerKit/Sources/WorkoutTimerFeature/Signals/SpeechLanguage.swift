func voiceLanguage(forLocalization localization: String) -> String {
    switch localization {
        case "ru": "ru-RU"
        case "en": "en-US"
        default: localization
    }
}

import Foundation

public enum SensitiveContentDetector {
    private static let secretPatterns = [
        #"(?i)\b(password|passcode|api[_ -]?key|secret|token|bearer|private[_ -]?key|access[_ -]?token|refresh[_ -]?token)\b\s*[:=]\s*\S{4,}"#,
        #"(?i)\bbearer\s+[A-Za-z0-9._~+/\-=]{12,}"#,
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
        #"(?i)\b(sk_live|sk_test|pk_live|pk_test|xox[baprs]|ghp|github_pat|glpat|AKIA)[A-Za-z0-9_\-]{12,}\b"#,
        #"\bAIza[0-9A-Za-z\-_]{35}\b"#,
        #"(?i)\b(verification code|one[- ]time code|otp|2fa|mfa|security code)\b\D{0,24}\d{4,8}\b"#
    ]

    public static func isLikelySensitive(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if secretPatterns.contains(where: { trimmed.range(of: $0, options: .regularExpression) != nil }) {
            return true
        }

        return containsLikelyPaymentCardNumber(trimmed)
    }

    private static func containsLikelyPaymentCardNumber(_ text: String) -> Bool {
        let pattern = #"(?<!\d)(?:\d[ -]?){13,19}(?!\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        return regex.matches(in: text, range: range).contains { match in
            guard let matchRange = Range(match.range, in: text) else { return false }
            let digits = text[matchRange].compactMap(\.wholeNumberValue)
            return (13...19).contains(digits.count)
                && Set(digits).count > 1
                && passesLuhn(digits)
        }
    }

    private static func passesLuhn(_ digits: [Int]) -> Bool {
        var sum = 0
        var shouldDouble = false

        for digit in digits.reversed() {
            var value = digit
            if shouldDouble {
                value *= 2
                if value > 9 {
                    value -= 9
                }
            }
            sum += value
            shouldDouble.toggle()
        }

        return sum % 10 == 0
    }
}

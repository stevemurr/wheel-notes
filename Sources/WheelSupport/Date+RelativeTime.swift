import Foundation

public extension Date {
    func abbreviatedRelativeTimeString() -> String {
        Date.abbreviatedRelativeFormatter.localizedString(for: self, relativeTo: Date())
    }

    private static let abbreviatedRelativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

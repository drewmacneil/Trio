import Foundation

enum HealthIngestBuild {
    /// `com-trio-commit-sha` is written into the built product by `scripts/capture-build-details.sh`,
    /// which the Trio target runs locally and in the GitHub Build Trio workflow.
    static var gitSha: String? {
        guard let url = Bundle.main.url(forResource: "BuildDetails", withExtension: "plist"),
              let plist = NSDictionary(contentsOf: url),
              let sha = plist["com-trio-commit-sha"] as? String
        else { return nil }
        let trimmed = sha.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (7 ... 40).contains(trimmed.count), trimmed.allSatisfy(\.isHexDigit) else { return nil }
        return trimmed
    }
}

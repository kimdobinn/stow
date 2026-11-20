#if DEBUG
import Foundation

/// `Stow --deploy-rules <firestore.rules>` (Debug builds only): publishes Firestore security
/// rules to the project with the service-account key (Firebase Rules API).
@MainActor
enum DeployRules {
    static let argument = "--deploy-rules"

    static func run() async -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: argument), args.indices.contains(index + 1) else {
            print("usage: Stow --deploy-rules <firestore.rules>")
            return false
        }
        do {
            let source = try String(contentsOf: URL(filePath: args[index + 1]), encoding: .utf8)
            let account = try ServiceAccount(json: Data(contentsOf: AppPaths.firebaseKeyFile))
            let http = FirebaseHTTP()
            let auth = GoogleAuth(account: account, http: http, scopes: ["https://www.googleapis.com/auth/cloud-platform"])
            let base = "https://firebaserules.googleapis.com/v1/projects/\(account.projectId)"
            let ruleset = try await send(auth, http, "POST", "\(base)/rulesets",
                                         ["source": ["files": [["name": "firestore.rules", "content": source]]]])
            guard let name = ruleset["name"] as? String else { throw StowError.parse("No ruleset name") }
            print("created \(name)")
            _ = try await send(auth, http, "PATCH", "\(base)/releases/cloud.firestore",
                               ["release": ["name": "projects/\(account.projectId)/releases/cloud.firestore", "rulesetName": name]])
            print("released to cloud.firestore")
            return true
        } catch {
            print("failed: \(error.logDescription)")
            return false
        }
    }

    private static func send(_ auth: GoogleAuth, _ http: FirebaseHTTP, _ method: String, _ url: String,
                             _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, status) = try await http.send(request)
        guard (200..<300).contains(status) else {
            throw StowError.network("Rules API (HTTP \(status)): \(FirebaseHTTP.message(from: data))")
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
#endif

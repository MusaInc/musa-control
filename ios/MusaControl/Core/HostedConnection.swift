import Foundation

enum HostedConnection {
    static func url(_ text: String) throws -> URL {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: value), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw GatewayError(status: 0, message: "Enter the secure https:// workspace address you were given, without a code or password in the address.", body: nil)
        }
        return url
    }
}

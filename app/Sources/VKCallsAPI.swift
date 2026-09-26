import Foundation

/// `calls.start` — create a VK call from the user's own account and get a
/// join link that SURVIVES the creator leaving (VK issue #69: hand-made links
/// die the moment the browser creator leaves; API-made ones don't). Port of
/// the iOS VKCallsAPI.
enum VKCallsAPI {
    static let apiVersion = "5.276"
    static let hosts = ["api.vk.ru", "api.vk.com"]

    struct Created { let joinLink: String }

    enum Failure: Error {
        case vk(code: Int, message: String)
        case transport(String)
        case malformed
        var userMessage: String {
            switch self {
            case let .vk(code, message): return "VK error \(code): \(message)"
            case let .transport(m): return "Сеть: \(m)"
            case .malformed: return "VK вернул неожиданный ответ."
            }
        }
    }

    static func startCall(accessToken: String) async -> Result<Created, Failure> {
        var lastTransport: Failure = .transport("нет доступных хостов")
        for host in hosts {
            var comps = URLComponents()
            comps.scheme = "https"
            comps.host = host
            comps.path = "/method/calls.start"
            comps.queryItems = [
                URLQueryItem(name: "v", value: apiVersion),
                URLQueryItem(name: "access_token", value: accessToken),
            ]
            guard let url = comps.url else { return .failure(.malformed) }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 20
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .failure(.malformed)
                }
                if let err = obj["error"] as? [String: Any] {
                    let code = err["error_code"] as? Int ?? -1
                    let msg = err["error_msg"] as? String ?? "unknown error"
                    return .failure(.vk(code: code, message: msg))
                }
                guard let resp = obj["response"] as? [String: Any],
                      let link = resp["join_link"] as? String, !link.isEmpty else {
                    return .failure(.malformed)
                }
                return .success(Created(joinLink: link))
            } catch {
                lastTransport = .transport(error.localizedDescription)
                continue
            }
        }
        return .failure(lastTransport)
    }
}

import AppKit
import Foundation

/// Images in Inbox descriptions and comments. GitHub images load only from GitHub's own hosts and without any
/// credentials; Jira attachments load from the connected Jira (the token goes nowhere else); images from other
/// hosts are not loaded (they could track who opened the item) and show as a link instead.
enum InboxMedia {
    struct Ref: Equatable { let url: String; let alt: String }

    /// Jira attachments in ADF become `![name](jira-attachment:name)`.
    static let jiraScheme = "jira-attachment:"
    /// Largest image loaded.
    static let maxBytes = 10 * 1024 * 1024

    /// The images of a Markdown block (`![alt](url "title")`, `<img … src="…" alt="…">`) and the text without them.
    static func images(in block: String) -> (refs: [Ref], rest: String) {
        var refs: [Ref] = []
        var rest = block
        let md = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)"#)
        let html = try! NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive])
        var found: [(NSRange, Ref)] = []
        let ns = block as NSString
        for m in md.matches(in: block, range: NSRange(location: 0, length: ns.length)) {
            found.append((m.range, Ref(url: ns.substring(with: m.range(at: 2)), alt: ns.substring(with: m.range(at: 1)))))
        }
        for m in html.matches(in: block, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            guard let src = attr("src", in: tag) else { continue }
            found.append((m.range, Ref(url: src, alt: attr("alt", in: tag) ?? "")))
        }
        found.sort { $0.0.location < $1.0.location }
        refs = found.map(\.1)
        for (r, _) in found.reversed() { rest = (rest as NSString).replacingCharacters(in: r, with: "") }
        // A link around an image ([![x](img)](link)) leaves an empty link behind.
        rest = rest.replacingOccurrences(of: #"\[\s*\]\([^)]*\)"#, with: "", options: .regularExpression)
        return (refs, rest)
    }

    private static func attr(_ name: String, in tag: String) -> String? {
        guard let r = tag.range(of: name + #"\s*=\s*"([^"]*)""#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let v = tag[r].split(separator: "\"", maxSplits: 2, omittingEmptySubsequences: false)
        return v.count > 1 ? String(v[1]) : nil
    }

    /// GitHub's own image hosts (no credentials are sent to them).
    static let githubHosts: Set<String> = [
        "github.com", "user-images.githubusercontent.com", "private-user-images.githubusercontent.com",
        "raw.githubusercontent.com", "camo.githubusercontent.com", "avatars.githubusercontent.com",
    ]

    enum Origin: Equatable { case github(URL), jira(String), blocked(String) }

    /// Where an image may come from: GitHub's hosts over https, the item's Jira attachments, or nowhere.
    static func origin(_ url: String) -> Origin {
        if url.hasPrefix(jiraScheme) { return .jira(String(url.dropFirst(jiraScheme.count))) }
        guard let u = URL(string: url), u.scheme == "https", let host = u.host?.lowercased(), githubHosts.contains(host) else {
            return .blocked(URL(string: url)?.host ?? url)
        }
        return .github(u)
    }
}

/// Loads and keeps Inbox images (memory only).
final class InboxImages: ObservableObject {
    static let shared = InboxImages()

    enum State { case loading, loaded(NSImage), failed(String) }
    @Published private(set) var states: [String: State] = [:]

    /// Fetches the bytes of an allowed image (network; the debug fixture swaps it).
    var fetch: (InboxMedia.Origin, InboxItem?) throws -> Data = InboxImages.download

    static func key(_ ref: InboxMedia.Ref, _ item: InboxItem?) -> String { (item?.id ?? "") + "|" + ref.url }

    /// What is known of an image; nil until `load` (blocked ones stay nil). Reading only: safe in a view body.
    func state(_ ref: InboxMedia.Ref, item: InboxItem?) -> State? { states[Self.key(ref, item)] }

    /// Starts loading an allowed image once (from onAppear, never while a view is drawn).
    func load(_ ref: InboxMedia.Ref, item: InboxItem?) {
        let key = Self.key(ref, item)
        guard states[key] == nil else { return }
        let origin = InboxMedia.origin(ref.url)
        if case .blocked = origin { return }
        states[key] = .loading
        let fetch = self.fetch
        DispatchQueue.global(qos: .utility).async {
            let r: State
            do {
                let data = try fetch(origin, item)
                if let img = NSImage(data: data), img.isValid { r = .loaded(img) } else { r = .failed("not an image") }
            } catch { r = .failed("\(error)") }
            DispatchQueue.main.async { self.states[key] = r }
        }
    }

    func forget() { states = [:] }

    /// No cookies, no cache on disk, no stored credentials: GitHub images go out without anything identifying.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCredentialStorage = nil
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c, delegate: SameSites.github, delegateQueue: nil)
    }()

    static func download(_ origin: InboxMedia.Origin, _ item: InboxItem?) throws -> Data {
        switch origin {
        case .blocked(let host): throw InboxError("images from \(host) are not loaded")
        case .jira(let name):
            guard let key = item?.key, item?.source == .jira else { throw InboxError("not a Jira item") }
            return try JiraClient.attachmentImage(issue: key, name: name, maxBytes: InboxMedia.maxBytes)
        case .github(let url):
            var result: Result<Data, Error> = .failure(InboxError("No answer"))
            let sem = DispatchSemaphore(value: 0)
            session.dataTask(with: url) { d, resp, e in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let type = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
                if let e { result = .failure(e) }
                else if code != 200 { result = .failure(InboxError("GitHub answered \(code)")) }
                else if !type.hasPrefix("image/") { result = .failure(InboxError("not an image (\(type))")) }
                else if let d, d.count <= InboxMedia.maxBytes { result = .success(d) }
                else { result = .failure(InboxError("too large")) }
                sem.signal()
            }.resume()
            sem.wait()
            return try result.get()
        }
    }
}

/// Follows a redirect only to an allowed host (GitHub's image hosts, or the Jira the request went to).
final class SameSites: NSObject, URLSessionTaskDelegate {
    static let github = SameSites { InboxMedia.githubHosts.contains($0) }
    let allow: (String) -> Bool
    init(_ allow: @escaping (String) -> Bool) { self.allow = allow }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let host = request.url?.host?.lowercased() ?? ""
        completionHandler(request.url?.scheme == "https" && allow(host) ? request : nil)
    }
}

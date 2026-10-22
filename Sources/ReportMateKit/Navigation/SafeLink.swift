import Foundation

/// The only way the app turns text from a device or the API into a link it opens.
/// A device reports what it likes (a CVE's `url`, SOFA's `security_info`), so a link
/// opens only when it is http or https with a host: never `file:`, `javascript:`,
/// `x-apple…:` or any other scheme a click would hand to the system.
public enum SafeLink {
    /// `text` as a URL when it is an http or https URL with a host, else nil.
    public static func url(_ text: String?) -> URL? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return url(URL(string: text))
    }

    /// `url` when it is http or https with a host, else nil.
    public static func url(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// A fixed https page with a device-reported value as its last path component,
    /// percent-encoded so the value cannot change the host, path or query.
    public static func url(base: String, component: String) -> URL? {
        let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) else { return nil }
        return url(URL(string: base + encoded))
    }
}

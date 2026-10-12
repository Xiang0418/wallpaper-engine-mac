import Foundation

@main struct SteamSubscriptionTests {
    static func cookie(_ name: String, _ value: String, domain: String = "steamcommunity.com", expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: "/", .secure: "TRUE"]
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }
    static func expectFailure(_ body: () throws -> Void) {
        do { try body(); fatalError("Expected rejection") } catch {}
    }
    static func main() throws {
        let cookies = [cookie("steamLoginSecure", "fixture-account"), cookie("sessionid", "csrf+&=fixture"),
                       cookie("unrelated", "do-not-send", domain: "store.steampowered.com"),
                       cookie("spoof", "do-not-send", domain: "steamcommunity.com.evil.test")]
        let request = try SteamSubscriptionRequest.make(id: "123456", cookies: cookies)
        precondition(request.url?.absoluteString == "https://steamcommunity.com/sharedfiles/subscribe")
        precondition(request.httpMethod == "POST")
        let body = String(data: request.httpBody!, encoding: .utf8)!
        let values = URLComponents(string: "https://fixture.test/?" + body)!.queryItems!
        precondition(values.contains(URLQueryItem(name: "id", value: "123456")))
        precondition(values.contains(URLQueryItem(name: "appid", value: "431960")))
        precondition(values.contains(URLQueryItem(name: "sessionid", value: "csrf+&=fixture")))
        precondition(values.contains(URLQueryItem(name: "include_dependencies", value: "false")))
        precondition(body.contains("%2B") && body.contains("%26"))
        let sentCookies = request.value(forHTTPHeaderField: "Cookie")!
        precondition(!sentCookies.contains("unrelated") && !sentCookies.contains("spoof"))
        expectFailure { _ = try SteamSubscriptionRequest.make(id: "123", cookies: []) }
        expectFailure { _ = try SteamSubscriptionRequest.make(id: "123", cookies: [cookies[0]]) }
        expectFailure { _ = try SteamSubscriptionRequest.make(id: "123", cookies: [cookies[1]]) }
        expectFailure { _ = try SteamSubscriptionRequest.make(id: "123", cookies: [cookie("steamLoginSecure", "expired", expires: .distantPast), cookies[1]]) }
        for id in ["", "0", "-1", "12&appid=1", "18446744073709551616"] {
            expectFailure { _ = try SteamSubscriptionRequest.make(id: id, cookies: cookies) }
        }
        func response(_ status: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        }
        try SteamSubscriptionRequest.validate(data: Data(#"{"success":1}"#.utf8), response: response(200))
        for text in [#"{"success":0}"#, #"{"success":15}"#, #"{"success":21}"#, #"{"success":25}"#, #"{"success":true}"#, #"{"success":"1"}"#, "{}", "<html>Sign in</html>"] {
            expectFailure { try SteamSubscriptionRequest.validate(data: Data(text.utf8), response: response(200)) }
        }
        for code in [302, 401, 403, 429, 500] {
            expectFailure { try SteamSubscriptionRequest.validate(data: Data(#"{"success":1}"#.utf8), response: response(code)) }
        }
        do {
            try SteamSubscriptionRequest.validate(data: Data(#"{"success":21}"#.utf8), response: response(200))
            fatalError("Expected sign-in requirement")
        } catch SteamSubscriptionError.signInRequired {}
        print("PASS: subscription request, CSRF encoding, cookie isolation, expiry, response errors and login detection")
    }
}

#!/usr/bin/env python3
"""Exercise production Steam URL routing without contacting Steam or using accounts."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
source = (root / 'Open Wallpaper Engine/ContentView/Components/WorkshopView.swift').read_text()
start = source.index('private enum SteamCommunityNavigation')
end = source.index('@MainActor', start)
checks = r'''
func url(_ value: String) -> URL { URL(string: value)! }
let allowed = ["https://steamcommunity.com/login/home/", "https://store.steampowered.com/login/", "https://login.steampowered.com/jwt/finalizelogin"]
let blocked = ["https://steamcommunity.com.evil.test/", "https://evilsteamcommunity.com/", "http://steamcommunity.com/", "file:///tmp/test", "javascript:alert(1)"]
for value in allowed { precondition(SteamCommunityNavigation.isSteamURL(url(value)), value) }
for value in blocked { precondition(!SteamCommunityNavigation.isSteamURL(url(value)), value) }
precondition(SteamCommunityNavigation.workshopID(url("https://steamcommunity.com/sharedfiles/filedetails/?id=123456&searchtext=test")) == "123456")
for value in ["https://evil.test/sharedfiles/filedetails/?id=123", "https://steamcommunity.com/sharedfiles/filedetails/?id=12%26appid%3D1", "https://steamcommunity.com/sharedfiles/filedetails/?id=0", "https://steamcommunity.com/sharedfiles/filedetails/?id=-1", "https://steamcommunity.com/sharedfiles/filedetails/?id=18446744073709551616", "https://steamcommunity.com/workshop/browse/?id=123", "http://steamcommunity.com/sharedfiles/filedetails/?id=123"] {
    precondition(SteamCommunityNavigation.workshopID(url(value)) == nil, value)
}
precondition(SteamCommunityNavigation.workshopID(nil) == nil)
precondition(SteamCommunityNavigation.subscriptions.path == "/my/myworkshopfiles")
let query = URLComponents(url: SteamCommunityNavigation.subscriptions, resolvingAgainstBaseURL: false)!.queryItems!
precondition(query.contains(URLQueryItem(name: "appid", value: "431960")))
precondition(query.contains(URLQueryItem(name: "browsefilter", value: "mysubscriptions")))
print("PASS: Steam navigation, account-relative subscriptions, and workshop ID validation")
'''
with tempfile.TemporaryDirectory(prefix='we-community-') as temporary:
    path = pathlib.Path(temporary)
    (path / 'main.swift').write_text('import Foundation\n' + source[start:end] + checks)
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(path / 'cache'), str(path / 'main.swift'), '-o', str(path / 'checks')], check=True)
    subprocess.run([str(path / 'checks')], check=True)

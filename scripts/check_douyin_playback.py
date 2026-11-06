#!/usr/bin/env python3
"""Offline regression checks for playback endpoint migration and signed URL preservation."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
source = (repo / 'src/Downloader.swift').read_text()
start = source.index('enum Douyin {')
end = source.index('// MARK: - 直接下载', start)
runner = '''
@main struct Check {
    static func main() {
        let query = "video_id=opaque%2Fid&ratio=1080p&signature=a%2Bb"
        let urls = Douyin.playbackURLs("https://aweme.snssdk.com/aweme/v1/play/?" + query)
        precondition(urls.map(\\.host) == ["www.douyin.com", "www.iesdouyin.com", "aweme.snssdk.com"])
        precondition(urls.allSatisfy { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery == query })
        let wm = Douyin.playbackURLs("http://aweme.snssdk.com/aweme/v1/playwm/?" + query)
        precondition(wm.allSatisfy { $0.scheme == "https" && URLComponents(url: $0, resolvingAgainstBaseURL: false)?.path == "/aweme/v1/play/" })
        for raw in [
            "https://cdn.example.invalid/playwm.mp4?signature=a%2Bb&expires=123",
            "https://notaweme.snssdk.com/aweme/v1/play/?video_id=123",
            "https://aweme.snssdk.com/unrelated/?video_id=123"
        ] {
            precondition(Douyin.playbackURLs(raw).map(\\.absoluteString) == [raw])
        }
        print("6 offline playback regression checks passed")
    }
}
'''
work = repo / '.work'
work.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='douyin-check-', dir=work) as tmp:
    path = Path(tmp)
    swift = path / 'Check.swift'
    swift.write_text('import Foundation\nstruct TError: LocalizedError { let message: String; var errorDescription: String? { message } }\n' + source[start:end] + runner)
    command = ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library']
    sdk = Path('/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk')
    if sdk.exists():
        command += ['-sdk', str(sdk)]
    command += [str(swift), '-o', str(path / 'check')]
    subprocess.run(command, check=True)
    subprocess.run([str(path / 'check')], check=True)

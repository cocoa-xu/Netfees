# NetFees

Every byte accounted for.

A native macOS menu bar meter that records real network traffic and calculates download costs at **€0.055 per GB**.

Written in Swift with AppKit. The panel, tables, menus, and popovers use native macOS controls; the small seven-day chart is drawn directly. No SwiftUI or Charts dependency.

## Use

Download a DMG from [GitHub Releases](https://github.com/cocoa-xu/Netfees/releases/latest), open it, and drag NetFees into Applications. Choose Apple Silicon for M-series Macs, Intel for Intel Macs, or Universal for either. Release apps are signed with Developer ID, and the DMGs are notarized and stapled.

Open NetFees. The two menu bar lines show today's downloaded data and network cost. Click them for a glass panel with your costs, downloads, uploads, live transfer speeds, a seven-day chart, and a scrolling application list sorted by download cost. Each application shows downloaded and uploaded bytes, cost, and current transfer speeds. History keeps every recorded day, includes expandable application breakdowns, and exports the overall ledger as CSV.

On first launch, choose whether to import the cumulative interface counters already available from macOS. Imported traffic has its own "Before NetFees" history entry and contributes to the all-time cost. Its dates are unknown, so it does not change today's bill or the daily chart. Existing installations retain their history without being asked to import it again.

Requires macOS 14 or later. macOS 26 and later use native `NSGlassEffectView`; older systems use a translucent AppKit material. No third-party dependencies, administrator privileges, packet capture, network extension, or installed privileged helper are required. Application metering runs the macOS-provided `nettop` command as the current user.

## Build

With Xcode installed:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./scripts/build.sh
open build/NetFees.app
```

For a stable local code signature, copy `.netfees-signing.example` to `.netfees-signing.local` and select an identity available in your login keychain. The local file is ignored by Git. An explicit `CODE_SIGN_IDENTITY` environment variable takes precedence; the previous `SIGNING_IDENTITY` variable is also accepted. `NETFEES_LOCAL_SIGNING_CONFIG` can select a different local configuration file.

Without a configured identity, the script uses an ad hoc signature for local development. Certificate-based builds enable hardened runtime and a secure timestamp. Every build verifies the bundle signature. The script does not export certificates, submit for notarization, or publish anything. The current build targets the host architecture.

Copy the bundle to `~/Applications/NetFees.app` for a stable installation before enabling launch at login. The Swift package can also be opened directly in Xcode.

The CI and release workflows use an XcodeGen project, following the same build and signing steps as [Battakorey](https://github.com/cocoa-xu/Battakorey):

```sh
brew install xcodegen
./scripts/generate-project.sh
xcodebuild -project NetFees.xcodeproj -scheme NetFees -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

The generated Xcode project and icon are ignored by Git. `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY` can be provided by the local signing configuration or overridden through environment variables.

The CI workflow tests the app and builds a universal binary. The release workflow runs for `v*` tags, builds Universal, Apple Silicon, and Intel variants, creates DMGs, notarizes and staples them, and attaches them to a GitHub Release.

Release builds require these repository Secrets:

| Secret | Purpose |
| --- | --- |
| `DEV_ID_APP_CERTIFICATE_BASE64` | Base64-encoded Developer ID Application `.p12`, including its private key |
| `DEV_ID_APP_CERTIFICATE_PASSWORD` | Password for that `.p12` |
| `KEYCHAIN_PASSWORD` | Password for the temporary runner keychain |
| `DEV_ID_PROVISIONING_PROFILE_BASE64` | Base64-encoded Developer ID provisioning profile for `moe.uwucocoa.Netfees` |
| `TEAM_ID` | Developer team that owns the certificate and profile |
| `APPLE_ID` | Apple account used for notarization |
| `NOTARY_PASSWORD` | App-specific password for that Apple account |

The release workflow uses the automatically supplied `GITHUB_TOKEN` with `contents: write`. Apple Development certificates and a separate personal access token are not needed for this workflow. Never commit actual certificate, profile, or password values.

## What the meter counts

- The top menu bar line is **today's** download total. Both lines reset at the ledger's midnight; older totals remain in History.
- One GB means 1,000,000,000 bytes. The ledger stores exact byte totals and computes fees with decimal arithmetic, rounding only for display. Uploads never contribute to the fee.
- The meter samples 64-bit `NET_RT_IFLIST2` counters every second for `en` interfaces with numeric suffixes, normally Ethernet, Wi-Fi, and USB networking. It excludes `utun`, bridges, loopback, and peer-to-peer interfaces to avoid common double counting. VPN transport is counted on its underlying physical interface.
- These are interface totals, including local-network traffic, retransmissions, and protocol overhead. All measured receive traffic contributes to the cost at the fixed rate.
- Daily totals count traffic observed while the process runs. The optional first-launch import captures existing interface counters once, separately from daily totals. These counters cover each interface's lifetime since creation or reset, which is not necessarily the Mac's entire uptime. An added or reset interface receives a fresh baseline for daily metering.
- Sampling intervals crossing midnight are divided proportionally by elapsed time. The time zone chosen on first launch stays fixed for consistent historical days, including daylight-saving transitions.
- JSON history is saved atomically every 15 seconds, at midnight, before sleep, and on normal quit. A crash can lose at most the unsaved interval. An unreadable or unsupported history file is preserved, and an on-screen error explains that the current session cannot be saved.

Application history starts when the feature begins observing traffic. `nettop` provides non-loopback TCP/UDP process deltas approximately every two seconds; NetFees discards the initial cumulative frame, calculates rates from elapsed time, and groups helpers with their enclosing app or an identifiable parent app. Background services and standalone command-line programs remain separate entries. Distinct executable paths can have the same display name; hover over a name to see its path.

Application accounting is separate from the physical-interface bill. VPNs, proxies, shared services, connection lifetimes, and very short-lived processes can affect attribution. App totals need not add up to the interface total and are never added to that total a second time. Application sampling pauses during sleep, resets its baseline on restart, and resumes automatically after a counter-service failure. Unobserved traffic is not reconstructed per app.

Overall history lives at `~/Library/Application Support/NetFees/ledger.json`; application history lives alongside it in `applications.json`. Both are saved atomically. An unreadable application history is preserved. CSV exports distinguish daily rows from the optional initial import. There is no telemetry or automatic network request. External source links open only when clicked.

## Background

Inspired by [the original PDF joke](https://x.com/_mizmo/status/2116845910181196046) and [French amendment I-1358](https://www.assemblee-nationale.fr/dyn/17/amendements/3210A/AN/1358). NetFees uses the proposal's €0.055/GB rate for its fixed-rate download cost calculation.

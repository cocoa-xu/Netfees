# NetFees

Every byte has a price. Apparently.

A native macOS menu bar meter that turns your downloads into an imaginary French internet bill at **€0.055 per GB**. Real traffic, fictional debt, no payment button.

## Use

Open `build/NetFees.app`. The two menu bar lines show today's downloaded data and simulated fee. Click them for a glass panel with your bill, downloads, uploads, live transfer speeds, and a seven-day chart. History keeps every recorded day and exports CSV. The settings menu includes launch at login and access to the local history file.

Requires macOS 14 or later. macOS 26 and later use native `NSGlassEffectView`; older systems use a translucent AppKit material. No third-party dependencies, administrator privileges, packet capture, or network extension are required.

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

## What the meter counts

- The top menu bar line is **today's** download total. Both lines reset at the ledger's midnight; older totals remain in History.
- One GB means 1,000,000,000 bytes. The ledger stores exact byte totals and computes fees with decimal arithmetic, rounding only for display. Uploads never contribute to the fee.
- The meter samples 64-bit `NET_RT_IFLIST2` counters every second for `en` interfaces with numeric suffixes, normally Ethernet, Wi-Fi, and USB networking. It excludes `utun`, bridges, loopback, and peer-to-peer interfaces to avoid common double counting. VPN transport is counted on its underlying physical interface.
- These are interface totals, including local-network traffic, retransmissions, and protocol overhead. They cannot identify taxable internet content, provider revenue caps, or French destinations. This is a deliberately approximate parody of a gross volume charge.
- Only traffic observed while the process runs is counted. Startup takes a fresh baseline instead of billing all traffic since boot. An added or reset interface also receives a fresh baseline.
- Sampling intervals crossing midnight are divided proportionally by elapsed time. The time zone chosen on first launch stays fixed for consistent historical days, including daylight-saving transitions.
- JSON history is saved atomically every 15 seconds, at midnight, before sleep, and on normal quit. A crash can lose at most the unsaved interval. An unreadable or unsupported history file is preserved, and an on-screen error explains that the current session cannot be saved.

History lives at `~/Library/Application Support/NetFees/ledger.json`. There is no telemetry or automatic network request. External source links open only when clicked.

## Background

Inspired by [the original PDF joke](https://x.com/_mizmo/status/2116845910181196046) and [French amendment I-1358](https://www.assemblee-nationale.fr/dyn/17/amendements/3210A/AN/1358). The proposal concerns content providers' downstream traffic to French subscribers, not an upload-and-download retail tariff. NetFees intentionally displays an uncapped simulation, not money owed.

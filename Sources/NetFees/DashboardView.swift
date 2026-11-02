import SwiftUI
import Charts
import NetFeesCore

struct DashboardView: View {
    @ObservedObject var model: UsageModel
    @State private var selection = 0
    @State private var showAbout = false
    private let accent = Color(red: 0.95, green: 0.35, blue: 0.24)

    var body: some View {
        VStack(spacing: 12) {
            header
            if let imported = model.pendingInitialImport {
                initialImport(imported)
            } else {
                Picker("View", selection: $selection) {
                    Text("Today").tag(0)
                    Text("History").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if selection == 0 { today } else { history }
            }

            Spacer(minLength: 0)
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(20)
        .frame(width: 440, height: 680)
        .tint(accent)
        .background {
            ZStack {
                Circle().fill(accent.opacity(0.13)).frame(width: 240, height: 240)
                    .blur(radius: 65).offset(x: 165, y: -215)
                Circle().fill(Color.teal.opacity(0.08)).frame(width: 180, height: 180)
                    .blur(radius: 60).offset(x: -180, y: 130)
            }.allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(accent.gradient)
                Image(systemName: "eurosign.arrow.circlepath")
                    .font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
            }.frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text("netfees").font(.system(size: 24, weight: .heavy, design: .rounded)).tracking(-1)
                Text("Every byte accounted for.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showAbout.toggle() } label: {
                Image(systemName: "info.circle").font(.system(size: 17))
            }
            .buttonStyle(.plain)
            .help("Traffic measurement and pricing")
            .accessibilityLabel("About NetFees")
            .popover(isPresented: $showAbout, arrowEdge: .top) { about }
        }
    }

    private var today: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("TODAY'S NETWORK COST")
                    .font(.system(size: 10, weight: .bold)).tracking(1.8)
                    .foregroundStyle(.secondary)
                Text(Display.euros(model.today.fee, precise: true))
                    .font(.system(size: 42, weight: .light, design: .rounded))
                    .monospacedDigit().tracking(-2)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                    .accessibilityLabel("Today's network cost: \(Display.euros(model.today.fee, precise: true))")
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(accent)
                    Text("\(Display.bytes(model.today.downloadBytes)) × €0.055 / GB")
                        .foregroundStyle(.secondary)
                }.font(.system(size: 11, design: .monospaced))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.07)))

            HStack(spacing: 12) {
                trafficCard("Downloaded", symbol: "arrow.down", bytes: model.today.downloadBytes,
                            speed: model.rate.received, color: accent)
                trafficCard("Uploaded", symbol: "arrow.up", bytes: model.today.uploadBytes,
                            speed: model.rate.sent, color: .teal)
            }
            weekChart
            applicationList
        }
    }

    private func trafficCard(_ title: String, symbol: String, bytes: UInt64, speed: UInt64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
            Text(Display.bytes(bytes)).font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text("\(Display.bytes(speed))/s").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 17))
    }

    private var weekChart: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("THE LAST 7 DAYS").font(.system(size: 9, weight: .bold)).tracking(1.5)
                Spacer()
                Text(Display.euros(model.lastWeek.reduce(0) { $0 + $1.fee }, precise: true))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }.foregroundStyle(.secondary)
            Chart(model.lastWeek) { day in
                BarMark(x: .value("Day", String(day.id.suffix(5))),
                        y: .value("Cost in EUR", NSDecimalNumber(decimal: day.fee).doubleValue), width: .ratio(0.5))
                    .foregroundStyle(day.id == model.today.id ? accent : accent.opacity(0.28))
                    .cornerRadius(4)
                    .accessibilityLabel("\(day.id): \(Display.euros(day.fee, precise: true))")
            }
            .chartXScale(domain: model.lastWeekDays.map { String($0.suffix(5)) })
            .chartYScale(domain: 0...max(0.01, model.lastWeek.map { NSDecimalNumber(decimal: $0.fee).doubleValue }.max() ?? 0))
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks { _ in AxisValueLabel().font(.system(size: 9)) }
            }
            .frame(height: 46)
        }.padding(.horizontal, 3)
    }

    private var applicationList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("APPLICATIONS TODAY").font(.system(size: 9, weight: .bold)).tracking(1.3)
                Spacer()
                Text("DOWNLOAD COST").font(.system(size: 8, weight: .medium)).tracking(0.6)
            }.foregroundStyle(.secondary)
            Text(model.applicationStatus).font(.system(size: 9)).foregroundStyle(.tertiary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    let applications = model.applications(on: model.today.id)
                    if applications.isEmpty {
                        Text("Application traffic will appear as it is measured.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 24)
                    }
                    ForEach(applications) { application in
                        applicationRow(application, showRate: true)
                        Divider().opacity(0.35)
                    }
                }
            }
            .frame(minHeight: 110, maxHeight: .infinity)
        }
    }

    private func applicationRow(_ application: ApplicationUsageRow, showRate: Bool) -> some View {
        HStack(spacing: 9) {
            Image(nsImage: model.icon(for: application.identity))
                .resizable().scaledToFit().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(application.identity.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    .help(application.identity.bundlePath ?? String(application.identity.id.dropFirst("process:".count)))
                Text("↓ \(Display.bytes(application.record.downloadBytes)) · ↑ \(Display.bytes(application.record.uploadBytes))")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                Text(Display.applicationEuros(application.record.fee))
                    .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(accent)
                if showRate {
                    Text("↓ \(Display.bytes(application.rate.received))/s · ↑ \(Display.bytes(application.rate.sent))/s")
                        .font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func initialImport(_ imported: InitialTrafficImport) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your Mac already has a tab.").font(.system(size: 24, weight: .semibold, design: .rounded))
            Text("Include the traffic already counted by macOS?").font(.system(size: 13))
            VStack(alignment: .leading, spacing: 8) {
                Text(Display.euros(imported.fee, precise: true)).font(.system(size: 42, weight: .light, design: .rounded))
                Text("↓ \(Display.bytes(imported.traffic.received)) downloaded")
                Text("↑ \(Display.bytes(imported.traffic.sent)) uploaded")
            }.font(.system(size: 12, design: .monospaced))
            Text("These counters accumulate until a network interface resets. They may cover several days. Imported usage gets its own history entry, separate from today's measured traffic.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Import existing usage") { model.resolveInitialImport(include: true) }
                .buttonStyle(.borderedProminent)
            Button("Start from now") { model.resolveInitialImport(include: false) }
                .buttonStyle(.bordered)
            Text("Application history starts when NetFees begins observing each app.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("THE RUNNING TAB").font(.system(size: 9, weight: .bold)).tracking(1.5).foregroundStyle(.secondary)
                    Text(Display.euros(model.totalFee, precise: true))
                        .font(.system(size: 40, weight: .light, design: .rounded)).monospacedDigit()
                }
                Spacer()
                Button { model.exportCSV() } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }.buttonStyle(.bordered).controlSize(.small)
            }
            HStack {
                Text("DAY")
                Spacer()
                Text("DOWNLOAD / UPLOAD")
                Text("EUR").frame(width: 77, alignment: .trailing)
            }.font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let imported = model.ledger.includedInitialImport {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Before NetFees").font(.system(size: 12, weight: .semibold))
                                Text("Imported \(imported.capturedAt.formatted(date: .abbreviated, time: .omitted)) · dates unknown")
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                                Text("↓ \(Display.bytes(imported.traffic.received)) · ↑ \(Display.bytes(imported.traffic.sent))")
                                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Display.euros(imported.fee, precise: true)).font(.system(size: 11, weight: .medium, design: .monospaced))
                        }.padding(.vertical, 12)
                        Divider().opacity(0.45)
                    }
                    ForEach(model.ledger.sortedRecords) { day in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(day.id == model.today.id ? "Today" : String(day.id.suffix(5)))
                                    .font(.system(size: 12, weight: .semibold))
                                Text(String(day.id.prefix(4))).font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("↓ \(Display.bytes(day.downloadBytes))")
                                Text("↑ \(Display.bytes(day.uploadBytes))").foregroundStyle(.secondary)
                            }.font(.system(size: 10, design: .monospaced))
                            Text(Display.euros(day.fee, precise: true))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .frame(width: 90, alignment: .trailing)
                        }.padding(.vertical, 12)
                        let applications = model.applications(on: day.id)
                        if !applications.isEmpty {
                            DisclosureGroup("\(applications.count) applications") {
                                ForEach(applications) { application in
                                    applicationRow(application, showRate: false)
                                }
                            }.font(.system(size: 10)).padding(.bottom, 10)
                        }
                        Divider().opacity(0.45)
                    }
                }
            }.frame(maxHeight: .infinity)
            Text("Stored on this Mac · \(model.ledger.timeZoneIdentifier)")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Divider().opacity(0.5)
            HStack(spacing: 6) {
                Circle().fill(model.error == nil ? Color.green : Color.orange).frame(width: 5, height: 5)
                Text(model.interfaces.isEmpty ? "Waiting for a network interface" : "Metering this Mac")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Toggle("Launch at login", isOn: Binding(
                        get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    Button("Export history as CSV…") { model.exportCSV() }
                    Button("Show history file") { model.revealHistory() }
                    Divider()
                    Button("Quit NetFees", role: .destructive) { NSApp.terminate(nil) }
                        .keyboardShortcut("q")
                } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 13))
                }.menuStyle(.borderlessButton).fixedSize().help("Settings and export")
            }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("About NetFees").font(.title2.bold())
            Text("NetFees reads this Mac's network counters and records daily upload and download totals.")
            Text("Download costs are calculated at €0.055 per decimal GB (1,000,000,000 bytes). Uploads are measured separately and do not contribute to the cost.")
            Text("Metering covers en* network interfaces while NetFees runs, including local-network traffic and protocol overhead. VPN tunnels and loopback are excluded to avoid counting traffic twice. No packet contents are read.")
            Text("On first launch, existing interface totals can be imported as a separate history entry. Daily history records traffic observed while NetFees runs. Days use \(model.ledger.timeZoneIdentifier).")
            Text("Application totals and speeds use macOS TCP/UDP process counters, without administrator access. Helpers are grouped with their apps. VPNs, proxies, shared services, and short-lived processes can affect attribution, so app totals may differ from the physical-interface total.")
            Button("Read amendment I-1358 ↗") {
                if NSWorkspace.shared.open(URL(string: "https://www.assemblee-nationale.fr/dyn/17/amendements/3210A/AN/1358")!) {
                    showAbout = false
                }
            }.buttonStyle(.link)
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(24).frame(width: 360)
    }
}

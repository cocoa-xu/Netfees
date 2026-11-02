import SwiftUI
import Charts
import NetFeesCore

struct DashboardView: View {
    @ObservedObject var model: UsageModel
    @State private var selection = 0
    @State private var showAbout = false
    private let accent = Color(red: 0.95, green: 0.35, blue: 0.24)

    var body: some View {
        VStack(spacing: 18) {
            header
            Picker("View", selection: $selection) {
                Text("Today").tag(0)
                Text("History").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if selection == 0 {
                today
            } else {
                history
            }

            Spacer(minLength: 0)
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(24)
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
                    .font(.system(size: 23, weight: .semibold)).foregroundStyle(.white)
            }.frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("netfees").font(.system(size: 26, weight: .heavy, design: .rounded)).tracking(-1)
                Text("Every byte has a price. Apparently.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showAbout.toggle() } label: {
                Image(systemName: "info.circle").font(.system(size: 17))
            }
            .buttonStyle(.plain)
            .help("The joke, the rate, and the fine print")
            .accessibilityLabel("About NetFees")
            .popover(isPresented: $showAbout, arrowEdge: .leading) { about }
        }
    }

    private var today: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("TODAY'S INTERNET BILL")
                        .font(.system(size: 10, weight: .bold)).tracking(1.8)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("SIMULATED")
                        .font(.system(size: 8, weight: .heavy)).tracking(1)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(accent.opacity(0.12), in: Capsule())
                        .foregroundStyle(accent)
                }
                Text(Display.euros(model.today.fee, precise: true))
                    .font(.system(size: 57, weight: .light, design: .rounded))
                    .monospacedDigit().tracking(-2)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                    .accessibilityLabel("Today's simulated bill: \(Display.euros(model.today.fee, precise: true))")
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(accent)
                    Text("\(Display.bytes(model.today.downloadBytes)) × €0.055 / GB")
                        .foregroundStyle(.secondary)
                }.font(.system(size: 11, design: .monospaced))
                Rectangle().fill(.primary.opacity(0.09)).frame(height: 1)
                HStack {
                    Text("Thank you for your contribution.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "building.columns").foregroundStyle(accent.opacity(0.7))
                }
            }
            .padding(20)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.07)))

            HStack(spacing: 12) {
                trafficCard("Downloaded", symbol: "arrow.down", bytes: model.today.downloadBytes,
                            speed: model.rate.received, color: accent)
                trafficCard("Uploaded", symbol: "arrow.up", bytes: model.today.uploadBytes,
                            speed: model.rate.sent, color: .teal)
            }
            weekChart
        }
    }

    private func trafficCard(_ title: String, symbol: String, bytes: UInt64, speed: UInt64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
            Text(Display.bytes(bytes)).font(.system(size: 23, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text("\(Display.bytes(speed))/s").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 17))
    }

    private var weekChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("THE LAST 7 DAYS").font(.system(size: 9, weight: .bold)).tracking(1.5)
                Spacer()
                Text(Display.euros(model.lastWeek.reduce(0) { $0 + $1.fee }, precise: true))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }.foregroundStyle(.secondary)
            Chart(model.lastWeek) { day in
                BarMark(x: .value("Day", String(day.id.suffix(5))),
                        y: .value("Simulated EUR", NSDecimalNumber(decimal: day.fee).doubleValue), width: .ratio(0.5))
                    .foregroundStyle(day.id == model.today.id ? accent : accent.opacity(0.28))
                    .cornerRadius(4)
                    .accessibilityLabel("\(day.id): \(Display.euros(day.fee, precise: true))")
            }
            .chartYScale(domain: 0...max(0.01, model.lastWeek.map { NSDecimalNumber(decimal: $0.fee).doubleValue }.max() ?? 0))
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks { _ in AxisValueLabel().font(.system(size: 9)) }
            }
            .frame(height: 78)
            Text("Your imaginary debt. Meticulously documented.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }.padding(.horizontal, 3)
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
            Text("Real bytes. Fictional bill. Nothing to pay.")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The price of a byte.").font(.title2.bold())
            Text("Inspired by the French €0.055/GB proposal and a very expensive imaginary PDF download.")
            Text("NetFees multiplies received bytes by €0.055 per decimal GB (1,000,000,000 bytes). Uploads are shown but never charged.")
            Text("The proposal targets content providers sending data to French subscribers, with revenue-based caps. This uncapped parody is not your ISP bill or a tax assessment.")
            Text("Metering covers en* network interfaces while NetFees runs, including local-network traffic and protocol overhead. VPN tunnels and loopback are excluded to avoid counting traffic twice. No packet contents are read.")
            Text("History begins when you first open NetFees. Closed-app traffic is not recorded. Intervals spanning midnight are divided by elapsed time. Days use \(model.ledger.timeZoneIdentifier).")
            Link("Read amendment I-1358 ↗", destination: URL(string: "https://www.assemblee-nationale.fr/dyn/17/amendements/3210A/AN/1358")!)
            Link("The original PDF joke ↗", destination: URL(string: "https://x.com/_mizmo/status/2116845910181196046")!)
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(24).frame(width: 360)
    }
}

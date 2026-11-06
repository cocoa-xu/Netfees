import AppKit
import NetFeesCore

@MainActor
final class UniFiPreferences: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let model: UniFiModel
    private let enabled = NSButton(checkboxWithTitle: "Enable UniFi site meter", target: nil, action: nil)
    private let endpoint = NSTextField()
    private let key = NSSecureTextField()
    private let connect = NSButton(title: "Connect", target: nil, action: nil)
    private let site = NSPopUpButton()
    private let message = DashboardStyle.label(size: 11, color: .secondaryLabelColor)
    private let save = NSButton(title: "Save", target: nil, action: nil)
    private let disconnect = NSButton(title: "Disconnect", target: nil, action: nil)
    private var sites: [UniFiSite] = []
    private var connectedEndpoint: UniFiEndpoint?
    private var connectedKey: String?
    private var certificatePin: String?
    private var task: Task<Void, Never>?

    init(model: UniFiModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "UniFi Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: 520, height: 440))
        window.contentView = content
        let introduction = DashboardStyle.paragraph("See your whole site's Internet usage and download cost. Connect directly to a UniFi OS console with a local API key from Integrations.", width: 472, size: 12)
        introduction.frame.origin = NSPoint(x: 24, y: 20)
        content.addSubview(introduction)
        enabled.frame = NSRect(x: 24, y: 76, width: 400, height: 24)
        enabled.target = self
        enabled.action = #selector(toggleEnabled)
        content.addSubview(enabled)
        let endpointLabel = DashboardStyle.label("Endpoint", weight: .medium)
        let keyLabel = DashboardStyle.label("API key", weight: .medium)
        let siteLabel = DashboardStyle.label("Site", weight: .medium)
        for (label, y) in [(endpointLabel, 119.0), (keyLabel, 161.0), (siteLabel, 242.0)] {
            label.frame = NSRect(x: 24, y: y, width: 86, height: 20)
            content.addSubview(label)
        }
        endpoint.frame = NSRect(x: 112, y: 114, width: 384, height: 26)
        endpoint.placeholderString = "https://unifi.example.com"
        endpoint.setAccessibilityLabel("UniFi endpoint")
        endpoint.delegate = self
        key.frame = NSRect(x: 112, y: 156, width: 384, height: 26)
        key.setAccessibilityLabel("UniFi API key")
        key.delegate = self
        connect.frame = NSRect(x: 386, y: 194, width: 110, height: 28)
        site.frame = NSRect(x: 112, y: 236, width: 384, height: 28)
        site.setAccessibilityLabel("UniFi site")
        message.maximumNumberOfLines = 0
        message.lineBreakMode = .byWordWrapping
        message.frame = NSRect(x: 24, y: 280, width: 472, height: 76)
        let privacy = DashboardStyle.paragraph("The API key stays in macOS Keychain. Only WAN statistics are read. Disabling UniFi stops requests and hides the panel.", width: 472, size: 10)
        privacy.frame.origin = NSPoint(x: 24, y: 354)
        disconnect.frame = NSRect(x: 18, y: 394, width: 112, height: 30)
        save.frame = NSRect(x: 400, y: 394, width: 102, height: 30)
        save.keyEquivalent = "\r"
        for (button, action) in [(connect, #selector(connectToConsole)), (save, #selector(saveSettings)), (disconnect, #selector(disconnectConsole))] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        [endpoint, key, connect, site, message, privacy, disconnect, save].forEach { content.addSubview($0) }
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        invalidateConnection()
        let config = model.configuration
        endpoint.stringValue = config?.endpoint.url.absoluteString ?? ""
        key.stringValue = ""
        key.placeholderString = config == nil ? "Local console API key" : "Leave blank to use the key in Keychain"
        enabled.state = config?.enabled == false ? .off : .on
        disconnect.isHidden = config == nil
        message.stringValue = model.settingsError ?? "Connect to load the sites available to this key."
        if let config {
            sites = [config.site]
            site.addItem(withTitle: config.site.displayName)
        }
        updateControls()
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        invalidateConnection()
        key.stringValue = ""
    }

    func controlTextDidChange(_ obj: Notification) {
        invalidateConnection()
        message.stringValue = "Connect to verify the updated connection."
        updateControls()
    }

    private func invalidateConnection() {
        task?.cancel()
        task = nil
        connectedEndpoint = nil
        connectedKey = nil
        certificatePin = nil
        sites = []
        site.removeAllItems()
    }

    private func updateControls() {
        let on = enabled.state == .on
        endpoint.isEnabled = on
        key.isEnabled = on
        connect.isEnabled = on && task == nil
        site.isEnabled = on && connectedEndpoint != nil
        save.isEnabled = !on || connectedEndpoint != nil
    }

    @objc private func toggleEnabled() {
        if enabled.state == .off { invalidateConnection() }
        message.stringValue = enabled.state == .off ? "UniFi will be disabled when you save." : "Connect to load the sites available to this key."
        updateControls()
    }

    @objc private func connectToConsole() {
        do {
            let address = try UniFiEndpoint(endpoint.stringValue)
            var secret = key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if secret.isEmpty, let config = model.configuration, config.endpoint == address {
                secret = try UniFiKeychain.read(account: config.keychainAccount, endpoint: address, certificatePin: config.certificatePin, interactive: true)
            }
            guard !secret.isEmpty, !secret.contains(where: { $0.isNewline }) else { throw UniFiError.key }
            invalidateConnection()
            var pin = model.configuration?.endpoint == address ? model.configuration?.certificatePin : nil
            message.stringValue = "Connecting to UniFi…"
            task = Task { [weak self] in
                guard let self else { return }
                for attempt in 0..<2 {
                    do {
                        let client = UniFiClient(endpoint: address, key: secret, certificatePin: pin)
                        let sites = try await client.sites()
                        guard !Task.isCancelled else { return }
                        guard !sites.isEmpty else { throw UniFiError.forbidden }
                        self.sites = sites
                        self.site.removeAllItems()
                        self.site.addItems(withTitles: sites.map(\.displayName))
                        if let old = self.model.configuration?.site.id, let index = sites.firstIndex(where: { $0.id == old }) { self.site.selectItem(at: index) }
                        self.connectedEndpoint = address
                        self.connectedKey = secret
                        self.certificatePin = pin
                        self.message.stringValue = "Connected. Choose a site and save. Costs use gateway WAN byte statistics, separate from this Mac."
                        break
                    } catch {
                        guard !Task.isCancelled else { return }
                        if case UniFiError.certificate(let fingerprint) = error, attempt == 0, self.approveCertificate(fingerprint, endpoint: address, changed: pin != nil) {
                            pin = fingerprint
                            continue
                        }
                        self.message.stringValue = (error as? LocalizedError)?.errorDescription ?? UniFiError.response.localizedDescription
                        break
                    }
                }
                self.task = nil
                self.updateControls()
            }
            updateControls()
        } catch { message.stringValue = error.localizedDescription }
    }

    private func approveCertificate(_ fingerprint: String, endpoint: UniFiEndpoint, changed: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = changed ? "The UniFi certificate changed" : "Trust this UniFi console certificate?"
        alert.informativeText = "\(endpoint.url.host ?? "UniFi") uses an untrusted certificate. Verify its SHA-256 fingerprint with your console before trusting it. This trust applies only to this endpoint.\n\n\(fingerprint)"
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Trust Certificate")
        return alert.runModal() == .alertSecondButtonReturn
    }

    @objc private func saveSettings() {
        do {
            if enabled.state == .off { try model.setEnabled(false) }
            else {
                guard let endpoint = connectedEndpoint, let key = connectedKey,
                      sites.indices.contains(site.indexOfSelectedItem) else { return }
                try model.save(endpoint: endpoint, site: sites[site.indexOfSelectedItem], key: key, certificatePin: certificatePin, enabled: true)
            }
            close()
        } catch { message.stringValue = error.localizedDescription }
    }

    @objc private func disconnectConsole() {
        do { try model.disconnect(); close() }
        catch { message.stringValue = error.localizedDescription }
    }
}

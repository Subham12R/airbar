import AirCloudKit
import AppKit
import SwiftUI

struct SettingsView: View {
    enum Tab: String, CaseIterable { case account = "Account", devices = "Devices", general = "General", about = "About" }
    @AppStorage("settingsTab") private var stored = Tab.account.rawValue
    var forced: Tab? = nil

    init(tab: Tab? = nil) { forced = tab }

    private var tab: Binding<Tab> {
        Binding(get: { forced ?? Tab(rawValue: stored) ?? .account }, set: { stored = $0.rawValue })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .frame(maxWidth: 380)
            .frame(maxWidth: .infinity)
            switch tab.wrappedValue {
            case .account: AccountPane()
            case .devices: DevicesPane()
            case .general: GeneralPane()
            case .about: AboutPane()
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(width: 560, height: 620)
    }
}

// MARK: - Account

struct AccountPane: View {
    @Environment(Store.self) var store
    enum Method: String, CaseIterable { case phone = "Phone", email = "Email" }
    @State private var method: Method = .phone
    @State private var country = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    private var canSubmit: Bool {
        password.count >= 4 && (method == .email ? email.contains("@") : phone.filter(\.isNumber).count >= 6)
    }

    var body: some View {
        if store.signedIn {
            VStack(alignment: .leading, spacing: 12) {
                Label("Signed in to airCloud", systemImage: "checkmark.seal.fill").font(.system(size: 14, weight: .semibold))
                HStack {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 28)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.account ?? "Account").font(.system(size: 13, weight: .medium))
                        Text("\(store.units.count) air conditioner\(store.units.count == 1 ? "" : "s") · password kept in your Keychain")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sign out") { Task { await store.signOut() } }.buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(16).card(16)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Sign in with the same account as the airCloud Go app.").font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("", selection: $method) { ForEach(Method.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                if method == .phone {
                    HStack(spacing: 8) {
                        HStack(spacing: 2) {
                            Text("+").foregroundStyle(.secondary)
                            TextField(store.config.defaultCountryCode, text: $country).textFieldStyle(.plain).frame(width: 34)
                        }
                        .font(.system(size: 13)).padding(.horizontal, 12).padding(.vertical, 9).card(10)
                        Field(placeholder: "Mobile number", text: $phone, icon: "phone")
                    }
                } else {
                    Field(placeholder: "Email", text: $email, icon: "envelope")
                }
                Field(placeholder: "Password", text: $password, secure: true, icon: "lock")
                HStack {
                    StatusLine(error: error)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button("Sign in") { submit() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!canSubmit || busy)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16).card(16)
        }
    }

    private func submit() {
        busy = true
        error = nil
        let m: SignInMethod = method == .email
            ? .email(email)
            : .phone(countryCode: country.isEmpty ? store.config.defaultCountryCode : country, number: phone)
        Task {
            do {
                try await store.signIn(m, password: password)
                password = ""
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: - General

struct GeneralPane: View {
    @Environment(Store.self) var store

    var body: some View {
        @Bindable var s = store
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Open AirBar at login", isOn: Binding(get: { store.launchAtLogin }, set: { store.launchAtLogin = $0 }))
            Toggle("Show the set temperature in the menu bar", isOn: $s.config.showTemperatureInMenuBar)
                .onChange(of: store.config.showTemperatureInMenuBar) { store.saveConfig() }
            HStack {
                Text("Refresh every")
                Picker("", selection: $s.config.refreshIntervalSeconds) {
                    Text("15 seconds").tag(15.0); Text("30 seconds").tag(30.0); Text("45 seconds").tag(45.0)
                    Text("1 minute").tag(60.0); Text("2 minutes").tag(120.0)
                }
                .labelsHidden().frame(width: 140)
                .onChange(of: store.config.refreshIntervalSeconds) { store.saveConfig() }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Advanced settings live in a JSON file (server URLs, timing, default country code).")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                HStack {
                    Button("Open config file") { NSWorkspace.shared.open(AirBarConfig.fileURL) }.buttonStyle(SecondaryButtonStyle())
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AirBarConfig.fileURL]) }
                        .buttonStyle(SecondaryButtonStyle())
                }
                Text("Restart AirBar after editing the file.").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12.5))
        .padding(16).card(16)
    }
}

// MARK: - About

struct AboutPane: View {
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "air.conditioner.horizontal.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.accent))
                VStack(alignment: .leading, spacing: 2) {
                    Text("AirBar \(version)").font(.system(size: 15, weight: .semibold))
                    Text("Your Hitachi AC and HomeMate lights, from the menu bar.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("GitHub") { open("https://github.com/Subham12R/airbar") }.buttonStyle(SecondaryButtonStyle())
                Button("Report an issue") { open("https://github.com/Subham12R/airbar/issues/new/choose") }.buttonStyle(SecondaryButtonStyle())
            }
            Text("AirBar is an independent open-source project. It is not affiliated with, endorsed by, or supported by Hitachi, Johnson Controls-Hitachi Air Conditioning, airCloud, HomeMate or Tuya. Product names are trademarks of their owners.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).card(16)
    }

    private func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }
}

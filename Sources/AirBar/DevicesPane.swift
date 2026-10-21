import AppKit
import SwiftUI
import TuyaKit

/// Settings › Devices: linked HomeMate / Tuya devices, the Tuya Cloud link, and adding devices.
struct DevicesPane: View {
    @Environment(Store.self) var store
    @State private var pairing = false
    @State private var manual = false

    var body: some View {
        if pairing {
            PairingView { pairing = false }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !store.devices.isEmpty { LinkedDevices() }
                    CloudCard()
                    Button { pairing = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(store.cloudConnected ? Theme.accent : Color.gray.opacity(0.45)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Add a device").font(.system(size: 13, weight: .semibold))
                                Text(store.cloudConnected ? "Scan, enter your Wi-Fi password, and AirBar connects it."
                                                          : "Connect Tuya Cloud above first.")
                                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(Pressable())
                    .card(16)
                    .disabled(!store.cloudConnected)
                    .opacity(store.cloudConnected ? 1 : 0.6)

                    DisclosureGroup(isExpanded: $manual) { ManualAdd().padding(.top, 8) } label: {
                        Text("Add with a local key").font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 4)
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
        }
    }
}

struct LinkedDevices: View {
    @Environment(Store.self) var store
    @State private var editing: String?
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Linked devices", systemImage: "lightbulb.2").font(.system(size: 13, weight: .semibold))
            ForEach(store.devices) { d in
                let st = store.deviceStates[d.id]
                HStack(spacing: 10) {
                    BulbGlyph(on: st?.online ?? false, color: d.isLight ? Theme.warm : Theme.accent, size: 26)
                    if editing == d.id {
                        TextField("Name", text: $newName, onCommit: { store.rename(d.id, to: newName); editing = nil })
                            .textFieldStyle(.roundedBorder)
                    } else {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.name).font(.system(size: 12.5, weight: .medium))
                            Text("\(d.isLight ? "Light" : "\(d.toggles.count) switch\(d.toggles.count == 1 ? "" : "es")") · \(d.ip.isEmpty ? "IP unknown" : d.ip) · v\(d.version)\(st?.online == false ? " · unreachable" : "")")
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button { editing = d.id; newName = d.name } label: { Image(systemName: "pencil") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Rename")
                    Button { store.removeDevice(d.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove")
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).card(16)
    }
}

struct CloudCard: View {
    @Environment(Store.self) var store
    @State private var accessId = ""
    @State private var secret = ""
    @State private var region = "in"
    @State private var busy = false
    @State private var error: String?
    @State private var success: String?
    @State private var showHow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.cloudConnected {
                Label("Tuya Cloud connected", systemImage: "checkmark.seal.fill").font(.system(size: 13, weight: .semibold))
                Text("New devices you pair, and devices already in your Smart Life account, are imported with their local keys. Control stays on your Wi-Fi.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Import devices") { run { "Imported \(try await store.importFromCloud()) device(s)." } }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Disconnect") { Task { await store.disconnectCloud() } }.buttonStyle(SecondaryButtonStyle())
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                }
            } else {
                Label("Connect Tuya Cloud (once)", systemImage: "cloud").font(.system(size: 13, weight: .semibold))
                Text("HomeMate devices are Tuya hardware, but the HomeMate app won't share them with other apps. A free Tuya developer project lets AirBar pair devices itself and read their local keys. After that, everything runs on your Wi-Fi.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup(isExpanded: $showHow) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. Sign up at iot.tuya.com and create a Cloud project (Smart Home, your region's data center).")
                        Text("2. In the project: Devices › Link App Account › Add App Account, and scan the QR with the Smart Life app.")
                        Text("3. Copy the project's Access ID and Access Secret from Overview into the fields below.")
                        Button("Open iot.tuya.com") { NSWorkspace.shared.open(URL(string: "https://iot.tuya.com/cloud/")!) }.buttonStyle(.link)
                    }
                    .font(.system(size: 11.5)).padding(.top, 4)
                } label: { Text("How to get these").font(.system(size: 11.5, weight: .medium)) }
                Field(placeholder: "Access ID", text: $accessId, icon: "person.badge.key")
                Field(placeholder: "Access Secret", text: $secret, secure: true, icon: "key")
                HStack {
                    Picker("Data center", selection: $region) {
                        ForEach(TuyaCloud.regions, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .frame(width: 220)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button("Connect") {
                        run { "Connected. Imported \(try await store.connectCloud(accessId: accessId, secret: secret, region: region)) device(s)." }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(accessId.count < 10 || secret.count < 10 || busy)
                }
            }
            StatusLine(error: error, success: success)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).card(16)
    }

    private func run(_ op: @escaping () async throws -> String) {
        busy = true; error = nil; success = nil
        Task {
            do { success = try await op(); secret = "" } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

struct ManualAdd: View {
    @Environment(Store.self) var store
    @State private var lan: [DiscoveredDevice] = []
    @State private var scanning = false
    @State private var id = ""
    @State private var name = ""
    @State private var key = ""
    @State private var ip = ""
    @State private var busy = false
    @State private var error: String?
    @State private var success: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Devices on your Wi-Fi").font(.system(size: 11.5, weight: .medium))
                Spacer()
                Button(scanning ? "Scanning…" : "Scan") { scan() }.buttonStyle(SecondaryButtonStyle()).disabled(scanning)
            }
            ForEach(lan) { d in
                let linked = store.devices.contains { $0.id == d.id }
                Button { id = d.id; ip = d.ip } label: {
                    HStack {
                        Image(systemName: id == d.id ? "largecircle.fill.circle" : "circle")
                        Text(d.id).font(.system(size: 11.5))
                        Spacer()
                        Text(linked ? "linked" : "\(d.ip) · v\(d.version)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Field(placeholder: "Device ID", text: $id, icon: "cpu")
            Field(placeholder: "Name (e.g. Desk Lamp)", text: $name, icon: "tag")
            Field(placeholder: "Local key (16 characters)", text: $key, secure: true, icon: "key")
            Field(placeholder: "IP address (optional)", text: $ip, icon: "network")
            HStack {
                StatusLine(error: error, success: success)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Add device") { add() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(id.isEmpty || key.count != 16 || busy)
            }
        }
        .padding(14).card(16)
        .onAppear { if lan.isEmpty { scan() } }
    }

    private func scan() {
        scanning = true
        Task { lan = await TuyaDiscovery.scan(seconds: 6).sorted { $0.ip < $1.ip }; scanning = false }
    }

    private func add() {
        busy = true; error = nil; success = nil
        Task {
            do {
                try await store.addManually(id: id.trimmingCharacters(in: .whitespaces), key: key, name: name, ip: ip)
                success = "Added \(name.isEmpty ? "the device" : name)."
                key = ""
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

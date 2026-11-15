import SwiftUI

enum CarrierStyle {
    static let accent = Color(uiColor: .systemBlue)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
}

extension View {
    func carrierScreen() -> some View {
        self.listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(CarrierStyle.background)
            .tint(CarrierStyle.accent)
    }
}

/// Delegate appearance, pressed/disabled states and contrast to the system.
struct CarrierActionStyle: PrimitiveButtonStyle {
    var prominent = true
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        let button = Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.frame(maxWidth: .infinity, minHeight: 24)
        }.controlSize(.large)
        if prominent { button.buttonStyle(.borderedProminent) }
        else { button.buttonStyle(.bordered) }
    }
}

/// Stacks label and value at accessibility text sizes instead of truncating either.
struct ValueRow: View {
    let title: String
    let value: String
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).foregroundStyle(.secondary)
                    Text(value).textSelection(.enabled)
                }
            } else {
                LabeledContent { Text(value).textSelection(.enabled) } label: { Text(title) }
            }
        }.accessibilityElement(children: .combine)
    }
}

struct OverviewHero: View {
    let hasPairing: Bool
    let device: DeviceSnapshot?
    @ScaledMetric(relativeTo: .title2) private var iconSize = 56.0
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                Image("BrandMark").resizable().scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .clipShape(RoundedRectangle(cornerRadius: 14)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("CarrierSelector").font(.title2.bold())
                    Text("Профили операторов").font(.subheadline).foregroundStyle(.secondary)
                }.fixedSize(horizontal: false, vertical: true)
            }
            Label(device != nil ? "Данные iPhone получены" : hasPairing ? "Pairing сохранён" : "Начните с подключения",
                  systemImage: device != nil ? "checkmark.circle" : "link")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(CarrierStyle.surface, in: RoundedRectangle(cornerRadius: 24))
    }
}

extension CarrierProfile {
    var bundleName: String { identifier.replacingOccurrences(of: "com.apple.", with: "") }
    var displayName: String {
        let parts = name.components(separatedBy: " · ")
        return parts.count > 1 && !parts[1].isEmpty ? parts[1] : bundleName
    }
    var regionLabel: String {
        let suffix = bundleName.split(separator: "_").last.map(String.init) ?? ""
        return suffix.count == 2 ? suffix.uppercased() : "SIM"
    }
}

struct ProfileCatalogRow: View {
    let profile: CarrierProfile
    let operators: String?
    let favorite: Bool
    var body: some View {
        HStack(spacing: 15) {
            Text(profile.regionLabel).font(.system(.subheadline, design: .monospaced, weight: .bold))
                .foregroundStyle(CarrierStyle.accent)
                .frame(width: 48, height: 54)
                .background(CarrierStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 15))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(profile.displayName).font(.headline)
                Text("\(profile.bundleName) · \(profile.version)").font(.caption).foregroundStyle(.secondary)
                if let operators {
                    Text(operators).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.orange).accessibilityLabel("В избранном") }
        }.padding(.vertical, 8)
    }
}

struct CreditsSection: View {
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                credit("GitHub · dreamw0rk", subtitle: "Автор iOS-приложения", url: "https://github.com/dreamw0rk")
                credit("yvl86 · 4PDA", subtitle: "Автор исходного CarrierSelector", url: "https://4pda.to/forum/index.php?showuser=4294738")
            }.padding(.vertical, 8)
        }.listRowBackground(Color.clear)
    }
    private func credit(_ title: String, subtitle: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 12) {
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.subheadline)
                    .frame(width: 28).foregroundStyle(CarrierStyle.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }.frame(minHeight: 52)
        }.buttonStyle(.plain)
    }
}

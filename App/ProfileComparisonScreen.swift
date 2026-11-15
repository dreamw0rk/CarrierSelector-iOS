import SwiftUI

struct ProfileComparisonScreen: View {
    let profile: CarrierProfile
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List {
            if let device = model.device, let line = model.selectedLine {
                let comparison = ProfileComparison(current: line, selected: profile, device: device,
                    profiles: model.catalog.profiles, research: model.catalog.research)
                Section {
                    ValueRow(title: "SIM", value: line.maskedIdentity)
                    ValueRow(title: "Текущий пакет", value: line.bundleID.replacingOccurrences(of: "com.apple.", with: "") + " · " + line.version)
                    ValueRow(title: "Выбранный пакет", value: profile.bundleName + " · " + profile.version)
                } footer: {
                    Text("Сравниваются настройки пакетов из каталога для этой модели iPhone. Это не измерение работающих услуг.")
                }
                if !comparison.currentFound {
                    Section {
                        Text("В каталоге нет текущего пакета с версией \(line.version). Его настройки неизвестны.")
                            .foregroundStyle(.secondary)
                    }
                }
                ComparisonSections(comparison: comparison)
            } else {
                ContentUnavailableView("Выберите SIM", systemImage: "simcard", description: Text("Подключите iPhone и выберите линию на экране установки."))
            }
        }.carrierScreen().navigationTitle("Сравнение профилей").navigationBarTitleDisplayMode(.inline)
    }
}

struct ComparisonSections: View {
    let comparison: ProfileComparison
    var firstLabel = "Текущий"
    var secondLabel = "Выбранный"
    var body: some View {
        Section("Отличаются · \(comparison.changed.count)") {
            if comparison.changed.isEmpty {
                Text(comparison.unknown.isEmpty ? "Сравниваемые настройки совпадают." : "В доступных данных отличий нет. Часть настроек сравнить не удалось.").foregroundStyle(.secondary)
            }
            ForEach(comparison.changed) { ComparisonRow(difference: $0, firstLabel: firstLabel, secondLabel: secondLabel) }
        }
        if !comparison.unknown.isEmpty {
            Section("Недостаточно данных · \(comparison.unknown.count)") {
                ForEach(comparison.unknown) { ComparisonRow(difference: $0, firstLabel: firstLabel, secondLabel: secondLabel) }
            }
        }
        if !comparison.unchanged.isEmpty {
            Section {
                DisclosureGroup("Совпадают · \(comparison.unchanged.count)") {
                    ForEach(comparison.unchanged) { ComparisonRow(difference: $0, firstLabel: firstLabel, secondLabel: secondLabel) }
                }
            }
        }
    }
}

private struct ComparisonRow: View {
    let difference: ProfileDifference
    let firstLabel: String
    let secondLabel: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(difference.title, systemImage: difference.changed ? "arrow.triangle.2.circlepath" : difference.comparable ? "equal.circle" : "questionmark.circle").font(.headline)
            ValueRow(title: firstLabel, value: difference.current.text)
            ValueRow(title: secondLabel, value: difference.selected.text)
        }.font(.subheadline).padding(.vertical, 6)
    }
}

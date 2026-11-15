import SwiftUI

struct OperationErrorContent: View {
    @EnvironmentObject private var model: AppModel
    var openConnection: (() -> Void)? = nil
    var body: some View {
        if let error = model.lastError {
            VStack(alignment: .leading, spacing: 12) {
                Label(model.connectionFailure?.title ?? model.status, systemImage: "exclamationmark.circle").font(.headline)
                Text(error).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                if let issue = model.connectionFailure {
                    if issue.needsPairing, let openConnection {
                        Button("Настройки подключения", action: openConnection).disabled(model.busy)
                    } else if !issue.needsPairing {
                        Button("Повторить подключение") { model.connect() }.disabled(model.busy)
                    }
                    if let technical = issue.technical {
                        DisclosureGroup("Технические сведения") { Text(technical).font(.caption.monospaced()) }
                            .font(.subheadline)
                    }
                }
            }
        }
    }
}

struct CatalogProgressContent: View {
    let progress: DownloadProgress
    let cancel: () -> Void
    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch progress.phase {
            case .downloading:
                HStack {
                    Text("Загрузка пакетов").font(.headline)
                    Spacer()
                    if let fraction = progress.fraction { Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit() }
                }
                ProgressView(value: progress.fraction).progressViewStyle(.linear)
                    .accessibilityLabel("Загрузка пакетов")
                Text(progress.expected.map { "\(bytes(progress.received)) из \(bytes($0))" } ?? "Скачано \(bytes(progress.received))")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Приостановить", action: cancel).buttonStyle(CarrierActionStyle(prominent: false))
            case .validating:
                ProgressView("Проверка пакетов…")
                Text("Файл загружен. Проверяется целостность.").font(.subheadline).foregroundStyle(.secondary)
            case .cancelling:
                ProgressView("Остановка загрузки…")
            }
        }.padding(.vertical, 4)
    }
}

struct CatalogDownloadSection: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        if let progress = model.downloadProgress {
            Section { CatalogProgressContent(progress: progress, cancel: model.cancelCatalogDownload) }
        } else if model.downloadRetryAvailable {
            Section {
                Text(model.downloadMessage ?? "Пакеты не загружены.").font(.subheadline)
                Button(model.downloadCanResume ? "Продолжить загрузку" : "Загрузить заново", action: model.downloadCatalog).disabled(model.busy)
                if model.downloadCanResume { Button("Начать с начала", action: model.restartCatalogDownload).disabled(model.busy) }
            } footer: { Text(model.downloadCanResume ? "Если сохранённые данные больше недоступны, загрузка начнётся с начала." : "Продолжить эту попытку нельзя. Пакеты будут загружены заново.") }
        }
    }
}

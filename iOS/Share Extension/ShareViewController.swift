import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let appGroup = "group.com.ao.SendFile-over-WiFi"
    private var finished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let label = UILabel()
        label.text = text("addingFiles")
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        importAttachments()
    }

    private func importAttachments() {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            finish()
            return
        }
        let inbox = container.appendingPathComponent("Share Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else { finish(); return }

        let group = DispatchGroup()
        for provider in providers {
            guard let typeIdentifier = provider.registeredTypeIdentifiers.first else { continue }
            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { source, _ in
                defer { group.leave() }
                guard let source else { return }
                let extensionPart = source.pathExtension.isEmpty ? "" : ".\(source.pathExtension)"
                let destination = inbox.appendingPathComponent("\(UUID().uuidString)\(extensionPart)")
                try? FileManager.default.copyItem(at: source, to: destination)
            }
        }
        group.notify(queue: .main) { [weak self] in self?.finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        let alert = UIAlertController(
            title: text("filesAdded"),
            message: text("openAppToSend"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: text("done"), style: .default) { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        present(alert, animated: true)
    }

    private func text(_ key: String) -> String {
        let preference = UserDefaults(suiteName: appGroup)?.string(forKey: "language") ?? ""
        let language: String
        if ["en", "ru", "it", "es", "pt", "cn"].contains(preference) {
            language = preference
        } else {
            let identifier = Locale.preferredLanguages.first?.lowercased() ?? "en"
            if identifier.hasPrefix("ru") { language = "ru" }
            else if identifier.hasPrefix("it") { language = "it" }
            else if identifier.hasPrefix("es") { language = "es" }
            else if identifier.hasPrefix("pt") { language = "pt" }
            else if identifier.hasPrefix("zh") { language = "cn" }
            else { language = "en" }
        }
        let strings: [String: [String: String]] = [
            "addingFiles": ["en": "Adding files to SendFile over WiFi…", "ru": "Добавляем файлы в SendFile over WiFi…", "it": "Aggiunta dei file a SendFile over WiFi…", "es": "Añadiendo archivos a SendFile over WiFi…", "pt": "Adicionando arquivos ao SendFile over WiFi…", "cn": "正在将文件添加到 SendFile over WiFi…"],
            "filesAdded": ["en": "Files added", "ru": "Файлы добавлены", "it": "File aggiunti", "es": "Archivos añadidos", "pt": "Arquivos adicionados", "cn": "文件已添加"],
            "openAppToSend": ["en": "Open SendFile over WiFi: the selected files will appear in the send list.", "ru": "Откройте SendFile over WiFi: выбранные файлы появятся в списке отправки.", "it": "Apri SendFile over WiFi: i file selezionati appariranno nell'elenco di invio.", "es": "Abra SendFile over WiFi: los archivos seleccionados aparecerán en la lista de envío.", "pt": "Abra o SendFile over WiFi: os arquivos selecionados aparecerão na lista de envio.", "cn": "打开 SendFile over WiFi：所选文件将显示在发送列表中。"],
            "done": ["en": "Done", "ru": "Готово", "it": "Fine", "es": "Listo", "pt": "Concluído", "cn": "完成"]
        ]
        return strings[key]?[language] ?? strings[key]?["en"] ?? key
    }
}

import Foundation

/// UI localisation independent of the language used by the operating system.
/// An empty preference means "follow the supported system language".
enum AppLocalization {
    static let supportedLanguages = ["en", "ru", "it", "es", "pt", "cn"]

    static func resolvedLanguage(_ preference: String = UserDefaults.standard.string(forKey: "language") ?? "") -> String {
        if supportedLanguages.contains(preference) { return preference }
        for identifier in Locale.preferredLanguages.map({ $0.lowercased() }) {
            if identifier.hasPrefix("ru") { return "ru" }
            if identifier.hasPrefix("it") { return "it" }
            if identifier.hasPrefix("es") { return "es" }
            if identifier.hasPrefix("pt") { return "pt" }
            if identifier.hasPrefix("zh") { return "cn" }
            if identifier.hasPrefix("en") { return "en" }
        }
        return "en"
    }

    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        let language = resolvedLanguage()
        let value = sharedStrings[key]?[language] ?? sharedStrings[key]?["en"] ?? strings[key]?[language] ?? strings[key]?["en"] ?? key
        return arguments.isEmpty ? value : String(format: value, locale: Locale(identifier: language == "cn" ? "zh_Hans" : language), arguments: arguments)
    }

    static func languageName(_ code: String) -> String { text("language.\(code)") }

    private struct SharedCatalog: Decodable { let strings: [String: [String: String]] }
    private static let sharedStrings: [String: [String: String]] = {
        guard let url = Bundle.main.url(forResource: "ui", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(SharedCatalog.self, from: data) else { return [:] }
        return catalog.strings
    }()

    private static let strings: [String: [String: String]] = [
        "automatic": ["en": "Automatic", "ru": "Автоматически", "it": "Automatico", "es": "Automático", "pt": "Automático", "cn": "自动"],
        "language.en": ["en": "English", "ru": "Английский", "it": "Inglese", "es": "Inglés", "pt": "Inglês", "cn": "英语"],
        "language.ru": ["en": "Russian", "ru": "Русский", "it": "Russo", "es": "Ruso", "pt": "Russo", "cn": "俄语"],
        "language.it": ["en": "Italian", "ru": "Итальянский", "it": "Italiano", "es": "Italiano", "pt": "Italiano", "cn": "意大利语"],
        "language.es": ["en": "Spanish", "ru": "Испанский", "it": "Spagnolo", "es": "Español", "pt": "Espanhol", "cn": "西班牙语"],
        "language.pt": ["en": "Portuguese", "ru": "Португальский", "it": "Portoghese", "es": "Portugués", "pt": "Português", "cn": "葡萄牙语"],
        "language.cn": ["en": "Chinese", "ru": "Китайский", "it": "Cinese", "es": "Chino", "pt": "Chinês", "cn": "中文"],
        "ready": ["en": "Ready", "ru": "Готово", "it": "Pronto", "es": "Listo", "pt": "Pronto", "cn": "就绪"],
        "waitingSender": ["en": "Waiting for sender", "ru": "Ожидание отправителя", "it": "In attesa del mittente", "es": "Esperando al remitente", "pt": "Aguardando remetente", "cn": "等待发送方"],
        "chooseFilesState": ["en": "Choose files", "ru": "Выберите файлы", "it": "Scegli file", "es": "Elija archivos", "pt": "Escolha arquivos", "cn": "选择文件"],
        "selectedFiles": ["en": "Selected files: %d", "ru": "Выбрано файлов: %d", "it": "File selezionati: %d", "es": "Archivos seleccionados: %d", "pt": "Arquivos selecionados: %d", "cn": "已选择文件：%d"],
        "searchRecipient": ["en": "Searching for recipient", "ru": "Поиск получателя", "it": "Ricerca destinatario", "es": "Buscando destinatario", "pt": "Procurando destinatário", "cn": "正在搜索接收方"],
        "checkingCode": ["en": "Checking code", "ru": "Проверка кода", "it": "Verifica codice", "es": "Verificando código", "pt": "Verificando código", "cn": "验证代码"],
        "error": ["en": "Error", "ru": "Ошибка", "it": "Errore", "es": "Error", "pt": "Erro", "cn": "错误"],
        "pressStart": ["en": "Click to start", "ru": "Нажмите, чтобы начать", "it": "Fai clic per iniziare", "es": "Haga clic para iniciar", "pt": "Clique para iniciar", "cn": "单击开始"],
        "wifiAvailable": ["en": "Receive is available over WiFi", "ru": "Прием доступен по WiFi", "it": "Ricezione disponibile via Wi‑Fi", "es": "La recepción está disponible por Wi‑Fi", "pt": "O recebimento está disponível por Wi‑Fi", "cn": "可通过 Wi‑Fi 接收"],
        "openFilePicker": ["en": "The system file picker will open", "ru": "Откроется системный выбор файлов", "it": "Si aprirà il selettore file di sistema", "es": "Se abrirá el selector de archivos del sistema", "pt": "O seletor de arquivos do sistema será aberto", "cn": "将打开系统文件选择器"],
        "searchAvailable": ["en": "You can search for a recipient", "ru": "Можно начать поиск получателя", "it": "Puoi cercare un destinatario", "es": "Puede buscar un destinatario", "pt": "Você pode procurar um destinatário", "cn": "可以搜索接收方"],
        "searchingDevices": ["en": "Looking for devices on the local network", "ru": "Ищем устройства в локальной сети", "it": "Ricerca dispositivi nella rete locale", "es": "Buscando dispositivos en la red local", "pt": "Procurando dispositivos na rede local", "cn": "正在本地网络中搜索设备"],
        "secureConnection": ["en": "Establishing a secure connection", "ru": "Устанавливаем защищённое соединение", "it": "Connessione protetta in corso", "es": "Estableciendo una conexión segura", "pt": "Estabelecendo conexão segura", "cn": "正在建立安全连接"],
        "transferring": ["en": "Transferring", "ru": "Передача", "it": "Trasferimento", "es": "Transfiriendo", "pt": "Transferindo", "cn": "正在传输"],
        "success": ["en": "Success", "ru": "Успех", "it": "Operazione riuscita", "es": "Correcto", "pt": "Sucesso", "cn": "成功"],
        "sendingFiles": ["en": "Sending files", "ru": "Передаём файлы", "it": "Invio dei file", "es": "Enviando archivos", "pt": "Enviando arquivos", "cn": "正在发送文件"],
        "filesSent": ["en": "Files sent", "ru": "Файлы переданы", "it": "File inviati", "es": "Archivos enviados", "pt": "Arquivos enviados", "cn": "文件已发送"],
        "sendingProgress": ["en": "File %d of %d: %@ / %@", "ru": "Файл %d из %d: %@ / %@", "it": "File %d di %d: %@ / %@", "es": "Archivo %d de %d: %@ / %@", "pt": "Arquivo %d de %d: %@ / %@", "cn": "文件 %d / %d：%@ / %@"],
        "sendSuccess": ["en": "Sent files: %d, size: %@", "ru": "Отправлено файлов: %d, размер: %@", "it": "File inviati: %d, dimensione: %@", "es": "Archivos enviados: %d, tamaño: %@", "pt": "Arquivos enviados: %d, tamanho: %@", "cn": "已发送文件：%d，大小：%@"],
        "sendWarning": ["en": "Sent: %d, skipped: %d, size: %@", "ru": "Отправлено: %d, пропущено: %d, размер: %@", "it": "Inviati: %d, ignorati: %d, dimensione: %@", "es": "Enviados: %d, omitidos: %d, tamaño: %@", "pt": "Enviados: %d, ignorados: %d, tamanho: %@", "cn": "已发送：%d，跳过：%d，大小：%@"],
        "settings": ["en": "Settings", "ru": "Настройки", "it": "Impostazioni", "es": "Ajustes", "pt": "Configurações", "cn": "设置"],
        "receive": ["en": "RECEIVE", "ru": "ПОЛУЧЕНИЕ", "it": "RICEVI", "es": "RECIBIR", "pt": "RECEBER", "cn": "接收"],
        "send": ["en": "SEND", "ru": "ОТПРАВКА", "it": "INVIA", "es": "ENVIAR", "pt": "ENVIAR", "cn": "发送"],
        "receiveButton": ["en": "Receive", "ru": "Получить", "it": "Ricevi", "es": "Recibir", "pt": "Receber", "cn": "接收"],
        "receiveAgain": ["en": "Receive more", "ru": "Получить еще", "it": "Ricevi altro", "es": "Recibir más", "pt": "Receber mais", "cn": "继续接收"],
        "showFiles": ["en": "Show files", "ru": "Показать файлы", "it": "Mostra file", "es": "Mostrar archivos", "pt": "Mostrar arquivos", "cn": "显示文件"],
        "stop": ["en": "Stop", "ru": "Остановить", "it": "Ferma", "es": "Detener", "pt": "Parar", "cn": "停止"],
        "chooseFiles": ["en": "Choose files to send", "ru": "Выбрать файлы для отправки", "it": "Scegli file da inviare", "es": "Elegir archivos para enviar", "pt": "Escolher arquivos para enviar", "cn": "选择要发送的文件"],
        "findRecipient": ["en": "Find recipient", "ru": "Найти получателя", "it": "Trova destinatario", "es": "Buscar destinatario", "pt": "Encontrar destinatário", "cn": "查找接收方"],
        "clearFileList": ["en": "Clear file list", "ru": "Очистить список файлов", "it": "Cancella elenco file", "es": "Limpiar lista de archivos", "pt": "Limpar lista de arquivos", "cn": "清除文件列表"],
        "cancel": ["en": "Cancel", "ru": "Отмена", "it": "Annulla", "es": "Cancelar", "pt": "Cancelar", "cn": "取消"],
        "done": ["en": "Done", "ru": "Готово", "it": "Fine", "es": "Listo", "pt": "Concluído", "cn": "完成"],
        "yes": ["en": "Yes", "ru": "Да", "it": "Sì", "es": "Sí", "pt": "Sim", "cn": "是"],
        "no": ["en": "No", "ru": "Нет", "it": "No", "es": "No", "pt": "Não", "cn": "否"],
        "accept": ["en": "Accept", "ru": "Принять", "it": "Accetta", "es": "Aceptar", "pt": "Aceitar", "cn": "接受"],
        "decline": ["en": "Decline", "ru": "Отклонить", "it": "Rifiuta", "es": "Rechazar", "pt": "Recusar", "cn": "拒绝"],
        "pairingCode": ["en": "Pairing code", "ru": "Код сопряжения", "it": "Codice di associazione", "es": "Código de emparejamiento", "pt": "Código de pareamento", "cn": "配对代码"],
        "cancelTransfer": ["en": "Cancel transfer", "ru": "Отменить передачу", "it": "Annulla trasferimento", "es": "Cancelar transferencia", "pt": "Cancelar transferência", "cn": "取消传输"],
        "waitReceiver": ["en": "Waiting for confirmation on the receiving device.", "ru": "Ожидаем подтверждения на принимающем устройстве.", "it": "In attesa di conferma sul dispositivo ricevente.", "es": "Esperando confirmación en el dispositivo receptor.", "pt": "Aguardando confirmação no dispositivo receptor.", "cn": "正在等待接收设备确认。"],
        "compareCode": ["en": "Compare the code with the sender's code", "ru": "Сверьте код с кодом отправителя", "it": "Confronta il codice con quello del mittente", "es": "Compare el código con el del remitente", "pt": "Compare o código com o do remetente", "cn": "请与发送方核对代码"],
        "acceptFiles": ["en": "Accept files?", "ru": "Принять файлы?", "it": "Accettare i file?", "es": "¿Aceptar archivos?", "pt": "Aceitar arquivos?", "cn": "接受文件吗？"],
        "filesSize": ["en": "Files: %d, size: %@", "ru": "Файлов: %d, размер: %@", "it": "File: %d, dimensione: %@", "es": "Archivos: %d, tamaño: %@", "pt": "Arquivos: %d, tamanho: %@", "cn": "文件：%d，大小：%@"],
        "chooseRecipient": ["en": "Choose recipient", "ru": "Выберите получателя", "it": "Scegli destinatario", "es": "Elija destinatario", "pt": "Escolha o destinatário", "cn": "选择接收方"],
        "searching": ["en": "Searching for devices", "ru": "Поиск устройств", "it": "Ricerca dispositivi", "es": "Buscando dispositivos", "pt": "Procurando dispositivos", "cn": "正在搜索设备"],
        "transferProgress": ["en": "Transfer: file %d of %d, %@ / %@ (%d%%)", "ru": "Передача: файл %d из %d, %@ / %@ (%d%%)", "it": "Trasferimento: file %d di %d, %@ / %@ (%d%%)", "es": "Transferencia: archivo %d de %d, %@ / %@ (%d%%)", "pt": "Transferência: arquivo %d de %d, %@ / %@ (%d%%)", "cn": "传输：文件 %d / %d，%@ / %@（%d%%）"],
        "receiveSuccess": ["en": "Success: received files: %d, size: %@", "ru": "Успех: получено файлов: %d, размер: %@", "it": "Riuscito: file ricevuti: %d, dimensione: %@", "es": "Correcto: archivos recibidos: %d, tamaño: %@", "pt": "Sucesso: arquivos recebidos: %d, tamanho: %@", "cn": "成功：已接收文件：%d，大小：%@"],
        "receiveWarning": ["en": "Received: %d, skipped: %d, size: %@", "ru": "Получено файлов: %d, пропущено: %d, размер: %@", "it": "Ricevuti: %d, ignorati: %d, dimensione: %@", "es": "Recibidos: %d, omitidos: %d, tamaño: %@", "pt": "Recebidos: %d, ignorados: %d, tamanho: %@", "cn": "已接收：%d，跳过：%d，大小：%@"],
        "displayName": ["en": "Display name", "ru": "Отображаемое имя", "it": "Nome visualizzato", "es": "Nombre mostrado", "pt": "Nome exibido", "cn": "显示名称"],
        "theme": ["en": "Theme", "ru": "Тема оформления", "it": "Tema", "es": "Tema", "pt": "Tema", "cn": "主题"],
        "language": ["en": "Language", "ru": "Язык", "it": "Lingua", "es": "Idioma", "pt": "Idioma", "cn": "语言"],
        "saveDates": ["en": "Preserve file dates", "ru": "Сохранять дату файлов", "it": "Mantieni date dei file", "es": "Conservar fechas de archivos", "pt": "Preservar datas dos arquivos", "cn": "保留文件日期"],
        "downloadDirectory": ["en": "Download folder", "ru": "Каталог загрузки", "it": "Cartella download", "es": "Carpeta de descargas", "pt": "Pasta de downloads", "cn": "下载文件夹"],
        "choose": ["en": "Choose…", "ru": "Выбрать…", "it": "Scegli…", "es": "Elegir…", "pt": "Escolher…", "cn": "选择…"],
        "noTrustedDevices": ["en": "No trusted devices.", "ru": "Нет доверенных устройств.", "it": "Nessun dispositivo attendibile.", "es": "No hay dispositivos de confianza.", "pt": "Não há dispositivos confiáveis.", "cn": "没有受信任设备。"],
        "delete": ["en": "Delete", "ru": "Удалить", "it": "Elimina", "es": "Eliminar", "pt": "Excluir", "cn": "删除"],
        "systemTheme": ["en": "System", "ru": "Системная", "it": "Sistema", "es": "Sistema", "pt": "Sistema", "cn": "系统"],
        "darkTheme": ["en": "Dark", "ru": "Тёмная", "it": "Scuro", "es": "Oscuro", "pt": "Escuro", "cn": "深色"],
        "lightTheme": ["en": "Light", "ru": "Светлая", "it": "Chiaro", "es": "Claro", "pt": "Claro", "cn": "浅色"]
        ,"sourceUnavailable": ["en": "File unavailable: %@", "ru": "Файл недоступен: %@", "it": "File non disponibile: %@", "es": "Archivo no disponible: %@", "pt": "Arquivo indisponível: %@", "cn": "文件不可用：%@"],
        "transferRejected": ["en": "Recipient declined the transfer (%d)", "ru": "Получатель отклонил передачу (%d)", "it": "Il destinatario ha rifiutato il trasferimento (%d)", "es": "El destinatario rechazó la transferencia (%d)", "pt": "O destinatário recusou a transferência (%d)", "cn": "接收方拒绝了传输（%d）"],
        "malformedResponse": ["en": "Invalid response from recipient", "ru": "Некорректный ответ получателя", "it": "Risposta non valida del destinatario", "es": "Respuesta no válida del destinatario", "pt": "Resposta inválida do destinatário", "cn": "接收方响应无效"],
        "malformedRequest": ["en": "Invalid HTTP request", "ru": "Некорректный HTTP-запрос", "it": "Richiesta HTTP non valida", "es": "Solicitud HTTP no válida", "pt": "Solicitação HTTP inválida", "cn": "HTTP 请求无效"],
        "connectionClosed": ["en": "Connection closed", "ru": "Соединение закрыто", "it": "Connessione chiusa", "es": "Conexión cerrada", "pt": "Conexão encerrada", "cn": "连接已关闭"],
        "invalidContentLength": ["en": "Invalid content length", "ru": "Некорректная длина содержимого", "it": "Lunghezza contenuto non valida", "es": "Longitud de contenido no válida", "pt": "Tamanho de conteúdo inválido", "cn": "内容长度无效"],
        "transferBusy": ["en": "Another transfer is already in progress", "ru": "Другая передача уже выполняется", "it": "È già in corso un altro trasferimento", "es": "Ya hay otra transferencia en curso", "pt": "Outra transferência já está em andamento", "cn": "另一个传输正在进行中"],
        "invalidManifest": ["en": "Invalid manifest", "ru": "Некорректный манифест", "it": "Manifest non valido", "es": "Manifiesto no válido", "pt": "Manifesto inválido", "cn": "清单无效"],
        "insufficientSpace": ["en": "Not enough free space", "ru": "Недостаточно свободного места", "it": "Spazio libero insufficiente", "es": "No hay suficiente espacio libre", "pt": "Não há espaço livre suficiente", "cn": "可用空间不足"],
        "transferNotFound": ["en": "Transfer not found", "ru": "Передача не найдена", "it": "Trasferimento non trovato", "es": "Transferencia no encontrada", "pt": "Transferência não encontrada", "cn": "未找到传输"],
        "offsetMismatch": ["en": "Chunk offset does not match", "ru": "Смещение блока не совпадает", "it": "L'offset del blocco non corrisponde", "es": "El desplazamiento del bloque no coincide", "pt": "O deslocamento do bloco não corresponde", "cn": "数据块偏移不匹配"],
        "invalidChunk": ["en": "Invalid chunk size", "ru": "Некорректный размер блока", "it": "Dimensione blocco non valida", "es": "Tamaño de bloque no válido", "pt": "Tamanho de bloco inválido", "cn": "数据块大小无效"],
        "transferIncomplete": ["en": "Transfer is not complete yet", "ru": "Передача ещё не завершена", "it": "Il trasferimento non è ancora completato", "es": "La transferencia aún no ha terminado", "pt": "A transferência ainda não foi concluída", "cn": "传输尚未完成"],
        "unnamedDevice": ["en": "Device %@", "ru": "Устройство %@", "it": "Dispositivo %@", "es": "Dispositivo %@", "pt": "Dispositivo %@", "cn": "设备 %@"]
    ]
}

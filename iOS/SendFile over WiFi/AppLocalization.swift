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

    static func languageName(_ code: String) -> String {
        text("language.\(code)")
    }

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
        "selectContent": ["en": "Choose content", "ru": "Выберите содержимое", "it": "Scegli contenuto", "es": "Elija contenido", "pt": "Escolha o conteúdo", "cn": "选择内容"],
        "waitingSender": ["en": "Waiting for sender", "ru": "Ожидание отправителя", "it": "In attesa del mittente", "es": "Esperando al remitente", "pt": "Aguardando remetente", "cn": "等待发送方"],
        "selectedFiles": ["en": "Selected files: %d", "ru": "Выбрано файлов: %d", "it": "File selezionati: %d", "es": "Archivos seleccionados: %d", "pt": "Arquivos selecionados: %d", "cn": "已选择文件：%d"],
        "searchRecipient": ["en": "Searching for recipient", "ru": "Поиск получателя", "it": "Ricerca destinatario", "es": "Buscando destinatario", "pt": "Procurando destinatário", "cn": "正在搜索接收方"],
        "checkingCode": ["en": "Checking code", "ru": "Проверка кода", "it": "Verifica codice", "es": "Verificando código", "pt": "Verificando código", "cn": "验证代码"],
        "transferring": ["en": "Transferring", "ru": "Передача", "it": "Trasferimento", "es": "Transfiriendo", "pt": "Transferindo", "cn": "正在传输"],
        "success": ["en": "Success", "ru": "Успех", "it": "Operazione riuscita", "es": "Correcto", "pt": "Sucesso", "cn": "成功"],
        "error": ["en": "Error", "ru": "Ошибка", "it": "Errore", "es": "Error", "pt": "Erro", "cn": "错误"],
        "pressStart": ["en": "Tap to start", "ru": "Нажмите, чтобы начать", "it": "Tocca per iniziare", "es": "Toque para iniciar", "pt": "Toque para iniciar", "cn": "轻点开始"],
        "usePhotoFiles": ["en": "Use the Photos or Files buttons.", "ru": "Используйте кнопки «Фото» или «Файлы».", "it": "Usa i pulsanti Foto o File.", "es": "Use los botones Fotos o Archivos.", "pt": "Use os botões Fotos ou Arquivos.", "cn": "请使用“照片”或“文件”按钮。"],
        "wifiAvailable": ["en": "Receive is available over WiFi", "ru": "Прием доступен по WiFi", "it": "Ricezione disponibile via Wi‑Fi", "es": "La recepción está disponible por Wi‑Fi", "pt": "O recebimento está disponível por Wi‑Fi", "cn": "可通过 Wi‑Fi 接收"],
        "pressSearch": ["en": "Tap to find a recipient", "ru": "Нажмите для поиска получателя", "it": "Tocca per cercare un destinatario", "es": "Toque para buscar un destinatario", "pt": "Toque para procurar um destinatário", "cn": "轻点以查找接收方"],
        "searchingDevices": ["en": "Looking for devices on the local network", "ru": "Ищем устройства в локальной сети", "it": "Ricerca dispositivi nella rete locale", "es": "Buscando dispositivos en la red local", "pt": "Procurando dispositivos na rede local", "cn": "正在本地网络中搜索设备"],
        "secureConnection": ["en": "Establishing a secure connection", "ru": "Устанавливаем защищённое соединение", "it": "Connessione protetta in corso", "es": "Estableciendo una conexión segura", "pt": "Estabelecendo conexão segura", "cn": "正在建立安全连接"],
        "sendingFiles": ["en": "Sending files", "ru": "Передаём файлы", "it": "Invio dei file", "es": "Enviando archivos", "pt": "Enviando arquivos", "cn": "正在发送文件"],
        "filesSent": ["en": "Files sent", "ru": "Файлы переданы", "it": "File inviati", "es": "Archivos enviados", "pt": "Arquivos enviados", "cn": "文件已发送"],
        "sendingProgress": ["en": "File %d of %d: %@ / %@", "ru": "Файл %d из %d: %@ / %@", "it": "File %d di %d: %@ / %@", "es": "Archivo %d de %d: %@ / %@", "pt": "Arquivo %d de %d: %@ / %@", "cn": "文件 %d / %d：%@ / %@"],
        "sendSuccess": ["en": "Sent files: %d, size: %@", "ru": "Отправлено файлов: %d, размер: %@", "it": "File inviati: %d, dimensione: %@", "es": "Archivos enviados: %d, tamaño: %@", "pt": "Arquivos enviados: %d, tamanho: %@", "cn": "已发送文件：%d，大小：%@"],
        "sendWarning": ["en": "Sent: %d, skipped: %d, size: %@", "ru": "Отправлено: %d, пропущено: %d, размер: %@", "it": "Inviati: %d, ignorati: %d, dimensione: %@", "es": "Enviados: %d, omitidos: %d, tamaño: %@", "pt": "Enviados: %d, ignorados: %d, tamanho: %@", "cn": "已发送：%d，跳过：%d，大小：%@"],
        "proRequired": ["en": "Sending multiple files is available after purchase.", "ru": "Передача нескольких файлов доступна после покупки.", "it": "L'invio di più file è disponibile dopo l'acquisto.", "es": "El envío de varios archivos está disponible tras la compra.", "pt": "O envio de vários arquivos está disponível após a compra.", "cn": "购买后可发送多个文件。"],
        "settings": ["en": "Settings", "ru": "Настройки", "it": "Impostazioni", "es": "Ajustes", "pt": "Configurações", "cn": "设置"],
        "yourFiles": ["en": "Your files", "ru": "Ваши файлы", "it": "I tuoi file", "es": "Sus archivos", "pt": "Seus arquivos", "cn": "您的文件"],
        "receive": ["en": "RECEIVE", "ru": "ПОЛУЧЕНИЕ", "it": "RICEVI", "es": "RECIBIR", "pt": "RECEBER", "cn": "接收"],
        "send": ["en": "SEND", "ru": "ОТПРАВКА", "it": "INVIA", "es": "ENVIAR", "pt": "ENVIAR", "cn": "发送"],
        "photos": ["en": "Photos", "ru": "Фото", "it": "Foto", "es": "Fotos", "pt": "Fotos", "cn": "照片"],
        "files": ["en": "Files", "ru": "Файлы", "it": "File", "es": "Archivos", "pt": "Arquivos", "cn": "文件"],
        "findRecipient": ["en": "Find recipient", "ru": "Найти получателя", "it": "Trova destinatario", "es": "Buscar destinatario", "pt": "Encontrar destinatário", "cn": "查找接收方"],
        "receiveButton": ["en": "Receive", "ru": "Получить", "it": "Ricevi", "es": "Recibir", "pt": "Receber", "cn": "接收"],
        "receiveAgain": ["en": "Receive more", "ru": "Получить еще", "it": "Ricevi altro", "es": "Recibir más", "pt": "Receber mais", "cn": "继续接收"],
        "stop": ["en": "Stop", "ru": "Остановить", "it": "Ferma", "es": "Detener", "pt": "Parar", "cn": "停止"],
        "cancel": ["en": "Cancel", "ru": "Отмена", "it": "Annulla", "es": "Cancelar", "pt": "Cancelar", "cn": "取消"],
        "done": ["en": "Done", "ru": "Готово", "it": "Fine", "es": "Listo", "pt": "Concluído", "cn": "完成"],
        "yes": ["en": "Yes", "ru": "Да", "it": "Sì", "es": "Sí", "pt": "Sim", "cn": "是"],
        "no": ["en": "No", "ru": "Нет", "it": "No", "es": "No", "pt": "Não", "cn": "否"],
        "accept": ["en": "Accept", "ru": "Принять", "it": "Accetta", "es": "Aceptar", "pt": "Aceitar", "cn": "接受"],
        "decline": ["en": "Decline", "ru": "Отклонить", "it": "Rifiuta", "es": "Rechazar", "pt": "Recusar", "cn": "拒绝"],
        "pairingCode": ["en": "Pairing code", "ru": "Код сопряжения", "it": "Codice di associazione", "es": "Código de emparejamiento", "pt": "Código de pareamento", "cn": "配对代码"],
        "compareCode": ["en": "Compare the code with the sender's code", "ru": "Сверьте код с кодом отправителя", "it": "Confronta il codice con quello del mittente", "es": "Compare el código con el del remitente", "pt": "Compare o código com o do remetente", "cn": "请与发送方核对代码"],
        "acceptFiles": ["en": "Accept files?", "ru": "Принять файлы?", "it": "Accettare i file?", "es": "¿Aceptar archivos?", "pt": "Aceitar arquivos?", "cn": "接受文件吗？"],
        "filesSize": ["en": "Files: %d, size: %@", "ru": "Файлов: %d, размер: %@", "it": "File: %d, dimensione: %@", "es": "Archivos: %d, tamaño: %@", "pt": "Arquivos: %d, tamanho: %@", "cn": "文件：%d，大小：%@"],
        "chooseRecipient": ["en": "Choose recipient", "ru": "Выберите получателя", "it": "Scegli destinatario", "es": "Elija destinatario", "pt": "Escolha o destinatário", "cn": "选择接收方"],
        "searching": ["en": "Searching for devices", "ru": "Поиск устройств", "it": "Ricerca dispositivi", "es": "Buscando dispositivos", "pt": "Procurando dispositivos", "cn": "正在搜索设备"],
        "chooseFiles": ["en": "Choose files to send", "ru": "Выбрать файлы для отправки", "it": "Scegli file da inviare", "es": "Elegir archivos para enviar", "pt": "Escolher arquivos para enviar", "cn": "选择要发送的文件"],
        "clearFileList": ["en": "Clear file list", "ru": "Очистить список файлов", "it": "Cancella elenco file", "es": "Limpiar lista de archivos", "pt": "Limpar lista de arquivos", "cn": "清除文件列表"],
        "transferProgress": ["en": "Transfer: file %d of %d, %@ / %@ (%d%%)", "ru": "Передача: файл %d из %d, %@ / %@ (%d%%)", "it": "Trasferimento: file %d di %d, %@ / %@ (%d%%)", "es": "Transferencia: archivo %d de %d, %@ / %@ (%d%%)", "pt": "Transferência: arquivo %d de %d, %@ / %@ (%d%%)", "cn": "传输：文件 %d / %d，%@ / %@（%d%%）"],
        "receiveSuccess": ["en": "Success: received files: %d, size: %@", "ru": "Успех: получено файлов: %d, размер: %@", "it": "Riuscito: file ricevuti: %d, dimensione: %@", "es": "Correcto: archivos recibidos: %d, tamaño: %@", "pt": "Sucesso: arquivos recebidos: %d, tamanho: %@", "cn": "成功：已接收文件：%d，大小：%@"],
        "receiveWarning": ["en": "Received: %d, skipped: %d, size: %@", "ru": "Получено файлов: %d, пропущено: %d, размер: %@", "it": "Ricevuti: %d, ignorati: %d, dimensione: %@", "es": "Recibidos: %d, omitidos: %d, tamaño: %@", "pt": "Recebidos: %d, ignorados: %d, tamanho: %@", "cn": "已接收：%d，跳过：%d，大小：%@"],
        "copyError": ["en": "Copy error details", "ru": "Копировать текст ошибки", "it": "Copia dettagli errore", "es": "Copiar detalles del error", "pt": "Copiar detalhes do erro", "cn": "复制错误详情"],
        "view": ["en": "View", "ru": "Посмотреть", "it": "Visualizza", "es": "Ver", "pt": "Ver", "cn": "查看"],
        "displayName": ["en": "Display name", "ru": "Отображаемое имя", "it": "Nome visualizzato", "es": "Nombre mostrado", "pt": "Nome exibido", "cn": "显示名称"],
        "appearance": ["en": "Appearance", "ru": "Оформление", "it": "Aspetto", "es": "Apariencia", "pt": "Aparência", "cn": "外观"],
        "theme": ["en": "Theme", "ru": "Тема оформления", "it": "Tema", "es": "Tema", "pt": "Tema", "cn": "主题"],
        "language": ["en": "Language", "ru": "Язык", "it": "Lingua", "es": "Idioma", "pt": "Idioma", "cn": "语言"],
        "saveDates": ["en": "Preserve file dates", "ru": "Сохранять дату файлов", "it": "Mantieni date dei file", "es": "Conservar fechas de archivos", "pt": "Preservar datas dos arquivos", "cn": "保留文件日期"],
        "saveAttributes": ["en": "Preserve attributes and MIME data", "ru": "Сохранять атрибуты и MIME-данные", "it": "Mantieni attributi e dati MIME", "es": "Conservar atributos y datos MIME", "pt": "Preservar atributos e dados MIME", "cn": "保留属性和 MIME 数据"],
        "trustedDevices": ["en": "Trusted devices", "ru": "Доверенные устройства", "it": "Dispositivi attendibili", "es": "Dispositivos de confianza", "pt": "Dispositivos confiáveis", "cn": "受信任设备"],
        "noTrustedDevices": ["en": "No trusted devices.", "ru": "Нет доверенных устройств.", "it": "Nessun dispositivo attendibile.", "es": "No hay dispositivos de confianza.", "pt": "Não há dispositivos confiáveis.", "cn": "没有受信任设备。"],
        "delete": ["en": "Delete", "ru": "Удалить", "it": "Elimina", "es": "Eliminar", "pt": "Excluir", "cn": "删除"],
        "systemTheme": ["en": "System", "ru": "Системная", "it": "Sistema", "es": "Sistema", "pt": "Sistema", "cn": "系统"],
        "darkTheme": ["en": "Dark", "ru": "Тёмная", "it": "Scuro", "es": "Oscuro", "pt": "Escuro", "cn": "深色"],
        "lightTheme": ["en": "Light", "ru": "Светлая", "it": "Chiaro", "es": "Claro", "pt": "Claro", "cn": "浅色"],
        "proTitle": ["en": "Send multiple files", "ru": "Отправка нескольких файлов", "it": "Invia più file", "es": "Enviar varios archivos", "pt": "Enviar vários arquivos", "cn": "发送多个文件"],
        "proDescription": ["en": "Upgrade to Pro to send multiple files at once.", "ru": "Перейдите на Pro, чтобы отправлять несколько файлов за одну сессию.", "it": "Passa a Pro per inviare più file insieme.", "es": "Actualice a Pro para enviar varios archivos a la vez.", "pt": "Atualize para Pro para enviar vários arquivos de uma vez.", "cn": "升级到 Pro 可一次发送多个文件。"],
        "oneTime": ["en": "%@ · One-time purchase", "ru": "%@ · Разовая покупка", "it": "%@ · Acquisto una tantum", "es": "%@ · Compra única", "pt": "%@ · Compra única", "cn": "%@ · 一次性购买"],
        "upgradePro": ["en": "Upgrade to Pro", "ru": "Перейти на Pro", "it": "Passa a Pro", "es": "Actualizar a Pro", "pt": "Atualizar para Pro", "cn": "升级到 Pro"],
        "loading": ["en": "Loading…", "ru": "Загрузка…", "it": "Caricamento…", "es": "Cargando…", "pt": "Carregando…", "cn": "正在加载…"],
        "restorePurchases": ["en": "Restore purchases", "ru": "Восстановить покупки", "it": "Ripristina acquisti", "es": "Restaurar compras", "pt": "Restaurar compras", "cn": "恢复购买"],
        "purchaseUnavailable": ["en": "Purchase is not available in the App Store yet.", "ru": "Покупка пока недоступна в App Store.", "it": "L'acquisto non è ancora disponibile nell'App Store.", "es": "La compra aún no está disponible en App Store.", "pt": "A compra ainda não está disponível na App Store.", "cn": "购买暂时无法在 App Store 中使用。"],
        "purchaseLoadFailed": ["en": "Could not load the App Store purchase. Try again later.", "ru": "Не удалось загрузить покупку App Store. Попробуйте позже.", "it": "Impossibile caricare l'acquisto App Store. Riprova più tardi.", "es": "No se pudo cargar la compra de App Store. Inténtelo más tarde.", "pt": "Não foi possível carregar a compra da App Store. Tente mais tarde.", "cn": "无法加载 App Store 购买项目，请稍后重试。"],
        "purchaseNotConfirmed": ["en": "The purchase did not confirm access. Try restoring purchases.", "ru": "Покупка не подтвердила доступ. Попробуйте восстановить покупки.", "it": "L'acquisto non ha confermato l'accesso. Prova a ripristinare gli acquisti.", "es": "La compra no confirmó el acceso. Intente restaurar las compras.", "pt": "A compra não confirmou o acesso. Tente restaurar as compras.", "cn": "购买未确认访问权限，请尝试恢复购买。"],
        "purchasePending": ["en": "Purchase is awaiting confirmation.", "ru": "Покупка ожидает подтверждения.", "it": "L'acquisto è in attesa di conferma.", "es": "La compra espera confirmación.", "pt": "A compra está aguardando confirmação.", "cn": "购买正在等待确认。"],
        "purchaseFinishFailed": ["en": "Could not complete the purchase.", "ru": "Не удалось завершить покупку.", "it": "Impossibile completare l'acquisto.", "es": "No se pudo completar la compra.", "pt": "Não foi possível concluir a compra.", "cn": "无法完成购买。"],
        "purchaseFailed": ["en": "Could not make the App Store purchase.", "ru": "Не удалось выполнить покупку App Store.", "it": "Impossibile effettuare l'acquisto App Store.", "es": "No se pudo realizar la compra de App Store.", "pt": "Não foi possível fazer a compra na App Store.", "cn": "无法完成 App Store 购买。"],
        "noPurchases": ["en": "No purchases were found for this Apple ID.", "ru": "Покупки для этого Apple ID не найдены.", "it": "Nessun acquisto trovato per questo ID Apple.", "es": "No se encontraron compras para este Apple ID.", "pt": "Nenhuma compra encontrada para este ID Apple.", "cn": "未找到此 Apple ID 的购买记录。"],
        "restoreFailed": ["en": "Could not restore purchases.", "ru": "Не удалось восстановить покупки.", "it": "Impossibile ripristinare gli acquisti.", "es": "No se pudieron restaurar las compras.", "pt": "Não foi possível restaurar as compras.", "cn": "无法恢复购买。"],
        "noReceivedFiles": ["en": "No received files", "ru": "Нет полученных файлов", "it": "Nessun file ricevuto", "es": "No hay archivos recibidos", "pt": "Não há arquivos recebidos", "cn": "没有已接收文件"],
        "receivedFilesHint": ["en": "Completed transfers will appear here.", "ru": "Завершённые передачи появятся здесь.", "it": "I trasferimenti completati appariranno qui.", "es": "Las transferencias completadas aparecerán aquí.", "pt": "As transferências concluídas aparecerão aqui.", "cn": "已完成的传输将显示在这里。"],
        "share": ["en": "Share", "ru": "Поделиться", "it": "Condividi", "es": "Compartir", "pt": "Compartilhar", "cn": "分享"],
        "saveToPhotos": ["en": "Save to Photos", "ru": "В Фото", "it": "Salva in Foto", "es": "Guardar en Fotos", "pt": "Salvar em Fotos", "cn": "存储到照片"],
        "savePhotosFailed": ["en": "Could not save to Photos", "ru": "Не удалось сохранить в Фото", "it": "Impossibile salvare in Foto", "es": "No se pudo guardar en Fotos", "pt": "Não foi possível salvar em Fotos", "cn": "无法存储到照片"],
        "photosPermission": ["en": "Allow the app to add files to Photos in iOS Settings.", "ru": "Разрешите приложению добавлять файлы в Фото в настройках iOS.", "it": "Consenti all'app di aggiungere file a Foto nelle Impostazioni di iOS.", "es": "Permita que la app agregue archivos a Fotos en Ajustes de iOS.", "pt": "Permita que o app adicione arquivos ao Fotos nos Ajustes do iOS.", "cn": "请在 iOS 设置中允许应用添加文件到照片。"],
        "systemSaveFailed": ["en": "The system save did not finish.", "ru": "Системное сохранение не завершилось.", "it": "Il salvataggio di sistema non è stato completato.", "es": "El guardado del sistema no se completó.", "pt": "O salvamento do sistema não foi concluído.", "cn": "系统保存未完成。"],
        "sourceUnavailable": ["en": "File unavailable: %@", "ru": "Файл недоступен: %@", "it": "File non disponibile: %@", "es": "Archivo no disponible: %@", "pt": "Arquivo indisponível: %@", "cn": "文件不可用：%@"],
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
        "unnamedDevice": ["en": "Device %@", "ru": "Устройство %@", "it": "Dispositivo %@", "es": "Dispositivo %@", "pt": "Dispositivo %@", "cn": "设备 %@"],
        "clearAll": ["en": "Clear all", "ru": "Очистить всё", "it": "Cancella tutto", "es": "Borrar todo", "pt": "Limpar tudo", "cn": "全部清除"],
        "deleteAllReceived": ["en": "Delete all received files?", "ru": "Удалить все полученные файлы?", "it": "Eliminare tutti i file ricevuti?", "es": "¿Eliminar todos los archivos recibidos?", "pt": "Excluir todos os arquivos recebidos?", "cn": "删除所有已接收文件吗？"],
        "deleteAll": ["en": "Delete all", "ru": "Удалить всё", "it": "Elimina tutto", "es": "Eliminar todo", "pt": "Excluir tudo", "cn": "全部删除"],
        "deleteReceivedHint": ["en": "Files will be removed from the app's local storage.", "ru": "Файлы будут удалены из локального хранилища приложения.", "it": "I file verranno rimossi dall'archivio locale dell'app.", "es": "Los archivos se eliminarán del almacenamiento local de la aplicación.", "pt": "Os arquivos serão removidos do armazenamento local do app.", "cn": "文件将从应用的本地存储中删除。"]
    ]
}

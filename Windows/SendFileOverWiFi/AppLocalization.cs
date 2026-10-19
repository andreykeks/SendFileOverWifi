using System.Globalization;
using System.Text.Json;

namespace SendFileOverWiFi;

/// <summary>Small app-local UI catalog. An empty preference follows a supported Windows UI language.</summary>
internal static class AppLocalization
{
    private static readonly string[] Supported = ["en", "ru", "it", "es", "pt", "cn"];
    private static string language = "en";

    internal static void Configure(string preference)
    {
        language = Supported.Contains(preference) ? preference : ResolveSystemLanguage();
    }

    internal static string T(string key)
    {
        if (!SharedStrings.TryGetValue(key, out var values) && !Strings.TryGetValue(key, out values)) return key;
        return values.TryGetValue(language, out var value) ? value : values["en"];
    }

    internal static string Format(string key, params object[] values) => string.Format(CultureInfo.CurrentCulture, T(key), values);

    internal static string LanguageName(string code) => T($"language.{code}");

    private sealed class SharedCatalog { public Dictionary<string, Dictionary<string, string>> Strings { get; set; } = []; }
    private static readonly Dictionary<string, Dictionary<string, string>> SharedStrings = LoadSharedStrings();
    private static Dictionary<string, Dictionary<string, string>> LoadSharedStrings()
    {
        try { return JsonSerializer.Deserialize<SharedCatalog>(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "ui.json")))?.Strings ?? []; }
        catch { return []; }
    }

    private static string ResolveSystemLanguage()
    {
        foreach (var candidate in CultureInfo.CurrentUICulture.Name.ToLowerInvariant().Split('-'))
        {
            if (candidate == "zh") return "cn";
            if (Supported.Contains(candidate)) return candidate;
        }
        return "en";
    }

    private static readonly Dictionary<string, Dictionary<string, string>> Strings = new()
    {
        ["settings"] = V("Settings", "Настройки", "Impostazioni", "Ajustes", "Configurações", "设置"),
        ["trustedDevices"] = V("Trusted devices: {0}", "Доверенные устройства: {0}", "Dispositivi attendibili: {0}", "Dispositivos de confianza: {0}", "Dispositivos confiáveis: {0}", "受信任设备：{0}"),
        ["trustedDevicesTitle"] = V("Trusted devices", "Доверенные устройства", "Dispositivi attendibili", "Dispositivos de confianza", "Dispositivos confiáveis", "受信任设备"),
        ["trustedDevicesEmpty"] = V("The list is empty", "Список пуст", "L'elenco è vuoto", "La lista está vacía", "A lista está vazia", "列表为空"),
        ["delete"] = V("Delete", "Удалить", "Elimina", "Eliminar", "Excluir", "删除"),
        ["done"] = V("Done", "Готово", "Fine", "Listo", "Concluído", "完成"),
        ["foundDevices"] = V("Found devices", "Найденные устройства", "Dispositivi trovati", "Dispositivos encontrados", "Dispositivos encontrados", "找到的设备"),
        ["choose"] = V("Choose", "Выбрать", "Scegli", "Elegir", "Escolher", "选择"),
        ["receive"] = V("RECEIVE", "ПОЛУЧЕНИЕ", "RICEVI", "RECIBIR", "RECEBER", "接收"),
        ["send"] = V("SEND", "ОТПРАВКА", "INVIA", "ENVIAR", "ENVIAR", "发送"),
        ["ready"] = V("Ready", "Готово", "Pronto", "Listo", "Pronto", "就绪"),
        ["success"] = V("Success", "Успех", "Riuscito", "Correcto", "Sucesso", "成功"),
        ["receiveButton"] = V("Receive", "Получить", "Ricevi", "Recibir", "Receber", "接收"),
        ["receiveAgain"] = V("Receive more", "Получить еще", "Ricevi altro", "Recibir más", "Receber mais", "继续接收"),
        ["stop"] = V("Stop", "Остановить", "Ferma", "Detener", "Parar", "停止"),
        ["findRecipient"] = V("Find recipient", "Найти получателя", "Trova destinatario", "Buscar destinatario", "Encontrar destinatário", "查找接收方"),
        ["chooseFiles"] = V("Choose files to send", "Выбрать файлы для отправки", "Scegli file da inviare", "Elegir archivos para enviar", "Escolher arquivos para enviar", "选择要发送的文件"),
        ["photos"] = V("Photos", "Фото", "Foto", "Fotos", "Fotos", "照片"),
        ["files"] = V("Files", "Файлы", "File", "Archivos", "Arquivos", "文件"),
        ["selectFiles"] = V("Select files to send", "Выберите файлы для отправки", "Scegli file da inviare", "Seleccione archivos para enviar", "Escolha arquivos para enviar", "选择要发送的文件"),
        ["selectedFiles"] = V("Selected files: {0}", "Выбрано файлов: {0}", "File selezionati: {0}", "Archivos seleccionados: {0}", "Arquivos selecionados: {0}", "已选择文件：{0}"),
        ["clear"] = V("Clear", "Очистить", "Cancella", "Limpiar", "Limpar", "清除"),
        ["clearSelection"] = V("Clear selection", "Очистить выбор", "Cancella selezione", "Limpiar selección", "Limpar seleção", "清除选择"),
        ["view"] = V("View", "Посмотреть", "Visualizza", "Ver", "Ver", "查看"),
        ["copyError"] = V("Copy error", "Копировать ошибку", "Copia errore", "Copiar error", "Copiar erro", "复制错误"),
        ["resume"] = V("Resume", "Продолжить", "Riprendi", "Continuar", "Continuar", "继续"),
        ["cancel"] = V("Cancel", "Отмена", "Annulla", "Cancelar", "Cancelar", "取消"),
        ["wifiAvailable"] = V("Receive is available over WiFi", "Прием доступен по WiFi", "Ricezione disponibile via Wi‑Fi", "La recepción está disponible por Wi‑Fi", "O recebimento está disponível por Wi‑Fi", "可通过 Wi‑Fi 接收"),
        ["waitingSender"] = V("Waiting for sender", "Ожидание отправителя", "In attesa del mittente", "Esperando al remitente", "Aguardando remetente", "等待发送方"),
        ["searchRecipient"] = V("Searching for recipient", "Поиск получателя", "Ricerca destinatario", "Buscando destinatario", "Procurando destinatário", "正在搜索接收方"),
        ["paused"] = V("Paused", "Пауза", "In pausa", "En pausa", "Pausado", "已暂停"),
        ["connectionLost"] = V("Connection lost. You can resume the transfer", "Соединение потеряно. Можно продолжить передачу", "Connessione persa. Puoi riprendere il trasferimento", "Conexión perdida. Puede continuar la transferencia", "Conexão perdida. Você pode continuar a transferência", "连接已断开，可以继续传输"),
        ["recipientNotFound"] = V("Recipient not found", "Получатель не найден", "Destinatario non trovato", "Destinatario no encontrado", "Destinatário não encontrado", "未找到接收方"),
        ["error400"] = V("Could not prepare the transfer. Start again", "Не удалось подготовить передачу. Начните заново", "Impossibile preparare il trasferimento. Riprova", "No se pudo preparar la transferencia. Inténtelo de nuevo", "Não foi possível preparar a transferência. Comece novamente", "无法准备传输，请重新开始"),
        ["error401"] = V("Receiver session changed. Search again", "Сессия получателя изменилась. Выполните поиск заново", "La sessione del destinatario è cambiata. Cerca di nuovo", "La sesión del receptor cambió. Busque de nuevo", "A sessão do destinatário mudou. Pesquise novamente", "接收方会话已变更，请重新搜索"),
        ["error403"] = V("Recipient declined the transfer", "Получатель отклонил передачу", "Il destinatario ha rifiutato il trasferimento", "El receptor rechazó la transferencia", "O destinatário recusou a transferência", "接收方拒绝了传输"),
        ["error409"] = V("Recipient is busy with another transfer", "Получатель занят другой передачей", "Il destinatario è occupato con un altro trasferimento", "El receptor está ocupado con otra transferencia", "O destinatário está ocupado com outra transferência", "接收方正忙于另一项传输"),
        ["error410"] = V("Resume period expired. Start again", "Срок докачки истёк. Начните передачу заново", "Il periodo di ripresa è scaduto. Ricomincia", "El período de reanudación caducó. Comience de nuevo", "O período de retomada expirou. Comece novamente", "续传期限已过，请重新开始"),
        ["error422"] = V("File changed and was not sent", "Файл изменился и не был передан", "Il file è cambiato e non è stato inviato", "El archivo cambió y no se envió", "O arquivo foi alterado e não foi enviado", "文件已更改，未发送"),
        ["error507"] = V("Recipient does not have enough free space", "У получателя недостаточно свободного места", "Il destinatario non ha spazio libero sufficiente", "El receptor no tiene suficiente espacio libre", "O destinatário não tem espaço livre suficiente", "接收方可用空间不足"),
        ["transferError"] = V("Transfer error. Try again", "Ошибка передачи. Попробуйте ещё раз", "Errore di trasferimento. Riprova", "Error de transferencia. Inténtelo de nuevo", "Erro de transferência. Tente novamente", "传输错误，请重试"),
        ["transferProgress"] = V("Sending: file {0}/{1}\n{2:N0} of {3:N0} bytes ({4}%)", "Передача: файл {0}/{1}\n{2:N0} из {3:N0} байт ({4}%)", "Invio: file {0}/{1}\n{2:N0} di {3:N0} byte ({4}%)", "Envío: archivo {0}/{1}\n{2:N0} de {3:N0} bytes ({4}%)", "Envio: arquivo {0}/{1}\n{2:N0} de {3:N0} bytes ({4}%)", "发送：文件 {0}/{1}\n{2:N0}/{3:N0} 字节（{4}%）"),
        ["receiveProgress"] = V("Receiving: file {0}/{1}\n{2:N0} of {3:N0} bytes ({4}%)", "Получение: файл {0}/{1}\n{2:N0} из {3:N0} байт ({4}%)", "Ricezione: file {0}/{1}\n{2:N0} di {3:N0} byte ({4}%)", "Recibiendo: archivo {0}/{1}\n{2:N0} de {3:N0} bytes ({4}%)", "Recebendo: arquivo {0}/{1}\n{2:N0} de {3:N0} bytes ({4}%)", "接收：文件 {0}/{1}\n{2:N0}/{3:N0} 字节（{4}%）"),
        ["successSend"] = V("Success\nSent files: {0}, {1:N0} bytes", "Успех\nПередано файлов: {0}, {1:N0} байт", "Riuscito\nFile inviati: {0}, {1:N0} byte", "Correcto\nArchivos enviados: {0}, {1:N0} bytes", "Sucesso\nArquivos enviados: {0}, {1:N0} bytes", "成功\n已发送文件：{0}，{1:N0} 字节"),
        ["successReceive"] = V("Success\nReceived files: {0}, {1:N0} bytes", "Успех\nПолучено файлов: {0}, {1:N0} байт", "Riuscito\nFile ricevuti: {0}, {1:N0} byte", "Correcto\nArchivos recibidos: {0}, {1:N0} bytes", "Sucesso\nArquivos recebidos: {0}, {1:N0} bytes", "成功\n已接收文件：{0}，{1:N0} 字节"),
        ["successWarning"] = V("Success with warnings\nCompleted: {0}/{1}, {2:N0} bytes\nSkipped: {3}", "Успех с предупреждением\nПередано: {0}/{1}, {2:N0} байт\nПропущено: {3}", "Riuscito con avvisi\nCompletati: {0}/{1}, {2:N0} byte\nIgnorati: {3}", "Correcto con advertencias\nCompletados: {0}/{1}, {2:N0} bytes\nOmitidos: {3}", "Sucesso com avisos\nConcluídos: {0}/{1}, {2:N0} bytes\nIgnorados: {3}", "成功但有警告\n已完成：{0}/{1}，{2:N0} 字节\n已跳过：{3}"),
        ["receiveWarning"] = V("Success with warnings\nReceived: {0}, skipped: {1}\nSkipped: {2}", "Успех с предупреждением\nПолучено: {0}, пропущено: {1}\nПропущено: {2}", "Riuscito con avvisi\nRicevuti: {0}, ignorati: {1}\nIgnorati: {2}", "Correcto con advertencias\nRecibidos: {0}, omitidos: {1}\nOmitidos: {2}", "Sucesso com avisos\nRecebidos: {0}, ignorados: {1}\nIgnorados: {2}", "成功但有警告\n已接收：{0}，已跳过：{1}\n已跳过：{2}"),
        ["checkingSpace"] = V("Checking storage\nFiles: {0}, {1:N0} bytes", "Проверка места\nФайлов: {0}, {1:N0} байт", "Verifica spazio\nFile: {0}, {1:N0} byte", "Comprobando espacio\nArchivos: {0}, {1:N0} bytes", "Verificando espaço\nArquivos: {0}, {1:N0} bytes", "正在检查空间\n文件：{0}，{1:N0} 字节"),
        ["waitingOffer"] = V("Waiting for file offer", "Ожидание предложения файлов", "In attesa dell'offerta di file", "Esperando oferta de archivos", "Aguardando oferta de arquivos", "等待文件请求"),
        ["waitingConsent"] = V("Waiting for receiver confirmation", "Ожидание согласия получателя", "In attesa della conferma del destinatario", "Esperando confirmación del receptor", "Aguardando confirmação do destinatário", "等待接收方确认"),
        ["pairing"] = V("Pairing code: {0}", "Код сопряжения: {0}", "Codice di associazione: {0}", "Código de emparejamiento: {0}", "Código de pareamento: {0}", "配对代码：{0}"),
        ["resumeProgress"] = V("Resume: file {0}/{1}, {2:N0} of {3:N0} bytes", "Докачка: файл {0}/{1}, {2:N0} из {3:N0} байт", "Riprendi: file {0}/{1}, {2:N0} di {3:N0} byte", "Reanudar: archivo {0}/{1}, {2:N0} de {3:N0} bytes", "Retomar: arquivo {0}/{1}, {2:N0} de {3:N0} bytes", "续传：文件 {0}/{1}，{2:N0}/{3:N0} 字节"),
        ["cleanupTitle"] = V("Clear unfinished transfer", "Очистка незавершённой передачи", "Cancella trasferimento incompleto", "Limpiar transferencia sin terminar", "Limpar transferência inacabada", "清除未完成的传输"),
        ["cleanupInfo"] = V("Incomplete files are cleared automatically 24 hours after the last activity.", "Неполученные и неполностью загруженные файлы будут автоматически очищены через 24 часа после последней активности.", "I file incompleti verranno eliminati automaticamente 24 ore dopo l'ultima attività.", "Los archivos incompletos se eliminarán automáticamente 24 horas después de la última actividad.", "Os arquivos incompletos serão apagados automaticamente 24 horas após a última atividade.", "未完成的文件将在最后活动后 24 小时自动清除。"),
        ["understood"] = V("OK", "Понятно", "OK", "Entendido", "OK", "知道了"),
        ["pairingCode"] = V("Pairing code", "Код сопряжения", "Codice di associazione", "Código de emparejamiento", "Código de pareamento", "配对代码"),
        ["compareCode"] = V("Compare the code with the sender's code", "Сверьте код с кодом отправителя", "Confronta il codice con quello del mittente", "Compare el código con el del remitente", "Compare o código com o do remetente", "请与发送方核对代码"),
        ["yes"] = V("Yes", "Да", "Sì", "Sí", "Sim", "是"),
        ["no"] = V("No", "Нет", "No", "No", "Não", "否"),
        ["acceptFiles"] = V("Accept files?", "Принять файлы?", "Accettare i file?", "¿Aceptar archivos?", "Aceitar arquivos?", "接受文件吗？"),
        ["accept"] = V("Accept", "Принять", "Accetta", "Aceptar", "Aceitar", "接受"),
        ["decline"] = V("Decline", "Отклонить", "Rifiuta", "Rechazar", "Recusar", "拒绝"),
        ["settingsDisplayName"] = V("Display name", "Отображаемое имя", "Nome visualizzato", "Nombre mostrado", "Nome exibido", "显示名称"),
        ["deviceNameRequired"] = V("Enter device name", "Введите имя устройства", "Inserisci il nome del dispositivo", "Introduzca el nombre del dispositivo", "Informe o nome do dispositivo", "输入设备名称"),
        ["deviceNamePrompt"] = V("Enter a name visible to people on other devices before sending or receiving files.", "Перед отправкой или получением файлов введите имя, видимое на других устройствах.", "Inserisci un nome visibile sugli altri dispositivi prima di inviare o ricevere file.", "Introduzca un nombre visible en otros dispositivos antes de enviar o recibir archivos.", "Informe um nome visível em outros dispositivos antes de enviar ou receber arquivos.", "发送或接收文件前，请输入其他设备可见的名称。"),
        ["continue"] = V("Continue", "Продолжить", "Continua", "Continuar", "Continuar", "继续"),
        ["downloadFolder"] = V("Download folder", "Каталог загрузки", "Cartella download", "Carpeta de descargas", "Pasta de downloads", "下载文件夹"),
        ["theme"] = V("Theme", "Тема оформления", "Tema", "Tema", "Tema", "主题"),
        ["language"] = V("Language", "Язык", "Lingua", "Idioma", "Idioma", "语言"),
        ["saveDates"] = V("Preserve file dates", "Сохранять дату файлов", "Mantieni date dei file", "Conservar fechas de archivos", "Preservar datas dos arquivos", "保留文件日期"),
        ["saveAttributes"] = V("Preserve attributes and MIME data", "Сохранять атрибуты и MIME-данные", "Mantieni attributi e dati MIME", "Conservar atributos y datos MIME", "Preservar atributos e dados MIME", "保留属性和 MIME 数据"),
        ["save"] = V("Save", "Сохранить", "Salva", "Guardar", "Salvar", "保存"),
        ["automatic"] = V("Automatic", "Автоматически", "Automatico", "Automático", "Automático", "自动"),
        ["systemTheme"] = V("System", "Системная", "Sistema", "Sistema", "Sistema", "系统"),
        ["darkTheme"] = V("Dark", "Тёмная", "Scuro", "Oscuro", "Escuro", "深色"),
        ["lightTheme"] = V("Light", "Светлая", "Chiaro", "Claro", "Claro", "浅色"),
        ["language.en"] = V("English", "Английский", "Inglese", "Inglés", "Inglês", "英语"),
        ["language.ru"] = V("Russian", "Русский", "Russo", "Ruso", "Russo", "俄语"),
        ["language.it"] = V("Italian", "Итальянский", "Italiano", "Italiano", "Italiano", "意大利语"),
        ["language.es"] = V("Spanish", "Испанский", "Spagnolo", "Español", "Espanhol", "西班牙语"),
        ["language.pt"] = V("Portuguese", "Португальский", "Portoghese", "Portugués", "Português", "葡萄牙语"),
        ["language.cn"] = V("Chinese", "Китайский", "Cinese", "Chino", "Chinês", "中文")
    };

    private static Dictionary<string, string> V(string en, string ru, string it, string es, string pt, string cn) => new()
    {
        ["en"] = en, ["ru"] = ru, ["it"] = it, ["es"] = es, ["pt"] = pt, ["cn"] = cn
    };
}

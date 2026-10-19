package com.ao.sendfileoverwifi;

import android.animation.ObjectAnimator;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.res.Configuration;
import android.database.Cursor;
import android.graphics.Color;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.Build;
import android.provider.OpenableColumns;
import android.view.Gravity;
import android.view.ContextThemeWrapper;
import android.view.View;
import android.view.animation.LinearInterpolator;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.ImageButton;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Space;
import android.widget.TextView;
import android.widget.Toast;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.text.DateFormat;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Date;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Main Android UI and the platform binding for protocol v1. */
public final class MainActivity extends Activity {
    // Temporary protocol-debug exception. Set false before a Google Play release.
    private static final boolean DEBUG_ALLOWS_MULTIPLE_FILE_SENDING = true;
    private static final int PICK_FILES = 101;
    private static final int PICK_MEDIA = 102;
    private final ArrayList<Uri> selectedUris = new ArrayList<>();
    private final Map<String, String[]> words = new HashMap<>();
    private SharedPreferences preferences;
    private LinearLayout content;
    private TextView receiveStatus;
    private TextView sendStatus;
    private TextView radar;
    private Button receiveAction;
    private Button findAction;
    private ObjectAnimator radarAnimation;
    private boolean receiving;
    private String language;
    private LocalDiscovery discovery;
    private IncomingTransferServer receiverServer;
    private String receiverToken;
    private org.json.JSONObject pendingIncoming;
    private org.json.JSONObject pendingOutgoing;
    private String resumeTransferId;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        preferences = getSharedPreferences("settings", MODE_PRIVATE);
        language = preferences.getString("language", "");
        discovery = new LocalDiscovery(this);
        pendingIncoming = TransferStateStore.load(this);
        pendingOutgoing = OutgoingResumeStore.load(this);
        initialiseWords();
        importSharedIntent(getIntent());
        rebuildUi();
    }

    @Override public void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        importSharedIntent(intent);
        rebuildUi();
    }

    @Override protected void onPause() {
        super.onPause();
        // Receiver advertising is a foreground-only action. A transfer already
        // accepted by the receiver owns its socket independently of this UI.
        if (receiving && receiverServer != null) {
            discovery.stopAdvertising();
            receiverServer.stopAccepting();
            receiving = false;
            if (radarAnimation != null) radarAnimation.cancel();
        }
    }

    @Override public void onConfigurationChanged(Configuration configuration) {
        super.onConfigurationChanged(configuration);
        rebuildUi();
    }

    private void initialiseWords() {
        try (java.io.InputStream input = getAssets().open("ui.json")) {
            byte[] bytes = input.readAllBytes();
            org.json.JSONObject strings = new org.json.JSONObject(new String(bytes, java.nio.charset.StandardCharsets.UTF_8)).getJSONObject("strings");
            java.util.Iterator<String> keys = strings.keys();
            while (keys.hasNext()) {
                String key = keys.next(); org.json.JSONObject values = strings.getJSONObject(key);
                words.put(key, new String[] { values.getString("en"), values.getString("ru"), values.getString("it"), values.getString("es"), values.getString("pt"), values.getString("cn") });
            }
            if (!words.isEmpty()) return;
        } catch (Exception ignored) { }
        put("files", "Your files", "Ваши файлы", "I tuoi file", "Tus archivos", "Seus arquivos", "你的文件");
        put("settings", "Settings", "Настройки", "Impostazioni", "Ajustes", "Configurações", "设置");
        put("pro", "Pro", "Pro", "Pro", "Pro", "Pro", "Pro");
        put("receive", "RECEIVE", "ПОЛУЧЕНИЕ", "RICEZIONE", "RECEPCIÓN", "RECEBER", "接收");
        put("send", "SEND", "ОТПРАВКА", "INVIO", "ENVÍO", "ENVIAR", "发送");
        put("get", "Receive", "Получить", "Ricevi", "Recibir", "Receber", "接收");
        put("stop", "Stop", "Остановить", "Ferma", "Detener", "Parar", "停止");
        put("receiveAgain", "Receive again", "Получить еще", "Ricevi ancora", "Recibir más", "Receber mais", "再次接收");
        put("wifi", "Receive available over WiFi", "Прием доступен по WiFi", "Ricezione disponibile via Wi‑Fi", "Recepción disponible por Wi‑Fi", "Recebimento disponível por Wi‑Fi", "可通过 Wi‑Fi 接收");
        put("waiting", "Waiting for sender", "Ожидание отправителя", "In attesa del mittente", "Esperando al remitente", "Aguardando remetente", "等待发送方");
        put("pairing", "Verify code", "Проверка кода", "Verifica codice", "Verificar código", "Verificar código", "验证代码");
        put("code", "Code", "Код", "Codice", "Código", "Código", "代码");
        put("photo", "Photos", "Фото", "Foto", "Fotos", "Fotos", "照片");
        put("pickFiles", "Files", "Файлы", "File", "Archivos", "Arquivos", "文件");
        put("find", "Find recipient", "Найти получателя", "Trova destinatario", "Buscar destinatario", "Encontrar destinatário", "查找接收方");
        put("searchingRecipients", "Searching for devices on the local network…", "Ищем устройства в локальной сети…", "Ricerca dispositivi nella rete locale…", "Buscando dispositivos en la red local…", "Procurando dispositivos na rede local…", "正在本地网络中搜索设备…");
        put("recipientNotFound", "Recipient not found", "Получатель не найден", "Destinatario non trovato", "No se encontró el destinatario", "Destinatário não encontrado", "未找到接收方");
        put("choose", "Choose files to send", "Выберите файлы для отправки", "Scegli i file da inviare", "Elige archivos para enviar", "Escolha arquivos para enviar", "选择要发送的文件");
        put("selected", "Selected files: %d", "Выбрано файлов: %d", "File selezionati: %d", "Archivos seleccionados: %d", "Arquivos selecionados: %d", "已选文件：%d");
        put("clear", "Clear selection", "Очистить выбор", "Cancella selezione", "Limpiar selección", "Limpar seleção", "清除选择");
        put("status", "Ready", "Готово", "Pronto", "Listo", "Pronto", "就绪");
        put("notReady", "Network transfer will be available after protocol setup.", "Сетевой обмен будет доступен после настройки протокола.", "Il trasferimento di rete sarà disponibile dopo la configurazione del protocollo.", "La transferencia de red estará disponible tras configurar el protocolo.", "A transferência pela rede estará disponível após configurar o protocolo.", "网络传输将在协议配置后可用。");
        put("settingsTitle", "Settings", "Настройки", "Impostazioni", "Ajustes", "Configurações", "设置");
        put("name", "Display name", "Отображаемое имя", "Nome visualizzato", "Nombre visible", "Nome exibido", "显示名称");
        put("theme", "Theme", "Тема оформления", "Tema", "Tema", "Tema", "主题");
        put("language", "Language", "Язык", "Lingua", "Idioma", "Idioma", "语言");
        put("save", "Save", "Сохранить", "Salva", "Guardar", "Salvar", "保存");
        put("cancel", "Cancel", "Отмена", "Annulla", "Cancelar", "Cancelar", "取消");
        put("share", "Share", "Поделиться", "Condividi", "Compartir", "Compartilhar", "分享");
        put("delete", "Delete", "Удалить", "Elimina", "Eliminar", "Excluir", "删除");
        put("emptyFiles", "No received files yet", "Полученных файлов пока нет", "Nessun file ricevuto", "Aún no hay archivos recibidos", "Ainda não há arquivos recebidos", "尚无接收的文件");
        put("selectFilesToShare", "Select at least one file to share", "Выберите хотя бы один файл, чтобы поделиться", "Seleziona almeno un file da condividere", "Seleccione al menos un archivo para compartir", "Selecione pelo menos um arquivo para compartilhar", "请选择至少一个要分享的文件");
        put("proTitle", "Send multiple files", "Отправка нескольких файлов", "Invia più file", "Enviar varios archivos", "Enviar vários arquivos", "发送多个文件");
        put("proText", "Upgrade to Pro to send multiple files at once.", "Перейдите на Pro, чтобы отправлять несколько файлов за одну сессию.", "Passa a Pro per inviare più file insieme.", "Actualiza a Pro para enviar varios archivos a la vez.", "Atualize para Pro para enviar vários arquivos de uma vez.", "升级到 Pro 以一次发送多个文件。");
        put("upgrade", "Upgrade to Pro", "Перейти на Pro", "Passa a Pro", "Actualizar a Pro", "Atualizar para Pro", "升级到 Pro");
        put("restore", "Restore Purchase", "Восстановить покупку", "Ripristina acquisto", "Restaurar compra", "Restaurar compra", "恢复购买");
        put("trusted", "Trusted devices", "Доверенные устройства", "Dispositivi attendibili", "Dispositivos de confianza", "Dispositivos confiáveis", "受信任设备");
        put("clearAll", "Clear all", "Очистить всё", "Cancella tutto", "Borrar todo", "Limpar tudo", "全部清除");
        put("saveDate", "Keep file dates", "Сохранять дату файлов", "Conserva date file", "Conservar fechas de archivos", "Manter datas dos arquivos", "保留文件日期");
        put("view", "View", "Посмотреть", "Mostra", "Ver", "Ver", "查看");
        put("copyDetails", "Copy details", "Копировать сведения", "Copia dettagli", "Copiar detalles", "Copiar detalhes", "复制详情");
        put("paused", "Paused transfer. You can resume it or clear its data.", "Передача приостановлена. Её можно продолжить или очистить данные.", "Trasferimento in pausa. Puoi riprenderlo o cancellarne i dati.", "Transferencia en pausa. Puedes reanudarla o borrar sus datos.", "Transferência pausada. Você pode retomá-la ou limpar os dados.", "传输已暂停。可以继续或清除其数据。");
    }

    private void put(String key, String... values) { words.put(key, values); }
    private int localeIndex() {
        String code = language.isEmpty() ? Locale.getDefault().getLanguage() : language;
        if (code.startsWith("ru")) return 1; if (code.startsWith("it")) return 2;
        if (code.startsWith("es")) return 3; if (code.startsWith("pt")) return 4;
        if (code.startsWith("zh") || code.startsWith("cn")) return 5; return 0;
    }
    private String t(String key) { return words.get(key)[localeIndex()]; }
    private String tf(String key, int value) { return String.format(Locale.getDefault(), t(key), value); }
    private int dp(int value) { return (int) (value * getResources().getDisplayMetrics().density + .5f); }

    private String applicationVersion() {
        try {
            return getPackageManager().getPackageInfo(getPackageName(), 0).versionName;
        } catch (Exception ignored) {
            return "1.0";
        }
    }

    private void rebuildUi() {
        boolean dark = isDarkTheme();
        int background = dark ? Color.BLACK : Color.WHITE;
        int card = Color.parseColor(dark ? "#1C1C1E" : "#F2F2F7");
        int foreground = dark ? Color.WHITE : Color.rgb(25, 25, 25);
        getWindow().setStatusBarColor(card); getWindow().setNavigationBarColor(background);
        getWindow().getDecorView().setSystemUiVisibility(dark ? 0 : View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR);
        LinearLayout root = new LinearLayout(this); root.setOrientation(LinearLayout.VERTICAL); root.setBackgroundColor(background);
        root.addView(header(card, foreground));
        boolean landscape = getResources().getConfiguration().orientation == Configuration.ORIENTATION_LANDSCAPE;
        content = new LinearLayout(this); content.setOrientation(landscape ? LinearLayout.HORIZONTAL : LinearLayout.VERTICAL); content.setPadding(dp(20), dp(20), dp(20), dp(20));
        content.addView(receiveCard(card, foreground), landscape ? new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1) : new LinearLayout.LayoutParams(-1, -2));
        Space gap = new Space(this); content.addView(gap, landscape ? new LinearLayout.LayoutParams(dp(16), 1) : new LinearLayout.LayoutParams(1, dp(16)));
        content.addView(sendCard(card, foreground), landscape ? new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1) : new LinearLayout.LayoutParams(-1, -2));
        View scroller;
        if (landscape) { HorizontalScrollView scroll = new HorizontalScrollView(this); scroll.addView(content); scroller = scroll; }
        else { ScrollView scroll = new ScrollView(this); scroll.addView(content); scroller = scroll; }
        root.addView(scroller, new LinearLayout.LayoutParams(-1, 0, 1));
        TextView footer = new TextView(this);
        footer.setText("v" + applicationVersion());
        footer.setTextColor(foreground);
        footer.setTextSize(12);
        footer.setGravity(Gravity.CENTER_VERTICAL | Gravity.END);
        footer.setPadding(dp(18), 0, dp(18), 0);
        footer.setBackgroundColor(card);
        root.addView(footer, new LinearLayout.LayoutParams(-1, dp(28)));
        setContentView(root);
    }

    private View header(int card, int foreground) {
        LinearLayout row = new LinearLayout(this); row.setGravity(Gravity.CENTER_VERTICAL); row.setPadding(dp(18), dp(10), dp(18), dp(10)); row.setBackgroundColor(card);
        ImageView logo = new ImageView(this); logo.setImageResource(R.drawable.logo); logo.setContentDescription("SendFile over WiFi"); row.addView(logo, new LinearLayout.LayoutParams(dp(42), dp(42)));
        Space fill = new Space(this); row.addView(fill, new LinearLayout.LayoutParams(0, 1, 1));
        Button pro = smallButton(t("pro")); pro.setOnClickListener(v -> showPro()); row.addView(pro);
        ImageButton files = headerIcon(R.drawable.ic_folder, t("files")); files.setOnClickListener(v -> showFiles()); row.addView(files);
        ImageButton settings = headerIcon(R.drawable.ic_settings, t("settings")); settings.setOnClickListener(v -> showSettings()); row.addView(settings);
        return row;
    }

    private View receiveCard(int card, int foreground) {
        LinearLayout box = card(card); LinearLayout title = new LinearLayout(this); title.setGravity(Gravity.CENTER_VERTICAL);
        title.addView(transferIcon(R.drawable.ic_receive), new LinearLayout.LayoutParams(dp(42), dp(42)));
        title.addView(new Space(this), new LinearLayout.LayoutParams(0, 1, 1));
        radar = new TextView(this); radar.setText("◉"); radar.setTextSize(28); radar.setTextColor(Color.rgb(10, 132, 255)); radar.setVisibility(receiving ? View.VISIBLE : View.GONE); title.addView(radar);
        receiveAction = primary(receiving ? t("stop") : t("get")); receiveAction.setOnClickListener(v -> toggleReceiver()); title.addView(receiveAction);
        box.addView(title);
        TextView name = heading(t("receive"), foreground); name.setPadding(0, dp(18), 0, 0); box.addView(name);
        String receiveText = receiving ? t("wifi") + "\n" + t("waiting") : pendingIncoming != null ? t("paused") : previousReceiveResult();
        receiveStatus = normal(receiveText, foreground); receiveStatus.setTextSize(18); receiveStatus.setPadding(0, dp(32), 0, dp(14)); box.addView(receiveStatus);
        if (pendingIncoming != null) { Button clear=primary(t("clear")); clear.setOnClickListener(v->{TransferStateStore.clear(this,pendingIncoming);pendingIncoming=null;rebuildUi();}); box.addView(clear); }
        if (!receiving && pendingIncoming == null && preferences.getBoolean("received-success", false)) { Button view = secondary(t("view")); view.setOnClickListener(v -> showFiles()); LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(40)); params.topMargin = dp(6); box.addView(view, params); }
        if (receiving) startRadar();
        return box;
    }

    private View sendCard(int card, int foreground) {
        LinearLayout box = card(card); LinearLayout title = new LinearLayout(this); title.setGravity(Gravity.CENTER_VERTICAL);
        title.addView(transferIcon(R.drawable.ic_send), new LinearLayout.LayoutParams(dp(42), dp(42)));
        title.addView(new Space(this), new LinearLayout.LayoutParams(0, 1, 1));
        if (!selectedUris.isEmpty()) { findAction = primary(t("find")); findAction.setOnClickListener(v -> findRecipient()); title.addView(findAction); }
        box.addView(title);
        TextView name = heading(t("send"), foreground); name.setPadding(0, dp(18), 0, 0); box.addView(name);
        LinearLayout line = new LinearLayout(this); line.setGravity(Gravity.CENTER_VERTICAL); line.setPadding(0, dp(16), 0, dp(10));
        sendStatus = normal(selectedUris.isEmpty() ? previousSendResult() : tf("selected", selectedUris.size()), foreground); sendStatus.setTextSize(18); line.addView(sendStatus, new LinearLayout.LayoutParams(0, -2, 1));
        if (!selectedUris.isEmpty()) { Button clear = smallButton("🗑"); clear.setContentDescription(t("clear")); clear.setOnClickListener(v -> { selectedUris.clear(); rebuildUi(); }); line.addView(clear); }
        box.addView(line);
        if (selectedUris.isEmpty()) { LinearLayout pickers = new LinearLayout(this); Button photo = primary(t("photo")); photo.setOnClickListener(v -> pick(PICK_MEDIA)); pickers.addView(photo, new LinearLayout.LayoutParams(0, -2, 1)); Space gap = new Space(this); pickers.addView(gap, new LinearLayout.LayoutParams(dp(12), 1)); Button files = primary(t("pickFiles")); files.setOnClickListener(v -> pick(PICK_FILES)); pickers.addView(files, new LinearLayout.LayoutParams(0, -2, 1)); box.addView(pickers); }
        if (pendingOutgoing != null) { LinearLayout actions=new LinearLayout(this); Button resume=primary(t("resume"));resume.setOnClickListener(v->resumeOutgoing());actions.addView(resume,new LinearLayout.LayoutParams(0,-2,1));Button cancel=primary(t("cancel"));cancel.setOnClickListener(v->{OutgoingResumeStore.clear(this);pendingOutgoing=null;rebuildUi();});actions.addView(cancel,new LinearLayout.LayoutParams(0,-2,1));box.addView(actions); }
        return box;
    }

    private LinearLayout card(int color) { LinearLayout box = new LinearLayout(this); box.setOrientation(LinearLayout.VERTICAL); box.setPadding(dp(26), dp(26), dp(26), dp(26)); GradientDrawable shape = new GradientDrawable(); shape.setColor(color); shape.setCornerRadius(dp(32)); box.setBackground(shape); return box; }
    private TextView heading(String value, int color) { TextView view = normal(value, color); view.setTextSize(18); view.setTypeface(android.graphics.Typeface.DEFAULT, android.graphics.Typeface.BOLD); view.setGravity(Gravity.CENTER_VERTICAL); return view; }
    private ImageView transferIcon(int drawable) { ImageView view = new ImageView(this); view.setImageResource(drawable); view.setScaleType(ImageView.ScaleType.CENTER_INSIDE); return view; }
    private TextView normal(String value, int color) { TextView view = new TextView(this); view.setText(value); view.setTextSize(16); view.setTextColor(color); return view; }
    private Button primary(String text) { Button button = new Button(this); button.setText(text); button.setTextColor(Color.WHITE); button.setTextSize(18); button.setMinHeight(dp(42)); button.setMinWidth(dp(112)); button.setPadding(dp(18), 0, dp(18), 0); button.setAllCaps(false); button.setBackground(pill(Color.rgb(10, 132, 255), dp(21))); return button; }
    private Button secondary(String text) { Button button = new Button(this); button.setText(text); button.setTextColor(Color.rgb(10, 132, 255)); button.setTextSize(18); button.setPadding(dp(20), 0, dp(20), 0); button.setAllCaps(false); button.setBackground(pill(isDarkTheme() ? Color.rgb(58, 58, 60) : Color.rgb(220, 220, 224), dp(20))); return button; }
    private Button smallButton(String text) { Button button = new Button(this); button.setText(text); button.setTextColor(Color.rgb(10, 132, 255)); button.setTextSize(17); button.setMinHeight(dp(50)); button.setPadding(dp(8), 0, dp(8), 0); button.setAllCaps(false); button.setBackgroundColor(Color.TRANSPARENT); return button; }
    private ImageButton headerIcon(int drawable, String description) { ImageButton button = new ImageButton(this); button.setImageResource(drawable); button.setContentDescription(description); button.setPadding(dp(10), dp(10), dp(10), dp(10)); button.setBackgroundColor(Color.TRANSPARENT); return button; }
    private GradientDrawable pill(int color, int radius) { GradientDrawable shape = new GradientDrawable(); shape.setColor(color); shape.setCornerRadius(radius); return shape; }
    private boolean isDarkTheme() { String chosen = preferences.getString("theme", "system"); boolean systemDark = (getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES; return "dark".equals(chosen) || ("system".equals(chosen) && systemDark); }
    private String previousReceiveResult() {
        if (!preferences.getBoolean("received-success", false)) return t("status");
        return "✓ " + preferences.getInt("received-count", 0) + " · " + formatBytes(preferences.getLong("received-bytes", 0));
    }
    private String previousSendResult() {
        if (!preferences.getBoolean("sent-success", false)) return t("choose");
        return "✓ " + preferences.getInt("sent-count", 0) + " · " + formatBytes(preferences.getLong("sent-bytes", 0));
    }
    private void clearCompletedReceiveResult() {
        if (pendingIncoming == null) preferences.edit().remove("received-success").remove("received-count").remove("received-bytes").apply();
    }
    private void clearPreviousSuccessfulSendResult() {
        preferences.edit().remove("sent-success").remove("sent-count").remove("sent-bytes").apply();
    }
    private AlertDialog.Builder dialogBuilder() { return new AlertDialog.Builder(new ContextThemeWrapper(this, isDarkTheme() ? R.style.AppDialogDark : R.style.AppDialogLight)); }

    private void toggleReceiver() {
        if (receiving) {
            receiving = false; discovery.stopAdvertising(); if (receiverServer != null) receiverServer.stop();
            if (radarAnimation != null) radarAnimation.cancel(); rebuildUi(); return;
        }
        try {
            // Do not erase a persisted incomplete incoming session: it remains
            // eligible for the protocol resume flow. Completed summaries are
            // cleared as a new receive operation explicitly begins.
            clearCompletedReceiveResult();
            receiverToken = LocalDiscovery.newToken();
            receiverServer = new IncomingTransferServer(this, new IncomingTransferServer.Callback() {
                @Override public boolean confirmPairing(String code, String fingerprint) { return confirmOnMain(t("pairing"), t("code") + ": " + code); }
                @Override public boolean confirmOffer(int count, long bytes, String sender) { boolean accepted = confirmOnMain(t("receive"), tf("selected", count) + "\n" + formatBytes(bytes)); if (accepted) runOnUiThread(() -> { ensureNotificationPermission(); TransferForegroundService.start(MainActivity.this, transferNotice("receivingFiles")); }); return accepted; }
                @Override public void onProgress(int index, int count, long bytes, long total) { TransferForegroundService.progress(MainActivity.this, transferNotice("Receiving " + index + "/" + count), bytes, total); runOnUiThread(() -> { if (receiveStatus != null) receiveStatus.setText(index + "/" + count + " · " + formatBytes(bytes) + " / " + formatBytes(total)); }); }
                @Override public void onCompleted(int count, long bytes, int skipped) { TransferForegroundService.stop(MainActivity.this); runOnUiThread(() -> { receiving = false; preferences.edit().putBoolean("received-success", true).putInt("received-count", count).putLong("received-bytes", bytes).apply(); discovery.stopAdvertising(); if (receiveStatus != null) receiveStatus.setText("✓ " + count + " · " + formatBytes(bytes)); if (radarAnimation != null) radarAnimation.cancel(); if (receiveAction != null) receiveAction.setText(t("receiveAgain")); rebuildUi(); }); }
                @Override public void onError(String message) { TransferForegroundService.stop(MainActivity.this); runOnUiThread(() -> { if (receiveStatus != null) receiveStatus.setText(friendlyError(message)); showNetworkError(message); }); }
            });
            int port = receiverServer.start(receiverToken);
            discovery.register(preferences.getString("name", android.os.Build.MODEL), port, receiverToken, () -> { receiving = true; rebuildUi(); }, this::showNetworkError);
        } catch (Exception error) { android.util.Log.e("SendFileReceiver", "Receiver startup failed; " + error.getClass().getSimpleName()); showNetworkError(error.getMessage() == null ? error.toString() : error.getMessage()); }
    }

    private boolean confirmOnMain(String title, String message) {
        CountDownLatch latch = new CountDownLatch(1); final boolean[] decision = {false};
        runOnUiThread(() -> {
            AlertDialog dialog = dialogBuilder().setTitle(title).setMessage(message).setNegativeButton(t("no"), (d, w) -> latch.countDown()).setPositiveButton(t("yes"), (d, w) -> { decision[0] = true; latch.countDown(); }).create();
            dialog.setOnCancelListener(d -> latch.countDown()); dialog.show();
            dialog.getButton(AlertDialog.BUTTON_NEGATIVE).setTextColor(Color.rgb(190, 30, 30));
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setTextColor(Color.rgb(35, 125, 50));
        });
        try { latch.await(90, TimeUnit.SECONDS); } catch (InterruptedException error) { Thread.currentThread().interrupt(); }
        return decision[0];
    }

    private String formatBytes(long bytes) { if (bytes < 1024 * 1024) return bytes / 1024 + " KB"; return String.format(Locale.getDefault(), "%.1f MB", bytes / 1048576d); }
    private void startRadar() { if (radar == null) return; radarAnimation = ObjectAnimator.ofFloat(radar, "rotation", 0f, 360f); radarAnimation.setDuration(1400); radarAnimation.setRepeatCount(ObjectAnimator.INFINITE); radarAnimation.setInterpolator(new LinearInterpolator()); radarAnimation.start(); }

    private void pick(int requestCode) { Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT); intent.addCategory(Intent.CATEGORY_OPENABLE); intent.setType(requestCode == PICK_MEDIA ? "image/*" : "*/*"); if (requestCode == PICK_MEDIA) intent.putExtra(Intent.EXTRA_MIME_TYPES, new String[]{"image/*", "video/*"}); intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true); startActivityForResult(intent, requestCode); }
    @Override protected void onActivityResult(int request, int result, Intent data) { super.onActivityResult(request, result, data); if (result != RESULT_OK || data == null) return; if (addUris(data)) clearPreviousSuccessfulSendResult(); rebuildUi(); }

    private boolean addUris(Intent data) { int previous = selectedUris.size(); if (data.getClipData() != null) for (int i = 0; i < data.getClipData().getItemCount(); i++) selectedUris.add(data.getClipData().getItemAt(i).getUri()); else if (data.getData() != null) selectedUris.add(data.getData()); return selectedUris.size() > previous; }
    private void importSharedIntent(Intent intent) { if (Intent.ACTION_SEND.equals(intent.getAction()) || Intent.ACTION_SEND_MULTIPLE.equals(intent.getAction())) { if (addUris(intent)) clearPreviousSuccessfulSendResult(); if (!selectedUris.isEmpty()) Toast.makeText(this, tf("selected", selectedUris.size()), Toast.LENGTH_SHORT).show(); } }

    private void findRecipient() {
        if (!DEBUG_ALLOWS_MULTIPLE_FILE_SENDING && selectedUris.size() > 1 && !preferences.getBoolean("pro", false)) { showPro(); return; }
        if (findAction != null) findAction.setEnabled(false);
        if (sendStatus != null) sendStatus.setText("◉  " + t("find"));
        LinearLayout searchContent = new LinearLayout(this);
        searchContent.setOrientation(LinearLayout.VERTICAL);
        searchContent.setPadding(dp(8), dp(8), dp(8), dp(8));
        TextView progress = normal(t("searchingRecipients"), isDarkTheme() ? Color.WHITE : Color.BLACK);
        progress.setPadding(0, dp(8), 0, dp(12));
        searchContent.addView(progress);
        final AlertDialog[] searchDialog = new AlertDialog[1];
        final boolean[] selected = {false};
        searchDialog[0] = dialogBuilder().setTitle(t("find")).setView(searchContent)
                .setNegativeButton(t("cancel"), (dialog, which) -> {
                    discovery.stopBrowsing();
                    if (!selected[0]) rebuildUi();
                }).create();
        searchDialog[0].setOnDismissListener(dialog -> {
            if (!selected[0]) discovery.stopBrowsing();
        });
        searchDialog[0].show();
        discovery.browseForEightSeconds(new LocalDiscovery.Listener() {
            @Override public void onRecipients(List<LocalDiscovery.Recipient> recipients) {
                if (recipients.isEmpty() || selected[0] || searchDialog[0] == null || !searchDialog[0].isShowing()) return;
                progress.setText(t("find"));
                while (searchContent.getChildCount() > 1) searchContent.removeViewAt(1);
                for (LocalDiscovery.Recipient recipient : recipients) {
                    Button choice = primary(recipient.name);
                    LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
                    params.topMargin = dp(8);
                    choice.setOnClickListener(view -> {
                        selected[0] = true;
                        discovery.stopBrowsing();
                        searchDialog[0].dismiss();
                        beginTransfer(recipient);
                    });
                    searchContent.addView(choice, params);
                }
            }
            @Override public void onDiscoveryError(String error) {
                if (searchDialog[0] != null && searchDialog[0].isShowing()) searchDialog[0].dismiss();
                showNetworkError(error);
            }
        });
        new Handler(Looper.getMainLooper()).postDelayed(() -> {
            if (!selected[0] && searchDialog[0] != null && searchDialog[0].isShowing()) {
                searchDialog[0].dismiss();
                if (sendStatus != null) sendStatus.setText(t("recipientNotFound"));
            }
            if (findAction != null && !findAction.isEnabled()) findAction.setEnabled(true);
        }, 8_200L);
    }

    private void beginTransfer(LocalDiscovery.Recipient recipient) {
        sendStatus.setText(t("find") + ": " + recipient.name);
        ensureNotificationPermission();
        TransferForegroundService.start(this, transferNotice("preparingTransfer"));
        OutgoingTransferClient client = new OutgoingTransferClient(this, new OutgoingTransferClient.Callback() {
            @Override public void onPairing(String code) { runOnUiThread(() -> { if (sendStatus != null) sendStatus.setText(t("pairing") + ": " + code + "\n" + t("waiting")); }); }
            @Override public void onProgress(int file, int count, long bytes, long total) { TransferForegroundService.progress(MainActivity.this, transferNotice("sendingFiles") + " " + file + "/" + count, bytes, total); runOnUiThread(() -> { if (sendStatus != null) sendStatus.setText(file + "/" + count + " · " + formatBytes(bytes) + " / " + formatBytes(total)); }); }
            @Override public void onCompleted(int sent, long bytes, int skipped) { TransferForegroundService.stop(MainActivity.this); runOnUiThread(() -> { resumeTransferId = null; pendingOutgoing = null; preferences.edit().putBoolean("sent-success", true).putInt("sent-count", sent).putLong("sent-bytes", bytes).apply(); selectedUris.clear(); rebuildUi(); Toast.makeText(MainActivity.this, "✓ " + sent + " · " + formatBytes(bytes), Toast.LENGTH_LONG).show(); }); }
            @Override public void onError(String error) { TransferForegroundService.stop(MainActivity.this); runOnUiThread(() -> showNetworkError(error)); }
        });
        String transferId = resumeTransferId;
        resumeTransferId = null;
        if (transferId == null) client.transfer(new ArrayList<>(selectedUris), recipient, preferences.getString("name", android.os.Build.MODEL));
        else client.resume(new ArrayList<>(selectedUris), recipient, transferId, preferences.getString("name", android.os.Build.MODEL));
    }

    private void ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission("android.permission.POST_NOTIFICATIONS") != android.content.pm.PackageManager.PERMISSION_GRANTED) requestPermissions(new String[]{"android.permission.POST_NOTIFICATIONS"}, 71);
    }
    private String transferNotice(String key) { return t(key); }

    private void resumeOutgoing(){ try { resumeTransferId=pendingOutgoing.getString("id"); org.json.JSONArray sources=pendingOutgoing.getJSONArray("sources"); selectedUris.clear(); for(int i=0;i<sources.length();i++){File f=new File(sources.getString(i));if(f.exists())selectedUris.add(Uri.fromFile(f));} if(selectedUris.isEmpty()){OutgoingResumeStore.clear(this);pendingOutgoing=null;rebuildUi();return;} findRecipient(); } catch(Exception e){OutgoingResumeStore.clear(this);pendingOutgoing=null;rebuildUi();} }

    private void showNetworkError(String error) {
        String visible = friendlyError(error);
        if (sendStatus != null) sendStatus.setText(visible);
        dialogBuilder().setTitle(t("find")).setMessage(visible).setNegativeButton(t("copyDetails"), (d,w) -> {
            String safe = error.replaceAll("(?i)(token|sas|key)[^\\n]*", "$1: [redacted]");
            ((android.content.ClipboardManager)getSystemService(CLIPBOARD_SERVICE)).setPrimaryClip(android.content.ClipData.newPlainText("SendFile error", safe));
        }).setPositiveButton(t("understood"), null).show();
    }
    private String friendlyError(String error) {
        if (error == null) return t("status");
        if (error.contains(" 400") || error.contains(": 400")) return t("error400");
        if (error.contains(" 401") || error.contains(": 401")) return t("error401");
        if (error.contains(" 403") || error.contains(": 403")) return t("error403");
        if (error.contains(" 409") || error.contains(": 409")) return t("error409");
        if (error.contains(" 410") || error.contains(": 410")) return t("error410");
        if (error.contains(" 422") || error.contains(": 422")) return t("error422");
        if (error.contains(" 507") || error.contains(": 507")) return t("error507");
        if (error.contains("timed out") || error.contains("Connection closed")) return t("connectionLost");
        return error;
    }
    private void showPro() { dialogBuilder().setTitle(t("proTitle")).setMessage(t("proText") + "\n\n" + String.format(Locale.getDefault(), t("oneTimePrice"), "€X.XX")).setPositiveButton(t("upgrade"), (d, w) -> Toast.makeText(this, t("proNotConfigured"), Toast.LENGTH_LONG).show()).setNeutralButton(t("restore"), (d, w) -> Toast.makeText(this, t("noPurchases"), Toast.LENGTH_SHORT).show()).setNegativeButton(t("cancel"), null).show(); }

    private void showFiles() {
        File received = new File(getFilesDir(), "Received Files"); received.mkdirs(); ArrayList<File> files = new ArrayList<>(); collectFiles(received, files);
        if (files.isEmpty()) { dialogBuilder().setTitle(t("files")).setMessage(t("emptyFiles")).setPositiveButton(t("understood"), null).show(); return; }
        int foreground = isDarkTheme() ? Color.WHITE : Color.rgb(25,25,25); boolean[] selected = new boolean[files.size()];
        LinearLayout rows = new LinearLayout(this); rows.setOrientation(LinearLayout.VERTICAL); rows.setPadding(dp(8), 0, dp(8), 0);
        for (int index = 0; index < files.size(); index++) {
            final int position = index; File file = files.get(index); LinearLayout row = new LinearLayout(this); row.setGravity(Gravity.CENTER_VERTICAL); row.setPadding(0, dp(8), 0, dp(8));
            CheckBox check = new CheckBox(new ContextThemeWrapper(this, isDarkTheme() ? R.style.AppDialogDark : R.style.AppDialogLight)); check.setOnCheckedChangeListener((button, checked) -> selected[position] = checked); row.addView(check, new LinearLayout.LayoutParams(dp(40), dp(42)));
            ImageView icon = new ImageView(this); icon.setScaleType(ImageView.ScaleType.CENTER_CROP); bindFileThumbnail(icon, file); row.addView(icon, new LinearLayout.LayoutParams(dp(42), dp(42)));
            LinearLayout info = new LinearLayout(this); info.setOrientation(LinearLayout.VERTICAL); info.setPadding(dp(10), 0, 0, 0); TextView name = normal(relative(received, file), foreground); name.setTextSize(12); name.setMaxLines(2); TextView date = normal(DateFormat.getDateTimeInstance().format(new Date(file.lastModified())), foreground); date.setTextSize(8); date.setAlpha(.65f); info.addView(name); info.addView(date); info.setOnClickListener(v -> openPreview(file)); row.addView(info, new LinearLayout.LayoutParams(0, -2, 1)); rows.addView(row);
        }
        ScrollView scroll = new ScrollView(this); scroll.addView(rows);
        AlertDialog dialog = dialogBuilder().setTitle(t("files")).setView(scroll).setPositiveButton(t("share"), null).setNeutralButton(t("delete"),(d,w)->{for(int i=0;i<files.size();i++)if(selected[i])files.get(i).delete();showFiles();}).setNegativeButton(t("clearAll"),(d,w)->{deleteTree(received);received.mkdirs();}).create();
        dialog.setOnShowListener(ignored -> dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
            if (shareFiles(files, selected)) dialog.dismiss();
        }));
        dialog.show();
    }
    private void openPreview(File file) { startActivity(new Intent(this, FilePreviewActivity.class).putExtra(FilePreviewActivity.EXTRA_PATH, file.getAbsolutePath())); }
    private void bindFileThumbnail(ImageView view, File file) { String name=file.getName().toLowerCase(Locale.ROOT); int dot=name.lastIndexOf('.'); String ext=dot<0?"":name.substring(dot+1); if(ext.matches("jpg|jpeg|png|gif|webp|bmp|heic|heif")){ Bitmap thumbnail=decodeThumbnail(file); if(thumbnail!=null){view.setImageBitmap(thumbnail);return;} } if(ext.matches("mp4|mov|m4v|webm|3gp")){ try { android.media.MediaMetadataRetriever retriever=new android.media.MediaMetadataRetriever(); retriever.setDataSource(file.getAbsolutePath()); Bitmap thumbnail=retriever.getFrameAtTime(); retriever.release(); if(thumbnail!=null){view.setImageBitmap(thumbnail);return;} }catch(Exception ignored){} } view.setImageResource(fileIcon(file)); }
    private Bitmap decodeThumbnail(File file) { try { BitmapFactory.Options bounds=new BitmapFactory.Options();bounds.inJustDecodeBounds=true;BitmapFactory.decodeFile(file.getAbsolutePath(),bounds);int sample=1;while(bounds.outWidth/sample>160||bounds.outHeight/sample>160)sample*=2;BitmapFactory.Options options=new BitmapFactory.Options();options.inSampleSize=sample;return BitmapFactory.decodeFile(file.getAbsolutePath(),options); } catch(Exception ignored) { return null; } }
    private int fileIcon(File file) { String name=file.getName().toLowerCase(Locale.ROOT); int dot=name.lastIndexOf('.'); String ext=dot<0?"":name.substring(dot+1); if(ext.matches("jpg|jpeg|png|gif|webp|bmp|heic|heif"))return R.drawable.ic_file_image; if(ext.matches("mp4|mov|m4v|webm|3gp"))return R.drawable.ic_file_video; if(ext.matches("mp3|wav|m4a|aac|ogg|flac"))return R.drawable.ic_file_audio; if(ext.matches("zip|rar|7z|tar|gz"))return R.drawable.ic_file_archive; if(ext.matches("pdf|doc|docx|xls|xlsx|ppt|pptx|txt|md|json|xml|csv"))return R.drawable.ic_file_document; return R.drawable.ic_file_generic; }
    private boolean shareFiles(List<File> files, boolean[] selected) { ArrayList<Uri> uris=new ArrayList<>(); for(int i=0;i<files.size();i++)if(selected[i])uris.add(androidx.core.content.FileProvider.getUriForFile(this,"com.ao.sendfileoverwifi.files",files.get(i))); if(uris.isEmpty()){Toast.makeText(this,t("selectFilesToShare"),Toast.LENGTH_SHORT).show();return false;} Intent intent=new Intent(Intent.ACTION_SEND_MULTIPLE);intent.setType("*/*");intent.putParcelableArrayListExtra(Intent.EXTRA_STREAM,uris);intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);startActivity(Intent.createChooser(intent,t("share"))); return true; }
    private static void collectFiles(File directory,List<File> into){File[] list=directory.listFiles();if(list==null)return;for(File file:list){if(file.isDirectory())collectFiles(file,into);else into.add(file);}}
    private static void deleteTree(File file){if(file.isDirectory()){File[] list=file.listFiles();if(list!=null)for(File child:list)deleteTree(child);}file.delete();}
    private static String relative(File root,File file){try{return root.toURI().relativize(file.toURI()).getPath();}catch(Exception ignored){return file.getName();}}

    private void showSettings() {
        int foreground = isDarkTheme() ? Color.WHITE : Color.rgb(25, 25, 25);
        LinearLayout layout = new LinearLayout(this); layout.setOrientation(LinearLayout.VERTICAL); int pad = dp(22); layout.setPadding(pad, 0, pad, 0);
        TextView nameLabel = normal(t("name"), foreground); layout.addView(nameLabel);
        EditText name = new EditText(new ContextThemeWrapper(this, isDarkTheme() ? R.style.AppDialogDark : R.style.AppDialogLight)); name.setTextColor(foreground); name.setText(preferences.getString("name", android.os.Build.MODEL)); layout.addView(name);
        TextView languageLabel = normal(t("language") + ": " + displayedLanguage(), foreground); languageLabel.setPadding(0, dp(18), 0, 0); layout.addView(languageLabel);
        Button theme = smallButton(t("theme") + ": " + themeName()); theme.setOnClickListener(v -> showThemePicker()); layout.addView(theme);
        CheckBox date = new CheckBox(new ContextThemeWrapper(this, isDarkTheme() ? R.style.AppDialogDark : R.style.AppDialogLight)); date.setTextColor(foreground); date.setText(t("saveDate")); date.setChecked(preferences.getBoolean("save-date", false)); layout.addView(date);
        Button trusted = smallButton(t("trusted")); trusted.setOnClickListener(v -> showTrusted()); layout.addView(trusted);
        String[] choices = {t("automatic"), t("language.ru"), t("language.it"), t("language.es"), t("language.pt"), t("language.cn")};
        String[] languageCodes = {"", "ru", "it", "es", "pt", "cn"};
        AlertDialog dialog = dialogBuilder().setTitle(t("settingsTitle")).setView(layout).setPositiveButton(t("save"), (d, w) -> preferences.edit().putString("name", name.getText().toString()).putBoolean("save-date", date.isChecked()).apply()).setNeutralButton(t("language"), null).setNegativeButton(t("cancel"), null).show();
        dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener(v -> dialogBuilder().setTitle(t("language")).setSingleChoiceItems(choices, languageChoice(), (picker, which) -> { language = languageCodes[which]; preferences.edit().putString("language", language).apply(); picker.dismiss(); dialog.dismiss(); rebuildUi(); }).show());
    }
    private String themeName(){String value=preferences.getString("theme","system");return "dark".equals(value)?t("darkTheme"):"light".equals(value)?t("lightTheme"):t("systemTheme");}
    private void showThemePicker(){String[] values={t("systemTheme"),t("darkTheme"),t("lightTheme")};String current=preferences.getString("theme","system");int selected="dark".equals(current)?1:"light".equals(current)?2:0;dialogBuilder().setTitle(t("theme")).setSingleChoiceItems(values,selected,(d,w)->{preferences.edit().putString("theme",w==0?"system":w==1?"dark":"light").apply();d.dismiss();rebuildUi();}).show();}
    private void showTrusted(){ List<TrustedDeviceStore.Device> devices=TrustedDeviceStore.all(this);if(devices.isEmpty()){dialogBuilder().setTitle(t("trusted")).setMessage(t("emptyFiles")).setPositiveButton(t("understood"),null).show();return;}String[] names=new String[devices.size()];for(int i=0;i<names.length;i++)names[i]=devices.get(i).name;dialogBuilder().setTitle(t("trusted")).setItems(names,(d,w)->dialogBuilder().setTitle(names[w]).setNegativeButton(t("delete"),(x,y)->{TrustedDeviceStore.remove(this,devices.get(w).fingerprint);}).setPositiveButton(t("understood"),null).show()).show();}
    private int languageChoice() { return language.isEmpty() ? 0 : Arrays.asList("ru", "it", "es", "pt", "cn").indexOf(language) + 1; }
    private String displayedLanguage() { return language.isEmpty() ? t("automatic") : language; }
}

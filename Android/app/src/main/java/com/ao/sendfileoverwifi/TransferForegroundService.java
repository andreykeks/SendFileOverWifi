package com.ao.sendfileoverwifi;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;

import androidx.core.app.NotificationCompat;

/**
 * Keeps an accepted transfer eligible for Android background execution. The
 * protocol workers remain in the app process; this service supplies the OS
 * foreground-service contract and a visible, progress-bearing notification.
 */
public final class TransferForegroundService extends Service {
    private static final String CHANNEL = "active-transfer";
    private static final int NOTIFICATION_ID = 4101;
    private static final String ACTION_START = "com.ao.sendfileoverwifi.TRANSFER_START";
    private static final String ACTION_PROGRESS = "com.ao.sendfileoverwifi.TRANSFER_PROGRESS";
    private static final String ACTION_STOP = "com.ao.sendfileoverwifi.TRANSFER_STOP";
    private static final String EXTRA_TEXT = "text";
    private static final String EXTRA_DONE = "done";
    private static final String EXTRA_TOTAL = "total";

    static void start(Context context, String text) { send(context, ACTION_START, text, 0, 0); }
    static void progress(Context context, String text, long done, long total) { send(context, ACTION_PROGRESS, text, done, total); }
    static void stop(Context context) { send(context, ACTION_STOP, "", 0, 0); }

    private static void send(Context context, String action, String text, long done, long total) {
        Intent intent = new Intent(context, TransferForegroundService.class).setAction(action)
                .putExtra(EXTRA_TEXT, text).putExtra(EXTRA_DONE, done).putExtra(EXTRA_TOTAL, total);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent);
        else context.startService(intent);
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? ACTION_STOP : intent.getAction();
        if (ACTION_STOP.equals(action)) { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf(); return START_NOT_STICKY; }
        String text = intent.getStringExtra(EXTRA_TEXT); long done = intent.getLongExtra(EXTRA_DONE, 0); long total = intent.getLongExtra(EXTRA_TOTAL, 0);
        Notification notification = notification(text == null ? localized("notificationActive") : text, done, total);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) startForeground(NOTIFICATION_ID, notification, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
        else startForeground(NOTIFICATION_ID, notification);
        return START_NOT_STICKY;
    }

    private Notification notification(String text, long done, long total) {
        NotificationManager manager = getSystemService(NotificationManager.class);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) manager.createNotificationChannel(new NotificationChannel(CHANNEL, localized("notificationChannel"), NotificationManager.IMPORTANCE_LOW));
        NotificationCompat.Builder builder = new NotificationCompat.Builder(this, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .setContentTitle("SendFile over WiFi")
                .setContentText(text)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setCategory(NotificationCompat.CATEGORY_PROGRESS);
        if (total > 0) builder.setProgress(100, (int)Math.min(100, done * 100 / total), false);
        else builder.setProgress(0, 0, true);
        return builder.build();
    }

    private String localized(String key) { try (java.io.InputStream input = getAssets().open("ui.json")) { org.json.JSONObject values = new org.json.JSONObject(new String(input.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8)).getJSONObject("strings").getJSONObject(key); String language = getSharedPreferences("settings", MODE_PRIVATE).getString("language", ""); String code = language.isEmpty() ? java.util.Locale.getDefault().getLanguage() : language; if ("zh".equals(code)) code = "cn"; return values.optString(code, values.getString("en")); } catch (Exception ignored) { return key; } }

    @Override public IBinder onBind(Intent intent) { return null; }
}

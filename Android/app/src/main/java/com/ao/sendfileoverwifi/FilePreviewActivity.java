package com.ao.sendfileoverwifi;

import android.app.Activity;
import android.content.Intent;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.VideoView;

import java.io.File;
import java.io.FileInputStream;
import java.nio.charset.StandardCharsets;
import java.util.Locale;

/** Local preview for received images, video and text; delegates other files safely. */
public final class FilePreviewActivity extends Activity {
    static final String EXTRA_PATH = "path";

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        File file = new File(getIntent().getStringExtra(EXTRA_PATH));
        if (!file.isFile()) { finish(); return; }
        boolean dark = "dark".equals(getSharedPreferences("settings", MODE_PRIVATE).getString("theme", "system"));
        int background = dark ? Color.BLACK : Color.WHITE, card = Color.parseColor(dark ? "#1C1C1E" : "#F2F2F7"), text = dark ? Color.WHITE : Color.rgb(25,25,25);
        LinearLayout root = new LinearLayout(this); root.setOrientation(LinearLayout.VERTICAL); root.setPadding(dp(20), dp(18), dp(20), dp(20)); root.setBackgroundColor(background);
        LinearLayout header = new LinearLayout(this); header.setGravity(Gravity.CENTER_VERTICAL);
        Button back = new Button(this); back.setText("‹"); back.setTextSize(30); back.setTextColor(Color.rgb(10,132,255)); back.setBackgroundColor(Color.TRANSPARENT); back.setOnClickListener(v -> finish()); header.addView(back, new LinearLayout.LayoutParams(dp(52), dp(48)));
        TextView title = label(file.getName(), text, 19); title.setSingleLine(true); header.addView(title, new LinearLayout.LayoutParams(0, dp(48), 1)); root.addView(header);
        LinearLayout content = new LinearLayout(this); content.setGravity(Gravity.CENTER); content.setPadding(dp(16), dp(16), dp(16), dp(16)); GradientDrawable surface = new GradientDrawable(); surface.setColor(card); surface.setCornerRadius(dp(28)); content.setBackground(surface);
        String extension = extension(file);
        if (isImage(extension)) { ImageView image = new ImageView(this); image.setImageBitmap(BitmapFactory.decodeFile(file.getPath())); image.setAdjustViewBounds(true); image.setScaleType(ImageView.ScaleType.FIT_CENTER); content.addView(image, new LinearLayout.LayoutParams(-1, -2)); }
        else if (isVideo(extension)) { VideoView video = new VideoView(this); video.setVideoURI(Uri.fromFile(file)); video.setOnPreparedListener(player -> { player.setLooping(true); video.start(); }); content.addView(video, new LinearLayout.LayoutParams(-1, dp(300))); }
        else if (isText(extension)) { TextView value = label(readText(file), text, 14); value.setTextIsSelectable(true); ScrollView scroll = new ScrollView(this); scroll.addView(value); content.addView(scroll, new LinearLayout.LayoutParams(-1, dp(360))); }
        else { TextView unavailable = label(t("previewUnavailable"), text, 16); unavailable.setGravity(Gravity.CENTER); content.addView(unavailable, new LinearLayout.LayoutParams(-1, dp(180))); }
        root.addView(content, new LinearLayout.LayoutParams(-1, 0, 1));
        Button open = new Button(this); open.setText(t("openWith")); open.setTextColor(Color.WHITE); open.setTextSize(17); open.setBackground(pill(Color.rgb(10,132,255))); open.setOnClickListener(v -> openExternal(file)); LinearLayout.LayoutParams openParams = new LinearLayout.LayoutParams(-1, dp(48)); openParams.topMargin = dp(14); root.addView(open, openParams);
        setContentView(root);
    }

    private void openExternal(File file) { Uri uri = androidx.core.content.FileProvider.getUriForFile(this, "com.ao.sendfileoverwifi.files", file); Intent intent = new Intent(Intent.ACTION_VIEW).setDataAndType(uri, getContentResolver().getType(uri) == null ? "*/*" : getContentResolver().getType(uri)).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION); startActivity(Intent.createChooser(intent, t("openWith"))); }
    private static boolean isImage(String x) { return x.matches("jpg|jpeg|png|gif|webp|bmp|heic|heif"); }
    private static boolean isVideo(String x) { return x.matches("mp4|mov|m4v|webm|3gp"); }
    private static boolean isText(String x) { return x.matches("txt|md|json|xml|csv|log|html|htm|java|swift|js|css"); }
    private static String extension(File file) { String name=file.getName(); int dot=name.lastIndexOf('.'); return dot < 0 ? "" : name.substring(dot+1).toLowerCase(Locale.ROOT); }
    private String readText(File file) { try(FileInputStream input=new FileInputStream(file)){byte[] bytes=new byte[(int)Math.min(file.length(),64*1024)];int count=input.read(bytes);return new String(bytes,0,Math.max(0,count),StandardCharsets.UTF_8);}catch(Exception error){return t("textReadFailed");} }
    private String t(String key) { try (java.io.InputStream input = getAssets().open("ui.json")) { org.json.JSONObject values = new org.json.JSONObject(new String(input.readAllBytes(), StandardCharsets.UTF_8)).getJSONObject("strings").getJSONObject(key); String language = getSharedPreferences("settings", MODE_PRIVATE).getString("language", ""); String code = language.isEmpty() ? java.util.Locale.getDefault().getLanguage() : language; if ("zh".equals(code)) code = "cn"; return values.optString(code, values.getString("en")); } catch (Exception ignored) { return key; } }
    private TextView label(String value,int color,int size){TextView view=new TextView(this);view.setText(value);view.setTextColor(color);view.setTextSize(size);return view;}
    private GradientDrawable pill(int color){GradientDrawable shape=new GradientDrawable();shape.setColor(color);shape.setCornerRadius(dp(24));return shape;}
    private int dp(int value){return (int)(value*getResources().getDisplayMetrics().density+.5f);}
}

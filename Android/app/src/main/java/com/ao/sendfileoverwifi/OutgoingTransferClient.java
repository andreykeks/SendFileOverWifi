package com.ao.sendfileoverwifi;

import android.content.ContentResolver;
import android.content.Context;
import android.net.Uri;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;

import javax.net.ssl.SSLSocket;

/** Sender half of v1: prepares stable private copies so sources can be re-read. */
final class OutgoingTransferClient {
    interface Callback { void onPairing(String code); void onProgress(int file, int count, long bytes, long total); void onCompleted(int sent, long bytes, int skipped); void onError(String error); }
    private final Context context; private final Callback callback;
    OutgoingTransferClient(Context context, Callback callback) { this.context = context.getApplicationContext(); this.callback = callback; }

    void transfer(ArrayList<Uri> uris, LocalDiscovery.Recipient recipient, String senderName) {
        new Thread(() -> run(uris, recipient, senderName), "sendfile-sender").start();
    }

    // Resume transport uses the same authenticated TLS connection. The caller
    // supplies sources restored from noBackupFilesDir and a prior transfer id.
    void resume(ArrayList<Uri> uris, LocalDiscovery.Recipient recipient, String transferId, String senderName) {
        // A missing/expired state is intentionally handled as a normal failed
        // transfer rather than silently creating a new offer.
        new Thread(() -> runResume(uris, recipient, transferId, senderName), "sendfile-resume").start();
    }

    private void run(ArrayList<Uri> uris, LocalDiscovery.Recipient recipient, String senderName) {
        ArrayList<Source> files = new ArrayList<>(); boolean successful = false;
        try {
            for (Uri uri : uris) files.add(copySource(uri));
            long total = 0; JSONArray manifestFiles = new JSONArray();
            for (Source file : files) { total += file.size; JSONObject item = new JSONObject().put("path", encode(file.name)).put("size", Long.toString(file.size)).put("sha256", file.sha); if (file.createdAt != null) item.put("createdAt", file.createdAt); if (file.modifiedAt != null) item.put("modifiedAt", file.modifiedAt); if (file.mimeType != null) item.put("mimeType", file.mimeType); manifestFiles.put(item); }
            try (SSLSocket socket = (SSLSocket) TlsIdentity.context(context).getSocketFactory().createSocket(recipient.host, recipient.port);
                 BufferedInputStream input = new BufferedInputStream(socket.getInputStream()); BufferedOutputStream output = new BufferedOutputStream(socket.getOutputStream())) {
                socket.setEnabledProtocols(new String[]{"TLSv1.3"}); socket.setSoTimeout(90_000); socket.startHandshake(); callback.onPairing(TlsIdentity.pairingCode(socket));
                Map<String,String> headers = headers(recipient, senderName); headers.put("Content-Type", "application/json");
                write(output, "POST", "/v1/offer", headers, new JSONObject().put("files", manifestFiles).toString().getBytes(StandardCharsets.UTF_8));
                Response offer = read(input); if (offer.status != 202) throw new Exception("Offer rejected: " + offer.status);
                String id = offer.headers.get("x-receive-file-transfer"); if (id == null) throw new Exception("Missing transfer ID");
                ArrayList<String> resumeSources = new ArrayList<>(); for (Source source : files) resumeSources.add(source.file.getAbsolutePath());
                OutgoingResumeStore.save(context, id, resumeSources);
                JSONObject acceptance = new JSONObject(new String(offer.body, StandardCharsets.UTF_8)); JSONArray states = acceptance.getJSONArray("files");
                int skipped = sendFiles(input, output, recipient, id, files, states);
                Response result = complete(input, output, recipient, id);
                OutgoingResumeStore.clear(context); successful = true; callback.onCompleted(files.size() - skipped, total(files), skipped);
            }
        } catch (Exception error) { callback.onError(error.getMessage() == null ? error.toString() : error.getMessage()); }
        finally { if (successful) for (Source source : files) source.file.delete(); }
    }

    private void runResume(ArrayList<Uri> uris, LocalDiscovery.Recipient recipient, String id, String senderName) {
        ArrayList<Source> files = new ArrayList<>(); boolean successful = false;
        try {
            for (Uri uri : uris) files.add(existingSource(uri));
            try (SSLSocket socket = (SSLSocket) TlsIdentity.context(context).getSocketFactory().createSocket(recipient.host, recipient.port);
                 BufferedInputStream input = new BufferedInputStream(socket.getInputStream()); BufferedOutputStream output = new BufferedOutputStream(socket.getOutputStream())) {
                socket.setEnabledProtocols(new String[]{"TLSv1.3"}); socket.setSoTimeout(90_000); socket.startHandshake(); callback.onPairing(TlsIdentity.pairingCode(socket));
                write(output, "GET", "/v1/transfers/" + id, headers(recipient, senderName), new byte[0]);
                Response response = read(input);
                if (response.status == 410) { OutgoingResumeStore.clear(context); throw new Exception("Resume expired (410)"); }
                if (response.status == 403) { OutgoingResumeStore.clear(context); throw new Exception("Resume is not authorized (403)"); }
                if (response.status != 200) throw new Exception("Resume status rejected: " + response.status);
                JSONArray states = new JSONObject(new String(response.body, StandardCharsets.UTF_8)).getJSONArray("files");
                if (states.length() != files.size()) throw new Exception("Saved transfer does not match receiver state");
                int skipped = sendFiles(input, output, recipient, id, files, states);
                complete(input, output, recipient, id);
                OutgoingResumeStore.clear(context); successful = true; callback.onCompleted(files.size() - skipped, total(files), skipped);
            }
        } catch (Exception error) { callback.onError(error.getMessage() == null ? error.toString() : error.getMessage()); }
        finally { if (successful) for (Source source : files) source.file.delete(); }
    }

    private int sendFiles(BufferedInputStream input, BufferedOutputStream output, LocalDiscovery.Recipient recipient, String id, ArrayList<Source> files, JSONArray states) throws Exception {
        long completed = 0; int skipped = 0;
        for (int index = 0; index < files.size(); index++) {
            Source file = files.get(index); JSONObject remote = states.getJSONObject(index);
            if (remote.optLong("size", file.size) != file.size) throw new Exception("Saved file size changed: " + file.name);
            String state = remote.optString("state", "uploading");
            long offset = remote.optLong("nextOffset", 0);
            if (offset < 0 || offset > file.size) throw new Exception("Invalid saved offset");
            if ("skipped".equals(state)) { skipped++; completed += file.size; continue; }
            if ("received".equals(state) || "already-present".equals(state)) { completed += file.size; callback.onProgress(index + 1, files.size(), completed, total(files)); continue; }
            if (!"uploading".equals(state)) throw new Exception("Receiver cannot resume file " + (index + 1));
            try (FileInputStream source = new FileInputStream(file.file)) {
                source.getChannel().position(offset); byte[] block = new byte[IncomingTransferServer.CHUNK_SIZE];
                while (offset < file.size || (file.size == 0 && offset == 0)) {
                    int wanted = (int)Math.min(block.length, file.size - offset); int count = wanted == 0 ? 0 : source.read(block, 0, wanted);
                    if (count != wanted) throw new Exception("Source changed: " + file.name);
                    byte[] body = count == 0 ? new byte[0] : java.util.Arrays.copyOf(block, count); Map<String,String> chunk = headers(recipient, null); chunk.put("Content-Type", "application/octet-stream"); chunk.put("X-Receive-File-Offset", Long.toString(offset));
                    write(output, "PATCH", "/v1/transfers/" + id + "/files/" + index, chunk, body); Response response = read(input);
                    if (response.status == 422) { skipped++; break; }
                    if (response.status == 409 && response.headers.containsKey("x-receive-file-next-offset")) { offset = Long.parseLong(response.headers.get("x-receive-file-next-offset")); source.getChannel().position(offset); continue; }
                    if (response.status != 204) throw new Exception("Chunk rejected: " + response.status);
                    offset += count; callback.onProgress(index + 1, files.size(), completed + offset, total(files)); if (count == 0) break;
                }
            }
            completed += file.size;
        }
        return skipped;
    }

    private Response complete(BufferedInputStream input, BufferedOutputStream output, LocalDiscovery.Recipient recipient, String id) throws Exception {
        write(output, "POST", "/v1/transfers/" + id + "/complete", headers(recipient, null), new byte[0]); Response result = read(input);
        if (result.status != 201 && result.status != 207) throw new Exception("Completion rejected: " + result.status);
        return result;
    }

    private long total(ArrayList<Source> files) { long value = 0; for (Source file : files) value = Math.addExact(value, file.size); return value; }

    private Source copySource(Uri uri) throws Exception {
        File dir = new File(context.getNoBackupFilesDir(), "outgoing"); dir.mkdirs(); String name = "file"; long modified = 0; android.database.Cursor cursor = context.getContentResolver().query(uri, null, null, null, null); if (cursor != null) { if (cursor.moveToFirst()) { int i = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME); if (i >= 0) name = cursor.getString(i); int m = cursor.getColumnIndex(android.provider.DocumentsContract.Document.COLUMN_LAST_MODIFIED); if (m >= 0 && !cursor.isNull(m)) modified = cursor.getLong(m); } cursor.close(); }
        File target = File.createTempFile("source-", "-" + name.replaceAll("[^A-Za-z0-9._-]", "_"), dir); MessageDigest hash = MessageDigest.getInstance("SHA-256"); long size = 0;
        try (InputStream input = context.getContentResolver().openInputStream(uri); FileOutputStream output = new FileOutputStream(target)) { if (input == null) throw new Exception("Source unavailable"); byte[] bytes = new byte[64 * 1024]; for (int n; (n = input.read(bytes)) != -1;) { output.write(bytes,0,n); hash.update(bytes,0,n); size += n; } }
        StringBuilder sha = new StringBuilder(); for (byte b : hash.digest()) sha.append(String.format(Locale.ROOT, "%02x", b)); String mime = context.getContentResolver().getType(uri); return new Source(target, name, size, sha.toString(), null, modified > 0 ? java.time.Instant.ofEpochMilli(modified).toString() : null, mime);
    }
    private Source existingSource(Uri uri) throws Exception {
        if (!"file".equals(uri.getScheme())) throw new Exception("Saved source unavailable");
        File source = new File(uri.getPath()).getCanonicalFile();
        File directory = new File(context.getNoBackupFilesDir(), "outgoing").getCanonicalFile();
        if (!source.exists() || !source.isFile() || !source.getPath().startsWith(directory.getPath() + File.separator)) throw new Exception("Saved source unavailable");
        MessageDigest hash = MessageDigest.getInstance("SHA-256"); long size = 0; byte[] bytes = new byte[64 * 1024];
        try (FileInputStream input = new FileInputStream(source)) { for (int n; (n = input.read(bytes)) != -1;) { hash.update(bytes, 0, n); size += n; } }
        StringBuilder sha = new StringBuilder(); for (byte b : hash.digest()) sha.append(String.format(Locale.ROOT, "%02x", b));
        String name = source.getName(); int dash = name.indexOf('-'); if (dash >= 0 && dash + 1 < name.length()) name = name.substring(dash + 1);
        return new Source(source, name, size, sha.toString(), null, source.lastModified() > 0 ? java.time.Instant.ofEpochMilli(source.lastModified()).toString() : null, null);
    }
    private static Map<String,String> headers(LocalDiscovery.Recipient r, String name) { Map<String,String> result = new LinkedHashMap<>(); result.put("Host", r.host + ":" + r.port); result.put("X-Receive-File-Token", r.token); if (name != null && !name.trim().isEmpty()) result.put("X-SendFile-Device-Name", name.replace("\r"," ").replace("\n"," ")); return result; }
    private static String encode(String value) { return value.replace("%", "%25").replace(" ", "%20").replace("/", "%2F"); }
    private static void write(BufferedOutputStream o, String method, String path, Map<String,String> headers, byte[] body) throws Exception { o.write((method + " " + path + " HTTP/1.1\r\n").getBytes(StandardCharsets.US_ASCII)); headers.put("Content-Length", Integer.toString(body.length)); for (Map.Entry<String,String> h : headers.entrySet()) o.write((h.getKey()+": "+h.getValue()+"\r\n").getBytes(StandardCharsets.UTF_8)); o.write("\r\n".getBytes(StandardCharsets.US_ASCII)); o.write(body); o.flush(); }
    private static Response read(BufferedInputStream in) throws Exception { String start=line(in); if(start==null) throw new Exception("Connection closed"); String[] p=start.split(" "); Map<String,String> h=new LinkedHashMap<>(); for(String l; !(l=line(in)).isEmpty();) { int c=l.indexOf(':'); h.put(l.substring(0,c).toLowerCase(Locale.ROOT),l.substring(c+1).trim()); } int n=Integer.parseInt(h.getOrDefault("content-length","0")); byte[] body=new byte[n]; for(int at=0,got;at<n;at+=got){got=in.read(body,at,n-at);if(got<0)throw new Exception("Connection closed");} return new Response(Integer.parseInt(p[1]),h,body); }
    private static String line(BufferedInputStream in) throws Exception { ByteArrayOutputStream b=new ByteArrayOutputStream(); int first=in.read(); if(first==-1)return null; if(first!='\r'&&first!='\n')b.write(first); for(int n;(n=in.read())!=-1;) { if(n=='\n') break; if(n!='\r') b.write(n); } return b.toString("UTF-8"); }
    private static final class Source { final File file; final String name,sha,createdAt,modifiedAt,mimeType; final long size; Source(File f,String n,long s,String h,String c,String m,String type){file=f;name=n;size=s;sha=h;createdAt=c;modifiedAt=m;mimeType=type;} }
    private static final class Response { final int status; final Map<String,String> headers; final byte[] body; Response(int s,Map<String,String>h,byte[]b){status=s;headers=h;body=b;} }
}

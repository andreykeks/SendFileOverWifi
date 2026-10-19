package com.ao.sendfileoverwifi;

import android.content.Context;
import android.os.StatFs;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.net.ServerSocket;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import javax.net.ssl.SSLServerSocket;
import javax.net.ssl.SSLSocket;

/** Receiver half of protocol v1. One accepted or paused session is allowed at a time. */
final class IncomingTransferServer {
    private static final String LOG = "SendFileReceiver";
    static final int CHUNK_SIZE = 4 * 1024 * 1024;

    interface Callback {
        boolean confirmPairing(String code, String fingerprint);
        boolean confirmOffer(int count, long bytes, String senderName);
        void onProgress(int index, int count, long bytes, long total);
        void onCompleted(int count, long bytes, int skipped);
        void onError(String message);
    }

    private final Context context;
    private final Callback callback;
    private final ExecutorService workers = Executors.newCachedThreadPool();
    private volatile SSLServerSocket listener;
    private volatile boolean active;
    private volatile String token;
    private volatile Session session;

    IncomingTransferServer(Context context, Callback callback) { this.context = context.getApplicationContext(); this.callback = callback; }

    synchronized int start(String expectedToken) throws Exception {
        stop(); token = expectedToken; restoreSession();
        listener = (SSLServerSocket) TlsIdentity.context(context).getServerSocketFactory().createServerSocket(0);
        listener.setEnabledProtocols(new String[]{"TLSv1.3"});
        listener.setNeedClientAuth(true);
        active = true;
        workers.execute(() -> acceptLoop(listener));
        return listener.getLocalPort();
    }

    synchronized void stop() {
        active = false;
        if (listener != null) try { listener.close(); } catch (IOException ignored) { }
        listener = null;
    }

    synchronized void stopAccepting() {
        if (listener != null) try { listener.close(); } catch (IOException ignored) { }
        listener = null;
    }

    boolean isActive() { return active; }

    private void acceptLoop(ServerSocket server) {
        while (active) try {
            SSLSocket socket = (SSLSocket) server.accept();
            workers.execute(() -> handle(socket));
        } catch (IOException error) { if (active) { safeLog("TLS listener error", error); callback.onError("Receiver socket error: " + error.getMessage()); } }
    }

    private void handle(SSLSocket socket) {
        try (SSLSocket connection = socket;
             BufferedInputStream input = new BufferedInputStream(connection.getInputStream());
             BufferedOutputStream output = new BufferedOutputStream(connection.getOutputStream())) {
            connection.setSoTimeout(90_000);
            connection.setEnabledProtocols(new String[]{"TLSv1.3"});
            connection.startHandshake();
            X509Certificate peer = (X509Certificate) connection.getSession().getPeerCertificates()[0];
            String fingerprint = TlsIdentity.fingerprint(peer);
            if (!isTrusted(fingerprint)) {
                if (!callback.confirmPairing(TlsIdentity.pairingCode(connection), fingerprint)) return;
                trust(fingerprint);
            }
            while (active && !connection.isClosed()) {
                Request request = Request.read(input);
                if (request == null) return;
                Response response = dispatch(request, fingerprint);
                response.write(output); output.flush();
                if (response.close) return;
            }
        } catch (Exception error) { if (active) { safeLog("TLS receiver connection failed", error); callback.onError("Receiver connection error: " + error.getMessage()); } }
    }

    /** System logs are a debug log too: never include exception text, headers or paths. */
    private static void safeLog(String event, Exception error) {
        Log.e(LOG, event + "; " + error.getClass().getSimpleName());
    }

    private Response dispatch(Request request, String fingerprint) throws Exception {
        if (!equalsToken(request.header("x-receive-file-token"))) return Response.empty(401, "Invalid Session Token");
        if ("POST".equals(request.method) && "/v1/offer".equals(request.path)) return offer(request, fingerprint);
        if ("PATCH".equals(request.method) && request.path.startsWith("/v1/transfers/")) return chunk(request, fingerprint);
        if ("POST".equals(request.method) && request.path.endsWith("/complete")) return complete(request, fingerprint);
        if ("GET".equals(request.method) && request.path.startsWith("/v1/transfers/")) return status(request, fingerprint);
        if ("DELETE".equals(request.method) && request.path.startsWith("/v1/transfers/")) { clearSession(); return Response.empty(204, "Transfer Cancelled"); }
        return Response.empty(400, "Bad Request");
    }

    private synchronized Response offer(Request request, String fingerprint) throws Exception {
        if (session != null) return Response.empty(409, "Another Offer Is Pending");
        JSONObject object = new JSONObject(new String(request.body, StandardCharsets.UTF_8));
        JSONArray files = object.getJSONArray("files");
        if (files.length() == 0) return Response.empty(400, "Bad Request");
        ArrayList<Entry> entries = new ArrayList<>(); long total = 0;
        for (int i = 0; i < files.length(); i++) {
            JSONObject item = files.getJSONObject(i);
            String path = item.getString("path"); long size = Long.parseLong(item.getString("size")); String sha = item.getString("sha256");
            if (size < 0 || !sha.matches("[0-9a-f]{64}") || !safePath(path)) return Response.empty(400, "Bad Request");
            total = Math.addExact(total, size); entries.add(new Entry(i, path, size, sha, item.optString("createdAt", null), item.optString("modifiedAt", null), item.optString("mimeType", null)));
        }
        long available = new StatFs(context.getFilesDir().getPath()).getAvailableBytes();
        if (available < total) return Response.empty(507, "Insufficient Storage");
        String sender = request.header("x-sendfile-device-name");
        TrustedDeviceStore.trust(context, fingerprint, sender);
        if (!callback.confirmOffer(entries.size(), total, sender == null ? "" : sender)) return Response.empty(403, "Declined");
        File stage = new File(context.getNoBackupFilesDir(), "receive-" + UUID.randomUUID()); if (!stage.mkdirs()) return Response.empty(507, "Insufficient Storage");
        File destination = new File(context.getFilesDir(), "Received Files"); destination.mkdirs();
        for (Entry entry : entries) entry.prepare(stage, destination);
        session = new Session(UUID.randomUUID().toString(), fingerprint, entries, total, stage);
        persist(session);
        JSONArray accepted = new JSONArray();
        for (Entry entry : entries) accepted.put(new JSONObject().put("index", entry.index).put("path", entry.path).put("state", entry.state));
        return Response.json(202, "Offer Accepted", new JSONObject().put("files", accepted).toString(), "X-Receive-File-Transfer", session.id);
    }

    private synchronized Response chunk(Request request, String fingerprint) throws Exception {
        Session current = matchingSession(request.path, fingerprint); if (current == null) return Response.empty(403, "Declined");
        String[] pieces = request.path.split("/"); if (pieces.length != 6) return Response.empty(400, "Bad Request");
        int index = Integer.parseInt(pieces[5]); if (index < 0 || index >= current.entries.size()) return Response.empty(400, "Bad Request");
        Entry entry = current.entries.get(index); long offset = Long.parseLong(request.header("x-receive-file-offset"));
        if (offset != entry.offset) return Response.empty(409, "Offset Mismatch", "X-Receive-File-Next-Offset", Long.toString(entry.offset));
        if (request.body.length > CHUNK_SIZE || offset + request.body.length > entry.size) return Response.empty(400, "Bad Request");
        try (FileOutputStream file = new FileOutputStream(entry.staging, true)) { file.write(request.body); file.getFD().sync(); }
        entry.offset += request.body.length;
        persist(current);
        if (entry.offset == entry.size) {
            if (!entry.sha.equals(sha256(entry.staging))) { entry.staging.delete(); entry.state = "skipped"; persist(current); return Response.empty(422, "File Changed"); }
            entry.state = "received";
            persist(current);
        }
        callback.onProgress(index + 1, current.entries.size(), current.confirmed(), current.total);
        return Response.empty(204, "Chunk Received", "X-Receive-File-Next-Offset", Long.toString(entry.offset));
    }

    private synchronized Response complete(Request request, String fingerprint) throws Exception {
        Session current = matchingSession(request.path, fingerprint); if (current == null) return Response.empty(403, "Declined");
        for (Entry entry : current.entries) if (!"received".equals(entry.state) && !"skipped".equals(entry.state) && !"already-present".equals(entry.state)) return Response.empty(409, "Transfer Incomplete");
        int skipped = 0;
        for (Entry entry : current.entries) if ("received".equals(entry.state)) entry.finish(context.getSharedPreferences("settings", Context.MODE_PRIVATE).getBoolean("save-date", false)); else if ("skipped".equals(entry.state)) skipped++;
        TransferStateStore.clear(context, null); delete(current.stage); session = null; active = false; stopAccepting(); callback.onCompleted(current.entries.size() - skipped, current.total, skipped);
        return Response.empty(skipped == 0 ? 201 : 207, skipped == 0 ? "Received" : "Transfer Completed With Skipped Files");
    }

    private synchronized Response status(Request request, String fingerprint) throws Exception {
        Session current = matchingSession(request.path, fingerprint); if (current == null) return Response.empty(410, "Transfer Expired");
        JSONArray files = new JSONArray(); for (Entry entry : current.entries) files.put(new JSONObject().put("index", entry.index).put("size", Long.toString(entry.size)).put("nextOffset", Long.toString(entry.offset)).put("state", entry.state));
        return Response.json(200, "Transfer Status", new JSONObject().put("state", "uploading").put("files", files).toString());
    }

    private Session matchingSession(String path, String fingerprint) { if (session == null || !session.senderFingerprint.equals(fingerprint) || !path.contains("/" + session.id)) return null; return session; }
    private boolean equalsToken(String value) { return token != null && token.equals(value); }
    private void clearSession() { if (session != null) { delete(session.stage); session = null; } TransferStateStore.clear(context, null); }
    private void persist(Session value) { try { org.json.JSONArray files=new org.json.JSONArray(); for(Entry e:value.entries)files.put(new org.json.JSONObject().put("index",e.index).put("path",e.path).put("size",Long.toString(e.size)).put("sha256",e.sha).put("createdAt",e.createdAt).put("modifiedAt",e.modifiedAt).put("mimeType",e.mimeType).put("offset",e.offset).put("state",e.state).put("staging",e.staging.getAbsolutePath()).put("final",e.finalFile.getAbsolutePath())); TransferStateStore.save(context,new org.json.JSONObject().put("id",value.id).put("fingerprint",value.senderFingerprint).put("stage",value.stage.getAbsolutePath()).put("total",Long.toString(value.total)).put("files",files)); } catch(Exception ignored) { } }
    private boolean isTrusted(String fingerprint) { return TrustedDeviceStore.contains(context, fingerprint); }
    private void trust(String fingerprint) { TrustedDeviceStore.trust(context, fingerprint, null); }
    private void restoreSession() {
        if (session != null) return;
        JSONObject saved = TransferStateStore.load(context); if (saved == null) return;
        try {
            File stage = new File(saved.getString("stage")).getCanonicalFile();
            File root = context.getNoBackupFilesDir().getCanonicalFile();
            if (!stage.exists() || !stage.getPath().startsWith(root.getPath() + File.separator)) { TransferStateStore.clear(context, saved); return; }
            ArrayList<Entry> entries = new ArrayList<>(); JSONArray list = saved.getJSONArray("files");
            for (int i = 0; i < list.length(); i++) {
                JSONObject item = list.getJSONObject(i); Entry entry = new Entry(item.getInt("index"), item.getString("path"), Long.parseLong(item.getString("size")), item.getString("sha256"), item.optString("createdAt", null), item.optString("modifiedAt", null), item.optString("mimeType", null));
                entry.offset = item.getLong("offset"); entry.state = item.getString("state"); entry.staging = new File(item.getString("staging")); entry.finalFile = new File(item.getString("final"));
                if (entry.offset < 0 || entry.offset > entry.size || !entry.staging.getCanonicalPath().startsWith(stage.getPath() + File.separator)) throw new IOException("Invalid saved transfer");
                if ("uploading".equals(entry.state) && (!entry.staging.exists() || entry.staging.length() != entry.offset)) throw new IOException("Missing partial file");
                entries.add(entry);
            }
            session = new Session(saved.getString("id"), saved.getString("fingerprint"), entries, Long.parseLong(saved.getString("total")), stage);
        } catch (Exception invalid) { TransferStateStore.clear(context, saved); }
    }
    private static boolean safePath(String encoded) { try { String path = java.net.URLDecoder.decode(encoded, "UTF-8"); return !path.startsWith("/") && !path.startsWith("\\") && !path.contains("\\") && !path.isEmpty() && !path.equals(".") && !path.equals("..") && !path.contains("../") && !path.contains("/../"); } catch (Exception error) { return false; } }
    private static String sha256(File file) throws Exception { MessageDigest hash = MessageDigest.getInstance("SHA-256"); byte[] block = new byte[64 * 1024]; try (FileInputStream input = new FileInputStream(file)) { for (int n; (n = input.read(block)) != -1;) hash.update(block, 0, n); } StringBuilder value = new StringBuilder(); for (byte b : hash.digest()) value.append(String.format(Locale.ROOT, "%02x", b)); return value.toString(); }
    private static void delete(File value) { if (value.isDirectory()) { File[] children = value.listFiles(); if (children != null) for (File child : children) delete(child); } value.delete(); }

    private static final class Entry {
        final int index; final String path; final long size; final String sha, createdAt, modifiedAt, mimeType; long offset; String state = "uploading"; File staging; File finalFile;
        Entry(int index, String path, long size, String sha, String createdAt, String modifiedAt, String mimeType) { this.index = index; this.path = path; this.size = size; this.sha = sha; this.createdAt = createdAt; this.modifiedAt = modifiedAt; this.mimeType = mimeType; }
        void prepare(File stage, File destination) throws Exception {
            staging = new File(stage, index + ".part"); String relative = java.net.URLDecoder.decode(path, "UTF-8"); File requested = new File(destination, relative).getCanonicalFile(); File root = destination.getCanonicalFile();
            if (!requested.getPath().startsWith(root.getPath() + File.separator)) throw new IOException("Unsafe path");
            if (requested.exists() && sha.equals(sha256(requested))) { finalFile = requested; state = "already-present"; }
            else finalFile = unique(requested);
        }
        void finish(boolean preserveDates) throws IOException {
            File parent = finalFile.getParentFile(); if (parent != null) parent.mkdirs();
            if (!staging.renameTo(finalFile)) throw new IOException("Cannot finalize received file");
            applyDates(preserveDates);
        }
        private void applyDates(boolean preserveDates) {
            if (!preserveDates || modifiedAt == null) return;
            // Android's public Java API has no setter for creation/birth time.
            // Apply modifiedAt after the final rename, independently of every
            // other metadata field, so it is never lost due to an unsupported
            // createdAt or MIME operation.
            try { finalFile.setLastModified(java.time.Instant.parse(modifiedAt).toEpochMilli()); }
            catch (Exception ignored) { }
        }
        private static File unique(File desired) { if (!desired.exists()) return desired; String n = desired.getName(); int dot = n.lastIndexOf('.'); String base = dot > 0 ? n.substring(0, dot) : n; String ext = dot > 0 ? n.substring(dot) : ""; for (int i = 2; ; i++) { File candidate = new File(desired.getParentFile(), base + " (" + i + ")" + ext); if (!candidate.exists()) return candidate; } }
    }
    private static final class Session { final String id, senderFingerprint; final ArrayList<Entry> entries; final long total; final File stage; Session(String id, String fp, ArrayList<Entry> entries, long total, File stage) { this.id = id; this.senderFingerprint = fp; this.entries = entries; this.total = total; this.stage = stage; } long confirmed() { long n = 0; for (Entry entry : entries) n += entry.offset; return n; } }
    private static final class Request {
        final String method, path; final Map<String, String> headers; final byte[] body;
        Request(String method, String path, Map<String, String> headers, byte[] body) { this.method = method; this.path = path; this.headers = headers; this.body = body; }
        String header(String key) { return headers.get(key.toLowerCase(Locale.ROOT)); }
        static Request read(BufferedInputStream input) throws Exception { String first = line(input); if (first == null) return null; String[] start = first.split(" "); if (start.length != 3) throw new IOException("Bad request line"); Map<String, String> headers = new LinkedHashMap<>(); for (String line; !(line = line(input)).isEmpty();) { int colon = line.indexOf(':'); if (colon <= 0) throw new IOException("Bad header"); headers.put(line.substring(0, colon).trim().toLowerCase(Locale.ROOT), line.substring(colon + 1).trim()); } int length = Integer.parseInt(headers.getOrDefault("content-length", "0")); if (length < 0 || length > CHUNK_SIZE) throw new IOException("Invalid content length"); byte[] body = new byte[length]; for (int at = 0, n; at < length; at += n) { n = input.read(body, at, length - at); if (n < 0) throw new IOException("Unexpected end of stream"); } return new Request(start[0], start[1], headers, body); }
        static String line(BufferedInputStream input) throws IOException { ByteArrayOutputStream value = new ByteArrayOutputStream(); int first = input.read(); if (first == -1) return null; if (first != '\r' && first != '\n') value.write(first); for (int next; (next = input.read()) != -1;) { if (next == '\n') break; if (next != '\r') value.write(next); if (value.size() > 16 * 1024) throw new IOException("Header too long"); } return value.toString("UTF-8"); }
    }
    private static final class Response {
        final int status; final String reason; final byte[] body; final Map<String, String> headers = new LinkedHashMap<>(); boolean close;
        Response(int status, String reason, byte[] body) { this.status = status; this.reason = reason; this.body = body; }
        static Response empty(int status, String reason, String... headers) { Response response = new Response(status, reason, new byte[0]); for (int i = 0; i + 1 < headers.length; i += 2) response.headers.put(headers[i], headers[i + 1]); return response; }
        static Response json(int status, String reason, String json, String... headers) { Response response = new Response(status, reason, json.getBytes(StandardCharsets.UTF_8)); response.headers.put("Content-Type", "application/json"); for (int i = 0; i + 1 < headers.length; i += 2) response.headers.put(headers[i], headers[i + 1]); return response; }
        void write(BufferedOutputStream output) throws IOException { headers.put("Content-Length", Integer.toString(body.length)); output.write(("HTTP/1.1 " + status + " " + reason + "\r\n").getBytes(StandardCharsets.US_ASCII)); for (Map.Entry<String, String> header : headers.entrySet()) output.write((header.getKey() + ": " + header.getValue() + "\r\n").getBytes(StandardCharsets.UTF_8)); output.write("\r\n".getBytes(StandardCharsets.US_ASCII)); output.write(body); }
    }
}

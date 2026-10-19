package com.ao.sendfileoverwifi;

import android.content.Context;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.Handler;
import android.os.Looper;

import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Android NSD implementation of the v1 `_sendfile._tcp` discovery contract. */
final class LocalDiscovery {
    static final String SERVICE_TYPE = "_sendfile._tcp.";

    static final class Recipient {
        final String name;
        final String host;
        final int port;
        final String token;
        Recipient(String name, String host, int port, String token) { this.name = name; this.host = host; this.port = port; this.token = token; }
        String key() { return host + ":" + port + "/" + token; }
    }

    interface Listener {
        void onRecipients(List<Recipient> recipients);
        void onDiscoveryError(String error);
    }

    private final NsdManager nsd;
    private final Handler main = new Handler(Looper.getMainLooper());
    private NsdManager.RegistrationListener registration;
    private NsdManager.DiscoveryListener discovery;
    private final Map<String, Recipient> recipients = new LinkedHashMap<>();
    private Runnable timeout;

    LocalDiscovery(Context context) { nsd = (NsdManager) context.getSystemService(Context.NSD_SERVICE); }

    void register(String displayName, int port, String token, Runnable onReady, java.util.function.Consumer<String> onError) {
        stopAdvertising();
        NsdServiceInfo info = new NsdServiceInfo();
        info.setServiceName(displayName == null || displayName.trim().isEmpty() ? "SendFile" : displayName.trim());
        info.setServiceType(SERVICE_TYPE);
        info.setPort(port);
        info.setAttribute("v", "1");
        info.setAttribute("t", token);
        registration = new NsdManager.RegistrationListener() {
            @Override public void onServiceRegistered(NsdServiceInfo value) { main.post(onReady); }
            @Override public void onRegistrationFailed(NsdServiceInfo value, int error) { main.post(() -> onError.accept("mDNS registration error " + error)); }
            @Override public void onServiceUnregistered(NsdServiceInfo value) { }
            @Override public void onUnregistrationFailed(NsdServiceInfo value, int error) { }
        };
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, registration);
    }

    void stopAdvertising() {
        if (registration != null) { try { nsd.unregisterService(registration); } catch (IllegalArgumentException ignored) { } registration = null; }
    }

    void browseForEightSeconds(Listener listener) {
        stopBrowsing(); recipients.clear();
        discovery = new NsdManager.DiscoveryListener() {
            @Override public void onDiscoveryStarted(String serviceType) { }
            @Override public void onServiceFound(NsdServiceInfo service) {
                if (!SERVICE_TYPE.equals(service.getServiceType())) return;
                try { nsd.resolveService(service, new NsdManager.ResolveListener() {
                    @Override public void onResolveFailed(NsdServiceInfo ignored, int error) { }
                    @Override public void onServiceResolved(NsdServiceInfo resolved) { addResolved(resolved, listener); }
                }); } catch (IllegalArgumentException ignored) { }
            }
            @Override public void onServiceLost(NsdServiceInfo service) { }
            @Override public void onDiscoveryStopped(String serviceType) { }
            @Override public void onStartDiscoveryFailed(String serviceType, int error) { main.post(() -> listener.onDiscoveryError("mDNS discovery error " + error)); stopBrowsing(); }
            @Override public void onStopDiscoveryFailed(String serviceType, int error) { stopBrowsing(); }
        };
        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discovery);
        timeout = () -> stopBrowsing(); main.postDelayed(timeout, 8_000L);
    }

    void stopBrowsing() {
        if (timeout != null) { main.removeCallbacks(timeout); timeout = null; }
        if (discovery != null) { try { nsd.stopServiceDiscovery(discovery); } catch (IllegalArgumentException ignored) { } discovery = null; }
    }

    private void addResolved(NsdServiceInfo value, Listener listener) {
        if (value.getHost() == null || value.getPort() <= 0) return;
        byte[] tokenBytes = value.getAttributes().get("t");
        if (tokenBytes == null || tokenBytes.length == 0) return;
        String token = new String(tokenBytes, java.nio.charset.StandardCharsets.US_ASCII);
        Recipient recipient = new Recipient(value.getServiceName(), value.getHost().getHostAddress(), value.getPort(), token);
        recipients.put(recipient.key(), recipient);
        main.post(() -> listener.onRecipients(new ArrayList<>(recipients.values())));
    }

    static String newToken() {
        byte[] bytes = new byte[8]; new SecureRandom().nextBytes(bytes);
        return android.util.Base64.encodeToString(bytes, android.util.Base64.URL_SAFE | android.util.Base64.NO_WRAP | android.util.Base64.NO_PADDING);
    }
}

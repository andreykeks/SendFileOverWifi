package com.ao.sendfileoverwifi;

import android.content.Context;
import org.json.JSONArray;
import org.json.JSONObject;
import java.util.ArrayList;
import java.util.List;

final class TrustedDeviceStore {
    static final class Device { final String fingerprint, name; Device(String f, String n) { fingerprint=f; name=n; } }
    private static final String KEY = "trusted-devices-v1";
    static synchronized List<Device> all(Context c) {
        ArrayList<Device> out = new ArrayList<>();
        try { JSONArray a = new JSONArray(c.getSharedPreferences("settings", Context.MODE_PRIVATE).getString(KEY, "[]")); for(int i=0;i<a.length();i++){JSONObject o=a.getJSONObject(i);out.add(new Device(o.getString("fingerprint"),o.optString("name","Unknown device")));} } catch(Exception ignored) { }
        return out;
    }
    static synchronized boolean contains(Context c,String f){for(Device d:all(c))if(d.fingerprint.equals(f))return true;return false;}
    static synchronized void trust(Context c,String f,String name){try{JSONArray a=new JSONArray();boolean found=false;for(Device d:all(c)){JSONObject o=new JSONObject().put("fingerprint",d.fingerprint).put("name",d.fingerprint.equals(f)&&name!=null&&!name.trim().isEmpty()?name:d.name);a.put(o);if(d.fingerprint.equals(f))found=true;}if(!found)a.put(new JSONObject().put("fingerprint",f).put("name",name==null||name.trim().isEmpty()?"Unknown device":name));c.getSharedPreferences("settings",Context.MODE_PRIVATE).edit().putString(KEY,a.toString()).apply();}catch(Exception ignored){}}
    static synchronized void remove(Context c,String f){try{JSONArray a=new JSONArray();for(Device d:all(c))if(!d.fingerprint.equals(f))a.put(new JSONObject().put("fingerprint",d.fingerprint).put("name",d.name));c.getSharedPreferences("settings",Context.MODE_PRIVATE).edit().putString(KEY,a.toString()).apply();}catch(Exception ignored){}}
}

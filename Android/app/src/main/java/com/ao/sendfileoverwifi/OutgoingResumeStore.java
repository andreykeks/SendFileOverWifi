package com.ao.sendfileoverwifi;

import android.content.Context;
import org.json.JSONArray;
import org.json.JSONObject;
import java.util.List;

/** Metadata only: no token, SAS, key or file contents are persisted. */
final class OutgoingResumeStore {
    private static final String KEY="outgoing-resume-v1";
    static void save(Context c,String transferId,List<String> sources){try{JSONArray a=new JSONArray();for(String s:sources)a.put(s);c.getSharedPreferences("settings",Context.MODE_PRIVATE).edit().putString(KEY,new JSONObject().put("id",transferId).put("sources",a).put("updatedAt",System.currentTimeMillis()).toString()).apply();}catch(Exception ignored){}}
    static JSONObject load(Context c){try{String s=c.getSharedPreferences("settings",Context.MODE_PRIVATE).getString(KEY,null);return s==null?null:new JSONObject(s);}catch(Exception ignored){return null;}}
    static void clear(Context c){c.getSharedPreferences("settings",Context.MODE_PRIVATE).edit().remove(KEY).apply();}
}

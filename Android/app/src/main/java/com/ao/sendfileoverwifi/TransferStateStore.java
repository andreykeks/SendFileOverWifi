package com.ao.sendfileoverwifi;

import android.content.Context;
import org.json.JSONObject;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;

/** Persisted receiver metadata; staging data is removed silently after 24 hours. */
final class TransferStateStore {
    private static final long EXPIRY_MS = 24L * 60L * 60L * 1000L;
    private static File file(Context c) { return new File(c.getNoBackupFilesDir(), "incoming-transfer-v1.json"); }
    static synchronized void save(Context c, JSONObject state) { try(FileOutputStream out=new FileOutputStream(file(c))){ state.put("updatedAt",System.currentTimeMillis());out.write(state.toString().getBytes("UTF-8")); }catch(Exception ignored){} }
    static synchronized JSONObject load(Context c) { try(FileInputStream in=new FileInputStream(file(c))){byte[] b=new byte[(int)file(c).length()];if(in.read(b)!=b.length)return null;JSONObject s=new JSONObject(new String(b,"UTF-8"));if(System.currentTimeMillis()-s.optLong("updatedAt")>EXPIRY_MS){clear(c,s);return null;}return s;}catch(Exception ignored){return null;} }
    static synchronized void clear(Context c, JSONObject state) { if(state!=null)delete(new File(state.optString("stage",""))); file(c).delete(); }
    private static void delete(File f){if(f.isDirectory()){File[] x=f.listFiles();if(x!=null)for(File q:x)delete(q);}f.delete();}
}

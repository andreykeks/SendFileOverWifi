package com.ao.sendfileoverwifi;

import android.content.Context;
import org.bouncycastle.asn1.x500.X500Name;
import org.bouncycastle.cert.X509v3CertificateBuilder;
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter;
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder;
import org.bouncycastle.jce.provider.BouncyCastleProvider;
import org.bouncycastle.operator.ContentSigner;
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder;
import org.conscrypt.Conscrypt;
import java.io.*; import java.math.BigInteger; import java.security.*; import java.security.cert.X509Certificate; import java.util.*;
import javax.net.ssl.*;

/** Local TLS identity. Persistence is deliberately app-local without Android Keystore. */
final class TlsIdentity {
 private static final String FILE="tls-identity-v4.bin"; private static final Provider C=Conscrypt.newProvider();
 static synchronized SSLContext context(Context c) throws Exception { if(Security.getProvider(C.getName())==null)Security.insertProviderAt(C,1); if(Security.getProvider("BC")==null)Security.addProvider(new BouncyCastleProvider()); KeyStore ks=KeyStore.getInstance("PKCS12"); ks.load(null); char[] p="sendfile".toCharArray(); Identity i=load(c); ks.setKeyEntry("identity",i.key,p,new java.security.cert.Certificate[]{i.cert}); KeyManagerFactory km=KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()); km.init(ks,p); SSLContext x=SSLContext.getInstance("TLS",C); x.init(km.getKeyManagers(),new TrustManager[]{new Trust()},new SecureRandom()); return x; }
 static String fingerprint(X509Certificate c)throws Exception{return hex(MessageDigest.getInstance("SHA-256").digest(c.getPublicKey().getEncoded()));}
 static String pairingCode(SSLSocket s)throws Exception{byte[] b=Conscrypt.exportKeyingMaterial(s,"EXPORTER-SendFile-v1-SAS",new byte[0],32);int v=((b[0]&255)<<12)|((b[1]&255)<<4)|((b[2]&255)>>>4);char[] a="0123456789ABCDEFGHJKMNPQRSTVWXYZ".toCharArray();return ""+a[v>>>15&31]+a[v>>>10&31]+a[v>>>5&31]+a[v&31];}
 private static Identity load(Context c)throws Exception{File f=new File(c.getNoBackupFilesDir(),FILE); try { if(f.exists()){KeyStore s=KeyStore.getInstance("PKCS12");char[] p="sendfile".toCharArray();s.load(new ByteArrayInputStream(read(f)),p);return new Identity((PrivateKey)s.getKey("identity",p),(X509Certificate)s.getCertificate("identity"));} } catch(Exception ignored){f.delete();} KeyPair g=KeyPairGenerator.getInstance("RSA").generateKeyPair();X509Certificate cert=cert(g);save(f,g.getPrivate(),cert);return new Identity(g.getPrivate(),cert);}
 private static void save(File f,PrivateKey k,X509Certificate cert)throws Exception{KeyStore s=KeyStore.getInstance("PKCS12");char[] p="sendfile".toCharArray();s.load(null,p);s.setKeyEntry("identity",k,p,new java.security.cert.Certificate[]{cert});try(FileOutputStream o=new FileOutputStream(f)){s.store(o,p);}}
 private static X509Certificate cert(KeyPair p)throws Exception{Date n=new Date(),e=new Date(n.getTime()+630720000000L);X500Name name=new X500Name("CN=SendFile over WiFi");X509v3CertificateBuilder b=new JcaX509v3CertificateBuilder(name,new BigInteger(64,new SecureRandom()),n,e,name,p.getPublic());ContentSigner sig=new JcaContentSignerBuilder("SHA256withRSA").build(p.getPrivate());return new JcaX509CertificateConverter().getCertificate(b.build(sig));}
 private static byte[] read(File f)throws Exception{try(FileInputStream i=new FileInputStream(f)){ByteArrayOutputStream b=new ByteArrayOutputStream();byte[] x=new byte[8192];for(int n;(n=i.read(x))>0;)b.write(x,0,n);return b.toByteArray();}}
 private static String hex(byte[] d){StringBuilder b=new StringBuilder();for(byte x:d)b.append(String.format(Locale.ROOT,"%02x",x));return b.toString();}
 private static final class Identity{final PrivateKey key;final X509Certificate cert;Identity(PrivateKey k,X509Certificate c){key=k;cert=c;}}
 private static final class Trust implements X509TrustManager{public void checkClientTrusted(X509Certificate[]c,String a){}public void checkServerTrusted(X509Certificate[]c,String a){}public X509Certificate[]getAcceptedIssuers(){return new X509Certificate[0];}}
}

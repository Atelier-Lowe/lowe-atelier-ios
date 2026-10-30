// Löwe Atelier – coquille iPhone
// Affiche l'appli web (lowe-atelier.netlify.app) et ajoute le scan LiDAR (Apple RoomPlan).
// Le plan coté est calculé dans l'appli web à partir du fichier du scan.
import { useEffect, useRef, useState } from "react";
import { View, Text, Pressable, Linking, StyleSheet, ActivityIndicator, Share } from "react-native";
import { StatusBar } from "expo-status-bar";
import { WebView } from "react-native-webview";
import { File, Paths } from "expo-file-system";
import { ExpoRoomplan as RoomPlan } from "expo-roomplan";

const APP_URL = "https://lowe-atelier.netlify.app/";
const APP_HOST = "lowe-atelier.netlify.app";

// base64 -> octets (sans dépendance)
const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
function b64ToBytes(b64) {
  const clean = b64.replace(/[^A-Za-z0-9+/]/g, "");
  const out = new Uint8Array(Math.floor((clean.length * 3) / 4));
  let o = 0;
  for (let i = 0; i < clean.length; i += 4) {
    const n = (B64.indexOf(clean[i]) << 18) | (B64.indexOf(clean[i + 1]) << 12) | ((B64.indexOf(clean[i + 2]) & 63) << 6) | (B64.indexOf(clean[i + 3]) & 63);
    out[o++] = (n >> 16) & 255;
    if (clean[i + 2] !== undefined) out[o++] = (n >> 8) & 255;
    if (clean[i + 3] !== undefined) out[o++] = n & 255;
  }
  return out.slice(0, o);
}

export default function App() {
  const web = useRef(null);
  const [failed, setFailed] = useState(false);
  const [busy, setBusy] = useState(false);

  // Résultat du scan : on lit le fichier JSON et on l'envoie à l'appli web
  useEffect(() => {
    const sub = RoomPlan.addListener("onDismissEvent", async (ev) => {
      setBusy(false);
      const send = (js) => web.current?.injectJavaScript(js + ";true;");
      if (ev?.status === "OK" && ev.jsonUrl) {
        try {
          const text = await new File(ev.jsonUrl).text();
          send(`window.__onScan && window.__onScan(${JSON.stringify(text)})`);
        } catch (e) {
          send(`window.__onScanStatus && window.__onScanStatus("Error")`);
        }
      } else if (ev?.status) {
        send(`window.__onScanStatus && window.__onScanStatus(${JSON.stringify(ev.status)})`);
      }
    });
    return () => sub?.remove();
  }, []);

  const onMessage = (e) => {
    let msg = {};
    try { msg = JSON.parse(e.nativeEvent.data); } catch {}
    if (msg.type === "file" && msg.b64) {
      // Fichier envoyé par l'appli web (plan SketchUp, image…) : on l'enregistre puis on ouvre le menu Partager
      try {
        const name = String(msg.name || "fichier").replace(/[\\/:*?"<>|]+/g, "-");
        const f = new File(Paths.cache, name);
        if (f.exists) f.delete();
        f.create();
        f.write(b64ToBytes(msg.b64));
        Share.share({ url: f.uri }).catch(() => {});
      } catch (err) {
        web.current?.injectJavaScript(`window.toast && toast("Le fichier n'a pas pu être partagé.");true;`);
      }
      return;
    }
    if (msg.type === "scan") {
      setBusy(true);
      RoomPlan.startCapture(msg.name || "piece", "PARAMETRIC", true).catch(() => setBusy(false));
    }
  };

  // Les liens vers d'autres sites (Gmail, Agenda, Drive…) s'ouvrent dans leur appli ou Safari
  // (pas de new URL() : sa version iPhone renvoie un hôte vide et tout partait dans Safari)
  const external = (url) => {
    if (typeof url !== "string" || !/^https?:\/\//i.test(url)) return false;
    const host = url.replace(/^https?:\/\//i, "").split(/[\/?#:]/)[0].toLowerCase();
    return host !== APP_HOST;
  };

  if (failed) {
    return (
      <View style={s.center}>
        <Text style={s.title}>Pas de connexion</Text>
        <Text style={s.text}>L'appli a besoin d'internet au premier lancement.</Text>
        <Pressable style={s.btn} onPress={() => setFailed(false)}><Text style={s.btnText}>Réessayer</Text></Pressable>
      </View>
    );
  }

  return (
    <View style={s.root}>
      <StatusBar style="dark" />
      <WebView
        ref={web}
        source={{ uri: APP_URL }}
        style={s.web}
        originWhitelist={["*"]}
        javaScriptEnabled
        domStorageEnabled
        allowsInlineMediaPlayback
        mediaCapturePermissionGrantType="grant"
        allowsBackForwardNavigationGestures
        contentInsetAdjustmentBehavior="never"
        automaticallyAdjustContentInsets={false}
        bounces={false}
        cacheEnabled
        onMessage={onMessage}
        onShouldStartLoadWithRequest={(req) => {
          if (req.navigationType === "click" && req.isTopFrame !== false && external(req.url)) { Linking.openURL(req.url); return false; }
          return true;
        }}
        onOpenWindow={(e) => Linking.openURL(e.nativeEvent.targetUrl)}
        onError={() => setFailed(true)}
        startInLoadingState
        renderLoading={() => <View style={s.center}><ActivityIndicator color="#24454A" /></View>}
      />
      {busy && <View style={s.overlay} pointerEvents="none"><ActivityIndicator color="#fff" /></View>}
    </View>
  );
}

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: "#F5F1E8" },
  web: { flex: 1, backgroundColor: "#F5F1E8" },
  center: { ...StyleSheet.absoluteFillObject, alignItems: "center", justifyContent: "center", backgroundColor: "#F5F1E8", padding: 24 },
  title: { fontSize: 20, fontWeight: "700", color: "#24454A", marginBottom: 8 },
  text: { fontSize: 15, color: "#5E6F70", textAlign: "center", marginBottom: 18 },
  btn: { backgroundColor: "#965A2E", paddingHorizontal: 22, paddingVertical: 12, borderRadius: 12 },
  btnText: { color: "#fff", fontWeight: "700", fontSize: 16 },
  overlay: { ...StyleSheet.absoluteFillObject, backgroundColor: "rgba(0,0,0,.25)", alignItems: "center", justifyContent: "center" },
});

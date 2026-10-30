// Löwe Atelier – coquille iPhone
// Affiche l'appli web (lowe-atelier.netlify.app) et ajoute le scan LiDAR (Apple RoomPlan).
// Le plan coté est calculé dans l'appli web à partir du fichier du scan.
import { useEffect, useRef, useState } from "react";
import { View, Text, Pressable, Linking, StyleSheet, ActivityIndicator } from "react-native";
import { StatusBar } from "expo-status-bar";
import { WebView } from "react-native-webview";
import { File } from "expo-file-system";
import { ExpoRoomplan as RoomPlan } from "expo-roomplan";

const APP_URL = "https://lowe-atelier.netlify.app/";
const APP_HOST = "lowe-atelier.netlify.app";

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
    if (msg.type === "scan") {
      setBusy(true);
      RoomPlan.startCapture(msg.name || "piece", "PARAMETRIC", true).catch(() => setBusy(false));
    }
  };

  // Les liens vers d'autres sites (Gmail, Agenda, Drive…) s'ouvrent dans leur appli ou Safari
  const external = (url) => {
    try { return new URL(url).host !== APP_HOST && /^https?:/.test(url); } catch { return false; }
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
          if (req.isTopFrame !== false && external(req.url)) { Linking.openURL(req.url); return false; }
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

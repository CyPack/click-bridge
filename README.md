# click-bridge

Tarayıcıda tıkladığın UI elementini **terminaldeki Claude Code'a** taşıyan minik localhost köprüsü.
Stdlib-only Python, tek dosya. `127.0.0.1:7823`'te dinler.

```
tarayıcı (react-dev-inspector / overlay / userscript)
   └─ POST http://127.0.0.1:7823/click  {component, source:{file,line}, ...}
        └─ ~/.click-bridge/last.json  (atomik)  +  history.jsonl (append)
             └─ Claude Code UserPromptSubmit hook'u last.json taze ise prompt'a enjekte eder
```

## Çalıştırma

```bash
python3 server.py                 # default: --port 7823 --dir ~/.click-bridge
# systemd: systemctl --user status click-bridge.service
```

## Endpoints

- `POST /click` — herhangi bir JSON objesi kabul edilir (max 256 KB). Konvansiyon alanları:
  `component`, `component_chain`, `source:{file,line}`, `url`, `selector`, `text`, `box`,
  `console_errors`, `failed_requests`, `viewport`, `note`.
  Server `ts` + `iso` ekler, `last.json`'ı atomik yazar, `history.jsonl`'a ekler.
- `GET /snippet.js` — **universal capture script** (aşağıya bak)
- `GET /last` — son tıklama (404 = henüz yok)
- `GET /health` — sağlık kontrolü
- CORS açık (`*`) — sadece 127.0.0.1'e bind olduğu için localhost dev origin'leri POST atabilir.

## En kolay entegrasyon: tek satır (dev-only!)

```html
<script src="http://127.0.0.1:7823/snippet.js"></script>
```

Snippet şunları yapar: Alt+hover kırmızı çerçeve · Alt+Click → component adı (`data-component` >
React fiber > tag) + kaynak (`data-file`/`data-line` > React `_debugSource`) + CSS selector + metin +
box-model (padding/margin/boyut) + **son 10 console hatası** + **son 10 başarısız network isteği** +
viewport'u tek payload'da POST'lar. ⚠️ ASLA production bundle'a koyma — dev-only guard kullan
(Vite: `import.meta.env.DEV`, Next: `NODE_ENV === 'development'`).

## curl örnekleri

```bash
curl -s -X POST http://127.0.0.1:7823/click \
  -H 'Content-Type: application/json' \
  -d '{"component":"TaskCard","source":{"file":"src/components/TaskCard.tsx","line":42},"note":"padding bozuk"}'

curl -s http://127.0.0.1:7823/last | jq
```

## Tarayıcı tarafını bağlama (React projesi)

Dev-only olarak [react-dev-inspector](https://github.com/zthxxx/react-dev-inspector) kur ve
callback'ini köprüye yönlendir:

```tsx
import { Inspector } from 'react-dev-inspector'

// Sadece dev build'de render et
{import.meta.env.DEV && (
  <Inspector
    keys={['alt', 'c']}   // Alt+C ile inspect modu aç/kapa
    onClickElement={(el) => {
      fetch('http://127.0.0.1:7823/click', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          component: el.name,
          source: { file: el.codeInfo?.absolutePath ?? el.codeInfo?.relativePath, line: el.codeInfo?.lineNumber, column: el.codeInfo?.columnNumber },
          url: location.href,
        }),
      }).catch(() => {})
    }}
  />
)}
```

Framework'süz sayfalar / başka siteler için: **mcp-pointer** (Option+Click → MCP tool) tamamlayıcı araçtır;
click-bridge kendi React app'lerinde component adı + dosya:satır verir, mcp-pointer her sitede DOM verir.

## Test

```bash
python3 -m pytest test_server.py -q   # 9 test
```

## v3/v4/v5 Eklentileri (özet — detay: docs/ARCHITECTURE.md + Skill `click-bridge`)

- **Session wiring (v5):** `dev-browser.sh` ile açılan sekme `#cb=TOKEN` taşır; hook token'ı başlatan
  Claude session'ına bağlar (`~/.click-bridge/bindings.jsonl`, process-ancestry PID eşleşmesi) → o sekmenin
  tıkları SADECE o session'a gider, çok-session çakışması biter. Token'sız tıklar eski davranışta (aşağısı).
- **Multi-session:** exactly-once teslimat (ilk yazan session alır) · `CLICK_BRIDGE_BROADCAST=1` = her session 1'er kez · `~/.click-bridge/delivery.jsonl` teslimat kaydı
- **Proje routing:** `~/.click-bridge/routes.json` — URL'deki host:port → proje dizini eşlemesi; tık SADECE o projenin session'larına gider (örnek: `examples-routes.json`)
- **Self-heal:** `click-bridge-heal.timer` (saatlik) — servis/endpoint/hook denetler + onarır
- **dev-browser:** `tools/dev-browser.sh` — mcp-pointer ext yüklü + CDP :9222 açık izole chromium
- **Masaüstü screenshot:** `tools/portal-screenshot.py` (GNOME Wayland portal)

## Uzak cihaz (Tailscale) kullanımı + platform kısayolları

Uzak cihaza **hiçbir kurulum gerekmez** — server Tailscale IP'ye de bind olur, snippet köprü
hedefini `location.hostname`'den dinamik alır. Tek sunucu-tarafı ön koşul: uygulamanın snippet
guard'ı Tailscale hostname'lerini kabul etmeli (`100.*` / `.ts.net`).

Uzak sekmeyi belirli bir Claude session'ına kablolamak için (dev-browser'ın uzak muadili):

```bash
# kablolamak istediğin session'ın İÇİNDE:
bash tools/pair-url.sh 8770
# → 🔗 tailscale: http://100.x.y.z:8770/#cb=TOKEN   ← bu URL'yi uzak cihazda aç
```

### Kısayol platform tablosu

| Cihaz / OS | Kısayol | Not |
|---|---|---|
| Linux / Windows | **Alt + Click** | Snippet capture-phase `preventDefault` ile Chrome'un Alt+Click-indirme davranışını bastırır |
| **macOS (MacBook)** | **⌥ Option + Click** | macOS'ta Alt tuşunun adı Option'dır; tarayıcı bunu aynı `e.altKey` olarak bildirir — davranış birebir aynı, sadece tuşun adı farklı |
| macOS + Safari | ⚠️ önerilmez | Option+Click Safari'de "linki indir" varsayılanıyla çakışabilir; Chrome/Arc/Edge/Chromium kullan |
| Telefon / tablet (klavyesiz) | ❌ yok | Alt/Option tuşu olmadığından mevcut jest çalışmaz (mobil jest henüz yok) |
| Tablet + fiziksel klavye | ✅ Alt/⌥ + tık | Donanım klavyesi varsa çalışır |

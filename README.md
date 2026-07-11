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
  `component`, `source:{file,line,column}`, `url`, `selector`, `text`, `note`, `props`.
  Server `ts` + `iso` ekler, `last.json`'ı atomik yazar, `history.jsonl`'a ekler.
- `GET /last` — son tıklama (404 = henüz yok)
- `GET /health` — sağlık kontrolü
- CORS açık (`*`) — sadece 127.0.0.1'e bind olduğu için localhost dev origin'leri POST atabilir.

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

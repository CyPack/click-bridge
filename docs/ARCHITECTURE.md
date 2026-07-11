# click-bridge — Mimari (agent-friendly referans)

> Amaç: tarayıcıdaki UI bağlamını (component, hata, network, geometri) terminaldeki Claude Code'a
> sıfır-komutla taşımak. Tamamı lokal (127.0.0.1), tamamı senin makinende.

## 1. Mimari Diyagram

```
┌─ TARAYICI (herhangi biri: dev-browser / Brave / Chromium) ─────────────────┐
│  senin app'in (+ /snippet.js)          demo :7824                          │
│  • console error/warn tamponu (25)     • BrokenZone test                   │
│  • başarısız istek tamponu (25)                                            │
│  • Alt+hover kırmızı çerçeve                                               │
│  • Alt+Click → payload                                                     │
└──────────────┬─────────────────────────────────────────────────────────────┘
               │ POST /click (localhost, CORS *)
               ▼
┌─ click-bridge server :7823 (systemd: click-bridge.service) ────────────────┐
│  stdlib Python · 127.0.0.1-only · 10 pytest                                │
│  • last.json  (ATOMİK yaz — son tık)                                       │
│  • history.jsonl (append-only olay günlüğü)                                │
│  • GET /snippet.js · /last · /health                                       │
└──────────────┬─────────────────────────────────────────────────────────────┘
               │ dosya okuma
               ▼
┌─ Claude Code hook katmanı (UserPromptSubmit, GLOBAL) ──────────────────────┐
│  click-bridge-inject.sh v3                                                 │
│  • taze (≤300s) + tüketilmemiş tık → prompt bağlamına ENJEKTE              │
│  • EXACTLY-ONCE: ilk yazılan session alır │ BROADCAST=1: her session 1 kez │
│  • delivery.jsonl → hangi session hangi tıkı aldı (instance takibi)        │
└──────────────┬─────────────────────────────────────────────────────────────┘
               ▼
        Claude Code session(ları) — N adet paralel, her proje/monitör
               │ derin analiz gerekirse (OPSİYONEL katman)
               ▼
┌─ Canlı analiz MCP katmanı ─────────────────────────────────────────────────┐
│  chrome-devtools MCP (kendi chromium'u) · playwright MCP (fallback)        │
│  dev-browser :9222 (CDP attach — KULLANICININ gezindiği pencere)           │
│  pointer MCP :7007 (mcp-pointer ext → get-pointed-element)                 │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 2. Ne Neyi Kullanıyor (bağımlılık matrisi)

| Katman | Bağımlılık | Zorunlu mu? |
|---|---|---|
| Köprü çekirdeği (server+snippet+hook) | Python3 stdlib, bash, jq, systemd-user | ✅ zorunlu — **HİÇBİR MCP GEREKMEZ** |
| Skill + lessons | ~/.claude/skills/click-bridge/ | ✅ (davranış rehberi) |
| pointer MCP (`@mcp-pointer/server@0.6.0` pinli) | Node/npx, extension | opsiyonel — her-site element seçimi |
| chrome-devtools MCP (`chrome-devtools-mcp@latest`) | kendi chromium instance'ı | opsiyonel — derin network/perf |
| playwright MCP (plugin) | kendi browser'ları | opsiyonel — devtools fallback + E2E doğrulama |
| dev-browser (tools/dev-browser.sh) | chromium-browser, vendor extension | opsiyonel — CDP 9222 + ext yüklü pencere |
| portal-screenshot (tools/) | GNOME portal, Gio | opsiyonel — masaüstü görsel bağlam |

## 3. Veri Akışı & Dosyalar (~/.click-bridge/)

| Dosya | İçerik | Yaşam döngüsü |
|---|---|---|
| `last.json` | son tıklamanın TAM payload'ı | her tıkta atomik overwrite; bozuksa heal karantinaya alır |
| `history.jsonl` | TÜM tıklamalar (append-only) | >50MB'da heal gzip-arşivler (SİLMEZ) |
| `delivery.jsonl` | hangi session hangi tıkı ne zaman aldı | append-only |
| `.consumed` / `.consumed-<hash>-<sid>` | teslimat dedup marker'ları | broadcast marker'ları 2 saatte temizlenir |
| `_health.log` | self-heal tespit/onarım kayıtları | 1MB'da rotate |

## 4. Self-Healing (3 katman — kanıtlı)

1. **systemd Restart=on-failure** — server/demo çökerse anında yeniden başlar.
2. **click-bridge-heal.timer (saatlik + boot+5dk, Persistent)** → `tools/self-heal.sh`:
   servisleri + endpoint'i + snippet'i + hook kaydını + hook smoke-test'i DENETLER; onarabildiğini ONARIR
   (restart, bozuk-json karantina, history arşivi), onaramadığını `_health.log`'a FAIL yazar.
   Kanıt (2026-07-11): servis kasıtlı durduruldu → heal tespit etti → restart etti → health 200.
3. **Lesson döngüsü (skill-execution protokolü)** — her yeni hata/çözüm `lessons/*.md` tablolarına işlenir;
   sonraki agent aynı hatayı yaşamadan çözer (şu an 13 error + golden-paths + edge-cases).

## 5. Multi-Session Yönetim Rehberi

- Hook GLOBAL → sınırsız paralel session; pratik sınır RAM + rate-limit (idle donduran workspace-nap kurulu).
- **Yönlendirme:** tıkla → hangi session'a yazarsan ONA gider (exactly-once). Broadcast istersen: session'ı
  `CLICK_BRIDGE_BROADCAST=1` env ile başlat.
- **Desen:** feature başına git worktree + 1 session ([[git-integration-workflow]]); hepsi aynı köprüyü paylaşır.
- **İzleme:** `delivery.jsonl` (tık→session eşlemesi) · `cc l` (session listesi) · herdr (multiplexer) ·
  `claude agents`.

## 6. Güvenlik Sınırları

- Server ve CDP SADECE 127.0.0.1. Snippet ASLA prod'a çıkmaz (dev-only guard). Payload metni 200 char kırpılır.
- mcp-pointer vetted-source build (`vendor/.PROVENANCE.md`), server paketi @0.6.0 PİNLİ (supply-chain).

## 7. Runbook (tek bakışta)

```bash
systemctl --user is-active click-bridge click-bridge-demo   # servisler
systemctl --user list-timers click-bridge-heal.timer        # self-heal timer
bash ~/projects/click-bridge/tools/self-heal.sh; echo $?    # manuel heal (0=sağlıklı)
tail ~/.click-bridge/_health.log                            # tespit/onarım geçmişi
~/projects/click-bridge/tools/dev-browser.sh                # izlenebilir dev penceresi
python3 -m pytest ~/projects/click-bridge/test_server.py -q # 10 test
```

*2026-07-11 · git: ~/projects/click-bridge · Skill: `click-bridge` · Memory: `cc-visual-context-component-referencing.md`*

## 8. v4 Güncellemesi — Proje Routing

`~/.click-bridge/routes.json`: tıklama URL'indeki host:port → proje dizini. Hook, session'ın `cwd`'sini
(stdin JSON) route'la karşılaştırır: eşleşen route varsa SADECE o projenin session'ları (worktree'ler dahil,
prefix) alır; route yoksa global. Fail-open (routing hatası enjeksiyonu engellemez). 6-senaryo test kanıtlı
(cc-dashboard↔mnmveldops çapraz izolasyon). Ayrıca: `mcp-proxy-watchdog.timer` (30dk) MCP altyapısını,
`click-bridge-heal.timer` (saatlik) köprüyü korur — iki bağımsız self-heal halkası.

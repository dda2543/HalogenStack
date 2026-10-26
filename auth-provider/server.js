// halogen-stack internal-auth-provider — минимальная реализация (без зависимостей).
//
// Назначение: отвечать на forward_auth-запросы reverse-proxy (Caddy).
//   GET /authz  — 200, если ключ из Authorization: Bearer <k> или x-api-key: <k>
//                 присутствует в keys.acl; иначе 401.
//   GET /healthz — 200, для healthcheck.
//
// keys.acl: строки вида `имя:ключ`, `#` — комментарий. Файл примонтирован с
// хоста; перечитывается при изменении mtime (make key-add не требует рестарта).

const http = require("http");
const fs = require("fs");
const crypto = require("crypto");

const KEYS_FILE = process.env.KEYS_FILE || "/etc/auth-provider/keys.acl";
const PORT = Number(process.env.PORT || 9000);

let keys = [];
let mtimeMs = -1;

function reload() {
  try {
    const st = fs.statSync(KEYS_FILE);
    if (st.mtimeMs === mtimeMs) return;
    mtimeMs = st.mtimeMs;
    keys = fs.readFileSync(KEYS_FILE, "utf8")
      .split("\n")
      .map(l => l.trim())
      .filter(l => l && !l.startsWith("#"))
      .map(l => l.slice(l.indexOf(":") + 1).trim())
      .filter(Boolean);
    console.log(`keys.acl перечитан: ${keys.length} ключ(ей)`);
  } catch (e) {
    console.error(`не удалось прочитать ${KEYS_FILE}: ${e.message}`);
    keys = []; // fail-closed: нет файла — нет доступа
  }
}

function constantTimeEq(a, b) {
  const ab = Buffer.from(a), bb = Buffer.from(b);
  return ab.length === bb.length && crypto.timingSafeEqual(ab, bb);
}

function tokenFrom(req) {
  const auth = req.headers["authorization"] || "";
  if (auth.startsWith("Bearer ")) return auth.slice(7).trim();
  if (req.headers["x-api-key"]) return String(req.headers["x-api-key"]).trim();
  return "";
}

http.createServer((req, res) => {
  // forward_auth (Caddy) переписывает запрос на /authz, но query-строку
  // исходного запроса сохраняет: `POST /v1/messages?x=1` приходит сюда как
  // `GET /authz?x=1` (см. /docs/caddy/modules/caddyhttp/rewrite/rewrite.go:
  // RawQuery перезаписывается только если в uri есть '?').
  // Сравниваем поэтому только путь.
  const path = req.url.split("?", 1)[0];
  if (path === "/healthz") { res.writeHead(200); res.end("ok"); return; }
  if (path !== "/authz") { res.writeHead(404); res.end(); return; }
  reload();
  const token = tokenFrom(req);
  const ok = Boolean(token) && keys.some(k => constantTimeEq(k, token));
  res.writeHead(ok ? 200 : 401, { "content-type": "application/json" });
  res.end(JSON.stringify({ allowed: ok }));
}).listen(PORT, () => console.log(`internal-auth-provider на :${PORT}, файл ключей: ${KEYS_FILE}`));

# Plano de Deploy — GitNexus na Oracle Cloud ARM

## Contexto

Deployar o GitNexus completo (CLI + MCP Server + Web UI + API HTTP) em uma VM ARM (Ampere A1) já existente na Oracle Cloud (4 OCPUs, 24GB RAM, 100GB disco). O objetivo é ter um servidor GitNexus acessível remotamente, tanto para a Web UI quanto para agentes de IA conectarem via MCP over HTTP.

---

## Componentes da Solução

| # | Componente | Tecnologia | Porta | Descrição |
|---|-----------|-----------|-------|-----------|
| 1 | **CLI** | Node.js + Commander.js | — | Indexação de repos, queries, geração de wiki |
| 2 | **MCP Server (stdio)** | @modelcontextprotocol/sdk | — | Protocolo para editores locais (Cursor, Claude Code) |
| 3 | **MCP Server (HTTP)** | StreamableHTTPServerTransport | 4747 | MCP remoto para agentes de IA externos |
| 4 | **API REST** | Express.js | 4747 | Endpoints REST (`/api/query`, `/api/search`, etc.) |
| 5 | **Web UI** | React 18 + Vite + Sigma.js | static | Frontend com grafo interativo, chat AI, explorador |
| 6 | **LadybugDB** | C++ embedded (N-API) | — | Banco de dados de grafos embarcado (`.gitnexus/lbug`) |
| 7 | **Embeddings** | HuggingFace transformers.js | — | snowflake-arctic-embed-xs (22M params, 384 dims) |
| 8 | **Hybrid Search** | BM25 (FTS) + Semantic + RRF | — | Busca full-text + vetorial com fusão RRF (k=60) |
| 9 | **Tree-sitter** | 13 parsers nativos (C++ N-API) | — | Parsing AST para 13+ linguagens |
| 10 | **Leiden Clustering** | graphology (vendored) | — | Detecção de comunidades funcionais |
| 11 | **Nginx** | Reverse proxy | 80/443 | HTTPS + CORS headers + auth para MCP |

---

## Dependências Nativas (ARM64)

Todos compilam do source via `node-gyp` — precisam de `python3`, `make`, `g++`.

| Dependência | Tipo | ARM64 | Notas |
|------------|------|-------|-------|
| `@ladybugdb/core@^0.15.1` | C++ addon (N-API) | Compila | `npm rebuild` |
| `tree-sitter@^0.21.0` | C++ addon | Compila | node-gyp |
| 13x tree-sitter-{lang} | C++ addons | Compilam | node-gyp |
| `tree-sitter-kotlin@^0.3.8` | C++ addon | Compila | Precisa `npx node-gyp rebuild` manual |
| `tree-sitter-swift@^0.6.0` | C++ addon | Compila | Precisa patch (`patch-tree-sitter-swift.cjs`) |
| `@huggingface/transformers@^3.0.0` | ONNX Runtime | CPU OK | Sem GPU no ARM, usa CPU fallback |

---

## Estrutura de Armazenamento

```
~/.gitnexus/                          # Registry global
├── registry.json                     # Lista de repos indexados (paths, metadata)
├── config.json                       # Config (modelo wiki, API keys)
└── meta.json                         # Metadata do índice

/repos/{repo-name}/.gitnexus/         # Índice por repo (gitignored)
├── lbug                              # LadybugDB (arquivo binário único)
├── meta.json                         # Stats: symbols, relations, embeddings count
└── csv/                              # CSVs intermediários (nodes, relationships)
```

---

## FASE 1 — Setup do Servidor (Dia 1)

### 1.1 Instalar dependências do SO

Criar `deploy/setup-server.sh`:

```bash
#!/bin/bash
set -euo pipefail

# Atualizar e instalar build tools + runtime
sudo apt-get update && sudo apt-get install -y \
  curl git python3 make g++ \
  nginx certbot python3-certbot-nginx \
  htop tmux

# Node.js 20 LTS (ARM64 suportado pelo NodeSource)
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs

# Verificar
node --version  # v20.x
npm --version
python3 --version
g++ --version
```

### 1.2 Criar usuário dedicado

```bash
sudo useradd -m -s /bin/bash gitnexus
sudo mkdir -p /opt/gitnexus
sudo chown gitnexus:gitnexus /opt/gitnexus
```

### 1.3 Abrir portas na Oracle Cloud

> Pedir ao user: confirmar Security List com portas 22, 80, 443 abertas.

---

## FASE 2 — Build & Install (Dia 1)

### 2.1 Clone e instalação

Criar `deploy/deploy-app.sh`:

```bash
#!/bin/bash
set -euo pipefail

APP_DIR=/opt/gitnexus
cd $APP_DIR

# Clone
sudo -u gitnexus git clone https://github.com/renatobardi/GitNexus.git app
cd app

# Instalar deps (ignora scripts pra controlar o rebuild manualmente)
sudo -u gitnexus npm ci --ignore-scripts

# Patch tree-sitter-swift (remove pre-build actions do binding.gyp)
sudo -u gitnexus node scripts/patch-tree-sitter-swift.cjs

# Rebuild TODOS os native addons para ARM64
sudo -u gitnexus npm rebuild

# tree-sitter-kotlin precisa rebuild manual
cd node_modules/tree-sitter-kotlin
sudo -u gitnexus npx node-gyp rebuild
cd ../..
```

### 2.2 Build TypeScript

```bash
# Build CLI/MCP (gitnexus package)
sudo -u gitnexus npm run build --workspace=gitnexus

# Build Web UI (gitnexus-web package)
sudo -u gitnexus npm run build --workspace=gitnexus-web
```

### 2.3 Verificar native addons

```bash
# Testar LadybugDB
sudo -u gitnexus node -e "require('@ladybugdb/core'); console.log('LadybugDB OK')"

# Testar tree-sitter
sudo -u gitnexus node -e "require('tree-sitter'); console.log('Tree-sitter OK')"

# Testar embedding model (download ~90MB na primeira vez)
sudo -u gitnexus node -e "
  import('@huggingface/transformers').then(t => {
    console.log('HuggingFace OK (CPU mode on ARM)');
  });
"
```

---

## FASE 3 — Indexar Repos de Teste (Dia 1)

### 3.1 Indexar o próprio GitNexus como teste

```bash
cd /opt/gitnexus/app
sudo -u gitnexus npx gitnexus analyze .

# Com embeddings (busca semântica)
sudo -u gitnexus npx gitnexus analyze . --embeddings

# Verificar
sudo -u gitnexus npx gitnexus status
sudo -u gitnexus npx gitnexus list
```

### 3.2 Validar queries

```bash
# Query por conceito
sudo -u gitnexus npx gitnexus query "hybrid search"

# Context de um símbolo
sudo -u gitnexus npx gitnexus context "handleMcpRequest"

# Impact analysis
sudo -u gitnexus npx gitnexus impact "LbugAdapter" --direction upstream
```

---

## FASE 4 — Systemd Service (Dia 2)

### 4.1 Criar service do servidor HTTP

Criar `deploy/gitnexus.service`:

```ini
[Unit]
Description=GitNexus HTTP Server (API + MCP StreamableHTTP)
After=network.target

[Service]
Type=simple
User=gitnexus
Group=gitnexus
WorkingDirectory=/opt/gitnexus/app
ExecStart=/usr/bin/node gitnexus/dist/cli/index.js serve --port 4747 --host 127.0.0.1
Restart=always
RestartSec=5
Environment=NODE_ENV=production
# Heap para repos grandes (8GB disponível no ARM 24GB)
Environment=NODE_OPTIONS=--max-old-space-size=8192

[Install]
WantedBy=multi-user.target
```

### 4.2 Instalar e ativar

```bash
sudo cp deploy/gitnexus.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable gitnexus
sudo systemctl start gitnexus

# Verificar
curl http://localhost:4747/api/repos
```

**O que roda na porta 4747:**
- `GET /api/repos` — lista repos indexados
- `POST /api/query` — queries Cypher
- `POST /api/search` — busca híbrida (BM25 + semântica)
- `GET /api/processes` — execution flows
- `GET /api/clusters` — comunidades Leiden
- `GET /api/file` — leitura de arquivos (com guard contra path traversal)
- `POST /api/mcp` — **MCP over HTTP** (StreamableHTTP, sessões stateful 30min TTL)

---

## FASE 5 — Nginx + HTTPS (Dia 2)

### 5.1 Config Nginx

Criar `deploy/nginx-gitnexus.conf`:

```nginx
server {
    listen 80;
    server_name DOMINIO_DO_USER;

    # Web UI — arquivos estáticos do build Vite
    location / {
        root /opt/gitnexus/app/gitnexus-web/dist;
        try_files $uri $uri/ /index.html;

        # Headers obrigatórios para SharedArrayBuffer (LadybugDB WASM)
        add_header Cross-Origin-Opener-Policy "same-origin" always;
        add_header Cross-Origin-Embedder-Policy "require-corp" always;
    }

    # API REST — proxy para Express
    location /api/ {
        proxy_pass http://127.0.0.1:4747;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # MCP sessions podem demorar
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
```

### 5.2 HTTPS com Let's Encrypt

```bash
sudo ln -s /etc/nginx/sites-available/gitnexus /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

# Certificado SSL
sudo certbot --nginx -d DOMINIO_DO_USER
```

### 5.3 CORS — Atualizar allowlist

O Express restringe CORS a `localhost` e `gitnexus.vercel.app`. Para o domínio do user funcionar, há duas opções:

**Opção A (Nginx override — sem mudar código):**
```nginx
location /api/ {
    # Override CORS headers no Nginx
    add_header Access-Control-Allow-Origin "https://DOMINIO_DO_USER" always;
    add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
    add_header Access-Control-Allow-Headers "Content-Type, mcp-session-id" always;

    if ($request_method = 'OPTIONS') {
        return 204;
    }

    proxy_pass http://127.0.0.1:4747;
}
```

**Opção B (Mudar código — mais limpo):**
Adicionar o domínio no array `allowedOrigins` em `gitnexus/src/server/api.ts`.

---

## FASE 6 — MCP Remoto para Agentes (Dia 2)

### 6.1 Como funciona

O endpoint `POST /api/mcp` já existe no Express e usa `StreamableHTTPServerTransport`:

1. **Primeira request** (sem header) → cria sessão, retorna `mcp-session-id` no header
2. **Requests seguintes** → incluem `mcp-session-id` para manter estado
3. **TTL** → sessões expiram após 30min de inatividade (sweep a cada 5min)
4. **Backend compartilhado** → todas as sessões usam o mesmo `LocalBackend`

### 6.2 Segurança do MCP

O MCP não tem autenticação built-in. Proteger via Nginx:

```nginx
# Basic Auth para o endpoint MCP
location /api/mcp {
    auth_basic "MCP Access";
    auth_basic_user_file /etc/nginx/.htpasswd-mcp;

    proxy_pass http://127.0.0.1:4747;
    proxy_set_header Host $host;
    proxy_read_timeout 300s;
}
```

```bash
# Criar credencial
sudo apt-get install -y apache2-utils
sudo htpasswd -c /etc/nginx/.htpasswd-mcp agente1
```

### 6.3 Configurar agentes remotos

**Claude Code (remote MCP):**
```json
{
  "mcpServers": {
    "gitnexus-remote": {
      "url": "https://DOMINIO_DO_USER/api/mcp",
      "headers": {
        "Authorization": "Basic BASE64_CREDENTIALS"
      }
    }
  }
}
```

**Cursor:**
```json
{
  "mcpServers": {
    "gitnexus-remote": {
      "url": "https://DOMINIO_DO_USER/api/mcp"
    }
  }
}
```

### 6.4 Tools disponíveis via MCP remoto

| Tool | Descrição |
|------|-----------|
| `query` | Busca híbrida (BM25 + semântica + RRF) com resultados agrupados por processo |
| `context` | Visão 360° de um símbolo (callers, callees, processos, módulo) |
| `impact` | Blast radius antes de editar (d=1 WILL BREAK, d=2 LIKELY, d=3 TESTING) |
| `detect_changes` | Mapeia git diff para símbolos e processos afetados |
| `rename` | Rename multi-arquivo coordenado (grafo + text search) |
| `cypher` | Queries Cypher diretas no knowledge graph |
| `list_repos` | Lista todos os repos indexados |

---

## FASE 7 — Automação & Manutenção (Dia 3)

### 7.1 Script de atualização

Criar `deploy/update.sh`:

```bash
#!/bin/bash
set -euo pipefail

cd /opt/gitnexus/app
sudo -u gitnexus git pull origin main
sudo -u gitnexus npm ci --ignore-scripts
sudo -u gitnexus node scripts/patch-tree-sitter-swift.cjs
sudo -u gitnexus npm rebuild
cd node_modules/tree-sitter-kotlin && sudo -u gitnexus npx node-gyp rebuild && cd ../..
sudo -u gitnexus npm run build --workspace=gitnexus
sudo -u gitnexus npm run build --workspace=gitnexus-web
sudo systemctl restart gitnexus
echo "GitNexus atualizado e reiniciado!"
```

### 7.2 Cron para renovação de certificado

```bash
# Certbot já instala o cron automaticamente, mas verificar:
sudo certbot renew --dry-run
```

### 7.3 Monitoramento básico

```bash
# Logs do serviço
sudo journalctl -u gitnexus -f

# Health check
curl -s http://localhost:4747/api/repos | jq .
```

---

## Arquivos a Criar

```
deploy/
├── setup-server.sh          # Fase 1 — deps do SO, Node.js, user
├── deploy-app.sh            # Fase 2 — clone, npm ci, rebuild ARM, build TS
├── gitnexus.service         # Fase 4 — systemd unit
├── nginx-gitnexus.conf      # Fase 5 — Nginx reverse proxy + CORS
└── update.sh                # Fase 7 — script de atualização
```

---

## Dados a Coletar do User

| Dado | Para quê |
|------|----------|
| IP público da VM | SSH e DNS |
| Usuário SSH | Acesso remoto |
| OS da VM | Ubuntu/Oracle Linux — ajusta package manager |
| Domínio | Nginx server_name + Let's Encrypt |
| Portas 80/443 abertas? | Security List da Oracle Cloud |

---

## Verificação Final

| # | Teste | Comando |
|---|-------|---------|
| 1 | Native addons ARM | `node -e "require('@ladybugdb/core')"` |
| 2 | Indexação | `npx gitnexus analyze /opt/gitnexus/app` |
| 3 | API local | `curl http://localhost:4747/api/repos` |
| 4 | Web UI | Abrir `https://DOMINIO` no browser |
| 5 | COOP/COEP headers | DevTools → Network → Response Headers |
| 6 | MCP remoto | `curl -X POST https://DOMINIO/api/mcp -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"capabilities":{}}}'` |
| 7 | Claude Code remoto | Configurar MCP e verificar tools disponíveis |

---

## Estimativa de Recursos

| Recurso | Uso Estimado |
|---------|-------------|
| **CPU** | Indexação: ~100% em 4 cores (burst). Serving: ~5% idle |
| **RAM** | Express + LadybugDB: ~500MB. Indexação com embeddings: até 4GB |
| **Disco** | App: ~500MB. Índice por repo: 50-500MB. Embeddings: +20-50% |
| **Rede** | Download modelo embedding: ~90MB (primeira vez) |

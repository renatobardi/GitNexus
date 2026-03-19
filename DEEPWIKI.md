# GitNexus — Deep Wiki

> Documentação completa da arquitetura e funcionamento do GitNexus, um motor de inteligência de código que transforma repositórios em grafos de conhecimento navegáveis por agentes de IA.

---

## Visão Geral

O **GitNexus** é uma plataforma de **Code Intelligence** que analisa repositórios de código-fonte e constrói um **grafo de conhecimento** (Knowledge Graph) contendo símbolos (funções, classes, métodos, variáveis), seus relacionamentos (chamadas, importações, herança) e fluxos de execução (processos). Esse grafo é então exposto via **MCP (Model Context Protocol)** para que assistentes de IA como Claude Code, Cursor e outros possam navegar e entender codebases de forma estruturada.

### O que ele resolve

Assistentes de IA precisam entender código para ajudar desenvolvedores. Sem o GitNexus, eles fazem `grep` e lêem arquivos — uma abordagem limitada. Com o GitNexus, eles consultam um grafo tipado com relações semânticas, fluxos de execução e análise de impacto.

```mermaid
graph LR
    A[Repositório de Código] -->|npx gitnexus analyze| B[Pipeline de Análise]
    B -->|Tree-sitter + Resolução| C[Grafo de Conhecimento]
    C -->|LadybugDB| D[Banco de Grafos]
    D -->|MCP Protocol| E[Assistente de IA]
    D -->|CLI| F[Desenvolvedor]
    D -->|HTTP Server| G[Web UI]
```

---

## Arquitetura de Alto Nível

```mermaid
graph TB
    subgraph "Camada de Interface"
        CLI[CLI - Commander.js]
        MCP[MCP Server - stdio]
        HTTP[HTTP Server - Express]
        EVAL[Eval Server - SWE-bench]
    end

    subgraph "Camada de Aplicação"
        TOOLS[Tools Layer<br/>query, context, impact,<br/>detect_changes, rename, cypher]
        WIKI[Wiki Generator<br/>Documentação LLM]
        AUG[Augmentation Engine<br/>Hook de contexto IDE]
        AICTX[AI Context Generator<br/>Skill files .claude/]
    end

    subgraph "Camada de Core"
        PIPE[Pipeline de Ingestão<br/>10 fases]
        SEARCH[Hybrid Search<br/>BM25 + Embeddings]
        GRAPH[In-Memory Graph<br/>Dual-Map O(1)]
    end

    subgraph "Camada de Persistência"
        LBUG[LadybugDB<br/>Grafo + FTS + Embeddings]
        REG[Registry<br/>~/.gitnexus/registry.json]
        LOCAL[.gitnexus/<br/>lbug, meta.json, csv/]
    end

    CLI --> TOOLS
    MCP --> TOOLS
    HTTP --> TOOLS
    EVAL --> TOOLS
    CLI --> WIKI
    CLI --> AUG

    TOOLS --> SEARCH
    TOOLS --> LBUG
    WIKI --> LBUG
    AUG --> SEARCH

    PIPE --> GRAPH
    GRAPH --> LBUG
    SEARCH --> LBUG
    LBUG --> LOCAL
    LBUG --> REG
```

---

## Pipeline de Ingestão — O Coração do Sistema

O pipeline de análise é o componente mais crítico. Ele processa o repositório em **10 fases sequenciais**, cada uma construindo sobre a anterior:

```mermaid
graph TD
    P1[1. Extracting<br/>Scan do filesystem<br/>~100K arquivos em ~10MB RAM] --> P2[2. Structure<br/>Árvore de diretórios<br/>Nós: Folder, File]
    P2 --> P3[3. Parsing<br/>Tree-sitter AST<br/>14+ linguagens]
    P3 --> P4[4. Imports<br/>Resolução de módulos<br/>Named bindings]
    P4 --> P5[5. Calls<br/>Grafo de chamadas<br/>Type-aware resolution]
    P5 --> P6[6. Heritage<br/>Herança e implementação<br/>EXTENDS / IMPLEMENTS]
    P6 --> P7[7. Communities<br/>Leiden Algorithm<br/>Clustering funcional]
    P7 --> P8[8. Processes<br/>Fluxos de execução<br/>Entry point → traces]
    P8 --> P9[9. Enriching<br/>Labeling LLM<br/>Nomes semânticos]
    P9 --> P10[10. Complete<br/>Persistência em LadybugDB<br/>CSV bulk load]

    style P1 fill:#e1f5fe
    style P3 fill:#fff3e0
    style P5 fill:#fce4ec
    style P7 fill:#e8f5e9
    style P8 fill:#f3e5f5
```

### Gestão de Memória

O pipeline usa **chunked processing** com budget de 20MB por chunk para manter o pico de memória entre 200-400MB, mesmo em repositórios com 100K+ arquivos. Um cache LRU de ASTs é limpo entre chunks.

---

## Modelo de Dados — O Grafo

### Tipos de Nó (22 tipos)

```mermaid
graph TB
    subgraph "Estrutura"
        FILE[File]
        FOLDER[Folder]
    end

    subgraph "Definições Core"
        FUNC[Function]
        CLASS[Class]
        METHOD[Method]
        IFACE[Interface]
        VAR[Variable]
        PROP[Property]
    end

    subgraph "Multi-linguagem"
        ENUM[Enum]
        STRUCT[Struct]
        TRAIT[Trait]
        IMPL[Impl]
        TALIAS[TypeAlias]
    end

    subgraph "Meta-análise"
        COMM[Community<br/>Cluster funcional]
        PROC[Process<br/>Fluxo de execução]
    end

    FOLDER -->|CONTAINS| FILE
    FILE -->|DEFINES| FUNC
    FILE -->|DEFINES| CLASS
    CLASS -->|HAS_METHOD| METHOD
    CLASS -->|HAS_PROPERTY| PROP
    CLASS -->|EXTENDS| CLASS
    CLASS -->|IMPLEMENTS| IFACE
    METHOD -->|CALLS| FUNC
    FUNC -->|CALLS| METHOD
    FUNC -->|MEMBER_OF| COMM
    FUNC -->|STEP_IN_PROCESS| PROC
```

### Tipos de Relacionamento (14 tipos)

| Relacionamento | Significado | Exemplo |
|---|---|---|
| `CONTAINS` | Hierarquia de diretórios | `src/` → `auth.ts` |
| `DEFINES` | Arquivo define símbolo | `auth.ts` → `validateUser()` |
| `IMPORTS` | Importação de módulo | `login.ts` → `auth.ts` |
| `CALLS` | Chamada de função/método | `login()` → `validateUser()` |
| `EXTENDS` | Herança de classe | `Admin` → `User` |
| `IMPLEMENTS` | Implementação de interface | `UserService` → `IService` |
| `HAS_METHOD` | Classe contém método | `UserService` → `getUser()` |
| `HAS_PROPERTY` | Classe contém propriedade | `User` → `email` |
| `OVERRIDES` | Sobrescrita de método (MRO) | `Admin.save()` → `User.save()` |
| `ACCESSES` | Acesso a propriedade | `fn()` → `user.name` |
| `MEMBER_OF` | Pertence a comunidade | `validateUser()` → `AuthCluster` |
| `STEP_IN_PROCESS` | Passo em fluxo de execução | `login()` → `AuthFlow` |

Cada relacionamento carrega um **confidence score** (0-1) e um **resolution tier** indicando como foi resolvido.

---

## Resolução de Símbolos — Como Chamadas São Conectadas

O sistema usa resolução em 4 tiers, do mais confiável ao menos:

```mermaid
graph TD
    CALL[Chamada detectada no AST<br/>ex: user.validate] --> T1{Tier 1: Same-File<br/>Confiança: 0.95}
    T1 -->|encontrado| R1[Relação CALLS criada]
    T1 -->|não encontrado| T2{Tier 2: Import-Scoped<br/>Confiança: 0.90}
    T2 -->|encontrado| R1
    T2 -->|não encontrado| T3{Tier 3: Package-Scoped<br/>Confiança: 0.90}
    T3 -->|encontrado| R1
    T3 -->|não encontrado| T4{Tier 4: Global<br/>Confiança: 0.50}
    T4 -->|encontrado| R1
    T4 -->|não encontrado| SKIP[Chamada não resolvida<br/>Descartada]
```

### Type Environment (TypeEnv)

Para resolver chamadas de método em receptores (ex: `user.validate()`), o sistema mantém um **TypeEnv** por arquivo com 3 tiers de inferência de tipo:

| Tier | Fonte | Exemplo |
|---|---|---|
| Tier 0 | Anotação de tipo | `const x: User = ...` |
| Tier 1 | Inferência de construtor | `const x = new User()` |
| Tier 2 | Propagação de atribuição | `const x = y` onde `y: User` |

---

## Linguagens Suportadas (14+)

```mermaid
graph LR
    subgraph "Tier 1 — Resolução Completa"
        TS[TypeScript/TSX]
        JS[JavaScript/JSX]
        PY[Python]
        JAVA[Java]
        GO[Go]
    end

    subgraph "Tier 2 — Resolução Boa"
        RUST[Rust]
        CSHARP[C#]
        KOTLIN[Kotlin]
        PHP[PHP]
        RUBY[Ruby]
    end

    subgraph "Tier 3 — Resolução Básica"
        C[C]
        CPP[C++]
        SWIFT[Swift]
    end

    TS & JS & PY & JAVA & GO --> TREESITTER[Tree-sitter Parser]
    RUST & CSHARP & KOTLIN & PHP & RUBY --> TREESITTER
    C & CPP & SWIFT --> TREESITTER
```

Cada linguagem tem:
- **Queries Tree-sitter** específicas para extração de definições, chamadas, imports e herança
- **Type Extractors** para inferência de tipos (anotações, generics, Option/Result unwrap)
- **Import Resolvers** que entendem o sistema de módulos da linguagem (go.mod, tsconfig paths, PSR-4, etc.)
- **Export Detection** com regras da linguagem (Go: letra maiúscula, Python: sem `_` prefixo, etc.)

---

## Detecção de Comunidades (Clusters)

O sistema usa o **algoritmo de Leiden** (evolução do Louvain) sobre o grafo de CALLS para detectar automaticamente módulos funcionais:

```mermaid
graph TD
    CALLS[Grafo de CALLS<br/>entre símbolos] --> LEIDEN[Algoritmo de Leiden<br/>Graphology]
    LEIDEN --> CLUSTERS[Comunidades Detectadas]
    CLUSTERS --> LABEL[Labeling Heurístico<br/>Análise de nomes, tipos, paths]
    LABEL --> LLM[Enrichment LLM<br/>Nomes semânticos]

    CLUSTERS --> C1[Auth System<br/>login, validateUser, session]
    CLUSTERS --> C2[Data Persistence<br/>save, query, migrate]
    CLUSTERS --> C3[API Layer<br/>handleRequest, route, middleware]
```

**Saída**: Comunidades com label semântico, score de coesão e contagem de membros.

---

## Detecção de Processos (Fluxos de Execução)

Processos são **caminhos no grafo de CALLS** que representam fluxos end-to-end:

```mermaid
graph LR
    EP[Entry Point Scoring] --> TRACE[BFS Tracing<br/>via CALLS edges]
    TRACE --> DEDUP[Deduplicação<br/>Remove subconjuntos]
    DEDUP --> PROC[Processos Finais<br/>max 75]

    subgraph "Exemplo: Auth Flow"
        A[handleLogin] -->|step 1| B[validateCredentials]
        B -->|step 2| C[hashPassword]
        C -->|step 3| D[queryUserDB]
        D -->|step 4| E[createSession]
        E -->|step 5| F[setAuthCookie]
    end
```

### Scoring de Entry Points

| Fator | Peso | Exemplo |
|---|---|---|
| Call Ratio (callees/callers) | Alto | Muitas saídas, poucas entradas |
| Export Status | +0.5 | Funções exportadas |
| Name Patterns | Variável | `handle*`, `on*`, `*Controller` |
| Framework Detection | 2.5-3.0x | Next.js pages, Express routes, Django views |

---

## MCP Server — Interface para IA

O MCP Server expõe o grafo via protocolo JSON-RPC stdio com 7 tools e 10+ resources:

```mermaid
graph TB
    subgraph "AI Assistant"
        CLAUDE[Claude Code]
        CURSOR[Cursor]
        OTHER[Outros MCP clients]
    end

    subgraph "MCP Server (stdio)"
        TRANSPORT[Compatible Stdio Transport<br/>Content-Length + Newline]
        DISPATCH[Tool Dispatcher]
        HINTS[Next-Step Hints<br/>Guia agente para tool-chaining]
    end

    subgraph "7 Tools"
        T1[query<br/>Busca semântica]
        T2[context<br/>Visão 360° de símbolo]
        T3[impact<br/>Análise de blast radius]
        T4[detect_changes<br/>Impacto de git diff]
        T5[rename<br/>Renomeação multi-arquivo]
        T6[cypher<br/>Queries customizadas]
        T7[list_repos<br/>Repos indexados]
    end

    subgraph "Resources (Read-Only)"
        R1[gitnexus://repo/name/context]
        R2[gitnexus://repo/name/clusters]
        R3[gitnexus://repo/name/processes]
        R4[gitnexus://repo/name/process/name]
        R5[gitnexus://repo/name/schema]
    end

    CLAUDE & CURSOR & OTHER --> TRANSPORT
    TRANSPORT --> DISPATCH
    DISPATCH --> T1 & T2 & T3 & T4 & T5 & T6 & T7
    DISPATCH --> R1 & R2 & R3 & R4 & R5
    DISPATCH --> HINTS
```

### Análise de Impacto — O Recurso Mais Poderoso

```mermaid
graph TD
    EDIT[Desenvolvedor quer<br/>editar validateUser] --> IMPACT[gitnexus_impact<br/>target: validateUser<br/>direction: upstream]
    IMPACT --> D1[d=1 WILL BREAK<br/>handleLogin, registerUser<br/>Chamadores diretos]
    IMPACT --> D2[d=2 LIKELY AFFECTED<br/>AuthController, UserAPI<br/>Deps indiretos]
    IMPACT --> D3[d=3 MAY NEED TESTING<br/>AppRouter, middleware<br/>Transitivos]

    D1 -->|MUST update| ACTION1[Atualizar assinatura<br/>nos chamadores]
    D2 -->|SHOULD test| ACTION2[Rodar testes<br/>dos módulos afetados]
    D3 -->|IF critical| ACTION3[Testar se path crítico]

    style D1 fill:#ffcdd2
    style D2 fill:#fff9c4
    style D3 fill:#c8e6c9
```

---

## Busca Híbrida

```mermaid
graph LR
    QUERY[Query do usuário<br/>ex: auth validation] --> BM25[BM25 Keyword Search<br/>LadybugDB FTS]
    QUERY --> SEM[Semantic Search<br/>snowflake-arctic-embed-xs<br/>384 dims]

    BM25 --> RRF[Reciprocal Rank Fusion<br/>K=60]
    SEM --> RRF
    RRF --> RESULTS[Resultados ranqueados<br/>por processo e relevância]
```

- **BM25**: Sempre disponível via Full-Text Search do LadybugDB
- **Embeddings**: Opcional, usa modelo `snowflake-arctic-embed-xs` (22M params, ~90MB)
- **Fusão**: RRF combina rankings com fórmula `1/(K + rank + 1)`

---

## Persistência — LadybugDB

```mermaid
graph TB
    subgraph "In-Memory Graph"
        NODES[Node Map<br/>O(1) lookup]
        RELS[Relationship Map<br/>O(1) lookup]
    end

    subgraph "CSV Serialization"
        CSV1[nodes.csv]
        CSV2[relationships.csv]
    end

    subgraph "LadybugDB"
        NTABLES[22 Node Tables<br/>File, Function, Class...]
        RTABLE[CodeRelation Table<br/>Todas as relações]
        ETABLE[CodeEmbedding Table<br/>Vetores 384-dim]
        FTS[Full-Text Search Index]
        VEC[Vector Index<br/>Busca semântica]
    end

    NODES --> CSV1
    RELS --> CSV2
    CSV1 -->|COPY| NTABLES
    CSV2 -->|COPY| RTABLE

    subgraph "Otimizações"
        POOL[Connection Pool<br/>8 max por repo]
        LRU[LRU Eviction<br/>5 repos max]
        IDLE[Idle Timeout<br/>5 min]
        LOCK[Session Locking<br/>Anti-race condition]
    end
```

---

## Wiki Generator

Pipeline de 4 fases para gerar documentação automática com LLM:

```mermaid
graph TD
    W0[Fase 0: Validação<br/>Verifica pré-requisitos] --> W1[Fase 1: Module Tree<br/>LLM agrupa arquivos<br/>em módulos lógicos]
    W1 --> W2[Fase 2: Module Pages<br/>Bottom-up, 1 call LLM<br/>por módulo]
    W2 --> W3[Fase 3: Overview<br/>Página principal<br/>+ Mermaid diagrams]
    W3 --> HTML[HTML Viewer<br/>Documentação interativa]
```

---

## Augmentation Engine — Contexto para IDE Hooks

Motor leve (<500ms) que enriquece ferramentas de IA com contexto do grafo:

```mermaid
sequenceDiagram
    participant IDE as IDE/Hook
    participant AUG as Augmentation Engine
    participant BM25 as BM25 Search
    participant DB as LadybugDB

    IDE->>AUG: pattern (ex: "handleAuth")
    AUG->>BM25: top 10 resultados
    BM25->>DB: FTS query
    DB-->>BM25: matches
    BM25-->>AUG: file results
    AUG->>DB: batch fetch: callers, callees, processes
    DB-->>AUG: relationships
    AUG->>AUG: rank by cohesion
    AUG-->>IDE: enriched context (plain text)
```

---

## CLI — 12 Comandos

```mermaid
graph TB
    subgraph "Análise"
        CMD1[analyze - Indexação completa]
        CMD2[status - Freshness do índice]
        CMD3[clean - Remove índice]
    end

    subgraph "Serving"
        CMD4[serve - HTTP port 4747]
        CMD5[mcp - Stdio server]
        CMD6[eval-server - SWE-bench]
    end

    subgraph "Consulta"
        CMD7[query - Busca semântica]
        CMD8[context - Visão 360°]
        CMD9[impact - Blast radius]
        CMD10[cypher - Queries raw]
    end

    subgraph "Outros"
        CMD11[wiki - Gerar documentação]
        CMD12[setup - Configurar IDE]
        CMD13[list - Listar repos]
        CMD14[augment - Enriquecimento]
    end
```

---

## Fluxo Completo — Do Repositório à Resposta do Agente

```mermaid
sequenceDiagram
    participant DEV as Desenvolvedor
    participant CLI as npx gitnexus
    participant PIPE as Pipeline
    participant TS as Tree-sitter
    participant GRAPH as In-Memory Graph
    participant DB as LadybugDB
    participant MCP as MCP Server
    participant AI as Claude Code

    DEV->>CLI: npx gitnexus analyze
    CLI->>PIPE: Iniciar pipeline
    PIPE->>PIPE: 1. Scan filesystem
    PIPE->>TS: 2-3. Parse ASTs (workers)
    TS-->>PIPE: Definições extraídas
    PIPE->>GRAPH: 4. Resolver imports
    PIPE->>GRAPH: 5. Resolver calls (TypeEnv)
    PIPE->>GRAPH: 6. Resolver herança (MRO)
    PIPE->>GRAPH: 7. Leiden clustering
    PIPE->>GRAPH: 8. Detectar processos
    PIPE->>DB: 9-10. Persistir grafo
    DB-->>DEV: ✅ Indexado

    DEV->>AI: "O que quebra se eu mudar validateUser?"
    AI->>MCP: gitnexus_impact(target: validateUser)
    MCP->>DB: Query upstream callers d=1,2,3
    DB-->>MCP: Blast radius
    MCP-->>AI: 3 diretos, 5 indiretos, risco MEDIUM
    AI-->>DEV: "Você precisa atualizar login() e register()..."
```

---

## Stack Tecnológica

| Camada | Tecnologia |
|---|---|
| **Linguagem** | TypeScript (ES2020, CommonJS) |
| **Parsing** | Tree-sitter (14+ linguagens via WASM/native) |
| **Grafo** | Graphology (in-memory) + LadybugDB (persistência) |
| **Embeddings** | @huggingface/transformers (snowflake-arctic-embed-xs) |
| **CLI** | Commander.js |
| **HTTP** | Express.js |
| **MCP** | @modelcontextprotocol/sdk |
| **Clustering** | Leiden Algorithm (vendored) |
| **Testes** | Vitest |
| **Build** | tsc (TypeScript compiler) |

---

## Métricas do Projeto

- **~99 arquivos TypeScript**, ~1.4MB de código-fonte
- **2075 símbolos** indexados, **4935 relacionamentos**, **157 fluxos de execução**
- **14+ linguagens** suportadas via Tree-sitter
- **22 tipos de nó**, **14 tipos de relacionamento**
- **7 MCP tools**, **10+ MCP resources**
- **12 comandos CLI**
- Processamento de repositórios com **100K+ arquivos** em memória limitada (~400MB pico)

---

## Resumo Funcional

O GitNexus é essencialmente um **compilador de conhecimento sobre código**. Ele:

1. **Lê** o código-fonte usando Tree-sitter (parsing multi-linguagem)
2. **Entende** as relações entre símbolos (imports, chamadas, herança, tipos)
3. **Agrupa** código em módulos funcionais (Leiden clustering)
4. **Traça** fluxos de execução end-to-end (process detection)
5. **Persiste** tudo em um banco de grafos (LadybugDB)
6. **Expõe** esse conhecimento para agentes de IA via MCP

O resultado é que um agente de IA pode perguntar "o que quebra se eu mudar X?" e receber uma resposta precisa baseada em análise estática real do grafo de dependências — não em heurísticas ou grep.

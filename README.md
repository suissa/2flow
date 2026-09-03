# 🌊 Notação 2flow: A Linguagem de Orquestração de Agentes, Grafos Causais e Protocolo de Execução Distribuída

A **notação 2flow** é a linguagem de fluxo utilizada pelo **AllasCode** para descrever grafos causais, orquestração distribuída de agentes e o protocolo de execução de baixo nível que conecta eventos a funções pertencentes aos seus respectivos contextos (*owned behaviors*).

A notação possui **dois níveis complementares**:

1. **2flow Topológica (*Topological 2flow*)** — descreve o grafo de negócio de alto nível: ordem de sequência causal, bifurcações e sincronizações paralelas (*fork-join*), rotas de contingência e compensação Saga, e pontos de parada para governança com intervenção humana (*HITL gates*).
2. **2flow de Execução (*Execution 2flow*)** — descreve o protocolo de baixo nível que ocorre no interior de cada nó topológico: qual evento entra no escopo, qual função ou comportamento atômico é invocado, qual função recebe a chamada e quais resultados estritamente tipados (`Ok<T>` ou `Error<E>`) saem do escopo.

A extensão de baixo nível não substitui a notação topológica original: ela torna cada nó do grafo **diretamente executável e compilável**, sem a necessidade de transferir a lógica de orquestração para blocos espaguete de código imperativo.

---

## 1. Por que Criamos a 2flow? (Motivação e Filosofia)

No desenvolvimento de sistemas distribuídos e plataformas multi-agente, existem três problemas crônicos recorrentes:

1. **A Verbose Insustentável de YAML/JSON**:  
   Definir pipelines em YAML ou JSON é prolixo, propenso a erros de indentação e incapaz de fornecer validação estática de tipos. Um erro de digitação no nome de um campo só é descoberto quando a transação falha em produção.
2. **O "Callback Hell" e a Perda de Visibilidade no Código Imperativo**:  
   Ao escrever fluxos concorrentes em linguagens tradicionais, o grafo de negócio se perde em meio a *mutexes*, *threads*, canais, promessas e blocos de tratamento de erro aninhados. Fica difícil para um arquiteto responder rapidamente: *"Qual é o caminho crítico deste processo?"* ou *"Se a etapa 3 falhar, quem é responsável pelo rollback?"*.
3. **Overhead de Interpretação em Runtime**:  
   Engenhos de workflow convencionais analisam strings e constroem árvores de decisão em tempo de execução, alocando memória na *heap* e introduzindo latência indesejada para sistemas de alta performance.

### A Filosofia da 2flow

> **"Se você consegue desenhar o fluxo em um guardanapo, você deve conseguir expressá-lo diretamente no código, sem intermediários e com garantia estática de que os tipos conversam entre si com custo zero de execução."**

A 2flow foi concebida para ser:

* **Visualmente óbvia**: A direção dos dados, das dependências causais e dos escopos é evidente pelo desenho dos operadores.
* **Computacionalmente gratuita**: O parsing e a validação ocorrem durante a compilação do Zig (**comptime**); o executável final recebe um grafo de chamadas nativas otimizadas (*Zero-Cost Abstraction*).
* **Segura por padrão**: Incompatibilidades de contrato disparam erros pedagógicos antes que o binário seja gerado.

---

## 2. Por que Existem Dois Níveis? (Topologia vs. Execução)

Um mesmo fluxo transacional responde a duas perguntas semânticas fundamentais e distintas:

```text
Topological 2flow  ──► O QUE deve acontecer antes de quê? O que roda em paralelo? Para onde vai a falha?
      ↓
Semantic Graph     ──► Visão clara de negócio, livre de detalhes acidentais de implementação.
      ↓
Execution 2flow    ──► COMO os eventos entram no agente, qual função local é acionada e o que é emitido?
      ↓
Event/Func Wiring  ──► Fiação precisa para compiladores e runtimes conectarem chamadas e eventos.
      ↓
Runtime Projection ──► Projeção agnóstica para Threads nativas, Atores, NATS, QUIC, RPC ou WASM.
```

### 1. Nível Topológico (Processo de Negócio)
```2flow
FinancialAgent.DetectNewSale
  :--: SalesAgent.ResolveSaleProducts
  :--: StockAgent.DecreaseStock
  :--: SalesAgent.CloseSale
```
Legível por arquitetos, gerentes de produto e engenheiros. Não expõe detalhes mecânicos de threads ou de recepção de eventos.

### 2. Nível de Execução (Fiação de Máquina)
```2flow
execution StockAgent.DecreaseStock
  -> Ok<SaleResolved>
  ->> DecreaseStock
  <<- DecreaseStock

  Ok<StockExitCommitted>
    <- Ok<StockExitCommitted>

  Error<StockExitError>
    <- Error<StockExitError>
```
Suficientemente rigoroso para que um compilador ou runtime consiga amarrar um evento de entrada a uma função interna e rotear o resultado sem ambiguidade.

O grafo topológico **permanece idêntico e válido** mesmo que a projeção física de execução mude de chamadas em memória para Atores, filas NATS, streams QUIC, microserviços remotos ou módulos WebAssembly.

---

## 3. Catálogo dos 8 Operadores da Notação 2flow

A linguagem é fundamentada em 8 operadores ortogonais divididos igualmente entre as camadas topológica e de execução:

| Nível | Operador | Nome Formal | Significado Prático |
| :--- | :---: | :--- | :--- |
| **Topológico** | `:--:` | **Sequência Causal** | Avança somente perante resultado `Ok<T>` causal do nó anterior. |
| **Topológico** | `[...]` | **Paralelismo Fork-Join** | Bifurca em ramos concorrentes e sincroniza na barreira de saída. |
| **Topológico** | `!->` | **Canal de Falha / Rollback** | Rota de desvio para compensador Saga em caso de `Error<E>`. |
| **Topológico** | `[? ...]` | **Gate Humano (HITL)** | Pausa o fluxo e exige evidência externa de autorização humana. |
| **Execução** | `->` | **Entrada de Evento (*Ingress*)** | Evento ou resultado externo entra no escopo do Agente. |
| **Execução** | `<-` | **Saída de Evento (*Egress*)** | Evento ou fato tipado é emitido para fora do escopo do Agente. |
| **Execução** | `->>` | **Invocar Comportamento Próprio** | O Agente invoca uma função/ação que pertence ao seu próprio escopo. |
| **Execução** | `<<-` | **Comportamento Sendo Invocado** | A função interna recebe e processa a chamada de seu proprietário. |

---

## 4. Detalhamento dos Operadores Topológicos

### 4.1. `:--:` — Sequência Causal

Conecta nós onde o nó seguinte depende estritamente do sucesso do anterior.

```2flow
ValidatePurchase
  :--: RegisterStock
  :--: RegisterFinancialEntry
```

* **Semântica Formal**: `A :--: B` significa que `Ok<A>` torna-se o insumo causal que habilita a execução de `B`. Um resultado `Error<E>` **jamais** avança através da aresta `:--:`.

---

### 4.2. `[...]` — Paralelismo & Barreira Fork-Join

Bifurca o processamento em múltiplos ramos executados concorrentemente, unindo-os em uma barreira de sincronização atômica (*Join Barrier*).

```2flow
ReceivePurchase
  :--: [RegisterFinancialEntry, RegisterAccountingEntry]
  :--: ContinueLifecycle
```

* **Semântica Formal**: Os nós dentro dos colchetes `[...]` podem ser executados simultaneamente. O nó subsequente (`ContinueLifecycle`) só é habilitado após todos os ramos atingirem a condição de junção declarada. Os colchetes descrevem a topologia do grafo, sem prescrever o mecanismo físico de concorrência (threads nativas, green threads ou workers distribuídos).

---

### 4.3. `!->` — Canal de Falha, Fallback ou Compensador Saga

Associa uma rota de contingência ou compensação a um nó que encontrou um resultado irrecuperável na via normal.

```2flow
ReserveStock !-> CancelReservation
  :--: CapturePayment
```

* **Semântica Formal**: `!->` **não é um terceiro tipo de resultado de função**. Funções computacionais retornam exclusivamente `Ok<T>` ou `Error<E>`. A relação é:
  ```text
  Função Executável
     ├─ Ok<T>    ──► Avança pela aresta normal :--:
     └─ Error<E> ──► Desvia pela aresta !-> (quando declarada)
  ```
  Se nenhuma aresta `!->` for declarada para o nó, o `Error<E>` propaga-se ao chamador conforme o contrato do escopo.

---

### 4.4. `[? ...]` — Ponto de Intervenção Humana (*Human-in-the-Loop Gate*)

Permite congelar o pipeline e suspender o consumo de CPU até que evidências externas de deliberação humana sejam apresentadas.

```2flow
PreparePayment
  :--: [? ApprovePayment]
  :--: ExecutePayment
```

* **Semântica Formal**: O grafo é suspenso no gate. Um gate humano não introduz um terceiro tipo computacional: a avaliação da evidência humana fornecida (via token criptográfico, interface A2UI, CLI ou dashboard) continua resolvendo estritamente como `Ok<Evidence>` ou `Error<Rejection>`.

---

## 5. Detalhamento dos Operadores de Execução (Low-Level Protocol)

Os nós topológicos declaram *quem* participa do grafo, mas não *como* a fiação interna de eventos e funções opera. O nível de execução preenche essa lacuna com precisão cirúrgica.

### 5.1. `->` — Entrada de Evento (*Event Ingress*)

```2flow
-> Ok<SaleResolved>
```

* **Semântica**: Um evento ou resultado causal é entregue ao Agente, Contexto ou escopo de execução atual. A direção é lida a partir do ponto de vista do escopo: a seta aponta **para dentro** do escopo.

### 5.2. `<-` — Saída de Evento (*Event Egress*)

```2flow
<- Ok<StockExitCommitted>
```

* **Semântica**: Um fato tipado ou resultado de processamento é emitido pelo escopo atual para o barramento ou para o nó causal seguinte. A seta aponta **para fora** do escopo.

### 5.3. `->>` — Invocar Comportamento Pertencente (*Invoke Owned Behavior*)

```2flow
->> DecreaseStock
```

* **Semântica**: O Agente ou proprietário do escopo invoca uma função, *Action* ou *AtomicBehavior* que pertence ao seu próprio domínio. Expressa a delegação da fronteira de orquestração para o código executável.

### 5.4. `<<-` — Comportamento Recebendo Invocação (*Function Being Invoked*)

```2flow
<<- DecreaseStock
```

* **Semântica**: A função ou comportamento atômico recebe e atende à invocação disparada pelo seu proprietário.

### 5.5. A Simetria dos Símbolos de Execução

A direção das setas é estritamente relativa ao nó sendo descrito:

```text
->    Conhecimento/evento ENTRA neste escopo
<-    Conhecimento/evento SAI deste escopo
->>   Este escopo INVOCA para dentro um comportamento que ele possui
<<-   O comportamento próprio RECEBE a invocação de seu proprietário
```

Essa convenção estabelece uma leitura perfeitamente simétrica:
- `->` e `<-` transportam eventos através de fronteiras semânticas;
- `->>` e `<<-` descrevem a invocação através de fronteiras de posse (*ownership*).

---

## 6. Leis Semânticas, Fronteiras e Invariantes Fundamentais

### 6.1. A Lei dos Resultados Tipados (*Typed Result Law*)

Toda função executável no ecossistema AllasCode possui exclusivamente duas famílias de resultado:

$$\text{execute} : \text{Input} \to \text{Ok}\langle\text{Output}\rangle \;\mid\; \text{Error}\langle\text{Failure}\rangle$$

* Fatos de domínio (ex.: `SaleDetected`, `StockExitCommitted`, `PurchaseRegistered`) são payloads transportados dentro de `Ok<T>`.
* Falhas e erros de domínio (ex.: `SaleDetectionError`, `StockEntryError`) são payloads transportados dentro de `Error<E>`.
* **Não existe terceiro estado implícito**: `null`, `undefined`, valores sentinela ou exceções não tratadas utilizadas como controle de fluxo são categoricamente proibidos.

### 6.2. Fronteira de Conhecimento do Agente (*Agent Knowledge Boundary*)

Um Agente **jamais** invoca funções ou comportamentos pertencentes a outro Agente de forma direta.

❌ **Acoplamento Inválido (Proibido)**:
```2flow
FinancialAgent
  ->> StockAgent.DecreaseStock
```

✅ **Coreografia Correta e Desacoplada**:
```2flow
FinancialAgent
  <- Ok<SaleDetected>

SalesAgent
  -> Ok<SaleDetected>
  ->> ResolveSaleProducts
```

Somente a fronteira do Agente conhece o evento que sai do seu contexto e os eventos que aceita de fora. As funções internas e *AtomicBehaviors* permanecem completamente agnósticas a contextos externos.

### 6.3. Auto-Cura Semântica e Normalização (*Self-Healing*)

Os comportamentos atômicos nascem integrados ao pipeline de auto-cura do AllasCode. A normalização de dados não é uma fase solta de execução; ela é governada pelo invariante:

$$\text{Normalização} \subset \text{Validate} \cup \text{SelfHealing}$$

$$\text{Normalização} \notin \text{DomainBehavior}$$

Um resultado final `Error<E>` indica que as estratégias de auto-cura permitidas pelo contrato foram esgotadas ou que uma evidência humana externa é estritamente necessária, podendo ativar um gate `[? ...]` ou uma aresta de compensação `!->`.

---

## 7. Os 10 Invariantes Canônicos do 2flow

```text
 1. :--: avança exclusivamente mediante um resultado de sucesso causal Ok<T>.
 2. !-> é uma aresta do grafo topológico, não um terceiro tipo de resultado de função.
 3. Toda função executável resolve estritamente como Ok<T> ou Error<E>.
 4. -> e <- transportam eventos através de fronteiras semânticas de escopo.
 5. ->> e <<- descrevem chamadas através da fronteira de posse do próprio Agente.
 6. Um Agente pode invocar unicamente funções e comportamentos que ele próprio possui.
 7. Comunicação inter-agentes ocorre exclusivamente através de eventos nas fronteiras.
 8. [...] declara semântica de concorrência independente da tecnologia do runtime.
 9. [? ...] expressa evidência humana externa, não uma nova álgebra computacional.
10. Normalização existe unicamente dentro de validação ou de auto-cura semântica.
```

---

## 8. Fluxos Canônicos de Validação dos Novos Operadores

Os fluxos a seguir estão disponíveis de forma canônica no repositório em [`examples/fluxos_novos_operadores.2flow`](file:///d:/www/Freelas/_____suissadev/Conceitos/AllasCode/Concepts/2flow/repo/examples/fluxos_novos_operadores.2flow).

### Fluxo 1: Aquisição e Suprimentos (Topologia + Execução)

```2flow
flow PurchaseProducts

# Grafo Topológico Causal
ProcurementAgent.RegisterPurchase
  :--: StockAgent.IncreaseStock
  :--: FinancialAgent.RegisterFinancialEntry

# Fiação de Execução de Baixo Nível
execution ProcurementAgent.RegisterPurchase
  -> PurchaseEvidenceReceived
  ->> RegisterPurchase
  <<- RegisterPurchase

  Ok<PurchaseRegistered>
    <- Ok<PurchaseRegistered>

  Error<PurchaseRegistrationError>
    <- Error<PurchaseRegistrationError>

execution StockAgent.IncreaseStock
  -> Ok<PurchaseRegistered>
  ->> IncreaseStock
  <<- IncreaseStock

  Ok<StockEntryCommitted>
    <- Ok<StockEntryCommitted>

  Error<StockEntryError>
    <- Error<StockEntryError>
```

---

### Fluxo 2: Roteamento de Falha e Rollback Saga com Fiação de Execução

```2flow
flow FailureRoutingSaga

# Grafo Topológico com Rota de Compensação (!->)
SalesAgent.ReserveStock !-> StockAgent.ReleaseReservation
  :--: FinancialAgent.CapturePayment

# Fiação de Execução do Nó com Falha
execution SalesAgent.ReserveStock
  -> SaleRequested
  ->> ReserveStock
  <<- ReserveStock

  Ok<StockReserved>
    <- Ok<StockReserved>

  Error<StockReservationError>
    <- Error<StockReservationError>

# Fiação do Compensador Acionado via !->
execution StockAgent.ReleaseReservation
  -> Error<StockReservationError>
  ->> ReleaseReservation
  <<- ReleaseReservation

  Ok<ReservationReleased>
    <- Ok<ReservationReleased>
```

---

### Fluxo 3: Paralelismo Fork-Join Concorrente

```2flow
flow ParallelConcurrencyForkJoin

# Grafo Topológico Concorrente
StockAgent.ReceivePurchase
  :--: [FinancialAgent.RegisterPayable, AccountingAgent.RegisterEntry]
  :--: PurchaseAgent.CompletePurchase

# Declaração Independente de Execução dos Ramos Paralelos
execution FinancialAgent.RegisterPayable
  -> Ok<StockReceived>
  ->> RegisterPayable
  <<- RegisterPayable
  <- Ok<PayableRegistered>
  <- Error<PayableRegistrationError>

execution AccountingAgent.RegisterEntry
  -> Ok<StockReceived>
  ->> RegisterEntry
  <<- RegisterEntry
  <- Ok<AccountingEntryRegistered>
  <- Error<AccountingEntryError>
```

---

### Fluxo 4: Governança Corporativa com Human-in-the-Loop (`[? ...]`)

```2flow
flow GovernanceHITL

RiskAgent.PreparePayment
  :--: [? ComplianceDirectorApproval]
  :--: TreasuryAgent.ExecutePayment

execution RiskAgent.PreparePayment
  -> PaymentIntentReceived
  ->> PreparePayment
  <<- PreparePayment
  <- Ok<PaymentPrepared>
  <- Error<PaymentRiskRejected>

execution TreasuryAgent.ExecutePayment
  -> Ok<PaymentApprovedByHuman>
  ->> ExecutePayment
  <<- ExecutePayment
  <- Ok<PaymentExecuted>
  <- Error<PaymentExecutionFailed>
```

---

### Fluxo 5: Pipeline Mestre Corporativo Unificado (Todos os 8 Operadores)

```2flow
flow EnterpriseMasterPipeline

RequisitarServidores
  :--: [AuditarComplianceFiscal, VerificarEstoqueFisico]
  :--: DebitarContaBancaria !-> CancelarReservaOrcamento
  :--: [? AutorizacaoDiretorFinanceiro]
  :--: EmitirNotaFiscal
  :--: DespacharLogisticaWMS

execution DebitarContaBancaria
  -> Ok<VerificacoesConcluidas>
  ->> DebitarConta
  <<- DebitarConta
  <- Ok<ContaDebitada>
  <- Error<SaldoInsuficiente>

execution CancelarReservaOrcamento
  -> Error<SaldoInsuficiente>
  ->> EstornarOrcamento
  <<- EstornarOrcamento
  <- Ok<OrcamentoRestaurado>
```

#### Diagrama Visual do Fluxo Mestre Corporativo:

```text
                               ┌──► [ AuditarComplianceFiscal ] ───┐
                               │                                   │
[ RequisitarServidores ] ─────┼                                   ▼ (Join Barrier)
        (Início)               │                       [ DebitarContaBancaria ]
                               └──► [ VerificarEstoqueFisico ] ───┘          │
                                                                              ├──────► [ CancelarReservaOrcamento ]
                                                                              │             (Rollback se falhar)
                                                                              ▼ (Sucesso)
                                                                [ ?AutorizacaoDiretorFinanceiro ]
                                                                      (HITL Gate / Pausa)
                                                                              │
                                                                              ▼ (Aprovado)
                                                                     [ EmitirNotaFiscal ]
                                                                              │
                                                                              ▼
                                                                  [ DespacharLogisticaWMS ]
                                                                           (Fim)
```

---

## 9. Compilação, Representação Intermediária (Node IR) e Execução Comptime

A DSL 2flow não é interpretada por scripts lentos em tempo de execução. Ela passa pelo seguinte pipeline estático de compilação em Zig:

```text
  DSL String ("A :--: [? Gate] :--: B !-> C")
                │
                ▼
    [ comptime Tokenizer ]  ──► Reconhece os 8 operadores (:--:, [...], !->, [?], ->, <-, ->>, <<-)
                │
                ▼
      [ comptime Parser ]   ──► Constrói NoFlowAST e blocos de execução estáticos
                │
                ▼
   [ Boundary & TypeChecker]──► Valida Agent Knowledge Boundary e assinaturas (@typeInfo)
                │
                ├─► [Incompatível] ──► Dispara @compileError pedagógico estático
                └─► [Válido]       ──► Gera grafo inline com Zero-Cost Abstraction
```

### Representação Intermediária Canônica (Node IR)

Para projetar os grafos 2flow em qualquer runtime semântico, o compilador rebaixa a notação para a seguinte estrutura de dados intermediária:

```text
Node IR
├── semantic_identity   (Identidade e versão do nó)
├── owner               (Agente proprietário)
├── accepts[]           (Lista de eventos e fatos aceitos via ->)
├── invokes[]           (Lista de funções próprias invocadas via ->>)
├── emits_ok[]          (Tipos de eventos emitidos com sucesso via <- Ok<T>)
├── emits_error[]       (Tipos de falha emitidos via <- Error<E>)
└── topology_edges[]    (Arestas causais :--:, branches [...], fallbacks !-> e gates [?])
```

---

## 10. WebAssembly & 2FV (Two-Factor Validation)

O 2flow é nativamente compatível com **WebAssembly (`wasm32-freestanding`)**, viabilizando a técnica de **2FV (Two-Factor Validation)** na stack **AllasCode**:

* **Fator 1 (Client-Side Pre-Flight)**: O motor semântico roda no navegador do usuário (`2flow.wasm` de apenas **2.7 KB**), validando regras de negócio, dados e injeções maliciosas em **< 0.05ms** antes de qualquer envio de rede. **Mais de 90% do processamento de invalidação de payloads é poupado no backend!**
* **Fator 2 (Server-Side Deterministic Proof)**: O cluster autoritativo executa a persistência com garantias de convergência e registro em ledger imutável.

Consulte a especificação detalhada em: **[`docs/2FV-TWO-FACTOR-VALIDATION-WASM.md`](file:///d:/www/Freelas/_____suissadev/Conceitos/AllasCode/Concepts/2flow/repo/docs/2FV-TWO-FACTOR-VALIDATION-WASM.md)**.

---

## 11. Guia Rápido de Referência Sintática

| Padrão Pretendido | Notação na DSL 2flow |
| :--- | :--- |
| Encadeamento causal linear | `A :--: B :--: C` |
| Ramo com compensador Saga em falha | `A :--: B !-> RollbackB :--: C` |
| Concorrência paralela Fork-Join | `A :--: [B, C] :--: D` |
| Ramo paralelo com sequência interna | `A :--: [B, C :--: D] :--: E` |
| Ponto de intervenção humana (HITL) | `A :--: [?AprovacaoGerente] :--: B` |
| Entrada de evento no escopo | `execution Agent.Node\n  -> Ok<InputEvent>` |
| Invocação de função interna pertencente | `execution Agent.Node\n  ->> FuncaoInterna` |
| Recepção da chamada pelo comportamento | `execution Agent.Node\n  <<- FuncaoInterna` |
| Emissão de resultado de sucesso tipado | `execution Agent.Node\n  <- Ok<FatoEmitido>` |
| Emissão de resultado de falha tipado | `execution Agent.Node\n  <- Error<FalhaEmitida>` |
| Fluxo corporativo completo | `A :--: [B, C] :--: D !-> CompD :--: [?Gate] :--: E` |

---

## 12. Execução dos Testes e Compilação

Para compilar o módulo WebAssembly e executar a suíte completa de testes automatizados com Zig:

```bash
# Executa os 7 testes de validação dos operadores 2flow (topologia + execução + HITL)
zig test tests/main.zig

# Executa o exemplo unificado demonstrativo
zig run main.zig

# Compila o binário WebAssembly 2FV ultra-leve (2.7 KB)
make wasm

# Executa todos os testes do repositório (testes centrais + 64 testes de invalidação pesada)
make test-all
```

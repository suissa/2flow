# 2flow — Avaliação Técnica Independente

> Documento de opinião produzido por **Claude (Sonnet 5)** via Claude Code em **2026-09-03**, a
> pedido do mantenedor. Baseia-se na revisão do código no worktree `claude/init-89cd8b` e na
> execução completa da suíte de testes com **Zig 0.16.0**. É uma leitura externa e sem filtro —
> o objetivo é ser útil, não gentil.

---

## 1. Método

O que foi lido e executado:

- **Motor central:** `main.zig`, `wasm.zig`, `tests/main.zig`
- **Exemplos:** `examples/data-pipeline/`, `examples/empresa-agentica/` (incluindo `tools.zig`, `config.2flow`, testes)
- **DSL:** o parser comptime, replicado em 4 arquivos
- **Docs:** `README.md`, `docs/2FV-TWO-FACTOR-VALIDATION-WASM.md`, `docs/prompts/01-critica-notebooklm.md`
- **Site:** `index.html` (raiz) e `site/`
- **Validação prática:** escrevi `tests/erp_complexo.zig`, que exercita o **motor real** (`main.zig` importado como módulo, sem cópia) com um fluxo de 19 agentes — Order-to-Cash + Procure-to-Pay + Logística —, 5 fork-joins (1 aninhado) e 5 sagas (2 dentro de ramos paralelos). Cenários cobertos: caminho feliz, rollback de saga com abort do downstream, quebra de barreira fork-join e compensador declarado dentro de um ramo paralelo.

Resultado: **29/29 testes do repositório passam no Zig 0.16.0** e o `2flow.wasm` compila para `wasm32-freestanding`. O motor **faz o que promete fazer** nos 3 operadores implementados.

**Não avaliado:** trabalho em progresso que existe apenas no worktree principal (`heavy_validator.zig`, `benchmark_invalidation.zig`, `test_heavy_invalidation.zig`, `e2e/`). Algumas críticas abaixo podem já estar sendo endereçadas lá.

---

## 2. Resumo executivo

**A ideia central é boa e a implementação-núcleo é competente.** Compilar uma topologia de fluxo
para uma AST em `comptime` e monomorfizá-la num orquestrador nativo é um uso legítimo e elegante
do Zig — não é truque de marketing, o parser realmente some do binário e as chamadas realmente
viram código direto.

**A engenharia ao redor é de protótipo.** Parser copiado em 4 arquivos, sem `build.zig`, corridas
de dados no fork-join, zero durabilidade, sem cancelamento nem timeout.

**A documentação promete três coisas que o código não entrega:** o operador de gate humano
`[?...]`, a checagem de tipos entre nós em comptime, e "transações distribuídas". Nenhuma existe.
Esse desalinhamento é o problema mais sério do projeto hoje — mais do que qualquer bug — porque
mina a credibilidade do que de fato foi construído.

Recomendação de uma linha: **consolide o motor num módulo único com `build.zig`, alinhe a
documentação com a realidade (implemente `[?...]` ou remova-o), e escolha um modelo de
concorrência de verdade.**

---

## 3. A ideia central, e por que ela merece atenção

O pitch do "guardanapo" — *se você desenha o fluxo, você escreve o fluxo* — é real aqui:

```
RequisitarServidores
  :--: [AuditarComplianceFiscal, VerificarEstoqueFisico]
  :--: DebitarContaBancaria !-> CancelarReservaOrcamento
  :--: EmitirNotaFiscal
```

Três propriedades que quase nenhum orquestrador de workflow tem juntas:

1. **Parsing com custo zero em runtime.** `tokenize` + `parseExpression` rodam em `comptime`
   (`main.zig:86-220`). O binário final não carrega tokenizer, string da DSL nem árvore de
   decisão — recebe uma `NoFlowAST` já resolvida.
2. **Orquestração monomorfizada.** `executarFlow` recebe `comptime node` e faz `inline for`
   sobre os filhos (`main.zig:279`, `293`). Cada nó `.modulo` vira um lookup + chamada direta;
   a estrutura do fluxo é desdobrada em uma função. Isso é *zero-cost abstraction* no sentido
   estrito.
3. **Compensação visível na notação.** O `!->` põe o rollback da saga **no desenho do fluxo**,
   não escondido num `catch` três camadas abaixo. É uma decisão de DX genuinamente boa e é o
   diferencial mais defensável da linguagem.

O **2FV** (`docs/2FV-TWO-FACTOR-VALIDATION-WASM.md`) é a segunda boa ideia, e independente da
primeira: compilar o motor de validação do backend para WASM e rodá-lo no cliente como
pre-flight, eliminando drift de regras e requisições desperdiçadas. Isso tem valor sozinho,
sem nenhum framing de "agentes".

---

## 4. Pontos fortes

| # | Ponto | Evidência |
|---|---|---|
| 1 | Conceito comptime bem executado | `parse2Flow` + `executarFlow` monomorfizado |
| 2 | `!->` torna saga/compensação legível | `config.2flow` dos dois exemplos |
| 3 | 2FV: mesma lógica no cliente e no servidor | `wasm.zig` reusa `examples/*/tools.zig` |
| 4 | Superfície pequena, sem árvore de dependências | ~500 linhas de motor, só `std` |
| 5 | Testes existem e são significativos | cada operador tem teste dedicado; exemplos têm 8 e 9 testes |
| 6 | Exemplos concretos e não-triviais | pipeline LGPD/sentimento e ciclo de micro-empresa completo |
| 7 | AST limpa e fácil de estender | `NoFlowAST` tem 4 campos, um `enum` de 3 variantes |
| 8 | `@embedFile` para `.2flow` externo | trocar topologia sem tocar em código (`data-pipeline/main.zig:362`) |

---

## 5. Pontos fracos (técnicos)

### 5.1 O parser está copiado em 4 arquivos

`tokenize`/`parseExpression`/`parse2Flow` e o orquestrador aparecem, quase idênticos, em
`main.zig`, `tests/main.zig`, `examples/data-pipeline/main.zig` e
`examples/empresa-agentica/main.zig`. Qualquer mudança de semântica precisa ser replicada 4
vezes, e os testes de `tests/main.zig` validam uma **cópia**, não o motor que roda em produção.
A causa (`@import("../main.zig")` cruza a fronteira de módulo do Zig) é resolvida com um
`build.zig` + `b.addModule`. Enquanto isso não existe, o projeto não tem uma "fonte da verdade"
do motor.

### 5.2 Não há `build.zig`

Tudo é `zig test arquivo.zig` avulso, coordenado por um `Makefile` que nem roda na máquina de
dev (não há `make` no Windows). Um projeto Zig sério tem `build.zig` com: módulo do motor, step
de testes agregando tudo, o alvo WASM como artefato de build, e `zig build test`. Isso também
elimina o 5.1.

### 5.3 O parser comptime não escala

`tokenize` faz `tokens = tokens ++ .{Token{...}}` dentro do loop (`main.zig:100`, `133`) — cada
`++` realoca o array inteiro, então é **O(n²)** em tempo/memória de comptime. Combinado com a
cota padrão de 1000 *backward branches*, qualquer fluxo com mais de ~10 nós **falha ao compilar**
até o chamador adicionar `@setEvalBranchQuota(...)` — coisa que nenhum call-site do repo faz. Meu
`tests/erp_complexo.zig` só compila porque eu chamo `@setEvalBranchQuota(500_000)` antes do
parse. Correção: `@setEvalBranchQuota` dentro do próprio `parse2Flow`, e contar tokens numa
passada para pré-alocar (ou usar um buffer comptime de tamanho fixo).

### 5.4 Concorrência insegura no fork-join

`.paralelo` (`main.zig:286-320`) tem três problemas:

- **Corrida de dados no `*Event`.** Todos os ramos recebem o mesmo ponteiro e os handlers
  escrevem campos (`ev.status = ...`, `ev.valor_eur = ...`) sem sincronização. Só
  `registrarPasso`/`registrarPasso` tem mutex, e o `EventoTransacional` de `main.zig` nem mutex
  tem. Escrita concorrente de slice `[]const u8` = ponteiro/len rasgados = crash possível.
- **Uso de pilha após retorno.** Se `std.Thread.spawn` falha, o código faz `return false`
  (`main.zig:301`) **sem dar join** nas threads já criadas neste loop. Essas threads continuam
  escrevendo em `&resultados[i]`, que é memória de pilha da função que está retornando.
- **`threads.append(...) catch {}`** (`main.zig:303`) engole falha de alocação silenciosamente;
  a thread nunca recebe join → mesma classe de bug.

Além disso: **uma thread de SO por ramo, incondicionalmente**, sem pool nem work-stealing. Um
fork largo dentro de um loop esgota threads. E **não há timeout nem cancelamento** — se um ramo
trava, o join trava para sempre.

### 5.5 O tipo de retorno do agente é `bool` — sem causa de erro

`AgenteHandlerFn` retorna `bool` (`main.zig:49`). Quando um nó falha, o compensador recebe o
mesmo `*Event` mas **nenhum erro estruturado** — não sabe *por que* falhou. Sagas reais precisam
da causa para compensar corretamente (estornar por timeout ≠ estornar por saldo insuficiente).
O `error union` do Zig (`fn(...) FlowError!void`) seria o encaixe natural e daria o "canal de
erro tipado" que o `!->` só finge ter.

### 5.6 Registro de agentes é *stringly-typed* e manual

Você escreve o fluxo com nomes e, **separadamente**, chama `registarAgente("Nome", fn)`. Um erro
de digitação vira `orelse return false` em runtime (`main.zig:250`), não erro de compilação.
Como a AST é comptime, o **conjunto de nomes exigidos é conhecível em comptime** e poderia ser
verificado contra o catálogo — hoje não é.

### 5.7 Fragilidades pontuais do orquestrador

- `ev.status = "EM_ROLLBACK"` (`main.zig:269`) é sobrescrito por qualquer compensador que
  escreva em `status` (descobri isso ao escrever os testes do ERP).
- `resultados: [N]bool = @splat(true)` (`main.zig:289`): um ramo que sequer conseguiu ser
  disparado pode contar como sucesso dependendo do caminho.
- Não há observabilidade além de `std.debug.print` com ANSI. Sem trace estruturado, sem métricas,
  sem duração por nó.

### 5.8 Tensão de design: desdobrar tudo vs. tamanho do binário

`executarFlow` com `inline for` desdobra o fluxo **inteiro** numa função. Para 100 nós isso é
muito código gerado e comptime que explode. Um híbrido — AST em comptime, interpretador em
runtime caminhando por ela — escalaria muito melhor e continuaria rápido (a AST cabe em cache).
Vale a pena medir antes de assumir que "zero-cost por desdobramento" é a escolha certa em escala.

---

## 6. Documentação × implementação — o maior problema

O `docs/prompts/01-critica-notebooklm.md` já contém uma crítica editorial correta (teoria
repetida duas vezes, tom oscilando entre jargão de negócio e minúcia de compilador, exemplos com
`A :--: B` em vez de um caso real). Não vou repetir. O que importa mais é isto:

### 6.1 `[?...]` (gate humano / HITL) não existe

É a **manchete** da tabela de "4 operadores fundamentais" do README e o tokenizer **rejeita `?`**
— só aceita `[A-Za-z0-9_]` (`main.zig:128`), então `[?Aprovacao]` dá
`@compileError("Caractere inválido")` (`main.zig:137`). Um dos quatro pilares anunciados da
linguagem não compila. Ou implemente, ou tire da documentação até implementar.

### 6.2 "Os tipos conversam em comptime" — não conversam

O README seção 4.1 afirma `OutputType(AgenteA) ≡ InputType(AgenteB)` verificado em comptime, com
"erros pedagógicos antes do binário ser gerado". **Não há checagem de tipos.** Todo agente é
`fn(ctx: *ContextoRuntime, ev: *EventoTransacional) bool` (`main.zig:49`). Não existe noção de
tipo numa aresta entre nós — existe um `Event` mutável único que cada agente lê e escreve à
vontade. Essa é a maior distância entre o discurso e o código.

### 6.3 "Transações distribuídas" / "microsserviços" / "nós distribuídos"

A implementação é **um processo, em memória, chamadas de função sobre threads**. Isso é um escopo
perfeitamente respeitável — mas o README fala em NATS, QUIC, supervisão estilo Erlang/OTP,
Black Friday e "o servidor não cai". Nada disso está no código. Vender o que não existe faz o
leitor técnico descontar o que existe.

### 6.4 Recomendação

Separe em dois documentos, como a própria crítica interna sugere:

- **`VISION.md`** — filosofia, padrões (saga, fork-join), onde isso quer chegar. Pode sonhar.
- **`SPEC.md`** — o que a v0.x faz **hoje**, com uma tabela "Implementado / Planejado / Não
  planejado". Cada afirmação verificável contra um teste.

---

## 7. Melhorias recomendadas (priorizadas)

### P0 — credibilidade e fundação

1. **`build.zig`** com módulo único do motor; deletar as 3 cópias do parser.
2. **Alinhar a documentação:** tabela de status dos operadores; remover ou implementar `[?...]`;
   remover as alegações de tipagem-entre-nós e de "distribuído" até serem verdade.
3. **`@setEvalBranchQuota` dentro de `parse2Flow`** + pré-alocação de tokens. Sem isso, ninguém
   consegue usar em um fluxo do tamanho de um ERP real.

### P1 — correção

4. **Isolar estado por ramo** no fork-join (cópia-por-ramo + merge determinístico na barreira,
   estilo *reducer* do LangGraph) ou documentar que ramos paralelos não podem escrever campos
   compartilhados.
5. **Corrigir o caminho de falha do `spawn`**: dar join em tudo que já foi disparado antes de
   retornar; não engolir o `catch` do `append`.
6. **`FlowError!void` em vez de `bool`** — canal de erro tipado de verdade, causa disponível ao
   compensador.
7. **Verificar em comptime que todo nome do fluxo tem agente registrado.**

### P2 — maturidade

8. **Timeout e cancelamento** por nó e por fork; pool de threads em vez de thread-por-ramo.
9. **Trace estruturado** (duração, status, causa por nó) — pré-requisito para qualquer uso sério.
10. **Persistência opcional de checkpoint** para o gate humano fazer sentido (sem isso, "pausar
    aguardando aprovação" não sobrevive a um restart).
11. Traduzir README/SPEC para inglês além do português — o público de infra open-source é
    majoritariamente anglófono.
12. **Extrair o 2FV** como projeto/artigo próprio. É a parte mais imediatamente útil e a menos
    dependente do resto.

---

## 8. Comparação com frameworks atuais

| Dimensão | **2flow** | LangGraph | Temporal / Restate / DBOS | Effect (TS) / ZIO | BPMN (Camunda/Zeebe) |
|---|---|---|---|---|---|
| Modelo | DSL textual → AST comptime | Grafo em Python (`StateGraph`) | Workflow-as-code + replay determinístico | Efeitos tipados compostos | Modelo visual (XML) |
| Custo de runtime | ~zero (monomorfizado) | Alto (interpretador Python por passo) | Médio (SDK + servidor) | Baixo (fibers) | Médio-alto (engine) |
| Durabilidade / resume | **Nenhuma** | Checkpointing | **Núcleo do produto** | Não (sem addon) | Sim |
| Erros tipados | Não (`bool`) | Parcial (via state) | Sim (Saga helper, retry policy) | **Sim (canal `E`)** | Compensação nativa |
| Human-in-the-loop | Anunciado, **não implementado** | `interrupt()` real | Signals / Updates | Manual | User Task nativa |
| Concorrência | thread/ramo, sem pool/cancelamento | async | Determinística + timers | **Structured concurrency + interrupção** | Parallel Gateway |
| Distribuído | Não (in-process) | Não (1 processo) | **Sim** | Não | Sim |
| Observabilidade | `print` + ANSI | LangSmith | Web UI + histórico completo | Tracing/Metrics | Cockpit / Operate |
| Peso operacional | 1 arquivo, sem deps | biblioteca | **cluster** | biblioteca | cluster |
| Alvo natural | pipelines fixos, baixa latência, 1 processo | loops de agentes LLM | processos de negócio longos | apps TS resilientes | processos corporativos |

### Por família

**LangGraph.** Estruturalmente é o parente mais próximo: `NoFlowAST` + `Event` compartilhado é o
mesmo formato do `StateGraph` + state. Diferenças que importam: o state do LangGraph é **tipado
com reducers explícitos** para updates concorrentes (2flow tem corrida); tem **checkpointing**
real (2flow não tem nada); o HITL via `interrupt()` **funciona** (o `[?...]` não). Em troca,
LangGraph é um runtime Python pesado que reinterpreta o grafo a cada passo — 2flow realmente
compila isso pra fora. 2flow poderia ser o *control plane* nativo embaixo de algo assim.

**Temporal / Restate / DBOS.** É a categoria que a retórica do README está mirando: execução
durável, replay determinístico, sagas que sobrevivem à morte do processo, workflows de meses. O
`!->` do 2flow é um `try`/compensa síncrono num processo só, sem durabilidade. A distância é
enorme — mas Temporal precisa de um cluster e 2flow é uma lib de 500 linhas. Classes de peso
diferentes; o erro é o discurso sugerir que estão na mesma.

**Effect (TS) / ZIO (Scala).** Filosoficamente é onde o 2flow *quer* chegar: efeitos
componíveis, **canal de erro tipado** (`Effect<A, E, R>`), fibers com interrupção,
structured concurrency. Effect faz **no nível de tipos** o que o 2flow gesticula. Se o autor
quer que "os tipos conversam" seja verdade, o modelo `Effect<A, E, R>` é o que estudar.

**BPMN (Camunda / Zeebe).** As primitivas são *exatamente* as mesmas: sequence flow, parallel
gateway, compensation/saga, user task (= HITL). 2flow é, na prática, **BPMN textual compilado
para código nativo**. Camunda/Zeebe são distribuídos, duráveis, com modelador visual e cockpit;
2flow troca tudo isso por overhead zero e uma sintaxe de uma linha.

**Frameworks de agente LLM (OpenAI Agents SDK, CrewAI, AutoGen, padrões da Anthropic).** Esses
tratam do que é específico de LLM: tool calling, handoffs, memória, gestão de contexto,
orçamento de tokens. 2flow é só camada de orquestração — os "agentes" são funções Zig. O README
cita "A2A", "agentes de IA", "LLM", mas **não há nenhuma integração com LLM**. 2flow poderia ser
o motor de controle *sob* um sistema desses, mas não resolve nada da parte de IA.

---

## 9. Onde o 2flow realmente se encaixa

O nicho defensável, sendo honesto sobre o que o código faz:

**Sim:** orquestração intra-processo de baixa latência e alta vazão, onde a topologia é fixa em
tempo de build e você quer que a estrutura do fluxo seja legível e compile para código nativo
sem interpretador. Exemplos: pipelines de tratamento de request dentro de um serviço, etapas de
ETL embutidas, lógica de jogo, pipelines de trading, sistemas embarcados, o próprio pre-flight
2FV.

**Não:** processos de negócio longos, qualquer coisa que precise sobreviver a restart, qualquer
coisa genuinamente distribuída, loops de agente LLM com planejamento dinâmico. Para esses, os
frameworks da seção 8 existem por bons motivos.

---

## 10. Veredito

Tirando o marketing e julgando só o código: é uma **prova de conceito bem-feita** de
"DSL → AST comptime → orquestrador monomorfizado", com uma segunda boa ideia acoplada (2FV). O
núcleo funciona e passa nos testes. Falta: consolidação num módulo com `build.zig`, uma história
de concorrência de verdade (pool, cancelamento, erros tipados, isolamento de estado), e —
acima de tudo — **documentação que descreva o que existe**. Implemente o `[?...]` e a checagem
de nós, ou pare de anunciá-los. A base é boa o suficiente para merecer esse cuidado.

**Nota geral (subjetiva):** ideia 8/10 · execução do núcleo 6/10 · robustez de produção 3/10 ·
honestidade da documentação 3/10 · potencial se o P0/P1 for feito 8/10.

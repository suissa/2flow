# **🌊 Notação 2flow: A Linguagem de Orquestração de Agentes e Fluxos Distribuídos**

## **1\. O que é a Notação 2flow?**

A **notação 2flow** é uma Linguagem de Domínio Específico (**DSL**) declarativa, concisa e simbólica, projetada para modelar, validar e orquestrar fluxos de trabalho complexos, agentes autônomos e transações distribuídas.

Diferente de formatos tradicionais de configuração de pipelines (como JSON, YAML ou XML) ou de frameworks de orquestração imperativos que exigem centenas de linhas de código estrutural, a 2flow permite expressar **grafos de dependência causal, paralelismo, canais de compensação de erros e pontos de decisão humana** em uma notação linear, intuitiva e expressiva.

No ecossistema do **agentd**, a 2flow é processada integralmente em tempo de compilação (**comptime**) pelo compilador do **Zig 0.13.0**, unindo legibilidade quase visual com garantias matemáticas de integridade e custo zero de execução (*Zero-Cost Abstraction*).

## **2\. Por que criamos a 2flow? (A Motivação)**

No desenvolvimento de sistemas distribuídos e plataformas multi-agente, existem três problemas crônicos recorrentes:

1. **A Verbose Insustentável de YAML/JSON**:  
   Definir pipelines em YAML ou JSON é prolixo, propenso a erros de indentação e incapaz de fornecer validação estática de tipos. Um erro de digitação no nome de um campo só é descoberto quando a transação falha em produção.  
2. **O "Callback Hell" e a Perda de Visibilidade no Código Imperativo**:  
   Ao escrever fluxos concorrentes em linguagens tradicionais, o grafo de negócio se perde em meio a *mutexes*, *threads*, canais, promessas e blocos de tratamento de erro aninhados. Fica difícil para um arquiteto ou desenvolvedor bater o olho no código e responder: *"Qual é o caminho crítico deste processo?"* ou *"Se a etapa 3 falhar, quem é responsável pelo rollback?"*.  
3. **Overhead de Interpretação em Runtime**:  
   Engenhos de workflow convencionais analisam strings e constroem árvores de decisão em tempo de execução, alocando memória na *heap* e introduzindo latência indesejada para sistemas de alta performance.

### **A Filosofia da 2flow**

> **"Se você consegue desenhar o fluxo em um guardanapo, você deve conseguir expressá-lo diretamente no código com uma única linha, sem intermediários e com garantia estática de que os tipos conversam entre si."**

A 2flow foi concebida para ser:

* **Visualmente óbvia**: A direção dos dados e das dependências é evidente pelo desenho dos operadores.  
* **Computacionalmente gratuita**: O parsing e a validação ocorrem durante a compilação do Zig; o executável final recebe um grafo de chamadas nativas otimizadas.  
* **Segura por padrão**: Tipos incompatíveis disparam erros pedagógicos antes que o binário seja gerado.

## **3\. Para que Serve a Notação 2flow?**

A notação serve como o **cérebro topológico** do framework, sendo aplicada em:

* **Orquestração de Agentes de IA (A2A)**: Definição clara de como agentes especialistas (ex: Arquiteto ![][image1] Backend ![][image1] QA ![][image1] DevOps) transferem contexto e delegam tarefas.  
* **Transações Distribuídas e Padrão Saga**: Coordenação de múltiplos microsserviços ou bancos de dados garantindo reversão automática (*Rollback LIFO*) caso uma etapa falhe.  
* **Pipelines de Concorrência Extrema (Fork-Join)**: Disparo simultâneo de ramificações analíticas com convergência obrigatória em barreiras atômicas.  
* **Governança com Human-in-the-Loop (HITL)**: Introdução de portas de controle para aprovação humana obrigatória em operações financeiras ou de alto risco.  
* **Ponte entre Negócio e Engenharia**: Um formato compacto o suficiente para ser discutido em reuniões de produto e rigoroso o bastante para ser compilado diretamente em código de máquina.

## **4\. A Anatomia dos 4 Operadores Fundamentais**

A notação baseia-se em quatro primitivas elegantes que podem ser combinadas recursivamente:

| Operador | Nome Formal | Significado Prático |
| :---- | :---- | :---- |
| :--: | **Sequência Causal (Pipeline)** | Conecta a saída do nó anterior à entrada do nó seguinte. |
| \!-\> | **Canal de Erro / Rollback** | Desvia a execução para um compensador em caso de falha (Saga). |
| \[...\] | **Paralelismo (Fork-Join)** | Bifurca o fluxo em ramos concorrentes e sincroniza na saída. |
| \[?...\] | **Gate Humano (HITL)** | Pausa o fluxo e exige autorização externa via token. |

### **4.1. :--: (Sequência Causal)**

Conecta dois nós onde o segundo depende estritamente do término com sucesso do primeiro.

Entrada :--: Validar :--: Processar :--: Saida  


[image1]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABUAAAAZCAYAAADe1WXtAAACsklEQVR4AYxTwYoTQRB9PW7YVUFyMKDJxM0hOYrKevUDBG+evYhHP8SDsEc9eBT8BU/+QURR9xRiQoZ4CYgKsqsmbfWrN9lOFLGYqX716lV1Tc9MgW0L24TinCemUxLIo6xpTktEig6IMMtx3GhkSdSEN6VWoggaFzmm6WJdZ5rg+xhKV1w7oAjrQCISdKg7sADblrPSS5JNCu8hLWXERHDTxgyC64k3XcE6cqcoHSCjkBJEiUrBxs1MrmE25I+vOorocgI+FtvATViLc+59UvUgJREpOhFMAp12++L+lf3HZVmeZZp88D2JI/xMWadEYMbfLHmPnQCazeZXY87t7OxcYzrXWyJd3pSJ6HVU0iHbHm4BH46Ofizj8kmM8UGv12s6H13KPkGT4v8t1VWz6r1VvLLGDw9uHDQM+0AJGErf6ZlOu2NHVA7MDcqu1tLWjt1ld5DzpkxxvyiKoTW9sFgs3tjE161f2s8WoLjcbu82Go1bIYQ7vJFWOCYnvMWvVqu71uG2Hdo7IFwC/ARgVnyaz79PppMXs1l1OJvNdFeHVcJVioVTnGlsym9W/7zVat2bTD6+DMDKntwowD+pmDAdfD/9OaRsFtRGAt2ye9Oe6qp9AU+Hr4c/66zXWtOwzbCODrWIGjqg3+/v2nneXy5Xz8bj8RfQlBT2T4qBGhHD+5HKpwZOjo/PW3K+t7f3lq2ooYNb/fF7lHk1ypgaVlX1eTqdPhqNRidsxc7w4xThZ6pEXSgJbCJsYkap9BeRZf1SAy7/mJTiVG6dpTWKyNZ0CVMDU0EW/vJHURsz0Z9v35MRNOkZyfmLYkCJnM6UBWtKwBbpmRY2VlfQpMwis00l06KIpSQlQgsz6d/fPPNcSay0qkRZcU7oyYxNan98BrmLfmyiVK7IFhLRwOlFSuFvAAAA///8Wr/FAAAABklEQVQDAHfZ7zrdOMtlAAAAAElFTkSuQmCC>

#### Regra de Tipos em Comptime

$$\text{OutputType}(\text{Agente A}) \equiv \text{InputType}(\text{Agente B})$$

$$\text{OutputType}(\text{Agente B}) \equiv \text{InputType}(\text{Agente C})$$

#### Exemplo Prático Isolado

```zig
// Pipeline simples de compras: Receber requisição -> Auditar NIF -> Emitir PO
const dsl_sequencia =
    \\ReceberRequisicao :--: ValidarFornecedorNIF :--: EmitirOrdemCompra
;

```

* **Semântica**: `ReceberRequisicao` produz uma `RequisicaoCompra`. O nó `ValidarFornecedorNIF` consome a requisição, valida o documento e produz uma `RequisicaoAuditada`. Por fim, `EmitirOrdemCompra` consome a requisição auditada e gera o documento fiscal final. Se qualquer etapa falhar, o pipeline é interrompido.

---

### 3.2. Canal de Erro / Rollback Saga (`!->`)

Implementa a resiliência do **Padrão Saga**. Associa uma ação compensatória imediata a um nó específico. Caso o nó execute com sucesso, o fluxo segue normalmente via `:--:`; se falhar, o fluxo é desviado imediatamente para o compensador.

#### Diagrama de Fluxo

```text
                       (Sucesso :--:)
              ┌──────────────────────────────► [ ReservarStock ]
[ DebitarSaldo ]
              └──────────────► [ EstornarLancamento ]
                       (Falha !->)

```

#### Exemplo Prático Isolado

```zig
// Se a cobrança falhar, aciona a compensação e aborta a reserva de stock
const dsl_saga =
    \\ValidarPedido :--: DebitarSaldo !-> EstornarLancamento :--: ReservarStock
;

```

* **Semântica**: `ValidarPedido` avança para `DebitarSaldo`. Se a conta tiver saldo suficiente, a execução prossegue para `ReservarStock`. Se ocorrer um erro (ex: `SaldoInsuficiente` ou falha de comunicação com o banco), o fluxo não avança para `ReservarStock`; em vez disso, o motor despacha o evento para `EstornarLancamento` passando o contexto do erro e a causa-raiz para restaurar a consistência contábil.

---

### 3.3. Paralelismo & Sincronização Fork-Join (`[...]`)

Permite a bifurcação (*Fork*) de uma mensagem para múltiplos ramos concorrentes (executados em *threads* separadas ou nós distribuídos) e a posterior junção sincronizada (*Join Barrier*) no passo seguinte.

#### Diagrama de Fluxo

```text
                         ┌──► [ Ramo 1: InspecaoQualidade ] ──────────────┐
                         │                                                │
[ DescarregarDoca ] ─────┼                                                ▼ (Barreira Join)
      (Fork)             │                                          [ DarEntradaWMS ]
                         └──► [ Ramo 2: ValidarGuiaFiscal :--: CalcularIVA ] ─┘

```

#### Exemplo Prático Isolado

```zig
// Descarrega na doca e, em paralelo, inspeciona qualidade e valida impostos antes de guardar
const dsl_fork_join =
    \\DescarregarDoca :--: [InspecaoQualidade, ValidarGuiaFiscal :--: CalcularIVA] :--: DarEntradaWMS
;

```

* **Semântica**:
1. `DescarregarDoca` é executado até ao fim.
2. O motor faz o *Fork*: dispara concorrentemente o `Ramo 1` (`InspecaoQualidade`) e o `Ramo 2` (que executa a sequência `ValidarGuiaFiscal :--: CalcularIVA`).
3. `DarEntradaWMS` é configurado como uma barreira atómica: ele aguarda obrigatoriamente a conclusão de ambos os ramos (`InspecaoQualidade` e `CalcularIVA`) para só então consolidar o inventário.



---

### 3.4. Ponto de Intervenção Humana (*Human-in-the-Loop* - `[?...]`)

Permite introduzir portas de governança (*Governance Gates*) onde o sistema congela o estado da transação, gera um identificador seguro (*Token*) e aguarda uma autorização humana explícita antes de continuar.

#### Diagrama de Fluxo

```text
                             (Pausa: Token TK-9041)
[ AvaliarLimiteCredito ] ──► [ ?AprovacaoDiretoria ] ──► [ TransferirFundosSEPA ]
                                     │
                        (Aprovação Manual via A2UI / CLI)

```

#### Exemplo Prático Isolado

```zig
// Transação de alto risco: requer aprovação manual de um operador antes da transferência
const dsl_hitl =
    \\AvaliarLimiteCredito :--: [?AprovacaoDiretoria] :--: TransferirFundosSEPA :--: NotificarCliente
;

```

* **Semântica**: Quando o fluxo atinge `[?AprovacaoDiretoria]`, a *thread* de execução é suspensa sem consumir CPU. Um evento de auditoria é enviado para o barramento (podendo renderizar um ecrã interativo via **A2UI**). O operador humano aprova ou rejeita a operação através da CLI, REST API ou Dashboard. Com a aprovação, o pipeline é reativado a partir do ponto exato onde parou.

---

## 4. Fluxo Completo Unificado (Integração de Todos os Operadores)

Abaixo está o exemplo definitivo que combina **Sequência**, **Paralelismo Fork-Join**, **Canal de Erro / Saga Rollback** e **Gate de Intervenção Humana** num único pipeline corporativo de compras e liquidação financeira:

### Expressão na DSL

```text
RequisitarServidores
  :--: [AuditarComplianceFiscal, VerificarEstoqueFisico]
  :--: DebitarContaBancaria !-> CancelarReservaOrcamento
  :--: [?AutorizacaoDiretorFinanceiro]
  :--: EmitirNotaFiscal
  :--: DespacharLogisticaWMS

```

### Topologia Completa do Grafo

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

### Explicação Passo a Passo da Semântica

1. **Início e Bifurcação Paralela (Fork)**:
* `RequisitarServidores` inicia o pipeline processando o pedido de compra (ex: 10 servidores para o datacenter).
* Ao concluir, o motor abre um bloco concorrente `[...]`.
* Em paralelo, o agente `AuditarComplianceFiscal` verifica se o fornecedor tem NIF comunitário regular e o agente `VerificarEstoqueFisico` consulta a disponibilidade de espaço na doca do armazém.


2. **Barreira de Sincronização (Join)**:
* O nó `DebitarContaBancaria` atua como barreira de junção. Ele só é acionado quando **ambas** as verificações paralelas terminarem com sucesso.


3. **Padrão Transacional Saga com Rollback**:
* `DebitarContaBancaria` tenta cativar o montante de $78.500,00\text{ EUR}$ junto do core banking.
* **Cenário de Sucesso**: O débito é efetuado e o fluxo avança via `:--:`.
* **Cenário de Falha**: Se a conta não tiver fundos ou o banco recusar, o operador `!->` desvia imediatamente a execução para `CancelarReservaOrcamento`. A ordem de compra é cancelada, os recursos do armazém são liberados e o fluxo é abortado antes de incomodar a diretoria.


4. **Governança Humana (HITL Gate)**:
* Uma vez debitado o valor, a transação atinge o gate `[?AutorizacaoDiretorFinanceiro]`, pois compras acima de $50.000,00\text{ EUR}$ exigem autorização formal.
* O pipeline pausa a execução, emite um documento **A2UI** para o painel administrativo e aguarda um token de assinatura criptográfica (Ed25519) do diretor.


5. **Finalização Sequencial**:
* Com a autorização concedida, o pipeline é reativado: `EmitirNotaFiscal` gera a fatura oficial com o imposto retido e encadeia para `DespacharLogisticaWMS`, que aciona as transportadoras para entrega física.



---

## 5. Compilação e Validação Estática em `comptime`

A string da DSL não é interpretada em tempo de execução. Ela passa pelo seguinte pipeline interno do compilador Zig:

```text
  DSL String ("A :--: B !-> C")
               │
               ▼
   [ comptime Tokenizer ]  ──► Gera array estático de tokens
               │
               ▼
     [ comptime Parser ]   ──► Constrói a ASTNode em memória estática
               │
               ▼
  [ comptime Graph Edge ]  ──► Mapeia Publishers, Subscribers e Barreiras
               │
               ▼
 [ TypeChecker (@typeInfo) ] ──► Inspeciona assinaturas fn(*Ctx, In) Out
               │
               ├─► [Incompatível] ──► Dispara @compileError pedagógico
               └─► [Válido]       ──► Gera grafo otimizado inline

```

### Exemplo de Erro de Compilação Pedagógico

Se um programador escrever uma conexão inválida na DSL, como tentar emitir a nota fiscal diretamente a partir da requisição bruta:

```zig
const dsl_invalida = "RequisitarServidores :--: EmitirNotaFiscal";

```

O compilador do Zig aborta imediatamente o comando `zig build` e apresenta a caixa de diagnóstico:

```text
  ┌── 🛑 FALHA DE CONTRATO DE TIPAGEM NO PIPELINE ────────────────────────────┐
  │                                                                            │
  │  A conexão declarada na sua DSL quebra as garantias de tipo estático:       │
  │    Fluxo Inválido : RequisitarServidores :--: EmitirNotaFiscal             │
  │                                                                            │
  ├────────────────────────────────────────────────────────────────────────────┤
  │  🔍 DIAGNÓSTICO:                                                           │
  │    1. O módulo 'RequisitarServidores' emite o tipo:                        │
  │       👉 [ RequisicaoCompraBruta ]                                         │
  │                                                                            │
  │    2. No entanto, o módulo 'EmitirNotaFiscal' espera consumir:             │
  │       📥 [ PagamentoConfirmado ]                                           │
  │                                                                            │
  ├────────────────────────────────────────────────────────────────────────────┤
  │  💡 DICA PEDAGÓGICA:                                                       │
  │    • Insira as etapas de validação e débito antes da emissão fiscal.       │
  └────────────────────────────────────────────────────────────────────────────┘


---

## 6. Guia Rápido de Referência Sintática

| Padrão Pretendido | Notação na DSL |
| :--- | :--- |
| Encadeamento linear simples | `A :--: B :--: C` |
| Passo com compensação em falha | `A :--: B !-> RollbackB :--: C` |
| Execução de 2 passos em paralelo | `A :--: [B, C] :--: D` |
| Ramo paralelo composto com sequência interna | `A :--: [B, C :--: D] :--: E` |
| Intervenção humana obrigatória | `A :--: [?AprovacaoGerente] :--: B` |
| Fluxo completo corporativo | `A :--: [B, C] :--: D !-> CompD :--: [?Gate] :--: E` |
```eof

### O que foi adicionado na especificação (`docs/DSL_SPECIFICATION.md`):

1. **Detalhamento Isolado com Diagramas e Exemplos de cada Operador**:
   - **Sequência Linear (`:--:`)**: Diagrama de dependência causal direta, regras de tipo e exemplo com requisição e fatura.

---

## ⚡ WebAssembly & 2FV (Two-Factor Validation)

O 2flow é nativamente compatível com **WebAssembly (`wasm32-freestanding`)**, viabilizando a técnica de **2FV (Two-Factor Validation)** na stack **AllasCode**:

- **Fator 1 (Client-Side Pre-Flight)**: O motor semântico roda no navegador do usuário (`2flow.wasm` de apenas **2.7 KB**), validando regras de negócio, dados e injeções em **< 0.05ms** antes de qualquer envio de rede. **Mais de 90% do processamento de invalidação de payloads é poupado no backend!**
- **Fator 2 (Server-Side Deterministic Proof)**: O cluster autoritativo executa a persistência com garantias de convergência e registro em ledger imutável.

Consulte a especificação completa em: **[docs/2FV-TWO-FACTOR-VALIDATION-WASM.md](file:///d:/www/Freelas/_____suissadev/Conceitos/AllasCode/Concepts/2flow/repo/docs/2FV-TWO-FACTOR-VALIDATION-WASM.md)**.

### Compilação via Makefile:
```bash
# Compila o módulo WebAssembly 2FV (ReleaseSmall)
make wasm

# Executa todos os testes unitários e de integração (WASM + Pipelines)
make test-all
```

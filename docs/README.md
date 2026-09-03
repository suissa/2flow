# 2flow

`2flow` is the flow notation used by AllasCode to describe causal graphs, distributed orchestration and the lower-level execution protocol that connects events to owned functions.

The notation has two complementary levels:

1. **Topological 2flow** — describes the graph: sequence, parallelism, failure/compensation routes and human gates.
2. **Execution 2flow** — describes what happens inside a topological node: which event enters, which function is invoked, which function is being called and which typed result leaves.

The low-level extension does not replace the original 2flow notation. It makes each node executable without moving orchestration logic into imperative code.

---

## 1. Topological 2flow

Topological 2flow answers:

> What must happen before what, what can happen concurrently, and where does execution go when the normal path cannot continue?

### `:--:` — causal sequence

```2flow
ValidatePurchase
  :--: RegisterStock
  :--: RegisterFinancialEntry
```

`B` may start only after the successful completion of `A`.

Conceptually:

```text
A :--: B
```

means:

```text
Ok<A> becomes the causal input that enables B.
```

An `Error<E>` does not advance through the normal `:--:` edge.

### `[...]` — parallel fork/join

```2flow
ReceivePurchase
  :--: [RegisterFinancialEntry, RegisterAccountingEntry]
  :--: ContinueLifecycle
```

The nodes inside the brackets may execute concurrently. The following node is enabled only after the fork reaches its declared join condition.

The bracket describes graph topology. It does not prescribe threads, processes, actors or machines. Those are runtime projection decisions.

### `!->` — failure, fallback or compensation edge

```2flow
ReserveStock !-> CancelReservation
  :--: CapturePayment
```

`!->` is an alternative graph edge activated when the source node cannot continue through its normal successful path.

It may represent:

- a Saga compensator;
- a fallback;
- a recovery action;
- a quarantine route;
- a human escalation node.

`!->` is **not** a third function result type. Functions still return only `Ok<T>` or `Error<E>`.

The relationship is:

```text
function
   ├─ Ok<T>    -> normal :--: edge
   └─ Error<E> -> !-> edge, when one is declared
```

If no `!->` edge exists, `Error<E>` is propagated to the owner/caller according to the surrounding contract.

### `[? ...]` — Human-in-the-Loop gate

```2flow
PreparePayment
  :--: [? ApprovePayment]
  :--: ExecutePayment
```

The graph pauses until external human evidence satisfies the gate contract.

A human gate does not introduce a third computational result. The operation that evaluates the supplied evidence still resolves as `Ok<T>` or `Error<E>`.

---

## 2. Execution 2flow

Topological notation is intentionally abstract. A node such as:

```2flow
StockAgent.DecreaseStock
```

says *what participates in the graph*, but not exactly how the Agent receives data or invokes its owned behavior.

Execution 2flow provides that lower-level description.

### `->` — event enters

```2flow
-> Ok<SaleResolved>
```

An event/result is delivered to the current Agent, Context or execution scope.

Direction is read from the scope's point of view: the arrow points **into** the scope.

### `<-` — event leaves

```2flow
<- Ok<StockExitCommitted>
```

An event/result is emitted by the current scope.

The arrow points **out of** the scope.

### `->>` — invoke owned function

```2flow
->> DecreaseStock
```

The current Agent/owner invokes a function, Action or AtomicBehavior that belongs to its own context.

It expresses delegation from the orchestration boundary toward the executable behavior.

### `<<-` — function is being invoked

```2flow
<<- DecreaseStock
```

The function/Action/AtomicBehavior receives the invocation from its owner.

`->>` and `<<-` are the two perspectives of the same call boundary:

```text
Owner ->> Function
Owner <<- Function
```

The first describes the call leaving the owner. The second makes the receiving side explicit in the executable graph.

---

## 3. Why two levels exist

A single flow has two different semantic questions.

### Topology

```2flow
FinancialAgent.DetectNewSale
  :--: SalesAgent.ResolveSaleProducts
  :--: StockAgent.DecreaseStock
  :--: SalesAgent.CloseSale
```

This is understandable as a business/process graph. It does not expose implementation mechanics.

### Execution

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

This is sufficiently precise for a runtime/compiler to wire an incoming event to an owned function and route its result.

Together:

```text
Topological 2flow
      ↓
semantic graph
      ↓
Execution 2flow
      ↓
event/function wiring
      ↓
runtime projection
```

The topological graph must remain valid even if the runtime projection changes from in-memory calls to Actors, NATS, QUIC, processes or distributed services.

---

## 4. Typed result law

Every executable function has only two result families:

```text
Ok<T>
Error<E>
```

Therefore:

```text
execute : Input -> Ok<Output> | Error<Failure>
```

Domain facts such as `SaleDetected`, `StockExitCommitted` or `PurchaseRegistered` are payload types carried by `Ok<T>`.

Failures such as `SaleDetectionError` or `StockEntryError` are payload types carried by `Error<E>`.

There is no third implicit state such as `null`, `undefined`, exception-as-control-flow or an untyped failure channel.

---

## 5. Self-healing and normalization

Semantic AtomicBehaviors are born with the AllasCode self-healing pipeline.

Normalization is not a general execution stage. It may exist only inside:

```text
validate
self-healing
```

Invariant:

```text
Normalization ⊂ Validate ∪ SelfHealing
```

and:

```text
Normalization ∉ DomainBehavior
```

A final `Error<E>` means the executable behavior could not satisfy its contract after the healing strategies allowed by its specification were exhausted or required external/human evidence.

A Human-in-the-Healing-Loop condition remains represented inside `Error<E>` and can activate a topological `[? ...]` or `!->` route.

---

## 6. Combined example

```2flow
flow PurchaseProducts

# High-level graph
ProcurementAgent.RegisterPurchase
  :--: StockAgent.IncreaseStock
  :--: FinancialAgent.RegisterFinancialEntry

# Low-level executable wiring
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

The first section defines the causal graph. The `execution` sections define how the compiler/runtime must realize each node.

---

## 7. Failure routing example

```2flow
ReserveStock !-> ReleaseReservation
  :--: CapturePayment
```

Low-level view:

```2flow
execution SalesAgent.ReserveStock
  -> SaleRequested
  ->> ReserveStock
  <<- ReserveStock

  Ok<StockReserved>
    <- Ok<StockReserved>

  Error<StockReservationError>
    <- Error<StockReservationError>
```

When `Error<StockReservationError>` is emitted, the topological `!-> ReleaseReservation` edge determines the next semantic node.

This preserves separation of concerns:

```text
function result = Ok | Error
flow decision   = topology
```

---

## 8. Parallel execution example

```2flow
StockAgent.ReceivePurchase
  :--: [FinancialAgent.RegisterPayable, AccountingAgent.RegisterEntry]
  :--: PurchaseAgent.CompletePurchase
```

Each parallel node has an independent execution declaration:

```2flow
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

The runtime may project these nodes into native threads, Actors, services or distributed workers. `[...]` specifies concurrency semantics, not the physical concurrency mechanism.

---

## 9. Agent knowledge boundary

An Agent does not call functions owned by another Agent directly.

Invalid coupling:

```2flow
FinancialAgent
  ->> StockAgent.DecreaseStock
```

Correct choreography:

```2flow
FinancialAgent
  <- Ok<SaleDetected>

SalesAgent
  -> Ok<SaleDetected>
  ->> ResolveSaleProducts
```

Only the Agent boundary knows the event that leaves its context and the events it accepts from outside. Lower-level Actions and AtomicBehaviors remain unaware of foreign contexts.

---

## 10. Semantic reading of the symbols

The direction of every arrow is relative to the node being described:

```text
->    knowledge/event enters this scope
<-    knowledge/event leaves this scope
->>   this scope calls inward to an owned behavior
<<-   the owned behavior receives/is called by its owner
```

This gives the language a symmetric reading:

```text
->   / <-
->>  / <<-
```

The opposite symbol expresses the opposite direction of the same relation.

---

## 11. Compilation model

A compiler/runtime can lower the combined notation into a graph containing at least:

```text
Flow
├── Topology
│   ├── sequence edges
│   ├── parallel fork/join edges
│   ├── failure/compensation edges
│   └── human gates
│
└── Execution
    ├── event ingress
    ├── function invocation
    ├── function receiver
    ├── Ok egress
    └── Error egress
```

A useful intermediate representation is:

```text
Node
├── semantic_identity
├── owner
├── accepts[]
├── invokes[]
├── emits_ok[]
├── emits_error[]
└── topology_edges[]
```

This allows the same `.2flow` source to be projected to multiple runtimes while preserving the semantic graph.

---

## 12. Core invariants

```text
1. :--: only advances through a successful causal result.
2. !-> is a graph edge, not a third function result.
3. Every executable function resolves to Ok<T> or Error<E>.
4. -> and <- transport events across a semantic boundary.
5. ->> and <<- describe invocation across an ownership boundary.
6. An Agent may invoke only behaviors it owns.
7. Cross-context communication occurs through Agent event boundaries.
8. [...] declares concurrency semantics independently of runtime technology.
9. [? ...] represents external human evidence, not a new result algebra.
10. Normalization exists only in validate or self-healing.
```

These invariants make 2flow both a human-readable graph notation and a lower-level executable orchestration language without collapsing domain topology into implementation code.

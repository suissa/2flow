# 🚀 Exemplos Práticos de 2flow (Zig 0.16)

Coleção de pipelines e fluxos orquestrados utilizando a notação declarativa **2flow**, compilados em tempo de compilação (**Comptime**) e com suporte a concorrência multi-thread e Sagas em Zig 0.16:

---

## 📂 Exemplos Disponíveis

### 1. [Modern Data Pipeline](data-pipeline/README.md)
Pipeline clássico de engenharia e telemetria de dados:
- **Fluxo:** Ingestão de Payload Bruto ➡️ Sanitização & Proteção de Injeções ➡️ `[Extração de Entidades, Anonimização LGPD/GDPR, Análise de Sentimento]` (Concorrente) ➡️ Enriquecimento de Negócio ➡️ Exportação de JSON Tipado.
- **Destaques:** Fork-join concorrente em threads nativas, fallback de quarentena via `!->`.

### 2. [Micro-Empresa Agêntica](empresa-agentica/README.md)
Ciclo operacional de ponta a ponta de uma empresa moderna:
- **Fluxo:** Fornecedor ➡️ Estoque ➡️ `[Financeiro (Contas a Pagar), Contábil (Partidas Dobradas & Crédito ICMS)]` (Concorrente) ➡️ Marketing (Markup & UTM) ➡️ Vendas (Faturamento & Baixa) ➡️ Cliente (Despacho & Rentabilidade).
- **Destaques:** Apuração da margem líquida, conformidade fiscal, estornos e compensadores Saga via `!->`.

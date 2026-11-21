# Registro de experimentos de performance

| # | Mudança | Hipótese | Req/s (antes → depois) | p95 (antes → depois) | CPU Banco | Pasta resultados | Conclusão |
|---|---|---|---|---|---|---|---|
| 00 | Linha de base | Estado original da aplicação | 2.86 req/s | 21.403 ms | 98.6% | `resultados/*-00-linha-de-base` | Banco no gargalo de CPU (98%), vazão baixa e latência crítica em relatórios e pedidos. |
| 01 | Pool de conexões (`pg.Pool`) | Reutilizar conexões elimina overhead de TCP e handshake a cada query | 2.86 → 3.59 req/s (+25.5%) | 21.403 → 17.399 ms (-18.7%) | 97.4% | `resultados/*-01-pool-conexoes` | **Ganho comprovado:** +25% de vazão e rotas simples ficaram ~68% mais rápidas. O gargalo agora são as buscas sem índice no banco. |
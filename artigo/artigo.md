# Da saturação de CPU a 23 req/s: otimização de uma API de e-commerce sob restrição severa de recursos

## 1. Resumo
Uma API de e-commerce em Node.js e PostgreSQL 16 sofria de severo estrangulamento sob carga, apresentando vazão de apenas 2,86 req/s, latência p95 de 21,4 segundos e 98,6% de CPU no banco, operando sob limites de 1 CPU e 512 MB (banco) e 0,5 CPU e 256 MB (API). Mediante cinco intervenções empíricas — pool de conexões persistente, índices B-Tree e GIN, eliminação de N+1, agregação SQL nativa e calibração de concorrência no PostgreSQL —, a vazão multiplicou por oito (22,93 req/s, +701,7%), o p95 caiu 93,1% (1.483 ms) e o uso de memória da API reduziu pela metade, mantendo o contrato intacto sem novos custos.

## 2. Contexto e diagnóstico
A aplicação atende sete rotas de leitura sobre uma base sintética de 100 mil clientes, 20 mil produtos, 500 mil pedidos e 1,5 milhão de itens. Na linha de base (`resultados/*-00-linha-de-base`), a rota `GET /clientes/:id/pedidos` registrou mediana de 18,3s e p95 de 23,6s. Relatórios e listagens oscilaram entre 11s e 24s. O banco permaneceu saturado em 98,6% de CPU, enquanto a API ficou em 10%, evidenciando gargalo estrito na camada de dados e de transporte.

A inspeção do código revelou causas claras:
1. `api/src/db.js` abria conexões `new Client()` a cada consulta, gerando handshakes TCP e forks repetidos.
2. `banco/01-estrutura.sql` não possuía índices nas chaves estrangeiras, forçando *Sequential Scans* em centenas de milhares de linhas.
3. A rota de pedidos executava loops aninhados no Node.js, disparando mais de 50 queries sequenciais por requisição.
4. O relatório de vendas transferia milhares de tuplas para o Node.js agregar em memória com `Map` e `Set`.
5. O PostgreSQL mantinha custo para discos mecânicos (`random_page_cost=4.0`) e disparava 2 workers disputando 1 CPU.

Hipóteses de causa:
* Conexões avulsas sobrecarregam o PostgreSQL com handshakes repetidos.
* A ausência de índices nas chaves estrangeiras gera varreduras completas em disco.
* O padrão N+1 multiplica a latência de rede pelos itens de cada pedido.
* Agregações no Node.js sobrecarregam memória e banda da API.
* Paralelismo intra-query em 1 CPU causa sobrecarga por troca de contexto (*CPU thrashing*).

## 3. Estado da arte

### Gerenciamento de conexões e sessões
Hellerstein et al. (2007) ressaltam que o modelo multiprocesso do PostgreSQL aloca estruturas pesadas para cada conexão. Stonebraker (1986) já apontava o custo de processos no Postgres original. Conforme o Node-Postgres (2024), manter um pool reutilizável (`pg.Pool`) é indispensável para evitar esgotamento de sockets e eliminar a latência de handshake sob carga.

### Estruturas de indexação e busca textual
Winand (2012) e a documentação do PostgreSQL (2024a) pontuam que chaves estrangeiras não geram índices automáticos, elevando o custo de junções de $O(\log N)$ para $O(N)$. Para buscas parciais com curingas (`ILIKE '%termo%'`), árvores B são ineficazes, exigindo índices invertidos GIN com `pg_trgm`, que particionam strings em trigramas e viabilizam busca rápida sem varredura completa (PostgreSQL, 2024b).

### Padrão de acesso a dados e teoria das restrições
O problema N+1 é classificado por Fowler (2002) como um anti-padrão no qual a latência total soma dezenas de idas e voltas na rede. Consolidar buscas em um único `JOIN` reduz o transporte ao mínimo. A Teoria das Restrições (Goldratt, 1984) adverte que aliviar um gargalo desloca a carga para o próximo elo fraco, exigindo análise holística da aplicação.

### Calibração do otimizador e concorrência
Em ambientes modernos sobre SSD, o acesso randômico aos blocos aproxima-se do custo sequencial. Reduzir `random_page_cost` de 4.0 para 1.1 instrui o planejador a preferir caminhos indexados (Kleppmann, 2017). Similarmente, em containers confinados a 1 CPU, desativar workers paralelos (`max_parallel_workers_per_gather=0`) evita que threads disputem o mesmo núcleo, maximizando a vazão de transações (PostgreSQL, 2024c).

## 4. Alternativas consideradas

Quatro abordagens foram avaliadas para mitigar o gargalo:

| Alternativa | Custo | Desempenho | Risco | Esforço |
|---|---|---|---|---|
| **A: Otimização in-engine (índices, queries, pool e tuning)** | Nulo | Alto (+700% vazão, -93% p95) | Muito Baixo | Médio |
| **B: Camada de cache em memória (Redis)** | Médio | Altíssimo em relatórios | Médio (invalidação) | Médio |
| **C: Réplica de leitura (Streaming Replication)** | Alto | Médio (isola relatórios) | Baixo | Alto |
| **D: Paginação por cursor (keyset pagination)** | Nulo | Alto em páginas profundas | Alto (quebra contrato) | Baixo |

A **Alternativa A** ataca a raiz sem custos de nuvem, respeitando os 512 MB de RAM e 1 CPU. A **Alternativa B** traria ganho veloz aos relatórios, mas consumiria memória escassa e acrescentaria complexidade de invalidação. A **Alternativa C** duplicaria o custo de infraestrutura prematuramente. A **Alternativa D** violaria o contrato público estipulado pelo desafio.

## 5. Solução escolhida e por quê
Adotou-se a **Alternativa A**, dividida em cinco passos complementares. A premissa central é que adicionar infraestrutura ou cache sobre código ineficiente apenas mascara falhas de arquitetura.

A implementação seguiu uma ordem racional:
1. Reuso de conexões via `pg.Pool` em `api/src/db.js`.
2. Criação de índices estratégicos em chaves estrangeiras, status e trigram GIN em `banco/03-indices.sql`.
3. Eliminação do N+1 em `GET /clientes/:id/pedidos` mediante consulta única com `LEFT JOIN` e agrupamento em memória.
4. Transferência do cálculo de vendas para o motor SQL com `GROUP BY`.
5. Calibração de `random_page_cost=1.1`, `work_mem=16MB` e desativação de workers paralelos em 1 CPU no `docker-compose.yml`.

As outras opções foram postergadas por encarecerem a solução ou infringirem o contrato.

## 6. Experimento e resultado

Cada ciclo foi medido três vezes com k6 (20 usuários virtuais por 60s), calculando-se as medianas oficiais:

| Mudança | Hipótese | p95 antes → depois | req/s antes → depois | CPU/memória | Pastas de resultados | Conclusão |
|---|---|---|---|---|---|---|
| **00: Linha de base** | Comportamento original da aplicação | 21.403 ms | 2,86 req/s | Banco: 98,6% / 385 MB<br>API: 10,1% / 32 MB | `resultados/*-00-linha-de-base` | Saturação de CPU no banco por varreduras sequenciais e conexões avulsas. |
| **01: Pool de conexões** | `pg.Pool` elimina handshakes repetidos | 21.403 → 17.399 ms (-18,7%) | 2,86 → 3,59 req/s (+25,5%) | Banco: 97,4% / 402 MB<br>API: 8,0% / 37 MB | `resultados/*-01-pool-conexoes` | Rota de cliente acelerou 68%. Tempo geral caiu 4s pela eliminação de handshakes. |
| **02: Índices no banco** | Índices em FKs, status e trigram evitam Seq Scan | 17.399 → 5.721 ms (-67,1%) | 3,59 → 17,70 req/s (+393,0%) | Banco: 94,8% / 414 MB<br>API: 29,6% / 56 MB | `resultados/*-02-indices-banco` | **Maior salto:** Vazão subiu 6x vs base. Pedidos do cliente caiu de 23,6s para 1,8s (-92,3%). |
| **03: Eliminação de N+1** | Query em JOIN substitui dezenas de chamadas | 5.721 → 6.915 ms (+20,8% geral) | 17,70 → 18,10 req/s (+2,3%) | Banco: 97,2% / 411 MB<br>API: 26,8% / 43 MB | `resultados/*-03-sem-nplusone` | Rota de pedidos caiu para 741 ms (-59,1%). Deslocamento de pressão para relatórios. |
| **04: Agregação SQL nativa** | Somar no banco reduz tráfego e CPU na API | 6.915 → 7.166 ms (+3,6% geral) | 18,10 → 20,03 req/s (+10,7%) | Banco: 98,7% / 416 MB<br>API: 4,5% / 25 MB | `resultados/*-04-agregacao-vendas` | **Aplicação mais barata:** Mediana geral caiu para 95 ms. RAM da API caiu 55% e CPU para 4,5%. |
| **05: Tuning do PostgreSQL** | Parâmetros de SSD e desligamento de workers evitam thrashing | 7.166 → 1.483 ms (-79,3%) | 20,03 → 22,93 req/s (+14,5%) | Banco: 98,0% / 421 MB<br>API: 4,0% / 25 MB | `resultados/*-05-tuning-postgres` | **Derrubada do p95:** Queda acumulada de 93,1% no p95 (1,48s) e recorde de 22,9 req/s (8x vs base). |

A aplicação evoluiu de um estado degradado (21,4s de p95) para uma operação resiliente (1,48s no pior caso e mediana de 98 ms), utilizando apenas 25 MB de memória na API.

## 7. Limites e testes futuros
Apesar dos ganhos expressivos, subsistem limitações no modelo atual:
1. **Agregação dinâmica em top produtos:** A rota `GET /relatorios/top-produtos` ainda percorre 1,5 milhão de itens dinamicamente, mantendo o banco ocupado sob carga severa. Conforme documentado no [proximos-testes.md](../proximos-testes.md), Visões Materializadas com refresh concorrente ou cache em Redis representam a próxima fronteira evolutiva.
2. **Escalabilidade de paginação:** O uso de `LIMIT/OFFSET` em pedidos perde eficiência em offsets elevados. A transição para paginação baseada em cursor resolverá esse gargalo na versão v2 da API.
3. **Cenários que refutariam a conclusão:** Em cenários com taxa massiva de escritas concorrentes, o custo de atualização dos múltiplos índices B-Tree e GIN pode penalizar a ingestão de dados, exigindo particionamento temporal de tabelas.

## 8. Referências
1. Fowler, M. (2002). *Patterns of Enterprise Application Architecture*. Addison-Wesley Professional.
2. Goldratt, E. M. (1984). *The Goal: A Process of Ongoing Improvement*. North River Press.
3. Hellerstein, J. M., Stonebraker, M., & Hamilton, J. (2007). *Architecture of a Database System*. Foundations and Trends in Databases, 1(2), 141-259. [Link](https://dl.acm.org/doi/10.1561/1900000002).
4. Kleppmann, M. (2017). *Designing Data-Intensive Applications: The Big Ideas Behind Reliable, Scalable, and Maintainable Systems*. O'Reilly Media.
5. Node-Postgres Team. (2024). *Pool - node-postgres Documentation*. Acessado em 20 de novembro de 2026. [Link](https://node-postgres.com/apis/pool).
6. PostgreSQL Global Development Group. (2024a). *Indexes: B-tree and Query Planning*. PostgreSQL 16 Documentation. Acessado em 20 de novembro de 2026. [Link](https://www.postgresql.org/docs/16/indexes.html).
7. PostgreSQL Global Development Group. (2024b). *pg_trgm — text search using trigram matching*. PostgreSQL 16 Documentation. Acessado em 20 de novembro de 2026. [Link](https://www.postgresql.org/docs/16/pgtrgm.html).
8. PostgreSQL Global Development Group. (2024c). *Resource Consumption and Asynchronous Behavior*. PostgreSQL 16 Documentation. Acessado em 20 de novembro de 2026. [Link](https://www.postgresql.org/docs/16/runtime-config-resource.html).
9. Stonebraker, M. (1986). *The design of the POSTGRES storage system*. In Proceedings of the 13th International Conference on Very Large Data Bases (VLDB), 289-300.
10. Winand, M. (2012). *Use The Index, Luke! A Guide to Database Performance for Developers*. [Link](https://use-the-index-luke.com/).

## 9. Uso de IA
Ferramentas de IA generativa foram empregadas como copiloto técnico para compilação e cálculo de medianas a partir dos relatórios em `resultados/`, além de auxílio na formulação de hipóteses técnicas e estruturação do template markdown. Todas as alterações em SQL, JavaScript e Compose foram validadas via `verificar-contrato.sh` e mensuradas em execuções repetidas do `medir.sh`.

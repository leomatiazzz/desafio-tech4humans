# Fichas de Ideias de Performance — Testes Futuros

Este documento registra abordagens e otimizações arquiteturais pesquisadas na literatura e práticas de mercado que foram catalogadas para evolução futura da aplicação, conforme as diretrizes do desafio.

---

## Ficha 01: Cache em Memória com Redis para Relatórios Analíticos

* **Status:** Pesquisada, teste futuro.
* **Origem e referência:** 
  * [Redis Documentation: Cache-Aside Pattern](https://redis.io/docs/latest/develop/use/patterns/cache-aside/)
  * *Designing Data-Intensive Applications* (Martin Kleppmann, 2017) — Capítulo sobre Caching e Sistemas Derivados.
* **O que ganharia:**
  * Redução drástica da latência na rota `GET /relatorios/top-produtos` (atualmente a mais pesada do sistema, exigindo varredura de 1,5 milhão de itens), passando de ~25 segundos para menos de 5 milissegundos nas requisições em cache.
  * Alívio quase total de CPU do PostgreSQL durante picos de consultas analíticas.
* **Como testaria:**
  1. Adicionar o container `redis:7-alpine` ao `docker-compose.yml` com limite de 64 MB de memória.
  2. Implementar na API o padrão *Cache-Aside*: antes de rodar a query no banco, verificar a chave `cache:relatorios:top-produtos:<limite>`. Se existir (*cache hit*), responder imediatamente; se não (*cache miss*), consultar o PostgreSQL e gravar no Redis com TTL de 60 a 300 segundos.
  3. Executar o `scripts/medir.sh` e comparar a vazão geral e latência de p95.
* **O que precisaria para testar:**
  * Adicionar dependência do cliente Redis (`ioredis`) no `package.json` da API.
  * Alocar memória adicional no Compose para o Redis, justificando a relação custo-benefício financeiro.
* **Por que não foi testada agora:**
  * O desafio impôs limites severos de recursos (512 MB de RAM para o banco e 256 MB para a API). A prioridade metodológica foi esgotar otimizações de *custo zero* (índices, queries e parâmetros) antes de introduzir novos componentes de infraestrutura que encareceriam o custo operacional.

---

## Ficha 02: Paginação Baseada em Cursor (Keyset Pagination) em vez de OFFSET

* **Status:** Pesquisada, teste futuro.
* **Origem e referência:**
  * [Use The Index, Luke! — Markus Winand: Paginating Large Result Sets](https://use-the-index-luke.com/no-offset)
  * [PostgreSQL Documentation: Index-Only Scans and Keyset Pagination](https://www.postgresql.org/docs/current/indexes-index-only-scans.html)
* **O que ganharia:**
  * Desempenho constante $O(1)$ na rota `GET /pedidos?status=&pagina=`. Na implementação atual com `LIMIT 20 OFFSET X`, páginas avançadas (como `pagina=15000`) forçam o banco a percorrer e descartar 300.000 linhas de índice antes de devolver 20 registros, elevando o tempo de execução.
* **Como testaria:**
  1. Alterar a query de busca paginada para filtrar com base na tupla do último item recebido:
     `WHERE status = $1 AND (criado_em, id) < ($2, $3) ORDER BY criado_em DESC, id DESC LIMIT 20`.
  2. Submeter carga com requisições simulando navegação profunda no k6 e medir se a latência permanece estável mesmo em offsets equivalentes a milhões de linhas.
* **O que precisaria para testar:**
  * Modificação do contrato de entrada e saída da rota da API (passando a aceitar parâmetros de cursor como `cursor` ou `ultimo_id` em vez de `pagina`).
* **Por que não foi testada agora:**
  * A regra expressa da Seção 07 do desafio proíbe terminantemente alterar o que as rotas recebem e devolvem (quebraria a validação do `scripts/verificar-contrato.sh`). Fica como proposta de evolução de versão da API (v2).

---

## Ficha 03: Visão Materializada Incremental (Materialized View) para Top Produtos

* **Status:** Pesquisada, teste futuro.
* **Origem e referência:**
  * [PostgreSQL Documentation: Materialized Views](https://www.postgresql.org/docs/16/rules-materializedviews.html)
  * ACM Queue — *Data on the Outside vs. Data on the Inside* (Pat Helland).
* **O que ganharia:**
  * Pré-computação das métricas agregadas de faturamento e unidades por produto (`sum(quantidade)`, `sum(quantidade * preco_unitario)`), eliminando o `JOIN` de 3 tabelas e 1,5 milhão de linhas a cada requisição HTTP.
  * Consulta executada em tempo inferior a 15 ms direto de uma tabela derivada compacta de apenas 20.000 linhas.
* **Como testaria:**
  1. Criar o script `banco/04-materialized-view.sql` com:
     `CREATE MATERIALIZED VIEW mv_top_produtos AS ...` com índice em `receita_centavos DESC`.
  2. Ajustar a rota `/relatorios/top-produtos` para consultar diretamente a view.
  3. Configurar job periódico com `REFRESH MATERIALIZED VIEW CONCURRENTLY mv_top_produtos`.
* **O que precisaria para testar:**
  * Definir a janela de tolerância a dados desatualizados (*eventual consistency*) aceitável para o negócio da loja.
* **Por que não foi testada agora:**
  * Em testes de carga curtos com dados transacionais dinâmicos, o refresh da view concorreria por I/O no banco, demandando um mecanismo agendado de concorrência que foge do escopo do teste unitário de 60 segundos.

---

## Ficha 04: Réplica de Leitura (Read Replica) Dedicada para Relatórios

* **Status:** Pesquisada, teste futuro.
* **Origem e referência:**
  * [PostgreSQL Documentation: Streaming Replication](https://www.postgresql.org/docs/16/warm-standby.html#STREAMING-REPLICATION)
  * [Martin Fowler: Command Query Responsibility Segregation (CQRS)](https://martinfowler.com/bliki/CQRS.html)
* **O que ganharia:**
  * Isolamento completo de recursos: relatórios gerenciais longos e pesados não concorreriam pela CPU (1 núcleo) nem pelas conexões do pool com os clientes que estão buscando produtos e finalizando pedidos.
* **Como testaria:**
  1. Configurar um segundo container PostgreSQL no `docker-compose.yml` atuando como standby em streaming replication do container primário.
  2. Criar um segundo pool de conexões na API direcionado exclusivamente para a réplica e apontar as rotas `/relatorios/*` para ele.
  3. Medir a latência das rotas de clientes sob estresse simultâneo com relatórios.
* **O que precisaria para testar:**
  * Alocação de hardware adicional (mais 1 CPU e 512 MB de RAM para o container réplica), aumentando o custo de nuvem.
* **Por que não foi testada agora:**
  * O desafio busca a solução mais barata e eficiente com os limites estipulados de 1 CPU e 512 MB para o banco atual.
-- Extensão para acelerar busca textual parcial com ILIKE '%...%'
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Índice para busca de clientes por e-mail (case-insensitive)
CREATE INDEX idx_clientes_lower_email ON clientes (lower(email));

-- Índice para pedidos por cliente (usado na rota pedidos-do-cliente)
CREATE INDEX idx_pedidos_cliente_id ON pedidos (cliente_id, criado_em DESC, id DESC);

-- Índice composto para paginação de pedidos por status
CREATE INDEX idx_pedidos_status_criado_em ON pedidos (status, criado_em DESC, id DESC);

-- Índices nas chaves estrangeiras de itens_pedido (usados em pedidos do cliente e relatórios)
CREATE INDEX idx_itens_pedido_pedido_id ON itens_pedido (pedido_id);
CREATE INDEX idx_itens_pedido_produto_id ON itens_pedido (produto_id);

-- Índice trigram para busca rápida de produtos por nome
CREATE INDEX idx_produtos_nome_trgm ON produtos USING gin (nome gin_trgm_ops);

-- Índice para filtro de data nos relatórios de vendas
CREATE INDEX idx_pedidos_criado_em_data ON pedidos ((criado_em::date)) WHERE status <> 'cancelado';
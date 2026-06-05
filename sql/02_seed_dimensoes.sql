-- ============================================================================
--  PROJETO ZIKA BR — 02_seed_dimensoes.sql
--  Popula as dimensões com os códigos oficiais do SINAN e do IBGE.
-- ============================================================================
SET search_path TO zika, public;

-- ---------------------------------------------------------------------------
-- 1. UFs do IBGE
-- ---------------------------------------------------------------------------
INSERT INTO dim_uf (cod_uf, sigla, nome, regiao) VALUES
    (11,'RO','Rondônia','Norte'),
    (12,'AC','Acre','Norte'),
    (13,'AM','Amazonas','Norte'),
    (14,'RR','Roraima','Norte'),
    (15,'PA','Pará','Norte'),
    (16,'AP','Amapá','Norte'),
    (17,'TO','Tocantins','Norte'),
    (21,'MA','Maranhão','Nordeste'),
    (22,'PI','Piauí','Nordeste'),
    (23,'CE','Ceará','Nordeste'),
    (24,'RN','Rio Grande do Norte','Nordeste'),
    (25,'PB','Paraíba','Nordeste'),
    (26,'PE','Pernambuco','Nordeste'),
    (27,'AL','Alagoas','Nordeste'),
    (28,'SE','Sergipe','Nordeste'),
    (29,'BA','Bahia','Nordeste'),
    (31,'MG','Minas Gerais','Sudeste'),
    (32,'ES','Espírito Santo','Sudeste'),
    (33,'RJ','Rio de Janeiro','Sudeste'),
    (35,'SP','São Paulo','Sudeste'),
    (41,'PR','Paraná','Sul'),
    (42,'SC','Santa Catarina','Sul'),
    (43,'RS','Rio Grande do Sul','Sul'),
    (50,'MS','Mato Grosso do Sul','Centro-Oeste'),
    (51,'MT','Mato Grosso','Centro-Oeste'),
    (52,'GO','Goiás','Centro-Oeste'),
    (53,'DF','Distrito Federal','Centro-Oeste')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. Sexo
-- ---------------------------------------------------------------------------
INSERT INTO dim_sexo (cod, descricao) VALUES
    ('M','Masculino'),
    ('F','Feminino'),
    ('I','Ignorado')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. Raça/cor (IBGE)
-- ---------------------------------------------------------------------------
INSERT INTO dim_raca (cod, descricao) VALUES
    (1,'Branca'),
    (2,'Preta'),
    (3,'Amarela'),
    (4,'Parda'),
    (5,'Indígena'),
    (9,'Ignorado')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4. Escolaridade
-- ---------------------------------------------------------------------------
INSERT INTO dim_escolaridade (cod, descricao) VALUES
    (0,'Analfabeto'),
    (1,'1ª a 4ª série incompleta do EF'),
    (2,'4ª série completa do EF'),
    (3,'5ª a 8ª série incompleta do EF'),
    (4,'Ensino Fundamental completo'),
    (5,'Ensino Médio incompleto'),
    (6,'Ensino Médio completo'),
    (7,'Educação superior incompleta'),
    (8,'Educação superior completa'),
    (9,'Ignorado'),
    (10,'Não se aplica')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 5. Idade gestacional
-- ---------------------------------------------------------------------------
INSERT INTO dim_gestante (cod, descricao) VALUES
    (1,'1º trimestre'),
    (2,'2º trimestre'),
    (3,'3º trimestre'),
    (4,'Idade gestacional ignorada'),
    (5,'Não'),
    (6,'Não se aplica'),
    (9,'Ignorado')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 6. Classificação final
-- ---------------------------------------------------------------------------
INSERT INTO dim_classificacao (cod, descricao) VALUES
    (0,'Descartado'),
    (1,'Confirmado'),
    (2,'Em investigação'),
    (8,'Inconclusivo')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 7. Critério de confirmação
-- ---------------------------------------------------------------------------
INSERT INTO dim_criterio (cod, descricao) VALUES
    (0,'Em investigação'),
    (1,'Laboratorial'),
    (2,'Clínico-epidemiológico')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 8. Evolução
-- ---------------------------------------------------------------------------
INSERT INTO dim_evolucao (cod, descricao) VALUES
    (0,'Em investigação'),
    (1,'Cura'),
    (2,'Óbito pelo agravo'),
    (3,'Óbito por outra causa'),
    (9,'Ignorado')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 9. Autoctonia
-- ---------------------------------------------------------------------------
INSERT INTO dim_autoctonia (cod, descricao) VALUES
    (1,'Sim (autóctone)'),
    (2,'Não (importado)'),
    (3,'Indeterminado')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 10. Dim de municípios e unidades é populada pelo ETL Python, a partir
--     dos códigos efetivamente presentes no CSV (lookup automático).
-- ---------------------------------------------------------------------------

RESET search_path;

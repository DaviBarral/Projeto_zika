-- ============================================================================
--  PROJETO ZIKA BR — 05_views.sql
--  Views prontas para alimentar o dashboard (BI / Streamlit / Power BI).
-- ============================================================================
SET search_path TO zika, public;

-- ---------------------------------------------------------------------------
-- 5.1  vw_serie_semanal — curva epidêmica por semana epidemiológica (Brasil)
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_serie_semanal CASCADE;
CREATE VIEW vw_serie_semanal AS
SELECT
    f.nu_ano                                                AS ano,
    f.sem_sintomas                                          AS semana_epi,
    MIN(date_trunc('week', f.dt_sintomas)::DATE)            AS inicio_sem,
    COUNT(*)                                                AS casos_total,
    COUNT(*) FILTER (WHERE f.cod_classificacao = 1)         AS casos_confirmados,
    COUNT(*) FILTER (WHERE f.cod_classificacao = 0)         AS casos_descartados,
    COUNT(*) FILTER (WHERE f.cod_classificacao = 2)         AS casos_em_invest,
    COUNT(*) FILTER (WHERE f.cod_evolucao = 2)              AS obitos
FROM   fato_notificacao f
WHERE  f.dt_sintomas IS NOT NULL
  AND  f.sem_sintomas BETWEEN 1 AND 53
GROUP BY f.nu_ano, f.sem_sintomas
ORDER BY f.nu_ano, f.sem_sintomas;

COMMENT ON VIEW vw_serie_semanal IS
    'Série temporal semanal para curvas epidêmicas e identificação de surtos.';

-- ---------------------------------------------------------------------------
-- 5.2  vw_serie_semanal_uf — mesma série, mas estratificada por UF
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_serie_semanal_uf CASCADE;
CREATE VIEW vw_serie_semanal_uf AS
SELECT
    u.sigla                                                 AS uf,
    u.regiao                                                AS regiao,
    f.nu_ano                                                AS ano,
    f.sem_sintomas                                          AS semana_epi,
    MIN(date_trunc('week', f.dt_sintomas)::DATE)            AS inicio_sem,
    COUNT(*)                                                AS casos_total,
    COUNT(*) FILTER (WHERE f.cod_classificacao = 1)         AS casos_confirmados
FROM       fato_notificacao f
INNER JOIN dim_uf u ON u.cod_uf = f.cod_uf_resi
WHERE      f.dt_sintomas IS NOT NULL
  AND      f.sem_sintomas BETWEEN 1 AND 53
GROUP BY   u.sigla, u.regiao, f.nu_ano, f.sem_sintomas
ORDER BY   f.nu_ano, f.sem_sintomas, u.sigla;

-- ---------------------------------------------------------------------------
-- 5.3  vw_casos_uf_ano — ranking de UFs por ano (para mapa coroplético)
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_casos_uf_ano CASCADE;
CREATE VIEW vw_casos_uf_ano AS
SELECT
    u.cod_uf,
    u.sigla                                                 AS uf,
    u.nome                                                  AS uf_nome,
    u.regiao,
    f.nu_ano                                                AS ano,
    COUNT(*)                                                AS casos_total,
    COUNT(*) FILTER (WHERE f.cod_classificacao = 1)         AS casos_confirmados,
    COUNT(*) FILTER (WHERE f.cod_evolucao      = 2)         AS obitos,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE f.cod_classificacao = 1)
              / NULLIF(COUNT(*), 0)
    , 2)                                                    AS taxa_confirmacao_pct
FROM       fato_notificacao f
INNER JOIN dim_uf u ON u.cod_uf = f.cod_uf_resi
GROUP BY   u.cod_uf, u.sigla, u.nome, u.regiao, f.nu_ano
ORDER BY   ano, casos_confirmados DESC;

-- ---------------------------------------------------------------------------
-- 5.4  vw_piramide_etaria — pirâmide por sexo e faixa etária
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_piramide_etaria CASCADE;
CREATE VIEW vw_piramide_etaria AS
SELECT
    f.faixa_etaria,
    s.descricao                                             AS sexo,
    f.nu_ano                                                AS ano,
    COUNT(*) FILTER (WHERE f.cod_classificacao = 1)         AS casos_confirmados,
    COUNT(*)                                                AS casos_total
FROM       fato_notificacao f
LEFT JOIN  dim_sexo s ON s.cod = f.cod_sexo
WHERE      f.faixa_etaria IS NOT NULL
  AND      f.cod_sexo IN ('M','F')
GROUP BY   f.faixa_etaria, s.descricao, f.nu_ano
ORDER BY   f.nu_ano, f.faixa_etaria, s.descricao;

-- ---------------------------------------------------------------------------
-- 5.5  vw_gestantes — vigilância de gestantes (foco em Zika congênito)
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_gestantes CASCADE;
CREATE VIEW vw_gestantes AS
SELECT
    f.nu_ano                                                AS ano,
    u.sigla                                                 AS uf,
    g.descricao                                             AS trimestre,
    COUNT(*) FILTER (WHERE f.cod_classificacao = 1)         AS gestantes_confirmadas,
    COUNT(*)                                                AS gestantes_notificadas,
    ROUND(AVG(f.idade_anos)::NUMERIC, 1)                    AS idade_media,
    COUNT(*) FILTER (WHERE f.cod_evolucao = 2)              AS obitos
FROM       fato_notificacao f
LEFT JOIN  dim_uf       u ON u.cod_uf = f.cod_uf_resi
LEFT JOIN  dim_gestante g ON g.cod    = f.cod_gestante
WHERE      f.cod_gestante IN (1,2,3,4)
GROUP BY   f.nu_ano, u.sigla, g.descricao
ORDER BY   f.nu_ano, u.sigla, g.descricao;

COMMENT ON VIEW vw_gestantes IS
    'Notificações em gestantes — recorte epidemiologicamente crítico para Zika.';

-- ---------------------------------------------------------------------------
-- 5.6  vw_municipios_top — ranking de municípios mais afetados
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_municipios_top CASCADE;
CREATE VIEW vw_municipios_top AS
SELECT
    m.cod_municipio,
    m.nome                                                  AS municipio,
    u.sigla                                                 AS uf,
    f.nu_ano                                                AS ano,
    COUNT(*) FILTER (WHERE f.cod_classificacao = 1)         AS casos_confirmados,
    COUNT(*)                                                AS casos_total,
    COUNT(*) FILTER (WHERE f.cod_evolucao = 2)              AS obitos,
    COUNT(*) FILTER (WHERE f.cod_gestante IN (1,2,3,4))     AS gestantes
FROM       fato_notificacao f
INNER JOIN dim_municipio m ON m.cod_municipio = f.cod_mun_resi
INNER JOIN dim_uf        u ON u.cod_uf        = m.cod_uf
GROUP BY   m.cod_municipio, m.nome, u.sigla, f.nu_ano
ORDER BY   casos_confirmados DESC;

-- ---------------------------------------------------------------------------
-- 5.7  vw_perfil_demografico — corte por raça, escolaridade, sexo
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_perfil_demografico CASCADE;
CREATE VIEW vw_perfil_demografico AS
SELECT
    f.nu_ano                                                AS ano,
    s.descricao                                             AS sexo,
    r.descricao                                             AS raca_cor,
    e.descricao                                             AS escolaridade,
    COUNT(*) FILTER (WHERE f.cod_classificacao = 1)         AS confirmados,
    COUNT(*)                                                AS notificados
FROM       fato_notificacao f
LEFT JOIN  dim_sexo         s ON s.cod = f.cod_sexo
LEFT JOIN  dim_raca         r ON r.cod = f.cod_raca
LEFT JOIN  dim_escolaridade e ON e.cod = f.cod_escolaridade
GROUP BY   f.nu_ano, s.descricao, r.descricao, e.descricao
ORDER BY   f.nu_ano, confirmados DESC;

-- ---------------------------------------------------------------------------
-- 5.8  vw_kpis — cards de KPI globais (1 linha)
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_kpis CASCADE;
CREATE VIEW vw_kpis AS
SELECT
    COUNT(*)                                                       AS total_notificacoes,
    COUNT(*) FILTER (WHERE cod_classificacao = 1)                  AS total_confirmados,
    COUNT(*) FILTER (WHERE cod_classificacao = 0)                  AS total_descartados,
    COUNT(*) FILTER (WHERE cod_evolucao = 2)                       AS total_obitos,
    COUNT(*) FILTER (WHERE cod_gestante IN (1,2,3,4)
                     AND cod_classificacao = 1)                    AS gestantes_confirmadas,
    COUNT(DISTINCT cod_mun_resi)                                   AS municipios_afetados,
    COUNT(DISTINCT cod_uf_resi)                                    AS ufs_afetadas,
    ROUND(100.0 * COUNT(*) FILTER (WHERE cod_classificacao = 1)
                / NULLIF(COUNT(*), 0), 2)                          AS taxa_confirmacao_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE cod_evolucao = 2)
                / NULLIF(COUNT(*) FILTER (WHERE cod_classificacao = 1), 0), 2)
                                                                   AS letalidade_pct,
    MIN(dt_sintomas)                                               AS dt_inicio,
    MAX(dt_sintomas)                                               AS dt_fim
FROM   fato_notificacao;

COMMENT ON VIEW vw_kpis IS
    'KPIs globais — alimenta os cards no topo do dashboard.';

-- ---------------------------------------------------------------------------
-- 5.9  vw_latencia_notificacao — qualidade da vigilância
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_latencia_notificacao CASCADE;
CREATE VIEW vw_latencia_notificacao AS
SELECT
    f.nu_ano                                                       AS ano,
    u.sigla                                                        AS uf,
    COUNT(*)                                                       AS n,
    ROUND(AVG((f.dt_notificacao - f.dt_sintomas))::NUMERIC, 1)    AS latencia_media_dias,
    PERCENTILE_CONT(0.5)
        WITHIN GROUP (ORDER BY (f.dt_notificacao - f.dt_sintomas)) AS latencia_mediana
FROM       fato_notificacao f
LEFT JOIN  dim_uf u ON u.cod_uf = f.cod_uf_resi
WHERE      f.dt_sintomas    IS NOT NULL
  AND      f.dt_notificacao IS NOT NULL
  AND      (f.dt_notificacao - f.dt_sintomas) BETWEEN 0 AND 365
GROUP BY   f.nu_ano, u.sigla
ORDER BY   ano, latencia_media_dias DESC;

-- ---------------------------------------------------------------------------
-- 5.10  vw_completude — % de preenchimento dos campos críticos por ano
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_completude CASCADE;
CREATE VIEW vw_completude AS
SELECT
    nu_ano                                                                 AS ano,
    COUNT(*)                                                               AS total,
    ROUND(100.0*COUNT(cod_raca)         /NULLIF(COUNT(*),0), 1)            AS raca_pct,
    ROUND(100.0*COUNT(cod_escolaridade) /NULLIF(COUNT(*),0), 1)            AS escolaridade_pct,
    ROUND(100.0*COUNT(cod_gestante)     /NULLIF(COUNT(*),0), 1)            AS gestante_pct,
    ROUND(100.0*COUNT(idade_anos)       /NULLIF(COUNT(*),0), 1)            AS idade_pct,
    ROUND(100.0*COUNT(cod_uf_resi)      /NULLIF(COUNT(*),0), 1)            AS uf_resi_pct,
    ROUND(100.0*COUNT(cod_mun_resi)     /NULLIF(COUNT(*),0), 1)            AS mun_resi_pct,
    ROUND(100.0*COUNT(cod_evolucao)     /NULLIF(COUNT(*),0), 1)            AS evolucao_pct
FROM   fato_notificacao
GROUP BY nu_ano
ORDER BY nu_ano;

-- ---------------------------------------------------------------------------
-- 5.11  Versão materializada da série semanal (acelera dashboards)
-- ---------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS mv_serie_semanal_uf CASCADE;
CREATE MATERIALIZED VIEW mv_serie_semanal_uf AS
    SELECT * FROM vw_serie_semanal_uf
WITH DATA;

CREATE UNIQUE INDEX idx_mv_serie_semanal_uf
    ON mv_serie_semanal_uf(uf, ano, semana_epi);

COMMENT ON MATERIALIZED VIEW mv_serie_semanal_uf IS
    'Cache da série semanal por UF. Rodar REFRESH MATERIALIZED VIEW CONCURRENTLY após nova carga.';

RESET search_path;

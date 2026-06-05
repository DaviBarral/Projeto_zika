-- ============================================================================
--  PROJETO ZIKA BR — 03_funcoes.sql
--  Funções PL/pgSQL para operações recorrentes.
-- ============================================================================
SET search_path TO zika, public;

-- ---------------------------------------------------------------------------
-- 3.1  fn_decodifica_idade(nu_idade_n) → INTERVAL e idade em anos (NUMERIC)
--
--  O campo NU_IDADE_N do SINAN é composto:
--      1º dígito: unidade (1=hora, 2=dia, 3=mês, 4=ano)
--      demais   : quantidade
--  Exemplos:
--      4025 → 25 anos          → 25.0
--      3006 → 6 meses          → 0.50
--      2015 → 15 dias          → 0.041
--      1010 → 10 horas         → 0.0011
--
--  Retorna NULL para entradas inválidas / vazias.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION fn_decodifica_idade(p_codigo INTEGER)
RETURNS NUMERIC(6,3)
LANGUAGE plpgsql
SET search_path = zika, public
IMMUTABLE
AS $$
DECLARE
    v_unidade SMALLINT;
    v_qtd     INTEGER;
    v_anos    NUMERIC(6,3);
BEGIN
    IF p_codigo IS NULL OR p_codigo <= 0 THEN
        RETURN NULL;
    END IF;

    v_unidade := (p_codigo / 1000)::SMALLINT;     -- 1, 2, 3 ou 4
    v_qtd     := p_codigo - (v_unidade * 1000);

    v_anos := CASE v_unidade
        WHEN 4 THEN v_qtd::NUMERIC                       -- anos
        WHEN 3 THEN v_qtd::NUMERIC / 12.0                -- meses → anos
        WHEN 2 THEN v_qtd::NUMERIC / 365.25              -- dias  → anos
        WHEN 1 THEN v_qtd::NUMERIC / (365.25 * 24.0)     -- horas → anos
        ELSE NULL
    END;

    RETURN ROUND(v_anos, 3);
END;
$$;

COMMENT ON FUNCTION fn_decodifica_idade(INTEGER) IS
    'Converte o campo NU_IDADE_N do SINAN em idade decimal em anos.';

-- Função auxiliar — faixa etária para pirâmide
CREATE OR REPLACE FUNCTION fn_faixa_etaria(p_idade NUMERIC)
RETURNS VARCHAR(15)
LANGUAGE sql
SET search_path = zika, public
IMMUTABLE
AS $$
    SELECT CASE
        WHEN p_idade IS NULL          THEN 'Ignorada'
        WHEN p_idade <  1             THEN '<1 ano'
        WHEN p_idade <  5             THEN '1-4'
        WHEN p_idade <  10            THEN '5-9'
        WHEN p_idade <  15            THEN '10-14'
        WHEN p_idade <  20            THEN '15-19'
        WHEN p_idade <  30            THEN '20-29'
        WHEN p_idade <  40            THEN '30-39'
        WHEN p_idade <  50            THEN '40-49'
        WHEN p_idade <  60            THEN '50-59'
        WHEN p_idade <  70            THEN '60-69'
        WHEN p_idade <  80            THEN '70-79'
        ELSE '80+'
    END;
$$;

-- ---------------------------------------------------------------------------
-- 3.2  fn_resumo_epidemiologico(p_uf, p_ano)
--
--  Resumo agregado por UF/ano: notificações, confirmados, taxa de confirmação,
--  óbitos, gestantes confirmadas, mediana de idade.
--
--  Use NULL em p_uf para "todas as UFs", e NULL em p_ano para "todos os anos".
-- ---------------------------------------------------------------------------

DROP TYPE IF EXISTS t_resumo_epi CASCADE;
CREATE TYPE t_resumo_epi AS (
    uf_sigla              CHAR(2),
    ano                   INTEGER,
    total_notificacoes    BIGINT,
    total_confirmados     BIGINT,
    taxa_confirmacao_pct  NUMERIC(5,2),
    total_obitos          BIGINT,
    letalidade_pct        NUMERIC(5,2),
    gestantes_confirmadas BIGINT,
    idade_mediana_anos    NUMERIC(6,2)
);

CREATE OR REPLACE FUNCTION fn_resumo_epidemiologico(
    p_uf  CHAR(2)   DEFAULT NULL,
    p_ano INTEGER   DEFAULT NULL
) RETURNS SETOF t_resumo_epi
LANGUAGE sql
SET search_path = zika, public
STABLE
AS $$
    SELECT
        u.sigla                                                                   AS uf_sigla,
        f.nu_ano                                                                  AS ano,
        COUNT(*)                                                                  AS total_notificacoes,
        COUNT(*) FILTER (WHERE f.cod_classificacao = 1)                           AS total_confirmados,
        ROUND(100.0 * COUNT(*) FILTER (WHERE f.cod_classificacao = 1)
                    / NULLIF(COUNT(*), 0), 2)                                     AS taxa_confirmacao_pct,
        COUNT(*) FILTER (WHERE f.cod_evolucao = 2)                                AS total_obitos,
        ROUND(100.0 * COUNT(*) FILTER (WHERE f.cod_evolucao = 2)
                    / NULLIF(COUNT(*) FILTER (WHERE f.cod_classificacao = 1), 0), 2)
                                                                                  AS letalidade_pct,
        COUNT(*) FILTER (WHERE f.cod_classificacao = 1 AND f.cod_gestante IN (1,2,3))
                                                                                  AS gestantes_confirmadas,
        ROUND(percentile_cont(0.5)
                  WITHIN GROUP (ORDER BY f.idade_anos)::NUMERIC, 2)               AS idade_mediana_anos
    FROM       fato_notificacao f
    LEFT JOIN  dim_uf u ON u.cod_uf = f.cod_uf_resi
    WHERE      (p_uf  IS NULL OR u.sigla   = p_uf)
      AND      (p_ano IS NULL OR f.nu_ano  = p_ano)
    GROUP BY   u.sigla, f.nu_ano
    ORDER BY   f.nu_ano, u.sigla;
$$;

COMMENT ON FUNCTION fn_resumo_epidemiologico(CHAR, INTEGER) IS
    'Resumo agregado de notificações por UF e ano. NULL = sem filtro.';

-- ---------------------------------------------------------------------------
-- 3.3  fn_inserir_notificacao(...)
--
--  Insert validado: aplica regras mínimas de consistência antes de persistir
--  na tabela fato_notificacao. Retorna o id_notif gerado, ou estoura exception.
--
--  Regras:
--      • dt_sintomas não pode ser futura nem anterior a 2010-01-01
--      • dt_notificacao >= dt_sintomas (se ambas presentes)
--      • dt_obito >= dt_sintomas (se presente)
--      • cod_sexo, cod_uf_resi e cod_classificacao devem existir nas dimensões
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION fn_inserir_notificacao(
    p_arquivo_origem    VARCHAR,
    p_ano_arquivo       SMALLINT,
    p_id_agravo         VARCHAR,
    p_dt_notificacao    DATE,
    p_dt_sintomas       DATE,
    p_cod_uf_notif      SMALLINT,
    p_cod_mun_notif     INTEGER,
    p_cod_uf_resi       SMALLINT,
    p_cod_mun_resi      INTEGER,
    p_nu_idade_codif    INTEGER,
    p_cod_sexo          CHAR,
    p_cod_classificacao SMALLINT,
    p_cod_evolucao      SMALLINT,
    p_dt_obito          DATE      DEFAULT NULL,
    p_cod_gestante      SMALLINT  DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql
SET search_path = zika, public
AS $$
DECLARE
    v_id BIGINT;
    v_idade NUMERIC(6,3) := fn_decodifica_idade(p_nu_idade_codif);
BEGIN
    -- Datas básicas
    IF p_dt_sintomas IS NULL THEN
        RAISE EXCEPTION 'Data dos primeiros sintomas é obrigatória';
    END IF;
    IF p_dt_sintomas > CURRENT_DATE THEN
        RAISE EXCEPTION 'dt_sintomas (%) não pode ser futura', p_dt_sintomas;
    END IF;
    IF p_dt_sintomas < DATE '2010-01-01' THEN
        RAISE EXCEPTION 'dt_sintomas (%) anterior a 2010 — provável erro de digitação', p_dt_sintomas;
    END IF;
    IF p_dt_notificacao IS NOT NULL AND p_dt_notificacao < p_dt_sintomas THEN
        RAISE EXCEPTION 'dt_notificacao (%) anterior a dt_sintomas (%)',
                        p_dt_notificacao, p_dt_sintomas;
    END IF;
    IF p_dt_obito IS NOT NULL AND p_dt_obito < p_dt_sintomas THEN
        RAISE EXCEPTION 'dt_obito (%) anterior a dt_sintomas (%)', p_dt_obito, p_dt_sintomas;
    END IF;

    -- Existência das chaves nas dimensões
    IF NOT EXISTS (SELECT 1 FROM dim_sexo          WHERE cod = p_cod_sexo) THEN
        RAISE EXCEPTION 'cod_sexo desconhecido: %', p_cod_sexo;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM dim_classificacao WHERE cod = p_cod_classificacao) THEN
        RAISE EXCEPTION 'cod_classificacao desconhecido: %', p_cod_classificacao;
    END IF;
    IF p_cod_uf_resi IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM dim_uf WHERE cod_uf = p_cod_uf_resi) THEN
        RAISE EXCEPTION 'cod_uf_resi desconhecido: %', p_cod_uf_resi;
    END IF;

    INSERT INTO fato_notificacao (
        arquivo_origem, ano_arquivo, id_agravo,
        dt_notificacao, dt_sintomas,
        cod_uf_notif, cod_mun_notif,
        cod_uf_resi, cod_mun_resi,
        nu_idade_codificada, idade_anos, faixa_etaria,
        cod_sexo, cod_classificacao, cod_evolucao,
        dt_obito, cod_gestante,
        nu_ano, sem_sintomas
    ) VALUES (
        p_arquivo_origem, p_ano_arquivo, p_id_agravo,
        p_dt_notificacao, p_dt_sintomas,
        p_cod_uf_notif, p_cod_mun_notif,
        p_cod_uf_resi, p_cod_mun_resi,
        p_nu_idade_codif, v_idade, fn_faixa_etaria(v_idade),
        p_cod_sexo, p_cod_classificacao, p_cod_evolucao,
        p_dt_obito, p_cod_gestante,
        EXTRACT(ISOYEAR FROM p_dt_sintomas)::INTEGER,
        EXTRACT(WEEK    FROM p_dt_sintomas)::INTEGER
    )
    RETURNING id_notif INTO v_id;

    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION fn_inserir_notificacao IS
    'Insert validado em fato_notificacao com regras epidemiológicas básicas.';

-- ---------------------------------------------------------------------------
-- 3.4  fn_detectar_duplicatas(p_janela_dias)
--
--  Identifica registros potencialmente duplicados — mesma combinação de
--  município de residência + sexo + idade + data dos sintomas dentro de uma
--  janela configurável (default 3 dias). Retorna grupos com >= 2 registros.
-- ---------------------------------------------------------------------------

DROP TYPE IF EXISTS t_duplicata CASCADE;
CREATE TYPE t_duplicata AS (
    grupo_hash      TEXT,
    n_ocorrencias   INTEGER,
    ids_duplicados  BIGINT[],
    cod_mun_resi    INTEGER,
    cod_sexo        CHAR(1),
    idade_anos      NUMERIC(6,2),
    dt_sintomas_min DATE,
    dt_sintomas_max DATE
);

CREATE OR REPLACE FUNCTION fn_detectar_duplicatas(p_janela_dias INTEGER DEFAULT 3)
RETURNS SETOF t_duplicata
LANGUAGE sql
SET search_path = zika, public
STABLE
AS $$
    WITH base AS (
        SELECT
            id_notif,
            cod_mun_resi,
            cod_sexo,
            ROUND(idade_anos, 0) AS idade_round,
            dt_sintomas,
            -- normaliza a data para "bucket" da janela
            (dt_sintomas - (EXTRACT(DOY FROM dt_sintomas)::INT % p_janela_dias))
                                                                AS bucket_data
        FROM fato_notificacao
        WHERE dt_sintomas IS NOT NULL
          AND cod_mun_resi IS NOT NULL
          AND cod_sexo     IS NOT NULL
    ),
    grupos AS (
        SELECT
            md5(cod_mun_resi::TEXT || cod_sexo || idade_round::TEXT || bucket_data::TEXT) AS grupo_hash,
            COUNT(*)                  AS n_ocorrencias,
            ARRAY_AGG(id_notif)       AS ids,
            cod_mun_resi, cod_sexo, idade_round,
            MIN(dt_sintomas)          AS dmin,
            MAX(dt_sintomas)          AS dmax
        FROM base
        GROUP BY 1, cod_mun_resi, cod_sexo, idade_round
        HAVING COUNT(*) > 1
    )
    SELECT
        grupo_hash, n_ocorrencias::INTEGER, ids,
        cod_mun_resi, cod_sexo, idade_round::NUMERIC(6,2),
        dmin, dmax
    FROM grupos
    ORDER BY n_ocorrencias DESC, dmin;
$$;

COMMENT ON FUNCTION fn_detectar_duplicatas(INTEGER) IS
    'Heurística para localizar fichas duplicadas: mesmo município, sexo, idade e
     data de sintomas dentro de janela configurável.';

-- ---------------------------------------------------------------------------
-- 3.5  fn_curva_semanal(p_uf, p_ano_inicio, p_ano_fim)
--
--  Série temporal semanal usada pelo dashboard (curva epidêmica).
-- ---------------------------------------------------------------------------

DROP TYPE IF EXISTS t_curva CASCADE;
CREATE TYPE t_curva AS (
    ano        INTEGER,
    semana_epi INTEGER,
    inicio_sem DATE,
    casos_total      BIGINT,
    casos_confirmado BIGINT
);

CREATE OR REPLACE FUNCTION fn_curva_semanal(
    p_uf          CHAR(2)  DEFAULT NULL,
    p_ano_inicio  INTEGER  DEFAULT 2018,
    p_ano_fim     INTEGER  DEFAULT 2026
) RETURNS SETOF t_curva
LANGUAGE sql
SET search_path = zika, public
STABLE
AS $$
    SELECT
        f.nu_ano,
        f.sem_sintomas,
        -- segunda-feira que abre a semana epidemiológica
        date_trunc('week', f.dt_sintomas)::DATE,
        COUNT(*),
        COUNT(*) FILTER (WHERE f.cod_classificacao = 1)
    FROM       fato_notificacao f
    LEFT JOIN  dim_uf u ON u.cod_uf = f.cod_uf_resi
    WHERE      f.dt_sintomas    IS NOT NULL
      AND      f.sem_sintomas   IS NOT NULL
      AND      f.nu_ano BETWEEN p_ano_inicio AND p_ano_fim
      AND      (p_uf IS NULL OR u.sigla = p_uf)
    GROUP BY   f.nu_ano, f.sem_sintomas, date_trunc('week', f.dt_sintomas)
    ORDER BY   f.nu_ano, f.sem_sintomas;
$$;

RESET search_path;
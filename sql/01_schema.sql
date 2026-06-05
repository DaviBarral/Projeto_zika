-- Criação idempotente do schema (não destrói dados existentes)
CREATE SCHEMA IF NOT EXISTS zika;
SET search_path TO zika, public;

-- ---------------------------------------------------------------------------
-- Extensões úteis
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;    -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS unaccent;    -- buscas tolerantes a acento
CREATE EXTENSION IF NOT EXISTS pg_trgm;     -- busca fuzzy em nomes

-- ===========================================================================
-- 1. DIMENSÕES DE LOCALIDADE
-- ===========================================================================

CREATE TABLE IF NOT EXISTS dim_uf (
    cod_uf       SMALLINT PRIMARY KEY,           -- código IBGE (ex.: 35 = SP)
    sigla        CHAR(2)  NOT NULL UNIQUE,
    nome         VARCHAR(60) NOT NULL,
    regiao       VARCHAR(20) NOT NULL
                 CHECK (regiao IN ('Norte','Nordeste','Sudeste','Sul','Centro-Oeste'))
);

COMMENT ON TABLE  dim_uf          IS 'Unidades da Federação — código IBGE de 2 dígitos';
COMMENT ON COLUMN dim_uf.cod_uf   IS 'Código IBGE da UF (11 a 53)';

CREATE TABLE IF NOT EXISTS dim_municipio (
    cod_municipio  INTEGER PRIMARY KEY,          -- código IBGE 6 ou 7 dígitos
    nome           VARCHAR(120) NOT NULL,
    cod_uf         SMALLINT     NOT NULL REFERENCES dim_uf(cod_uf)
);

CREATE INDEX IF NOT EXISTS idx_dim_municipio_uf       ON dim_municipio(cod_uf);
CREATE INDEX IF NOT EXISTS idx_dim_municipio_nome_trg ON dim_municipio USING gin (nome gin_trgm_ops);

COMMENT ON TABLE dim_municipio IS 'Municípios IBGE — usado para residência, notificação e local provável de infecção';

-- ===========================================================================
-- 2. DIMENSÕES CATEGÓRICAS (look-up tables)
-- ===========================================================================

CREATE TABLE IF NOT EXISTS dim_sexo (
    cod          CHAR(1) PRIMARY KEY,            -- M, F, I
    descricao    VARCHAR(20) NOT NULL
);

CREATE TABLE IF NOT EXISTS dim_raca (
    cod          SMALLINT PRIMARY KEY,
    descricao    VARCHAR(20) NOT NULL
);

CREATE TABLE IF NOT EXISTS dim_escolaridade (
    cod          SMALLINT PRIMARY KEY,
    descricao    VARCHAR(60) NOT NULL
);

CREATE TABLE IF NOT EXISTS dim_gestante (
    cod          SMALLINT PRIMARY KEY,
    descricao    VARCHAR(40) NOT NULL
);

CREATE TABLE IF NOT EXISTS dim_classificacao (
    cod          SMALLINT PRIMARY KEY,           -- 0,1,2,8
    descricao    VARCHAR(40) NOT NULL
);

CREATE TABLE IF NOT EXISTS dim_criterio (
    cod          SMALLINT PRIMARY KEY,           -- 0,1,2
    descricao    VARCHAR(40) NOT NULL
);

CREATE TABLE IF NOT EXISTS dim_evolucao (
    cod          SMALLINT PRIMARY KEY,
    descricao    VARCHAR(40) NOT NULL
);

CREATE TABLE IF NOT EXISTS dim_autoctonia (
    cod          SMALLINT PRIMARY KEY,           -- 1 Sim, 2 Não, 3 Indeterminado
    descricao    VARCHAR(30) NOT NULL
);

-- Unidade notificadora (CNES). Tabela ampla pode crescer; mantemos pequena.
CREATE TABLE IF NOT EXISTS dim_unidade_saude (
    cod_cnes     BIGINT PRIMARY KEY,
    nome         VARCHAR(200),
    tipo         VARCHAR(60),
    cod_municipio INTEGER REFERENCES dim_municipio(cod_municipio)
);

-- ===========================================================================
-- 3. TABELA FATO — uma linha por notificação
-- ===========================================================================

CREATE TABLE IF NOT EXISTS fato_notificacao (
    id_notif            BIGSERIAL PRIMARY KEY,

    -- Identificação do registro de origem
    arquivo_origem      VARCHAR(40)  NOT NULL,
    ano_arquivo BIGINT     NOT NULL,
    tp_not              SMALLINT,                          -- 2 = individual

    -- Agravo
    id_agravo           VARCHAR(10)  NOT NULL,             -- A92, A928

    -- Datas-chave
    dt_notificacao      DATE,
    sem_notificacao INTEGER,                          -- 1..53
    nu_ano BIGINT,                          -- ano da notificação
    dt_sintomas         DATE,
    sem_sintomas INTEGER,
    dt_investigacao     DATE,
    dt_encerramento     DATE,
    dt_obito            DATE,
    dt_digitacao        DATE,

    -- Localidade de NOTIFICAÇÃO
    cod_uf_notif        SMALLINT REFERENCES dim_uf(cod_uf),
    cod_mun_notif       INTEGER  REFERENCES dim_municipio(cod_municipio),
    id_regional_notif   INTEGER,

    -- Localidade de RESIDÊNCIA
    cod_uf_resi         SMALLINT REFERENCES dim_uf(cod_uf),
    cod_mun_resi        INTEGER  REFERENCES dim_municipio(cod_municipio),
    id_regional_resi    INTEGER,
    id_pais_resi        INTEGER,

    -- Localidade de INFECÇÃO (autoctonia)
    cod_autoctonia      SMALLINT REFERENCES dim_autoctonia(cod),
    cod_uf_infec        SMALLINT REFERENCES dim_uf(cod_uf),
    cod_mun_infec       INTEGER  REFERENCES dim_municipio(cod_municipio),
    cod_pais_infec      INTEGER,

    -- Demografia (FKs)
    nu_idade_codificada INTEGER,                           -- valor bruto (4025, 3006…)
    idade_anos          NUMERIC(5,2),                      -- calculado no ETL
    faixa_etaria        VARCHAR(15),                       -- calculado no ETL
    cod_sexo            CHAR(1)  REFERENCES dim_sexo(cod),
    cod_gestante        SMALLINT REFERENCES dim_gestante(cod),
    cod_raca            SMALLINT REFERENCES dim_raca(cod),
    cod_escolaridade    SMALLINT REFERENCES dim_escolaridade(cod),
    ano_nascimento BIGINT,
    cod_ocupacao        VARCHAR(10),                       -- CBO

    -- Investigação e desfecho
    cod_classificacao   SMALLINT REFERENCES dim_classificacao(cod),
    cod_criterio        SMALLINT REFERENCES dim_criterio(cod),
    cod_evolucao        SMALLINT REFERENCES dim_evolucao(cod),
    doenca_trabalho     SMALLINT,
    cs_suspeito         VARCHAR(20),

    -- Unidade notificadora
    cod_cnes_unidade    BIGINT REFERENCES dim_unidade_saude(cod_cnes),
    tp_unidade_notif    SMALLINT,
    tp_sistema          SMALLINT,

    -- Controle de fluxo / qualidade
    nduplic_n           SMALLINT,
    in_vincula          SMALLINT,
    cs_flxret           SMALLINT,
    flxrecebi           SMALLINT,

    -- Metadados de carga
    carregado_em        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    hash_linha          UUID        NOT NULL DEFAULT gen_random_uuid()
);

-- Índices que servem ao dashboard e às análises
CREATE INDEX IF NOT EXISTS idx_fato_dt_sintomas       ON fato_notificacao(dt_sintomas);
CREATE INDEX IF NOT EXISTS idx_fato_dt_notif          ON fato_notificacao(dt_notificacao);
CREATE INDEX IF NOT EXISTS idx_fato_uf_notif_ano      ON fato_notificacao(cod_uf_notif, nu_ano);
CREATE INDEX IF NOT EXISTS idx_fato_uf_resi_ano       ON fato_notificacao(cod_uf_resi, nu_ano);
CREATE INDEX IF NOT EXISTS idx_fato_mun_resi          ON fato_notificacao(cod_mun_resi);
CREATE INDEX IF NOT EXISTS idx_fato_classificacao     ON fato_notificacao(cod_classificacao);
CREATE INDEX IF NOT EXISTS idx_fato_classif_ano_uf    ON fato_notificacao(cod_classificacao, nu_ano, cod_uf_resi);
CREATE INDEX IF NOT EXISTS idx_fato_gestante          ON fato_notificacao(cod_gestante)
                                          WHERE cod_gestante IN (1,2,3);
CREATE INDEX IF NOT EXISTS idx_fato_obito             ON fato_notificacao(dt_obito)
                                          WHERE dt_obito IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_fato_semana_ano        ON fato_notificacao(nu_ano, sem_sintomas);

COMMENT ON TABLE fato_notificacao IS
    'Tabela fato — uma linha por ficha SINAN de Zika.
     Para análises de casos confirmados, filtre por cod_classificacao = 1.';

-- ===========================================================================
-- 4. AUDITORIA — log de DML em JSONB
-- ===========================================================================

CREATE TABLE IF NOT EXISTS aud_log (
    id_aud         BIGSERIAL PRIMARY KEY,
    tabela         VARCHAR(50)  NOT NULL,
    operacao       CHAR(1)      NOT NULL CHECK (operacao IN ('I','U','D')),
    pk_alvo        TEXT,                                   -- id do registro afetado
    usuario_db     TEXT         NOT NULL DEFAULT current_user,
    ip_cliente     INET         DEFAULT inet_client_addr(),
    momento        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    dados_antes    JSONB,
    dados_depois   JSONB,
    diff           JSONB                                   -- só os campos que mudaram (UPDATE)
);

CREATE INDEX IF NOT EXISTS idx_aud_log_tabela  ON aud_log(tabela);
CREATE INDEX IF NOT EXISTS idx_aud_log_momento ON aud_log(momento DESC);
CREATE INDEX IF NOT EXISTS idx_aud_log_pk      ON aud_log(pk_alvo);

COMMENT ON TABLE aud_log IS
    'Log universal de auditoria. Recebe snapshot antes/depois e diff (JSONB) das
     mudanças em fato_notificacao e dimensões críticas.';

-- ===========================================================================
-- 5. STAGING — tabela bruta para carga (ETL Python escreve aqui primeiro)
-- ===========================================================================
--  A staging recebe o CSV "como está" (todas as colunas como TEXT) para que
--  validações e conversões sejam feitas em SQL, com erros isoláveis.
-- ===========================================================================

CREATE TABLE IF NOT EXISTS stg_zika_raw (
    linha_id        BIGSERIAL PRIMARY KEY,
    arquivo_origem  TEXT,
    ano_arquivo     TEXT,
    tp_not          TEXT,
    id_agravo       TEXT,
    cs_suspeit      TEXT,
    dt_notific      TEXT,
    sem_not         TEXT,
    nu_ano          TEXT,
    sg_uf_not       TEXT,
    id_municip      TEXT,
    id_regiona      TEXT,
    dt_sin_pri      TEXT,
    sem_pri         TEXT,
    nu_idade_n      TEXT,
    cs_sexo         TEXT,
    cs_gestant      TEXT,
    cs_raca         TEXT,
    cs_escol_n      TEXT,
    sg_uf           TEXT,
    id_mn_resi      TEXT,
    id_rg_resi      TEXT,
    id_pais         TEXT,
    nduplic_n       TEXT,
    in_vincula      TEXT,
    dt_invest       TEXT,
    id_ocupa_n      TEXT,
    classi_fin      TEXT,
    criterio        TEXT,
    tpautocto       TEXT,
    coufinf         TEXT,
    copaisinf       TEXT,
    comuninf        TEXT,
    doenca_tra      TEXT,
    evolucao        TEXT,
    dt_obito        TEXT,
    dt_encerra      TEXT,
    cs_flxret       TEXT,
    flxrecebi       TEXT,
    tp_sistema      TEXT,
    tpuninot        TEXT,
    id_unidade      TEXT,
    ano_nasc        TEXT,
    dt_digita       TEXT
);

COMMENT ON TABLE stg_zika_raw IS
    'Staging do CSV bruto. Tudo TEXT — converte-se para os tipos do modelo na rotina de carga.';

-- ===========================================================================
-- Encerramento
-- ===========================================================================
RESET search_path;

-- ============================================================================
--  PROJETO ZIKA BR — 06_fk_erd.sql
--  Conecta aud_log e stg_zika_raw à fato_notificacao para aparecerem no ERD.
--  Rodar APÓS 01_schema.sql.
-- ============================================================================
SET search_path TO zika, public;

-- ---------------------------------------------------------------------------
-- aud_log → fato_notificacao
--
--  pk_alvo (TEXT) guarda o id_notif como string.
--  Adicionamos id_notif_ref (BIGINT, nullable) com FK explícita para que o
--  pgAdmin desenhe a aresta no diagrama.
--  Preenchimento: UPDATE aud_log SET id_notif_ref = pk_alvo::BIGINT
--                 WHERE tabela = 'fato_notificacao' AND pk_alvo ~ '^\d+$';
-- ---------------------------------------------------------------------------
ALTER TABLE aud_log
    ADD COLUMN IF NOT EXISTS id_notif_ref BIGINT
        REFERENCES fato_notificacao(id_notif)
        ON DELETE SET NULL;

COMMENT ON COLUMN aud_log.id_notif_ref IS
    'FK para fato_notificacao. Espelha pk_alvo quando tabela = ''fato_notificacao''.
     Mantida NULL para logs de outras tabelas.';

CREATE INDEX IF NOT EXISTS idx_aud_log_notif_ref
    ON aud_log(id_notif_ref)
    WHERE id_notif_ref IS NOT NULL;

-- ---------------------------------------------------------------------------
-- stg_zika_raw → fato_notificacao
--
--  A staging é TEXT puro, impossível fazer FK nas colunas existentes.
--  Adicionamos id_notif_gerado: preenchido pelo ETL após inserir a linha
--  em fato_notificacao, para rastreabilidade e para aparecer no ERD.
-- ---------------------------------------------------------------------------
ALTER TABLE stg_zika_raw
    ADD COLUMN IF NOT EXISTS id_notif_gerado BIGINT
        REFERENCES fato_notificacao(id_notif)
        ON DELETE SET NULL;

COMMENT ON COLUMN stg_zika_raw.id_notif_gerado IS
    'FK para fato_notificacao. Preenchida pelo ETL após carga bem-sucedida da linha.
     NULL indica linha ainda não processada ou rejeitada.';

CREATE INDEX IF NOT EXISTS idx_stg_notif_gerado
    ON stg_zika_raw(id_notif_gerado)
    WHERE id_notif_gerado IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Como preencher após carga (exemplo):
--
--  UPDATE zika.aud_log
--     SET id_notif_ref = pk_alvo::BIGINT
--   WHERE tabela = 'fato_notificacao'
--     AND pk_alvo ~ '^\d+$';
--
--  No ETL Python, após INSERT em fato_notificacao retornar id_notif:
--      UPDATE zika.stg_zika_raw
--         SET id_notif_gerado = <id_retornado>
--       WHERE linha_id = <linha_id_da_staging>;
-- ---------------------------------------------------------------------------

RESET search_path;

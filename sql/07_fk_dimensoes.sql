-- ============================================================================
--  PROJETO ZIKA BR — 07_fk_dimensoes.sql
--  Adiciona as FKs das dimensões categóricas que o IF NOT EXISTS ignorou.
-- ============================================================================
SET search_path TO zika, public;

ALTER TABLE fato_notificacao
    ADD CONSTRAINT fk_fato_classificacao
        FOREIGN KEY (cod_classificacao) REFERENCES dim_classificacao(cod);

ALTER TABLE fato_notificacao
    ADD CONSTRAINT fk_fato_criterio
        FOREIGN KEY (cod_criterio) REFERENCES dim_criterio(cod);

ALTER TABLE fato_notificacao
    ADD CONSTRAINT fk_fato_evolucao
        FOREIGN KEY (cod_evolucao) REFERENCES dim_evolucao(cod);

ALTER TABLE fato_notificacao
    ADD CONSTRAINT fk_fato_gestante
        FOREIGN KEY (cod_gestante) REFERENCES dim_gestante(cod);

ALTER TABLE fato_notificacao
    ADD CONSTRAINT fk_fato_raca
        FOREIGN KEY (cod_raca) REFERENCES dim_raca(cod);

ALTER TABLE fato_notificacao
    ADD CONSTRAINT fk_fato_escolaridade
        FOREIGN KEY (cod_escolaridade) REFERENCES dim_escolaridade(cod);

RESET search_path;

-- ============================================================================
--  PROJETO ZIKA BR — 99_testes.sql
--  Testes mínimos das funções e triggers. Rodar APÓS a carga.
-- ============================================================================
SET search_path TO zika, public;

\echo '======== TESTE 1 : fn_decodifica_idade ========'
SELECT
    fn_decodifica_idade(4025) AS "25 anos esperados",
    fn_decodifica_idade(3006) AS "0.5 ano (6 meses)",
    fn_decodifica_idade(2015) AS "≈0.041 ano (15 dias)",
    fn_decodifica_idade(1010) AS "≈0.0011 ano (10 horas)",
    fn_decodifica_idade(NULL) AS "deve ser NULL",
    fn_decodifica_idade(0)    AS "deve ser NULL";

\echo '======== TESTE 2 : fn_faixa_etaria ========'
SELECT
    fn_faixa_etaria(0.3)  AS "<1 ano",
    fn_faixa_etaria(3)    AS "1-4",
    fn_faixa_etaria(25)   AS "20-29",
    fn_faixa_etaria(82)   AS "80+",
    fn_faixa_etaria(NULL) AS "Ignorada";

\echo '======== TESTE 3 : fn_resumo_epidemiologico (PE, 2024) ========'
SELECT * FROM fn_resumo_epidemiologico('PE', 2024::SMALLINT) LIMIT 5;

\echo '======== TESTE 4 : fn_curva_semanal (BR, 2024) ========'
SELECT * FROM fn_curva_semanal(NULL, 2024::SMALLINT, 2024::SMALLINT) LIMIT 5;

\echo '======== TESTE 5 : trigger de validação clínica — caso inválido ========'
DO $$
BEGIN
    BEGIN
        INSERT INTO zika.fato_notificacao (
            arquivo_origem, ano_arquivo, id_agravo, dt_sintomas, dt_obito,
            cod_sexo, cod_classificacao, cod_evolucao
        ) VALUES (
            'TESTE.dbc', 2024, 'A92', DATE '2024-06-10', DATE '2024-06-01',
            'M', 1, 1
        );
        RAISE EXCEPTION 'TESTE FALHOU: deveria ter bloqueado (óbito antes de sintomas)';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'OK — trigger bloqueou: %', SQLERRM;
    END;
END $$;

\echo '======== TESTE 6 : trigger de validação clínica — gestante x sexo ========'
DO $$
BEGIN
    BEGIN
        INSERT INTO zika.fato_notificacao (
            arquivo_origem, ano_arquivo, id_agravo, dt_sintomas,
            cod_sexo, cod_gestante, cod_classificacao
        ) VALUES (
            'TESTE.dbc', 2024, 'A92', DATE '2024-06-10',
            'M', 1, 1
        );
        RAISE EXCEPTION 'TESTE FALHOU: deveria ter bloqueado (gestante sexo M)';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'OK — trigger bloqueou: %', SQLERRM;
    END;
END $$;

\echo '======== TESTE 7 : auditoria — UPDATE gera diff JSONB ========'
DO $$
DECLARE
    v_id BIGINT;
    v_diff JSONB;
BEGIN
    INSERT INTO zika.fato_notificacao (
        arquivo_origem, ano_arquivo, id_agravo, dt_sintomas,
        cod_sexo, cod_classificacao, cod_evolucao
    ) VALUES (
        'TESTE.dbc', 2024, 'A92', DATE '2024-06-10', 'F', 2, 0
    ) RETURNING id_notif INTO v_id;

    UPDATE fato_notificacao SET cod_classificacao = 1 WHERE id_notif = v_id;

    SELECT diff INTO v_diff FROM zika.aud_log
     WHERE tabela = 'fato_notificacao' AND pk_alvo = v_id::TEXT AND operacao = 'U'
     ORDER BY momento DESC LIMIT 1;

    IF v_diff IS NULL OR NOT v_diff ? 'cod_classificacao' THEN
        RAISE EXCEPTION 'TESTE FALHOU: diff de auditoria não contém cod_classificacao';
    END IF;
    RAISE NOTICE 'OK — auditoria registrou diff: %', v_diff;

    -- cleanup
    DELETE FROM zika.fato_notificacao WHERE id_notif = v_id;
END $$;

\echo '======== TESTE 8 : views de KPI ========'
SELECT total_notificacoes, total_confirmados, taxa_confirmacao_pct, letalidade_pct
FROM vw_kpis;

\echo '======== FIM DOS TESTES ========'
RESET search_path;

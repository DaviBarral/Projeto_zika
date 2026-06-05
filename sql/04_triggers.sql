-- ============================================================================
--  PROJETO ZIKA BR — 04_triggers.sql
--  Triggers de auditoria (INSERT/UPDATE/DELETE) e de validação clínica.
-- ============================================================================
SET search_path TO zika, public;

-- ===========================================================================
-- 4.1  Função genérica de auditoria com snapshot JSONB
-- ===========================================================================
--  Grava em aud_log:
--      • INSERT → dados_depois
--      • DELETE → dados_antes
--      • UPDATE → dados_antes, dados_depois e o diff (só campos modificados)
-- ===========================================================================

CREATE OR REPLACE FUNCTION trg_fn_auditar()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = zika, public
AS $$
DECLARE
    v_pk     TEXT;
    v_antes  JSONB;
    v_depois JSONB;
    v_diff   JSONB;
BEGIN
    -- Resolve PK alvo (usa "id_notif" se existir; senão usa todos os PKs)
    BEGIN
        IF TG_OP = 'DELETE' THEN
            v_pk := (to_jsonb(OLD) ->> 'id_notif');
        ELSE
            v_pk := (to_jsonb(NEW) ->> 'id_notif');
        END IF;
    EXCEPTION WHEN OTHERS THEN
        v_pk := NULL;
    END;

    IF TG_OP = 'INSERT' THEN
        v_depois := to_jsonb(NEW);
        INSERT INTO aud_log (tabela, operacao, pk_alvo, dados_depois)
        VALUES (TG_TABLE_NAME, 'I', v_pk, v_depois);
        RETURN NEW;

    ELSIF TG_OP = 'DELETE' THEN
        v_antes := to_jsonb(OLD);
        INSERT INTO aud_log (tabela, operacao, pk_alvo, dados_antes)
        VALUES (TG_TABLE_NAME, 'D', v_pk, v_antes);
        RETURN OLD;

    ELSIF TG_OP = 'UPDATE' THEN
        v_antes  := to_jsonb(OLD);
        v_depois := to_jsonb(NEW);

        -- diff: somente chaves cujos valores mudaram
        SELECT jsonb_object_agg(key, jsonb_build_object('de', v_antes -> key,
                                                        'para', v_depois -> key))
          INTO v_diff
          FROM jsonb_each(v_depois)
         WHERE v_antes -> key IS DISTINCT FROM v_depois -> key;

        -- só registra UPDATE se realmente houve mudança
        IF v_diff IS NOT NULL AND v_diff <> '{}'::JSONB THEN
            INSERT INTO aud_log (tabela, operacao, pk_alvo,
                                 dados_antes, dados_depois, diff)
            VALUES (TG_TABLE_NAME, 'U', v_pk, v_antes, v_depois, v_diff);
        END IF;

        RETURN NEW;
    END IF;

    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION trg_fn_auditar IS
    'Função genérica de trigger: grava snapshot e diff em aud_log.';

-- Vincula a função à fato_notificacao e às dimensões críticas
DROP TRIGGER IF EXISTS trg_aud_fato_notificacao ON fato_notificacao;
CREATE TRIGGER trg_aud_fato_notificacao
    AFTER INSERT OR UPDATE OR DELETE ON fato_notificacao
    FOR EACH ROW EXECUTE FUNCTION trg_fn_auditar();

DROP TRIGGER IF EXISTS trg_aud_dim_uf ON dim_uf;
CREATE TRIGGER trg_aud_dim_uf
    AFTER INSERT OR UPDATE OR DELETE ON dim_uf
    FOR EACH ROW EXECUTE FUNCTION trg_fn_auditar();

DROP TRIGGER IF EXISTS trg_aud_dim_classif ON dim_classificacao;
CREATE TRIGGER trg_aud_dim_classif
    AFTER INSERT OR UPDATE OR DELETE ON dim_classificacao
    FOR EACH ROW EXECUTE FUNCTION trg_fn_auditar();

-- ===========================================================================
-- 4.2  Trigger de VALIDAÇÃO CLÍNICA — roda BEFORE INSERT/UPDATE
-- ===========================================================================
--  Bloqueia gravação de registros inconsistentes:
--      • cronologia de datas
--      • óbito coerente com evolução
--      • gestação coerente com sexo
--      • idade dentro de faixa plausível
--      • semana epidemiológica coerente com a data
--
--  Erros silenciosos viram WARNING (não bloqueiam a carga em massa).
--  Os "duros" estouram EXCEPTION.
-- ===========================================================================

CREATE OR REPLACE FUNCTION trg_fn_validar_clinico()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = zika, public
AS $$
BEGIN
    -- A) Cronologia
    IF NEW.dt_sintomas IS NOT NULL AND NEW.dt_notificacao IS NOT NULL
       AND NEW.dt_notificacao < NEW.dt_sintomas THEN
        RAISE EXCEPTION 'Inconsistência: dt_notificacao (%) anterior a dt_sintomas (%)',
                        NEW.dt_notificacao, NEW.dt_sintomas;
    END IF;

    IF NEW.dt_obito IS NOT NULL AND NEW.dt_sintomas IS NOT NULL
       AND NEW.dt_obito < NEW.dt_sintomas THEN
        RAISE EXCEPTION 'Inconsistência: dt_obito (%) anterior a dt_sintomas (%)',
                        NEW.dt_obito, NEW.dt_sintomas;
    END IF;

    IF NEW.dt_encerramento IS NOT NULL AND NEW.dt_notificacao IS NOT NULL
       AND NEW.dt_encerramento < NEW.dt_notificacao THEN
        RAISE EXCEPTION 'Inconsistência: dt_encerramento (%) anterior a dt_notificacao (%)',
                        NEW.dt_encerramento, NEW.dt_notificacao;
    END IF;

    -- B) Óbito coerente com evolução
    --    Se evolução = 2 (óbito pelo agravo), dt_obito deve estar preenchida.
    IF NEW.cod_evolucao = 2 AND NEW.dt_obito IS NULL THEN
        RAISE WARNING 'Evolução = óbito pelo agravo, mas dt_obito vazia (id provisório)';
    END IF;

    --    Se dt_obito preenchida e evolução é "Cura", há contradição.
    IF NEW.dt_obito IS NOT NULL AND NEW.cod_evolucao = 1 THEN
        RAISE EXCEPTION 'Inconsistência: dt_obito preenchida mas evolução = Cura';
    END IF;

    -- C) Gestação coerente com sexo
    --    cod_gestante 1..3 ou 4 = gestante / ignorada → sexo deve ser F
    IF NEW.cod_gestante IN (1,2,3,4)
       AND NEW.cod_sexo IS NOT NULL
       AND NEW.cod_sexo <> 'F' THEN
        RAISE EXCEPTION 'Inconsistência: gestante=% mas sexo=%', NEW.cod_gestante, NEW.cod_sexo;
    END IF;

    -- D) Idade plausível
    IF NEW.idade_anos IS NOT NULL AND (NEW.idade_anos < 0 OR NEW.idade_anos > 120) THEN
        RAISE EXCEPTION 'Idade fora da faixa plausível: % anos', NEW.idade_anos;
    END IF;

    -- E) Semana epidemiológica deve estar entre 1 e 53
    IF NEW.sem_sintomas IS NOT NULL
       AND (NEW.sem_sintomas < 1 OR NEW.sem_sintomas > 53) THEN
        RAISE EXCEPTION 'Semana epidemiológica fora do intervalo (1..53): %', NEW.sem_sintomas;
    END IF;

    -- F) Coerência ano de nascimento × idade
    IF NEW.ano_nascimento IS NOT NULL AND NEW.dt_sintomas IS NOT NULL THEN
        IF (EXTRACT(YEAR FROM NEW.dt_sintomas) - NEW.ano_nascimento) < 0 THEN
            RAISE EXCEPTION 'ano_nascimento (%) posterior à data dos sintomas (%)',
                            NEW.ano_nascimento, NEW.dt_sintomas;
        END IF;
    END IF;

    -- G) Preenche derivados se vierem nulos
    IF NEW.idade_anos IS NULL AND NEW.nu_idade_codificada IS NOT NULL THEN
        NEW.idade_anos := fn_decodifica_idade(NEW.nu_idade_codificada);
    END IF;
    IF NEW.faixa_etaria IS NULL AND NEW.idade_anos IS NOT NULL THEN
        NEW.faixa_etaria := fn_faixa_etaria(NEW.idade_anos);
    END IF;
    IF NEW.nu_ano IS NULL AND NEW.dt_sintomas IS NOT NULL THEN
        NEW.nu_ano := EXTRACT(ISOYEAR FROM NEW.dt_sintomas)::SMALLINT;
    END IF;
    IF NEW.sem_sintomas IS NULL AND NEW.dt_sintomas IS NOT NULL THEN
        NEW.sem_sintomas := EXTRACT(WEEK FROM NEW.dt_sintomas)::SMALLINT;
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION trg_fn_validar_clinico IS
    'Validação clínica e preenchimento de campos derivados. Roda BEFORE INSERT/UPDATE.';

DROP TRIGGER IF EXISTS trg_val_fato ON fato_notificacao;
CREATE TRIGGER trg_val_fato
    BEFORE INSERT OR UPDATE ON fato_notificacao
    FOR EACH ROW EXECUTE FUNCTION trg_fn_validar_clinico();

-- ===========================================================================
-- 4.3  Toggle de validação para carga em massa
-- ===========================================================================
--  Em cargas iniciais (CSV de 236 mil linhas), é comum desativar a validação
--  para acelerar e tratar erros depois. Estas helpers permitem ligar/desligar.
-- ===========================================================================

CREATE OR REPLACE PROCEDURE sp_desativar_validacao_clinica()
LANGUAGE plpgsql AS $$
BEGIN
    ALTER TABLE zika.fato_notificacao DISABLE TRIGGER trg_val_fato;
    RAISE NOTICE 'Trigger trg_val_fato DESATIVADA — carga em massa permitida.';
END;
$$;

CREATE OR REPLACE PROCEDURE sp_ativar_validacao_clinica()
LANGUAGE plpgsql AS $$
BEGIN
    ALTER TABLE zika.fato_notificacao ENABLE TRIGGER trg_val_fato;
    RAISE NOTICE 'Trigger trg_val_fato ATIVADA.';
END;
$$;

RESET search_path;

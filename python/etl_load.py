#!/usr/bin/env python3
"""
ETL — Zika BR (SINAN 2018–2026)
================================
Carrega o CSV unificado em PostgreSQL respeitando o esquema relacional definido em
sql/01_schema.sql.

Fluxo:
    1. Lê o CSV em chunks (pandas) — robusto para 236 mil linhas.
    2. Faz COPY em massa para `zika.stg_zika_raw` (TEXT puro).
    3. Popula dim_municipio e dim_unidade_saude a partir dos códigos vistos.
    4. Transforma e migra de stg_zika_raw → fato_notificacao usando SQL,
       aproveitando as funções já criadas (fn_decodifica_idade etc.).
    5. Atualiza a materialized view e roda VACUUM ANALYZE.

Uso:
    python etl_load.py --csv /caminho/ZIKA_BR_2018_2026_UNIFICADO.csv
                       --dsn  postgresql://user:senha@localhost:5432/zika

Dependências: psycopg[binary]>=3.1, pandas, tqdm
"""
from __future__ import annotations

import argparse
import io
import logging
import sys
import time
import re
from contextlib import contextmanager
from pathlib import Path

import pandas as pd
import psycopg
from psycopg import sql
from tqdm import tqdm

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-7s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("etl")

# ---------------------------------------------------------------------------
# Colunas esperadas no CSV (ordem fixa)
# ---------------------------------------------------------------------------
CSV_COLUNAS = [
    "arquivo_origem", "ano_arquivo", "TP_NOT", "ID_AGRAVO", "CS_SUSPEIT",
    "DT_NOTIFIC", "SEM_NOT", "NU_ANO", "SG_UF_NOT", "ID_MUNICIP", "ID_REGIONA",
    "DT_SIN_PRI", "SEM_PRI", "NU_IDADE_N", "CS_SEXO", "CS_GESTANT", "CS_RACA",
    "CS_ESCOL_N", "SG_UF", "ID_MN_RESI", "ID_RG_RESI", "ID_PAIS", "NDUPLIC_N",
    "IN_VINCULA", "DT_INVEST", "ID_OCUPA_N", "CLASSI_FIN", "CRITERIO",
    "TPAUTOCTO", "COUFINF", "COPAISINF", "COMUNINF", "DOENCA_TRA", "EVOLUCAO",
    "DT_OBITO", "DT_ENCERRA", "CS_FLXRET", "FLXRECEBI", "TP_SISTEMA",
    "TPUNINOT", "ID_UNIDADE", "ANO_NASC", "DT_DIGITA",
]

# Mapeamento CSV → coluna na staging (lowercase)
STG_COLUNAS = [c.lower() for c in CSV_COLUNAS]

CHUNK_SIZE = 50_000   # linhas por chunk para o COPY


# ===========================================================================
# Helpers
# ===========================================================================

@contextmanager
def conexao(dsn: str):
    conn = psycopg.connect(dsn, autocommit=False)
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def executar_arquivo(conn: psycopg.Connection, caminho: Path) -> None:
    """Roda um arquivo .sql inteiro."""
    log.info("Executando %s ...", caminho.name)
    with conn.cursor() as cur, open(caminho, "r", encoding="utf-8") as f:
        cur.execute(f.read())


# ===========================================================================
# 1. Cria estrutura e popula dimensões
# ===========================================================================

def criar_estrutura(conn: psycopg.Connection, sql_dir: Path) -> None:
    for nome in ("01_schema.sql",
                 "02_seed_dimensoes.sql",
                 "03_funcoes.sql",
                 "04_triggers.sql",
                 "05_views.sql"):
        executar_arquivo(conn, sql_dir / nome)
    log.info("Estrutura criada com sucesso.")


# ===========================================================================
# 2. Carga da staging via COPY
# ===========================================================================

def carregar_staging(conn: psycopg.Connection, csv_path: Path) -> int:
    """Lê o CSV em chunks e faz COPY em zika.stg_zika_raw. Retorna n linhas."""
    total = 0
    cols_sql = sql.SQL(",").join(sql.Identifier(c) for c in STG_COLUNAS)
    copy_sql = sql.SQL(
        "COPY zika.stg_zika_raw ({}) FROM STDIN WITH (FORMAT CSV, HEADER FALSE)"
    ).format(cols_sql)

    # Limpa staging para garantir idempotência (re-execução não duplica dados)
    with conn.cursor() as cur_trunc:
        cur_trunc.execute("TRUNCATE TABLE zika.stg_zika_raw RESTART IDENTITY;")
    log.info("Staging limpa (TRUNCATE).")
    log.info("Iniciando carga em staging a partir de %s", csv_path)
    iterador = pd.read_csv(
        csv_path,
        chunksize=CHUNK_SIZE,
        dtype=str,             # tudo string — staging absorve depois
        keep_default_na=False,
        na_values=[""],
        encoding="utf-8",
        low_memory=False,
    )

    with conn.cursor() as cur:
        for chunk in tqdm(iterador, desc="COPY chunks", unit=f"{CHUNK_SIZE}lin"):
            # garante que o chunk tem exatamente as colunas esperadas, na ordem certa
            faltando = [c for c in CSV_COLUNAS if c not in chunk.columns]
            if faltando:
                raise RuntimeError(f"Colunas ausentes no CSV: {faltando}")
            chunk = chunk[CSV_COLUNAS]

            buf = io.StringIO()
            chunk.to_csv(buf, index=False, header=False, na_rep="")
            buf.seek(0)

            with cur.copy(copy_sql) as copy:
                copy.write(buf.read())

            total += len(chunk)

    log.info("Staging populada com %s linhas.", f"{total:,}")
    return total


# ===========================================================================
# 3. Popula dim_municipio dinamicamente (VERSÃO CORRIGIDA)
# ===========================================================================

def popular_municipios(conn: psycopg.Connection) -> None:
    """
    Popula dim_municipio a partir dos códigos vistos no CSV.
    Versão simplificada e robusta sem erros de sintaxe.
    """
    log.info("Populando dim_municipio a partir da staging...")
    cur = conn.cursor()
    
    # Dicionário de regiões para cada UF
    regioes_uf = {
        11: 'Norte', 12: 'Norte', 13: 'Norte', 14: 'Norte', 15: 'Norte', 16: 'Norte', 17: 'Norte',
        21: 'Nordeste', 22: 'Nordeste', 23: 'Nordeste', 24: 'Nordeste', 25: 'Nordeste', 
        26: 'Nordeste', 27: 'Nordeste', 28: 'Nordeste', 29: 'Nordeste',
        31: 'Sudeste', 32: 'Sudeste', 33: 'Sudeste', 35: 'Sudeste',
        41: 'Sul', 42: 'Sul', 43: 'Sul',
        50: 'Centro-Oeste', 51: 'Centro-Oeste', 52: 'Centro-Oeste', 53: 'Centro-Oeste'
    }
    
    # Nomes das UFs
    nomes_uf = {
        11: 'Rondônia', 12: 'Acre', 13: 'Amazonas', 14: 'Roraima', 15: 'Pará', 16: 'Amapá', 17: 'Tocantins',
        21: 'Maranhão', 22: 'Piauí', 23: 'Ceará', 24: 'Rio Grande do Norte', 25: 'Paraíba',
        26: 'Pernambuco', 27: 'Alagoas', 28: 'Sergipe', 29: 'Bahia',
        31: 'Minas Gerais', 32: 'Espírito Santo', 33: 'Rio de Janeiro', 35: 'São Paulo',
        41: 'Paraná', 42: 'Santa Catarina', 43: 'Rio Grande do Sul',
        50: 'Mato Grosso do Sul', 51: 'Mato Grosso', 52: 'Goiás', 53: 'Distrito Federal'
    }
    
    # Siglas das UFs
    siglas_uf = {
        11: 'RO', 12: 'AC', 13: 'AM', 14: 'RR', 15: 'PA', 16: 'AP', 17: 'TO',
        21: 'MA', 22: 'PI', 23: 'CE', 24: 'RN', 25: 'PB', 26: 'PE', 27: 'AL', 28: 'SE', 29: 'BA',
        31: 'MG', 32: 'ES', 33: 'RJ', 35: 'SP',
        41: 'PR', 42: 'SC', 43: 'RS',
        50: 'MS', 51: 'MT', 52: 'GO', 53: 'DF'
    }
    
    # dim_uf já foi populada pelo 02_seed_dimensoes.sql.
    # Upsert para garantir idempotência em re-execuções.
    for cod, nome in nomes_uf.items():
        cur.execute("""
            INSERT INTO zika.dim_uf (cod_uf, sigla, nome, regiao)
            VALUES (%s, %s, %s, %s)
            ON CONFLICT (cod_uf) DO NOTHING;
        """, (cod, siglas_uf[cod], nome, regioes_uf[cod]))

    log.info("dim_uf verificada: %s UFs.", len(nomes_uf))

    # Aceita 6 OU 7 dígitos; filtro estrito evita erro com siglas como 'BA'
    cur.execute("""
        INSERT INTO zika.dim_municipio (cod_municipio, nome, cod_uf)
        SELECT DISTINCT
            cod_municipio::INTEGER,
            'MUN-' || cod_municipio::TEXT,
            (cod_municipio::INTEGER / 100000)::SMALLINT
        FROM (
            SELECT id_municip AS cod_municipio
            FROM zika.stg_zika_raw
            WHERE id_municip ~ '^[0-9]{6,7}$'
            UNION
            SELECT id_mn_resi
            FROM zika.stg_zika_raw
            WHERE id_mn_resi ~ '^[0-9]{6,7}$'
            UNION
            SELECT comuninf
            FROM zika.stg_zika_raw
            WHERE comuninf ~ '^[0-9]{6,7}$'
        ) AS t
        WHERE cod_municipio IS NOT NULL
          AND (cod_municipio::BIGINT / 100000)::SMALLINT
              IN (SELECT cod_uf FROM zika.dim_uf)
        ON CONFLICT (cod_municipio) DO NOTHING;
    """)
    
    # Contar quantos municípios foram inseridos
    cur.execute("SELECT COUNT(*) FROM zika.dim_municipio;")
    count = cur.fetchone()[0]
    log.info("dim_municipio populada: %s municípios distintos.", f"{count:,}")


def popular_unidades(conn: psycopg.Connection) -> None:
    log.info("Populando dim_unidade_saude (CNES vistos na staging)...")
    cur = conn.cursor()
    cur.execute("""
        INSERT INTO zika.dim_unidade_saude (cod_cnes, nome)
        SELECT DISTINCT NULLIF(id_unidade,'')::BIGINT,
                        'CNES-' || id_unidade
          FROM zika.stg_zika_raw
         WHERE id_unidade ~ '^[0-9]+$'
           AND NULLIF(id_unidade,'') IS NOT NULL
         ON CONFLICT (cod_cnes) DO NOTHING;
    """)
    cur.execute("SELECT COUNT(*) FROM zika.dim_unidade_saude;")
    count = cur.fetchone()[0]
    log.info("dim_unidade_saude populada: %s registros.", f"{count:,}")


# ===========================================================================
# 4. Transforma staging → fato_notificacao
# ===========================================================================

SQL_INSERIR_FATO = """
INSERT INTO zika.fato_notificacao (
    arquivo_origem, ano_arquivo, tp_not, id_agravo, cs_suspeito,
    dt_notificacao, sem_notificacao, nu_ano,
    cod_uf_notif, cod_mun_notif, id_regional_notif,
    dt_sintomas, sem_sintomas,
    nu_idade_codificada, idade_anos, faixa_etaria,
    cod_sexo, cod_gestante, cod_raca, cod_escolaridade,
    cod_uf_resi, cod_mun_resi, id_regional_resi, id_pais_resi,
    nduplic_n, in_vincula, dt_investigacao, cod_ocupacao,
    cod_classificacao, cod_criterio, cod_autoctonia,
    cod_uf_infec, cod_pais_infec, cod_mun_infec,
    doenca_trabalho, cod_evolucao, dt_obito, dt_encerramento,
    cs_flxret, flxrecebi, tp_sistema, tp_unidade_notif,
    cod_cnes_unidade, ano_nascimento, dt_digitacao
)
SELECT
    s.arquivo_origem,
    -- ano_arquivo: extrair apenas o ano
    CASE 
        WHEN s.ano_arquivo ~ '^[0-9]{4}$' THEN s.ano_arquivo::INTEGER
        WHEN LENGTH(s.ano_arquivo) > 4    THEN SUBSTRING(s.ano_arquivo, 1, 4)::INTEGER
        ELSE NULL
    END,
    CASE WHEN s.tp_not ~ '^[0-9]+$' THEN NULLIF(s.tp_not, '')::INTEGER ELSE NULL END,
    s.id_agravo,
    s.cs_suspeit,
    CASE WHEN s.dt_notific ~ '^\\d{4}-\\d{2}-\\d{2}$' THEN s.dt_notific::DATE ELSE NULL END,
    CASE WHEN s.sem_not ~ '^[0-9]+$' THEN NULLIF(s.sem_not, '')::INTEGER ELSE NULL END,
    CASE WHEN s.nu_ano ~ '^[0-9]+$' THEN NULLIF(s.nu_ano, '')::INTEGER ELSE NULL END,
    CASE WHEN s.sg_uf_not ~ '^[0-9]+$' THEN NULLIF(s.sg_uf_not, '')::INTEGER ELSE NULL END,
    -- município: usar os primeiros 6 dígitos
    CASE 
        WHEN s.id_municip ~ '^[0-9]+$' THEN 
            CASE 
                WHEN LENGTH(s.id_municip) >= 6 THEN SUBSTRING(s.id_municip, 1, 6)::INT
                ELSE s.id_municip::INT
            END
        ELSE NULL 
    END,
    CASE WHEN s.id_regiona ~ '^[0-9]+$' THEN s.id_regiona::INT ELSE NULL END,
    CASE WHEN s.dt_sin_pri ~ '^\\d{4}-\\d{2}-\\d{2}$' THEN s.dt_sin_pri::DATE ELSE NULL END,
    CASE WHEN s.sem_pri ~ '^[0-9]+$' THEN NULLIF(s.sem_pri, '')::INTEGER ELSE NULL END,
    CASE WHEN s.nu_idade_n ~ '^[0-9]+$' THEN s.nu_idade_n::INT ELSE NULL END,
    zika.fn_decodifica_idade(
        CASE WHEN s.nu_idade_n ~ '^[0-9]+$' THEN s.nu_idade_n::INT ELSE NULL END
    ),
    zika.fn_faixa_etaria(
        zika.fn_decodifica_idade(
            CASE WHEN s.nu_idade_n ~ '^[0-9]+$' THEN s.nu_idade_n::INT ELSE NULL END
        )
    ),
    UPPER(CASE WHEN s.cs_sexo ~ '^[MF]$' THEN s.cs_sexo ELSE NULL END),
    CASE WHEN s.cs_gestant ~ '^[0-9]+$' THEN NULLIF(s.cs_gestant, '')::INTEGER ELSE NULL END,
    CASE WHEN s.cs_raca ~ '^[0-9]+$' THEN NULLIF(s.cs_raca, '')::INTEGER ELSE NULL END,
    CASE WHEN s.cs_escol_n ~ '^[0-9]+$' THEN NULLIF(s.cs_escol_n, '')::INTEGER ELSE NULL END,
    CASE WHEN s.sg_uf ~ '^[0-9]+$' THEN NULLIF(s.sg_uf, '')::INTEGER ELSE NULL END,
    -- município residência: usar os primeiros 6 dígitos
    CASE 
        WHEN s.id_mn_resi ~ '^[0-9]+$' THEN 
            CASE 
                WHEN LENGTH(s.id_mn_resi) >= 6 THEN SUBSTRING(s.id_mn_resi, 1, 6)::INT
                ELSE s.id_mn_resi::INT
            END
        ELSE NULL 
    END,
    CASE WHEN s.id_rg_resi ~ '^[0-9]+$' THEN s.id_rg_resi::INT ELSE NULL END,
    CASE WHEN s.id_pais ~ '^[0-9]+$' THEN s.id_pais::INT ELSE NULL END,
    CASE WHEN s.nduplic_n ~ '^[0-9]+$' THEN NULLIF(s.nduplic_n, '')::INTEGER ELSE NULL END,
    CASE WHEN s.in_vincula ~ '^[0-9]+$' THEN NULLIF(s.in_vincula, '')::INTEGER ELSE NULL END,
    CASE WHEN s.dt_invest ~ '^\\d{4}-\\d{2}-\\d{2}$' THEN s.dt_invest::DATE ELSE NULL END,
    CASE WHEN s.id_ocupa_n ~ '^[0-9]+$' THEN s.id_ocupa_n ELSE NULL END,
    CASE WHEN s.classi_fin ~ '^[0-9]+$' THEN NULLIF(s.classi_fin, '')::INTEGER ELSE NULL END,
    CASE WHEN s.criterio ~ '^[0-9]+$' THEN NULLIF(s.criterio, '')::INTEGER ELSE NULL END,
    CASE WHEN s.tpautocto ~ '^[0-9]+$' THEN NULLIF(s.tpautocto, '')::INTEGER ELSE NULL END,
    CASE WHEN s.coufinf ~ '^[0-9]+$' THEN NULLIF(s.coufinf, '')::INTEGER ELSE NULL END,
    CASE WHEN s.copaisinf ~ '^[0-9]+$' THEN s.copaisinf::INT ELSE NULL END,
    -- município infecção: usar os primeiros 6 dígitos
    CASE 
        WHEN s.comuninf ~ '^[0-9]+$' THEN 
            CASE 
                WHEN LENGTH(s.comuninf) >= 6 THEN SUBSTRING(s.comuninf, 1, 6)::INT
                ELSE s.comuninf::INT
            END
        ELSE NULL 
    END,
    CASE WHEN s.doenca_tra ~ '^[0-9]+$' THEN NULLIF(s.doenca_tra, '')::INTEGER ELSE NULL END,
    CASE WHEN s.evolucao ~ '^[0-9]+$' THEN NULLIF(s.evolucao, '')::INTEGER ELSE NULL END,
    CASE WHEN s.dt_obito ~ '^\\d{4}-\\d{2}-\\d{2}$' THEN s.dt_obito::DATE ELSE NULL END,
    CASE WHEN s.dt_encerra ~ '^\\d{4}-\\d{2}-\\d{2}$' THEN s.dt_encerra::DATE ELSE NULL END,
    CASE WHEN s.cs_flxret ~ '^[0-9]+$' THEN NULLIF(s.cs_flxret, '')::INTEGER ELSE NULL END,
    CASE WHEN s.flxrecebi ~ '^[0-9]+$' THEN NULLIF(s.flxrecebi, '')::INTEGER ELSE NULL END,
    CASE WHEN s.tp_sistema ~ '^[0-9]+$' THEN NULLIF(s.tp_sistema, '')::INTEGER ELSE NULL END,
    CASE WHEN s.tpuninot ~ '^[0-9]+$' THEN NULLIF(s.tpuninot, '')::INTEGER ELSE NULL END,
    CASE WHEN s.id_unidade ~ '^[0-9]+$' THEN s.id_unidade::BIGINT ELSE NULL END,
    CASE WHEN s.ano_nasc ~ '^[0-9]{4}$' THEN s.ano_nasc::INTEGER ELSE NULL END,
    CASE WHEN s.dt_digita ~ '^\\d{4}-\\d{2}-\\d{2}$' THEN s.dt_digita::DATE ELSE NULL END
FROM zika.stg_zika_raw s
WHERE s.dt_sin_pri ~ '^\\d{4}-\\d{2}-\\d{2}$'
  AND s.dt_sin_pri IS NOT NULL
  AND s.dt_sin_pri != '';
"""


def migrar_para_fato(conn: psycopg.Connection) -> None:
    log.info("Migrando staging → fato_notificacao (validação clínica desligada)...")
    # Garante idempotência: remove dados anteriores antes de re-inserir
    with conn.cursor() as cur_del:
        cur_del.execute("DELETE FROM zika.fato_notificacao;")
        log.info("fato_notificacao limpa antes da migração.")
    cur = conn.cursor()
    
    # Desativar triggers se existirem
    try:
        cur.execute("CALL zika.sp_desativar_validacao_clinica();")
        log.info("Triggers de validação clínica desativados.")
    except psycopg.errors.UndefinedProcedure:
        log.warning("Procedimento sp_desativar_validacao_clinica não encontrado")
    except Exception as e:
        log.warning(f"Não foi possível desativar triggers: {e}")
    
    t0 = time.time()
    
    # Executar a inserção principal
    cur.execute(SQL_INSERIR_FATO)
    
    log.info("Inseridas %s linhas em fato_notificacao (%.1fs).",
             f"{cur.rowcount:,}", time.time() - t0)
    
    # Reativar triggers
    try:
        cur.execute("CALL zika.sp_ativar_validacao_clinica();")
        log.info("Triggers de validação clínica reativados.")
    except psycopg.errors.UndefinedProcedure:
        log.warning("Procedimento sp_ativar_validacao_clinica não encontrado")
    except Exception as e:
        log.warning(f"Não foi possível reativar triggers: {e}")


def refresh_materialized(conn: psycopg.Connection) -> None:
    log.info("Atualizando materialized view e rodando ANALYZE...")
    cur = conn.cursor()
    try:
        cur.execute("REFRESH MATERIALIZED VIEW CONCURRENTLY zika.mv_serie_semanal_uf;")
        log.info("Materialized view mv_serie_semanal_uf atualizada.")
    except psycopg.errors.UndefinedTable:
        log.warning("Materialized view mv_serie_semanal_uf não encontrada, pulando...")
    except psycopg.errors.FeatureNotSupported:
        log.warning("CONCURRENTLY não suportado, tentando sem...")
        try:
            cur.execute("REFRESH MATERIALIZED VIEW zika.mv_serie_semanal_uf;")
            log.info("Materialized view mv_serie_semanal_uf atualizada (sem CONCURRENTLY).")
        except Exception as e:
            log.warning(f"Não foi possível atualizar MV: {e}")
    cur.execute("ANALYZE zika.fato_notificacao;")
    log.info("ANALYZE concluído.")


# ===========================================================================
# 5. Diagnóstico final
# ===========================================================================

def diagnostico(conn: psycopg.Connection) -> None:
    try:
        cur = conn.cursor()
        cur.execute("""
            SELECT 
                COUNT(*) as total_notificacoes,
                COUNT(DISTINCT cod_mun_notif) as municipios_notificacao,
                COUNT(DISTINCT cod_mun_resi) as municipios_residencia,
                MIN(dt_sintomas) as primeira_data,
                MAX(dt_sintomas) as ultima_data,
                COUNT(CASE WHEN cod_mun_resi IS NULL THEN 1 END) as sem_municipio_resi,
                COUNT(CASE WHEN cod_classificacao = 1 THEN 1 END) as confirmados,
                COUNT(CASE WHEN cod_evolucao = 2 THEN 1 END) as obitos
            FROM zika.fato_notificacao;
        """)
        row = cur.fetchone()
        if row and row[0] > 0:
            log.info("=" * 60)
            log.info("📊 RESUMO DA CARGA")
            log.info("=" * 60)
            log.info("  %-25s %s", "Total notificações:", f"{row[0]:,}")
            log.info("  %-25s %s", "Casos confirmados:", f"{row[6]:,}")
            log.info("  %-25s %s", "Óbitos:", f"{row[7]:,}")
            log.info("  %-25s %s", "Municípios (notificação):", f"{row[1]:,}")
            log.info("  %-25s %s", "Municípios (residência):", f"{row[2]:,}")
            log.info("  %-25s %s", "Sem município residência:", f"{row[5]:,}")
            log.info("  %-25s %s", "Primeira data:", row[3])
            log.info("  %-25s %s", "Última data:", row[4])
            log.info("=" * 60)
        else:
            log.warning("⚠️ Nenhum dado encontrado em fato_notificacao!")
    except Exception as e:
        log.warning(f"Não foi possível obter diagnóstico: {e}")


# ===========================================================================
# Main
# ===========================================================================

def main() -> None:
    ap = argparse.ArgumentParser(description="ETL — Zika BR (SINAN 2018–2026)")
    ap.add_argument("--csv", required=True, help="Caminho para o ZIKA_BR_2018_2026_UNIFICADO.csv")
    ap.add_argument("--dsn", required=True, help="DSN do PostgreSQL")
    ap.add_argument("--sql-dir", default="sql", help="Pasta com os arquivos .sql")
    ap.add_argument("--skip-schema", action="store_true",
                    help="Não executa os arquivos .sql (assume schema pronto)")
    args = ap.parse_args()

    csv_path = Path(args.csv).expanduser().resolve()
    sql_dir  = Path(args.sql_dir).expanduser().resolve()

    if not csv_path.is_file():
        log.error("CSV não encontrado em %s", csv_path)
        sys.exit(1)

    with conexao(args.dsn) as conn:
        if not args.skip_schema:
            criar_estrutura(conn, sql_dir)
        else:
            log.info("Pulei a criação do schema (--skip-schema).")

        carregar_staging(conn, csv_path)
        popular_municipios(conn)
        popular_unidades(conn)
        migrar_para_fato(conn)
        refresh_materialized(conn)
        diagnostico(conn)

    log.info("✅ ETL concluído com sucesso!")


if __name__ == "__main__":
    main()
#!/usr/bin/env python3
"""
Análise estatística epidemiológica — Zika BR (SINAN 2018–2026)
==============================================================
Executa as cinco análises previstas no projeto:

    1. Sazonalidade        — decomposição STL da série semanal nacional.
    2. Tendência por UF    — regressão linear sobre os anos.
    3. Previsão            — Facebook Prophet, horizonte de 52 semanas.
    4. Clustering          — K-Means de municípios por perfil epidemiológico.
    5. Pirâmide etária     — gráfico complementar.

As saídas (PNG + CSV) são gravadas em --out-dir.

Uso:
    python analise_estatistica.py --dsn postgres://... --out-dir output/

Dependências: pandas, numpy, matplotlib, seaborn, statsmodels,
              scikit-learn, prophet, psycopg[binary]
"""
from __future__ import annotations

import argparse
import logging
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import psycopg
import seaborn as sns
from sklearn.cluster import KMeans
from sklearn.metrics import silhouette_score
from sklearn.preprocessing import StandardScaler
from statsmodels.tsa.seasonal import STL

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s  %(levelname)-7s  %(message)s",
                    datefmt="%H:%M:%S")
log = logging.getLogger("analise")

sns.set_theme(style="whitegrid", context="talk")
PALETA = sns.color_palette("crest", 9)


# ===========================================================================
# Conexão e helpers de I/O
# ===========================================================================

def ler_sql(dsn: str, query: str) -> pd.DataFrame:
    with psycopg.connect(dsn) as conn:
        return pd.read_sql_query(query, conn)


def salvar_fig(fig: plt.Figure, out_dir: Path, nome: str) -> None:
    arquivo = out_dir / f"{nome}.png"
    fig.savefig(arquivo, dpi=130, bbox_inches="tight")
    plt.close(fig)
    log.info("→ %s", arquivo.name)


# ===========================================================================
# 1. Sazonalidade — STL na série semanal nacional
# ===========================================================================

def analise_sazonalidade(dsn: str, out_dir: Path) -> pd.DataFrame:
    log.info("[1/5] Sazonalidade — decomposição STL da série semanal nacional")

    df = ler_sql(dsn, """
        SELECT inicio_sem, casos_confirmados
          FROM zika.vw_serie_semanal
         WHERE inicio_sem IS NOT NULL
         ORDER BY inicio_sem;
    """)
    df["inicio_sem"] = pd.to_datetime(df["inicio_sem"])
    # consolida possíveis duplicatas de inicio_sem (ex.: virada de ano)
    df = df.groupby("inicio_sem", as_index=True)["casos_confirmados"].sum()
    serie = df.asfreq("W-MON").fillna(0)

    if len(serie) < 104:
        log.warning("Série muito curta (%d semanas) — STL pode ficar ruim.", len(serie))

    stl = STL(serie, period=52, robust=True).fit()

    fig, axes = plt.subplots(4, 1, figsize=(14, 11), sharex=True)
    axes[0].plot(serie.index, serie.values, color=PALETA[7])
    axes[0].set_ylabel("Observado")
    axes[0].set_title("Decomposição STL — casos confirmados de Zika (semanal, Brasil)",
                      loc="left", fontsize=14, weight="bold")
    axes[1].plot(serie.index, stl.trend, color=PALETA[5])
    axes[1].set_ylabel("Tendência")
    axes[2].plot(serie.index, stl.seasonal, color=PALETA[3])
    axes[2].set_ylabel("Sazonalidade")
    axes[3].plot(serie.index, stl.resid, color=PALETA[1])
    axes[3].set_ylabel("Resíduo")
    axes[3].set_xlabel("Semana epidemiológica")
    fig.tight_layout()
    salvar_fig(fig, out_dir, "01_stl_sazonalidade")

    # Tabela auxiliar com a sazonalidade média por semana do ano
    tabela = (pd.DataFrame({"semana": serie.index.isocalendar().week,
                            "sazonal": stl.seasonal.values})
              .groupby("semana", as_index=False)["sazonal"].mean())
    tabela.to_csv(out_dir / "01_sazonalidade_por_semana.csv", index=False)
    return tabela


# ===========================================================================
# 2. Tendência por UF — regressão linear casos × ano
# ===========================================================================

def analise_tendencia_uf(dsn: str, out_dir: Path) -> pd.DataFrame:
    log.info("[2/5] Tendência por UF — regressão linear sobre os anos")

    df = ler_sql(dsn, """
        SELECT uf, ano, casos_confirmados
          FROM zika.vw_casos_uf_ano
         WHERE ano BETWEEN 2018 AND 2026
         ORDER BY uf, ano;
    """)
    res = []
    for uf, g in df.groupby("uf"):
        if len(g) < 3:
            continue
        x, y = g["ano"].values, g["casos_confirmados"].values
        slope, intercept = np.polyfit(x, y, 1)
        res.append({"uf": uf,
                    "slope_anual": slope,
                    "intercept": intercept,
                    "casos_2018": g.loc[g["ano"] == 2018, "casos_confirmados"].sum(),
                    "casos_2026": g.loc[g["ano"] == 2026, "casos_confirmados"].sum()})

    tend = pd.DataFrame(res).sort_values("slope_anual")
    tend.to_csv(out_dir / "02_tendencia_uf.csv", index=False)

    fig, ax = plt.subplots(figsize=(11, 9))
    cores = ["#c0392b" if s > 0 else "#27ae60" for s in tend["slope_anual"]]
    ax.barh(tend["uf"], tend["slope_anual"], color=cores)
    ax.axvline(0, color="black", lw=1)
    ax.set_xlabel("Variação anual média de casos confirmados\n(coeficiente da regressão linear)")
    ax.set_title("Tendência de casos de Zika por UF (2018–2026)",
                 loc="left", fontsize=15, weight="bold")
    fig.tight_layout()
    salvar_fig(fig, out_dir, "02_tendencia_uf")
    return tend


# ===========================================================================
# 3. Previsão Prophet (horizonte de 52 semanas)
# ===========================================================================

def analise_previsao(dsn: str, out_dir: Path) -> None:
    log.info("[3/5] Previsão — Facebook Prophet, horizonte de 52 semanas")
    try:
        from prophet import Prophet  # importação tardia: lib pesada
    except ImportError:
        log.warning("Prophet não instalado — pulando esta análise.")
        return

    df = ler_sql(dsn, """
        SELECT inicio_sem AS ds, casos_confirmados AS y
          FROM zika.vw_serie_semanal
         WHERE inicio_sem IS NOT NULL
         ORDER BY inicio_sem;
    """)
    df["ds"] = pd.to_datetime(df["ds"])
    df = df.dropna(subset=["ds"])
    df["y"] = df["y"].astype(float)

    m = Prophet(yearly_seasonality=True,
                weekly_seasonality=False,
                daily_seasonality=False,
                seasonality_mode="multiplicative")
    m.fit(df)

    futuro = m.make_future_dataframe(periods=52, freq="W-MON")
    prev = m.predict(futuro)
    prev[["ds", "yhat", "yhat_lower", "yhat_upper"]].to_csv(
        out_dir / "03_prophet_previsao.csv", index=False)

    fig = m.plot(prev, figsize=(14, 6))
    ax = fig.gca()
    ax.set_title("Previsão semanal de casos confirmados de Zika — horizonte 52 semanas",
                 loc="left", fontsize=14, weight="bold")
    ax.set_xlabel("Data")
    ax.set_ylabel("Casos confirmados / semana")
    salvar_fig(fig, out_dir, "03_prophet_previsao")

    fig2 = m.plot_components(prev, figsize=(14, 8))
    salvar_fig(fig2, out_dir, "03_prophet_componentes")


# ===========================================================================
# 4. Clustering K-Means de municípios
# ===========================================================================

def analise_clustering(dsn: str, out_dir: Path, k_max: int = 8) -> pd.DataFrame:
    log.info("[4/5] Clustering K-Means de municípios por perfil epidemiológico")

    df = ler_sql(dsn, """
        SELECT m.cod_municipio,
               m.nome           AS municipio,
               u.sigla          AS uf,
               COUNT(*) FILTER (WHERE f.cod_classificacao = 1)      AS confirmados,
               COUNT(*) FILTER (WHERE f.cod_evolucao = 2)           AS obitos,
               COUNT(*) FILTER (WHERE f.cod_gestante IN (1,2,3,4))  AS gestantes,
               AVG(f.idade_anos)::NUMERIC(6,2)                      AS idade_media,
               COUNT(*)                                             AS notificacoes
          FROM zika.fato_notificacao f
          JOIN zika.dim_municipio m ON m.cod_municipio = f.cod_mun_resi
          JOIN zika.dim_uf        u ON u.cod_uf        = m.cod_uf
         GROUP BY m.cod_municipio, m.nome, u.sigla
        HAVING COUNT(*) >= 30
         ORDER BY notificacoes DESC;
    """)
    log.info("Municípios elegíveis: %d", len(df))
    if len(df) < 10:
        log.warning("Poucos municípios — pulando clustering.")
        return df

    feats = ["confirmados", "obitos", "gestantes", "idade_media", "notificacoes"]
    X = df[feats].astype(float).fillna(0)

    # Escolha do k pelo silhouette
    scaler = StandardScaler()
    Xs = scaler.fit_transform(X)
    melhor_k, melhor_s = None, -1
    scores = []
    for k in range(2, k_max + 1):
        km = KMeans(n_clusters=k, n_init=10, random_state=42).fit(Xs)
        s = silhouette_score(Xs, km.labels_)
        scores.append({"k": k, "silhouette": s})
        if s > melhor_s:
            melhor_k, melhor_s = k, s
    log.info("Melhor k = %d (silhouette = %.3f)", melhor_k, melhor_s)

    km = KMeans(n_clusters=melhor_k, n_init=10, random_state=42).fit(Xs)
    df["cluster"] = km.labels_
    df.to_csv(out_dir / "04_kmeans_municipios.csv", index=False)

    # Centróides interpretáveis
    centroides = pd.DataFrame(
        scaler.inverse_transform(km.cluster_centers_), columns=feats
    ).round(1)
    centroides.index.name = "cluster"
    centroides.to_csv(out_dir / "04_kmeans_centroides.csv")

    # Heatmap dos centróides
    fig, ax = plt.subplots(figsize=(10, 0.7 * melhor_k + 2))
    sns.heatmap(
        StandardScaler().fit_transform(centroides),
        annot=centroides.values,
        fmt=".0f",
        cmap="crest",
        cbar=False,
        xticklabels=feats,
        yticklabels=[f"Cluster {i}" for i in centroides.index],
        ax=ax,
    )
    ax.set_title("Perfis de municípios — centróides K-Means",
                 loc="left", fontsize=14, weight="bold")
    fig.tight_layout()
    salvar_fig(fig, out_dir, "04_kmeans_centroides")

    # Silhouette por k
    fig, ax = plt.subplots(figsize=(8, 5))
    sdf = pd.DataFrame(scores)
    ax.plot(sdf["k"], sdf["silhouette"], marker="o", color=PALETA[6])
    ax.axvline(melhor_k, color="red", ls="--", alpha=.5,
               label=f"melhor k = {melhor_k}")
    ax.set_xlabel("Número de clusters (k)")
    ax.set_ylabel("Silhouette score")
    ax.legend()
    ax.set_title("Escolha do k — método silhouette", loc="left", weight="bold")
    fig.tight_layout()
    salvar_fig(fig, out_dir, "04_silhouette")

    return df


# ===========================================================================
# 5. Pirâmide etária (complementar)
# ===========================================================================

def analise_piramide(dsn: str, out_dir: Path) -> None:
    log.info("[5/5] Pirâmide etária — confirmados acumulados")

    df = ler_sql(dsn, """
        SELECT faixa_etaria, sexo, SUM(casos_confirmados) AS n
          FROM zika.vw_piramide_etaria
         WHERE faixa_etaria <> 'Ignorada'
         GROUP BY faixa_etaria, sexo;
    """)
    if df.empty:
        log.warning("Sem dados para pirâmide.")
        return

    ordem = ['<1 ano','1-4','5-9','10-14','15-19','20-29','30-39',
             '40-49','50-59','60-69','70-79','80+']
    df["faixa_etaria"] = pd.Categorical(df["faixa_etaria"], categories=ordem, ordered=True)
    p = df.pivot(index="faixa_etaria", columns="sexo", values="n").fillna(0).sort_index()

    fig, ax = plt.subplots(figsize=(10, 7))
    ax.barh(p.index.astype(str), -p.get("Masculino", 0), color="#2980b9", label="Masculino")
    ax.barh(p.index.astype(str),  p.get("Feminino",  0), color="#c0392b", label="Feminino")
    ax.set_xlabel("Casos confirmados")
    ax.set_title("Pirâmide etária — casos confirmados de Zika (Brasil, 2018–2026)",
                 loc="left", fontsize=14, weight="bold")
    ax.axvline(0, color="black", lw=0.5)
    ticks = ax.get_xticks()
    ax.set_xticks(ticks)
    ax.set_xticklabels([f"{abs(int(t)):,}" for t in ticks])
    ax.legend()
    fig.tight_layout()
    salvar_fig(fig, out_dir, "05_piramide_etaria")


# ===========================================================================
# Main
# ===========================================================================

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", required=True, help="DSN PostgreSQL")
    ap.add_argument("--out-dir", default="output", help="Pasta de saída")
    args = ap.parse_args()

    out_dir = Path(args.out_dir).expanduser().resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    analise_sazonalidade(args.dsn, out_dir)
    analise_tendencia_uf(args.dsn, out_dir)
    analise_previsao(args.dsn, out_dir)
    analise_clustering(args.dsn, out_dir)
    analise_piramide(args.dsn, out_dir)

    log.info("Análises concluídas. Resultados em %s", out_dir)


if __name__ == "__main__":
    main()

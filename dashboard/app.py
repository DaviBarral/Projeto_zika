from __future__ import annotations

import os
from pathlib import Path

import pandas as pd
import plotly.express as px
import plotly.graph_objects as go
import psycopg
import streamlit as st

# ---------------------------------------------------------------------------
# Configuração da página
# ---------------------------------------------------------------------------
st.set_page_config(
    page_title="Zika BR · SINAN 2018–2026",
    layout="wide",
    initial_sidebar_state="expanded",
    page_icon="🦟",
)

# CSS customizado — tema epidemiológico escuro
st.markdown("""
<style>
  /* Fundo geral */
  .stApp { background-color: #0d1117; color: #e6edf3; }
  
  /* Cards de KPI */
  [data-testid="metric-container"] {
    background: linear-gradient(135deg, #161b22 0%, #1c2128 100%);
    border: 1px solid #30363d;
    border-radius: 12px;
    padding: 16px 20px;
    box-shadow: 0 4px 12px rgba(0,0,0,0.4);
  }
  [data-testid="stMetricLabel"] { font-size: 0.78rem; color: #8b949e; font-weight: 600; letter-spacing: 0.05em; text-transform: uppercase; }
  [data-testid="stMetricValue"] { font-size: 2rem; font-weight: 700; color: #58a6ff; }
  [data-testid="stMetricDelta"] { font-size: 0.85rem; }

  /* Sidebar */
  [data-testid="stSidebar"] { background: #161b22; border-right: 1px solid #30363d; }
  
  /* Tabs */
  .stTabs [data-baseweb="tab-list"] { background: #161b22; border-radius: 8px; gap: 4px; }
  .stTabs [data-baseweb="tab"] { color: #8b949e; border-radius: 6px; }
  .stTabs [data-baseweb="tab"][aria-selected="true"] { background: #238636; color: #fff; }

  /* Título principal */
  h1 { color: #58a6ff !important; border-bottom: 2px solid #238636; padding-bottom: 8px; }
  h2, h3 { color: #79c0ff !important; }

  /* Linha divisória */
  hr { border-color: #30363d; }
  
  /* Alerta / info */
  .stAlert { border-radius: 8px; }
  
  /* Rodapé */
  .rodape { text-align:center; color:#484f58; font-size:0.75rem; margin-top:40px; padding-top:16px; border-top:1px solid #30363d; }
</style>
""", unsafe_allow_html=True)

# ---------------------------------------------------------------------------
# Conexão com o banco
# ---------------------------------------------------------------------------
DSN = os.environ.get("ZIKA_DSN", "postgresql://postgres:postgres@localhost:5432/zika")
OUTPUT_DIR = Path(os.environ.get("ZIKA_OUTPUT", "./output"))


def _nova_conexao():
    return psycopg.connect(DSN, connect_timeout=10)


@st.cache_data(ttl=600, show_spinner=False)
def ler(query: str, params: tuple | None = None) -> pd.DataFrame:
    try:
        with psycopg.connect(DSN) as c:
            return pd.read_sql_query(query, c, params=params)
    except Exception as e:
        st.error(f"❌ Erro ao consultar o banco: {e}")
        return pd.DataFrame()


# ---------------------------------------------------------------------------
# Sidebar — filtros globais
# ---------------------------------------------------------------------------
with st.sidebar:
    st.markdown("## 🦟 Zika BR")
    st.caption("SINAN · DataSUS · 2018–2026")
    st.markdown("---")

    ufs_df = ler("SELECT sigla, nome FROM zika.dim_uf ORDER BY sigla")
    if not ufs_df.empty:
        uf_sel = st.multiselect(
            "🗺️ UF de residência",
            ufs_df["sigla"].tolist(),
            placeholder="Todas as UFs",
        )
    else:
        uf_sel = []

    ano_min, ano_max = st.slider("📅 Período (ano)", 2018, 2026, (2018, 2026))

    apenas_confirmados = st.toggle("✅ Apenas casos confirmados", value=False)

    st.markdown("---")
    st.caption("💡 Casos confirmados = `CLASSI_FIN = 1`")
    st.caption("📊 Fonte: SINAN/DataSUS")

# Helpers de filtro SQL
filtro_uf_col  = f"AND uf IN ({','.join([repr(u) for u in uf_sel])})"   if uf_sel else ""
filtro_uf_col2 = f"AND u.sigla IN ({','.join([repr(u) for u in uf_sel])})" if uf_sel else ""
col_casos = "casos_confirmados" if apenas_confirmados else "casos_total"

# ---------------------------------------------------------------------------
# Cabeçalho
# ---------------------------------------------------------------------------
st.title("Painel Epidemiológico · Zika no Brasil")
st.caption("Vigilância nacional · período 2018–2026 · base SINAN unificada · SINAN/DataSUS")

# ---------------------------------------------------------------------------
# KPIs
# ---------------------------------------------------------------------------
kpis = ler("SELECT * FROM zika.vw_kpis")

if not kpis.empty:
    k = kpis.iloc[0]
    c1, c2, c3, c4, c5, c6 = st.columns(6)
    c1.metric("📋 Notificações",  f"{int(k['total_notificacoes']):,}".replace(",", "."))
    c2.metric("✅ Confirmados",   f"{int(k['total_confirmados']):,}".replace(",", "."),
              f"{k['taxa_confirmacao_pct']} % taxa")
    c3.metric("💀 Óbitos",        f"{int(k['total_obitos']):,}".replace(",", "."),
              f"{k['letalidade_pct']} % letalidade")
    c4.metric("🤰 Gestantes",     f"{int(k['gestantes_confirmadas']):,}".replace(",", "."))
    c5.metric("🏙️ Municípios",    f"{int(k['municipios_afetados']):,}".replace(",", "."))
    c6.metric("🗺️ UFs afetadas",  f"{int(k['ufs_afetadas'])}",
              f"{k['dt_inicio']} → {k['dt_fim']}")

st.markdown("---")

# ---------------------------------------------------------------------------
# Tabs principais
# ---------------------------------------------------------------------------
tab1, tab2, tab3, tab4, tab5, tab6 = st.tabs([
    "📈 Série Temporal",
    "🗺️ Mapa por UF",
    "👥 Pirâmide Etária",
    "🤰 Gestantes",
    "🔮 Previsão",
    "🔍 Qualidade dos Dados",
])

# ==========================================================================
# TAB 1: Série Temporal
# ==========================================================================
with tab1:
    st.subheader("Curva Epidêmica Semanal")
    st.caption("Baseada na data dos primeiros sintomas (DT_SIN_PRI) — mais precisa epidemiologicamente")

    df_serie = ler(f"""
        SELECT * FROM zika.vw_serie_semanal_uf
         WHERE ano BETWEEN %s AND %s {filtro_uf_col}
    """, (ano_min, ano_max))

    if df_serie.empty:
        st.info("Sem dados para os filtros escolhidos.")
    else:
        # Curva Brasil (agregada)
        agg = (df_serie.groupby("inicio_sem", as_index=False)[col_casos]
               .sum().rename(columns={col_casos: "casos"}))
        fig1 = px.area(
            agg, x="inicio_sem", y="casos",
            title="Brasil — casos por semana epidemiológica",
            labels={"inicio_sem": "Semana", "casos": "Casos"},
            color_discrete_sequence=["#58a6ff"],
            template="plotly_dark",
        )
        fig1.update_traces(fill="tozeroy", line_width=1.5)
        fig1.update_layout(height=380, paper_bgcolor="#0d1117", plot_bgcolor="#0d1117",
                           xaxis=dict(gridcolor="#21262d"), yaxis=dict(gridcolor="#21262d"))
        st.plotly_chart(fig1, use_container_width=True)

        # Por UF
        if uf_sel or st.checkbox("Mostrar curvas por UF", value=False):
            top_ufs = (df_serie.groupby("uf")[col_casos].sum()
                       .nlargest(10).index.tolist())
            df_top = df_serie[df_serie["uf"].isin(top_ufs)]
            fig2 = px.line(
                df_top, x="inicio_sem", y=col_casos, color="uf",
                title="Curva epidêmica por UF (Top 10)",
                labels={"inicio_sem": "Semana", col_casos: "Casos", "uf": "UF"},
                template="plotly_dark",
            )
            fig2.update_layout(height=430, paper_bgcolor="#0d1117", plot_bgcolor="#0d1117",
                               xaxis=dict(gridcolor="#21262d"), yaxis=dict(gridcolor="#21262d"))
            st.plotly_chart(fig2, use_container_width=True)

        # Sazonalidade por ano
        st.subheader("Sazonalidade — casos por semana do ano")
        pivot_saz = (df_serie.groupby(["ano", "semana_epi"])[col_casos]
                     .sum().reset_index())
        fig3 = px.line(
            pivot_saz, x="semana_epi", y=col_casos, color=pivot_saz["ano"].astype(str),
            title="Perfil sazonal por ano",
            labels={"semana_epi": "Semana epidemiológica", col_casos: "Casos", "color": "Ano"},
            template="plotly_dark",
        )
        fig3.update_layout(height=380, paper_bgcolor="#0d1117", plot_bgcolor="#0d1117",
                           xaxis=dict(gridcolor="#21262d"), yaxis=dict(gridcolor="#21262d"))
        st.plotly_chart(fig3, use_container_width=True)

# ==========================================================================
# TAB 2: Mapa por UF
# ==========================================================================
with tab2:
    st.subheader("Distribuição Geográfica por UF")

    df_uf = ler(f"""
        SELECT * FROM zika.vw_casos_uf_ano
         WHERE ano BETWEEN %s AND %s {filtro_uf_col}
    """, (ano_min, ano_max))

    if df_uf.empty:
        st.info("Sem dados.")
    else:
        df_uf_agg = (df_uf.groupby(["cod_uf", "uf", "uf_nome", "regiao"], as_index=False)
                     [[col_casos, "obitos", "taxa_confirmacao_pct"]].sum())

        # Mapa coroplético Brasil (GeoJSON simplificado por sigla)
        fig_map = px.choropleth(
            df_uf_agg,
            geojson="https://raw.githubusercontent.com/codeforamerica/click_that_hood/master/public/data/brazil-states.geojson",
            locations="uf",
            featureidkey="properties.sigla",
            color=col_casos,
            color_continuous_scale="Reds",
            hover_name="uf_nome",
            hover_data={col_casos: True, "obitos": True, "taxa_confirmacao_pct": True},
            title=f"Casos {'confirmados' if apenas_confirmados else 'totais'} por UF ({ano_min}–{ano_max})",
            template="plotly_dark",
        )
        fig_map.update_geos(
            fitbounds="locations", visible=False,
            bgcolor="#0d1117",
        )
        fig_map.update_layout(height=550, paper_bgcolor="#0d1117",
                               coloraxis_colorbar=dict(title="Casos"))
        st.plotly_chart(fig_map, use_container_width=True)

        # Heatmap UF × Ano
        st.subheader("Heatmap — UF × Ano")
        piv = df_uf.pivot_table(index="uf", columns="ano", values=col_casos, aggfunc="sum").fillna(0)
        fig_heat = px.imshow(
            piv, text_auto=".0f", aspect="auto",
            color_continuous_scale="YlOrRd",
            title="Casos por UF e Ano",
            template="plotly_dark",
        )
        fig_heat.update_layout(height=650, paper_bgcolor="#0d1117")
        st.plotly_chart(fig_heat, use_container_width=True)

        # Ranking
        col_r1, col_r2 = st.columns([2, 1])
        with col_r1:
            st.subheader("Ranking de UFs")
            rank = (df_uf_agg.sort_values(col_casos, ascending=False)
                    [["uf", "uf_nome", "regiao", col_casos, "obitos", "taxa_confirmacao_pct"]]
                    .reset_index(drop=True))
            rank.index += 1
            st.dataframe(rank, use_container_width=True)
        with col_r2:
            fig_pie = px.pie(
                df_uf_agg.nlargest(8, col_casos),
                names="uf", values=col_casos,
                title="Top 8 UFs",
                template="plotly_dark",
                hole=0.45,
            )
            fig_pie.update_layout(paper_bgcolor="#0d1117", height=380)
            st.plotly_chart(fig_pie, use_container_width=True)

# ==========================================================================
# TAB 3: Pirâmide Etária
# ==========================================================================
with tab3:
    st.subheader("Pirâmide Etária — Casos por Faixa e Sexo")

    df_pir = ler(f"""
        SELECT * FROM zika.vw_piramide_etaria
         WHERE ano BETWEEN %s AND %s
    """, (ano_min, ano_max))

    if df_pir.empty:
        st.info("Sem dados.")
    else:
        col_pir = "casos_confirmados" if apenas_confirmados else "casos_total"
        p = df_pir.groupby(["faixa_etaria", "sexo"], as_index=False)[col_pir].sum()

        ordem = ['<1 ano','1-4','5-9','10-14','15-19','20-29',
                 '30-39','40-49','50-59','60-69','70-79','80+']
        p["faixa_etaria"] = pd.Categorical(p["faixa_etaria"], categories=ordem, ordered=True)
        p = p.sort_values("faixa_etaria")
        p_plot = p.copy()
        p_plot.loc[p_plot["sexo"] == "Masculino", col_pir] *= -1

        fig_pir = px.bar(
            p_plot, x=col_pir, y="faixa_etaria", color="sexo",
            orientation="h",
            title="Pirâmide Etária — Casos de Zika",
            color_discrete_map={"Masculino": "#388bfd", "Feminino": "#f78166"},
            template="plotly_dark",
            labels={col_pir: "← Masculino | Feminino →", "faixa_etaria": "Faixa etária"},
        )
        fig_pir.update_layout(
            height=540, paper_bgcolor="#0d1117", plot_bgcolor="#0d1117",
            xaxis=dict(gridcolor="#21262d",
                       tickvals=[-5000, -2500, 0, 2500, 5000],
                       ticktext=["5k", "2.5k", "0", "2.5k", "5k"]),
            yaxis=dict(gridcolor="#21262d"),
            bargap=0.15,
        )
        st.plotly_chart(fig_pir, use_container_width=True)

        # Perfil sociodemográfico
        st.subheader("Perfil por Raça/Cor e Escolaridade")
        df_dem = ler(f"""
            SELECT * FROM zika.vw_perfil_demografico
             WHERE ano BETWEEN %s AND %s
        """, (ano_min, ano_max))
        if not df_dem.empty:
            col_dem = "confirmados" if apenas_confirmados else "notificados"
            c1d, c2d = st.columns(2)
            with c1d:
                raca = df_dem.groupby("raca_cor", as_index=False)[col_dem].sum()
                fig_r = px.bar(raca.sort_values(col_dem, ascending=True),
                               x=col_dem, y="raca_cor", orientation="h",
                               title="Por Raça/Cor", template="plotly_dark",
                               color_discrete_sequence=["#3fb950"])
                fig_r.update_layout(paper_bgcolor="#0d1117", plot_bgcolor="#0d1117", height=320)
                st.plotly_chart(fig_r, use_container_width=True)
            with c2d:
                esc = df_dem.groupby("escolaridade", as_index=False)[col_dem].sum()
                fig_e = px.bar(esc.sort_values(col_dem, ascending=True),
                               x=col_dem, y="escolaridade", orientation="h",
                               title="Por Escolaridade", template="plotly_dark",
                               color_discrete_sequence=["#d29922"])
                fig_e.update_layout(paper_bgcolor="#0d1117", plot_bgcolor="#0d1117", height=320)
                st.plotly_chart(fig_e, use_container_width=True)

# ==========================================================================
# TAB 4: Gestantes
# ==========================================================================
with tab4:
    st.subheader("🤰 Vigilância de Gestantes")
    st.caption("Foco epidemiológico crítico: risco de síndrome congênita do Zika")

    df_gest = ler(f"""
        SELECT * FROM zika.vw_gestantes
         WHERE ano BETWEEN %s AND %s {filtro_uf_col}
    """, (ano_min, ano_max))

    if df_gest.empty:
        st.info("Sem dados para os filtros escolhidos.")
    else:
        total_gest = df_gest["gestantes_confirmadas"].sum()
        total_noti = df_gest["gestantes_notificadas"].sum()
        obitos_g   = df_gest["obitos"].sum()

        g1, g2, g3 = st.columns(3)
        g1.metric("Gestantes notificadas", f"{int(total_noti):,}".replace(",", "."))
        g2.metric("Gestantes confirmadas", f"{int(total_gest):,}".replace(",", "."),
                  f"{100*total_gest/max(total_noti,1):.1f} % taxa")
        g3.metric("Óbitos em gestantes",   f"{int(obitos_g)}")

        st.markdown("---")

        # Barras por trimestre e ano
        fig_g1 = px.bar(
            df_gest, x="ano", y="gestantes_confirmadas", color="trimestre",
            barmode="stack",
            title="Gestantes confirmadas por ano e trimestre gestacional",
            template="plotly_dark",
            color_discrete_sequence=px.colors.qualitative.Safe,
        )
        fig_g1.update_layout(paper_bgcolor="#0d1117", plot_bgcolor="#0d1117",
                              xaxis=dict(gridcolor="#21262d"), yaxis=dict(gridcolor="#21262d"),
                              height=400)
        st.plotly_chart(fig_g1, use_container_width=True)

        # Por UF
        if not df_gest.empty and "uf" in df_gest.columns:
            top_uf_g = (df_gest.groupby("uf", as_index=False)["gestantes_confirmadas"]
                        .sum().nlargest(15, "gestantes_confirmadas"))
            fig_g2 = px.bar(
                top_uf_g.sort_values("gestantes_confirmadas"),
                x="gestantes_confirmadas", y="uf", orientation="h",
                title="Top 15 UFs — gestantes confirmadas",
                template="plotly_dark",
                color_discrete_sequence=["#f78166"],
            )
            fig_g2.update_layout(paper_bgcolor="#0d1117", plot_bgcolor="#0d1117", height=420)
            st.plotly_chart(fig_g2, use_container_width=True)

        st.dataframe(df_gest.sort_values("gestantes_confirmadas", ascending=False),
                     use_container_width=True, hide_index=True)

# ==========================================================================
# TAB 5: Previsão Prophet
# ==========================================================================
with tab5:
    st.subheader("🔮 Previsão de Casos — Facebook Prophet")
    st.caption("Modelo treinado na série semanal nacional de casos confirmados")

    imgs = list(OUTPUT_DIR.glob("03_prophet_*.png")) if OUTPUT_DIR.exists() else []
    if imgs:
        for img in sorted(imgs):
            st.image(str(img), use_column_width=True,
                     caption=img.stem.replace("_", " ").title())
    else:
        st.info(f"Imagens de previsão não encontradas em `{OUTPUT_DIR}`.\n\n"
                "Execute primeiro:\n```bash\npython python/analise_estatistica.py --dsn $ZIKA_DSN --out-dir output/\n```")

    # CSV de previsão
    csv_prev = OUTPUT_DIR / "03_prophet_previsao.csv" if OUTPUT_DIR.exists() else None
    if csv_prev and csv_prev.exists():
        df_prev = pd.read_csv(csv_prev)
        st.subheader("Tabela de Previsão (próximas 52 semanas)")
        fig_prev = px.line(
            df_prev, x="ds", y=["yhat", "yhat_lower", "yhat_upper"],
            title="Previsão semanal com intervalo de confiança",
            template="plotly_dark",
            labels={"ds": "Data", "value": "Casos", "variable": ""},
        )
        fig_prev.update_layout(paper_bgcolor="#0d1117", plot_bgcolor="#0d1117", height=380)
        st.plotly_chart(fig_prev, use_container_width=True)
        st.dataframe(df_prev.tail(52), use_container_width=True, hide_index=True)

    # STL sazonalidade
    img_stl = OUTPUT_DIR / "01_stl_sazonalidade.png" if OUTPUT_DIR.exists() else None
    if img_stl and img_stl.exists():
        st.subheader("Decomposição STL — Sazonalidade")
        st.image(str(img_stl), use_column_width=True)

# ==========================================================================
# TAB 6: Qualidade dos Dados
# ==========================================================================
with tab6:
    st.subheader("🔍 Completude dos Campos Críticos")

    df_comp = ler("SELECT * FROM zika.vw_completude ORDER BY ano")
    if not df_comp.empty:
        pct_cols = [c for c in df_comp.columns if c.endswith("_pct")]
        fig_comp = px.line(
            df_comp.melt(id_vars="ano", value_vars=pct_cols),
            x="ano", y="value", color="variable",
            title="Evolução da completude por ano (%)",
            labels={"ano": "Ano", "value": "Completude (%)", "variable": "Campo"},
            template="plotly_dark",
            markers=True,
        )
        fig_comp.add_hline(y=80, line_dash="dash", line_color="#f85149",
                           annotation_text="Meta 80%", annotation_position="bottom right")
        fig_comp.update_layout(paper_bgcolor="#0d1117", plot_bgcolor="#0d1117",
                                xaxis=dict(gridcolor="#21262d"), yaxis=dict(gridcolor="#21262d"),
                                height=420)
        st.plotly_chart(fig_comp, use_container_width=True)
        st.dataframe(df_comp, use_container_width=True, hide_index=True)

    st.subheader("Latência de Notificação (dias: sintomas → notificação)")
    df_lat = ler(f"SELECT * FROM zika.vw_latencia_notificacao WHERE 1=1 {filtro_uf_col} ORDER BY ano, uf")
    if not df_lat.empty:
        fig_lat = px.box(
            df_lat, x="ano", y="latencia_media_dias",
            title="Latência média de notificação por ano",
            template="plotly_dark",
            color_discrete_sequence=["#388bfd"],
        )
        fig_lat.update_layout(paper_bgcolor="#0d1117", plot_bgcolor="#0d1117", height=360)
        st.plotly_chart(fig_lat, use_container_width=True)
        st.dataframe(df_lat, use_container_width=True, hide_index=True)

    # Duplicatas
    st.subheader("Detecção de Duplicatas")
    if st.button("🔍 Verificar duplicatas no banco"):
        df_dup = ler("SELECT * FROM zika.fn_detectar_duplicatas() LIMIT 20")
        if df_dup.empty:
            st.success("✅ Nenhuma duplicata detectada.")
        else:
            st.warning(f"⚠️ {len(df_dup)} grupos de possíveis duplicatas encontrados.")
            st.dataframe(df_dup, use_container_width=True, hide_index=True)

# ---------------------------------------------------------------------------
# Rodapé
# ---------------------------------------------------------------------------
st.markdown("""
<div class="rodape">
  🦟 Zika BR · SINAN/DataSUS 2018–2026 · Desenvolvido para disciplina de Banco de Dados e Análise Epidemiológica<br>
  PostgreSQL 15+ · Python 3.10+ · Streamlit · Plotly
</div>
""", unsafe_allow_html=True)

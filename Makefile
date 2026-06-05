# =====================================================================
#  Makefile — Projeto Zika BR
#  Use `make help` para a lista de alvos.
# =====================================================================
SHELL := /bin/bash

DSN     ?= postgresql://postgres:postgres@localhost:5432/zika
CSV     ?= ./data/ZIKA_BR_2018_2026_UNIFICADO.csv
PYTHON  ?= python3
PIP     ?= pip3

.PHONY: help install db etl analise dashboard test clean fmt

help:
	@echo ""
	@echo "Alvos disponíveis:"
	@echo "  install     — instala dependências Python"
	@echo "  db          — executa apenas os .sql (schema + seed + funções + triggers + views)"
	@echo "  etl         — roda o ETL completo (CSV → PostgreSQL)"
	@echo "  analise     — gera todos os PNG/CSV em ./output"
	@echo "  dashboard   — sobe o Streamlit em http://localhost:8501"
	@echo "  test        — testes rápidos das funções SQL"
	@echo "  clean       — remove artefatos gerados"
	@echo ""
	@echo "Variáveis: DSN=$(DSN)   CSV=$(CSV)"
	@echo ""

install:
	$(PIP) install -r python/requirements.txt

db:
	psql "$(DSN)" -v ON_ERROR_STOP=1 -f sql/01_schema.sql
	psql "$(DSN)" -v ON_ERROR_STOP=1 -f sql/02_seed_dimensoes.sql
	psql "$(DSN)" -v ON_ERROR_STOP=1 -f sql/03_funcoes.sql
	psql "$(DSN)" -v ON_ERROR_STOP=1 -f sql/04_triggers.sql
	psql "$(DSN)" -v ON_ERROR_STOP=1 -f sql/05_views.sql

etl:
	$(PYTHON) python/etl_load.py --csv "$(CSV)" --dsn "$(DSN)" --sql-dir sql

etl-skip-schema:
	$(PYTHON) python/etl_load.py --csv "$(CSV)" --dsn "$(DSN)" --sql-dir sql --skip-schema

analise:
	$(PYTHON) python/analise_estatistica.py --dsn "$(DSN)" --out-dir output

dashboard:
	ZIKA_DSN="$(DSN)" streamlit run dashboard/app.py

test:
	psql "$(DSN)" -v ON_ERROR_STOP=1 -f sql/99_testes.sql

clean:
	rm -rf output/*.png output/*.csv

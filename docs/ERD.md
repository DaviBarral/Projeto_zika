# Diagrama Entidade-Relacionamento — Base Zika BR

Modelo em estrela com a tabela `fato_notificacao` no centro, dimensões geográficas
(UF, município), categóricas (sexo, raça, escolaridade, gestante, classificação,
critério, evolução, autoctonia) e a tabela `aud_log` de auditoria transversal.

```mermaid
erDiagram
    dim_uf {
        smallint cod_uf PK
        char(2)  sigla
        varchar  nome
        varchar  regiao
    }

    dim_municipio {
        int      cod_municipio PK
        varchar  nome
        smallint cod_uf FK
    }

    dim_sexo {
        char(1) cod PK
        varchar descricao
    }
    dim_raca {
        smallint cod PK
        varchar  descricao
    }
    dim_escolaridade {
        smallint cod PK
        varchar  descricao
    }
    dim_gestante {
        smallint cod PK
        varchar  descricao
    }
    dim_classificacao {
        smallint cod PK
        varchar  descricao
    }
    dim_criterio {
        smallint cod PK
        varchar  descricao
    }
    dim_evolucao {
        smallint cod PK
        varchar  descricao
    }
    dim_autoctonia {
        smallint cod PK
        varchar  descricao
    }
    dim_unidade_saude {
        bigint   cod_cnes PK
        varchar  nome
        varchar  tipo
        int      cod_municipio FK
    }

    fato_notificacao {
        bigserial id_notif PK
        varchar   arquivo_origem
        smallint  ano_arquivo
        varchar   id_agravo
        date      dt_notificacao
        date      dt_sintomas
        date      dt_obito
        smallint  cod_uf_notif FK
        int       cod_mun_notif FK
        smallint  cod_uf_resi FK
        int       cod_mun_resi FK
        smallint  cod_uf_infec FK
        int       cod_mun_infec FK
        smallint  cod_autoctonia FK
        char(1)   cod_sexo FK
        smallint  cod_gestante FK
        smallint  cod_raca FK
        smallint  cod_escolaridade FK
        smallint  cod_classificacao FK
        smallint  cod_criterio FK
        smallint  cod_evolucao FK
        bigint    cod_cnes_unidade FK
        numeric   idade_anos
        varchar   faixa_etaria
    }

    aud_log {
        bigserial   id_aud PK
        varchar     tabela
        char(1)     operacao
        text        pk_alvo
        jsonb       dados_antes
        jsonb       dados_depois
        jsonb       diff
        timestamptz momento
    }

    dim_uf            ||--o{ dim_municipio       : "contém"
    dim_uf            ||--o{ fato_notificacao    : "UF notif/resi/infec"
    dim_municipio     ||--o{ fato_notificacao    : "município notif/resi/infec"
    dim_municipio     ||--o{ dim_unidade_saude   : "abriga"
    dim_sexo          ||--o{ fato_notificacao    : "sexo"
    dim_raca          ||--o{ fato_notificacao    : "raça/cor"
    dim_escolaridade  ||--o{ fato_notificacao    : "escolaridade"
    dim_gestante      ||--o{ fato_notificacao    : "gestação"
    dim_classificacao ||--o{ fato_notificacao    : "classificação final"
    dim_criterio      ||--o{ fato_notificacao    : "critério"
    dim_evolucao      ||--o{ fato_notificacao    : "evolução"
    dim_autoctonia    ||--o{ fato_notificacao    : "autoctonia"
    dim_unidade_saude ||--o{ fato_notificacao    : "unidade notif"
    fato_notificacao  ||--o{ aud_log             : "audita"
```

## Convenções

- **PK = Primary Key**, **FK = Foreign Key**.
- Toda dimensão categórica usa um código (`cod`) curto e uma `descricao` textual.
- A `fato_notificacao` se relaciona **três vezes** com `dim_uf` e três vezes com
  `dim_municipio`, refletindo notificação, residência e local provável de infecção
  — uma distinção crítica do SINAN.
- `aud_log` é uma tabela transversal, alimentada por triggers em todas as tabelas
  críticas. O snapshot anterior e posterior é armazenado em `JSONB`.

## Cardinalidades

| Relação | Cardinalidade |
|---|---|
| `dim_uf` → `dim_municipio` | 1 : N |
| `dim_uf` → `fato_notificacao` | 1 : N (×3: notif / resi / infec) |
| `dim_municipio` → `fato_notificacao` | 1 : N (×3) |
| Dimensões categóricas → `fato_notificacao` | 1 : N |
| `fato_notificacao` → `aud_log` | 1 : N (uma linha por DML) |

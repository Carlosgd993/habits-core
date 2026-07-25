# habits-core

Esquema, vistas y funciones de la base de datos del ecosistema personal.

Este repositorio es la **dependencia compartida** de todos los clientes
(Stream Deck, PWA, app NFC, bot de Telegram, agente). Ninguno de ellos contiene
lógica de negocio: la lógica vive aquí, dentro de Postgres.

## La regla

> Ningún cliente hace `SELECT` sobre una tabla, ni `INSERT` / `UPDATE` /
> `DELETE` directo. Solo vistas y funciones.

No es una convención: RLS lo hace imposible. Ver
[`docs/contrato.md`](docs/contrato.md).

## Puesta en marcha

```bash
npm install -g supabase          # o brew install supabase/tap/supabase
supabase init                    # genera supabase/config.toml
supabase link --project-ref <ref>
supabase db push                 # aplica las migraciones al proyecto cloud
```

`supabase init` crea `supabase/config.toml`; las migraciones de este repo ya
están en `supabase/migrations/`.

## Verificación tras aplicar

Estas cuatro comprobaciones son el criterio de "ha funcionado". Hazlas con la
clave **anon**, no con la de servicio.

```http
### 1. La vista responde
GET {{url}}/rest/v1/v_today_habits?select=*
apikey: {{anon}}

### 2. La tabla NO responde  (debe dar 401/403 o lista vacía)
GET {{url}}/rest/v1/habits?select=*
apikey: {{anon}}

### 3. La escritura directa NO funciona  (debe fallar)
POST {{url}}/rest/v1/habit_checkins
apikey: {{anon}}
Content-Type: application/json

{ "habit_id": "<id>", "checkin_date": "2026-07-24", "value": 1 }

### 4. La función SÍ funciona
POST {{url}}/rest/v1/rpc/habit_step
apikey: {{anon}}
Content-Type: application/json

{ "p_habit_id": "<id>" }
```

Si la 2 o la 3 tienen éxito, el contrato no está cerrado: revisa los `revoke`
de `20260724120300_rls_contract.sql`.

## Estructura del repositorio

```
.
├── docs/
│   └── contrato.md              # el contrato de lectura/escritura para los clientes
└── supabase/
    └── migrations/
        ├── 20260724120000_time_and_status.sql   # app_today() + statuses.is_done
        ├── 20260724120100_views_today.sql        # v_today_habits, v_today_tasks
        ├── 20260724120200_rpc_write.sql           # habit_step/set/undo, (un)complete_task
        └── 20260724120300_rls_contract.sql        # RLS + grants mínimos a anon
```

Las migraciones se aplican en orden por su timestamp. `supabase/config.toml`
no se versiona aquí: cada entorno lo genera con `supabase init` y lo enlaza a
su propio proyecto con `supabase link`.

## Estado

Implementado:

- `app_today()` — el único dueño de la fecha
- `v_today_habits`, `v_today_tasks`
- `habit_step`, `habit_set`, `habit_undo`
- `complete_task`, `uncomplete_task`
- RLS cerrado + permisos mínimos a `anon`

Pendiente (sesiones futuras):

- Tipos de programación de hábitos y tareas (fijas vs deslizantes)
- `task_templates` + materialización de ocurrencias con `pg_cron`
- `deleted_at` (tombstones) en todas las tablas
- Vistas de análisis (`v_habit_stats`) para Grafana y PWA
- `v_inbox_tasks` (tareas sin fecha)

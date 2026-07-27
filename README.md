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

Estas comprobaciones son el criterio de "ha funcionado". Hazlas con la clave
**anon**, no con la de servicio.

```http
### 1. Las vistas responden
GET {{url}}/rest/v1/v_today_habits?select=*
apikey: {{anon}}

GET {{url}}/rest/v1/v_log_habits?select=*
apikey: {{anon}}

### 2. La tabla NO responde  (debe dar 401/403 o lista vacía)
GET {{url}}/rest/v1/habits?select=*
apikey: {{anon}}

### 3. La escritura directa NO funciona  (debe fallar)
POST {{url}}/rest/v1/habit_checkins
apikey: {{anon}}
Content-Type: application/json

{ "habit_id": "<id>", "checkin_date": "2026-07-27", "value": 1 }

### 4. Las funciones SÍ funcionan
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
        ├── 20260724115900_base_tables.sql          # tablas base (DDL documentado en docs/estructura-bd.md)
        ├── 20260724120000_time_and_status.sql       # app_today() + statuses.is_done
        ├── 20260724120100_views_today.sql            # v_today_habits (v1), v_today_tasks (v1)
        ├── 20260724120200_rpc_write.sql              # habit_step/set/undo, (un)complete_task (v1)
        ├── 20260724120300_rls_contract.sql           # RLS + grants mínimos a anon
        ├── 20260727120000_schedule_columns.sql       # schedule_type, purpose, task_templates, skipped_time
        └── 20260727120100_schedule_views_rpc.sql     # vistas y RPCs actualizados al contrato v2
```

Las migraciones se aplican en orden por su timestamp. `supabase/config.toml`
no se versiona aquí: cada entorno lo genera con `supabase init` y lo enlaza a
su propio proyecto con `supabase link`.

## Estado

Implementado:

- `app_today()` — el único dueño de la fecha
- `v_today_habits` — hábitos con objetivo que tocan hoy según su `schedule_type`
- `v_log_habits` — hábitos de solo registro (purpose=log)
- `v_today_tasks` — ocurrencias pendientes (ni hechas ni omitidas) con vencimiento hoy o antes
- `habit_step`, `habit_set`, `habit_undo`
- `instantiate_task`, `complete_task` (con enganche deslizante), `uncomplete_task`
- `skip_task`, `unskip_task`
- `task_templates` — definición reutilizable de tareas
- Tipos de programación de hábitos: `interval_calendar`, `weekly_days`, `weekly_quota`, `monthly_day`
- Tipos de programación de plantillas: `interval_calendar`, `interval_completion`, `monthly_day`, `none`
- RLS cerrado + permisos mínimos a `anon`

Pendiente (sesiones futuras):

- Materialización automática de ocurrencias fijas con `pg_cron` (tareas `interval_calendar` y `times_of_day`)
- `deleted_at` (tombstones) en todas las tablas
- Vistas de análisis (`v_habit_stats`) para Grafana y PWA
- `v_inbox_tasks` (tareas sin fecha)

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

Primero el linter, que es gratis y detecta lo que las peticiones no ven:

```bash
supabase db advisors --level warn     # CLI v2.81.3+ (o MCP get_advisors)
```

Tres avisos son **esperados y deliberados**; cualquier otro sí hay que mirarlo:

| Aviso | Por qué se ignora |
| --- | --- |
| `security_definer_view` en las 4 vistas | Es el mecanismo, no un descuido: la vista atraviesa el RLS para que `anon` lea sin tocar la tabla. Ponerle `security_invoker = true` las deja devolviendo cero filas, sin error |
| `function_search_path_mutable` en `app_today` / `app_timezone` | Son `security invoker`, así que no escalan privilegios, y la cláusula `SET` les quitaría el inlining dentro de las vistas |
| `anon_security_definer_function_executable` en las 8 funciones del contrato | Es el contrato haciendo su trabajo: `anon` tiene que poder llamarlas. Si este aviso aparece en una función que **no** está en la tabla de escritura de `docs/contrato.md`, eso sí es una fuga real |

Luego las peticiones. Hazlas con la clave **publishable**, nunca con la de
servicio: la de servicio salta RLS y daría falsos positivos en la 2 y la 3. La
clave va **solo en la cabecera `apikey`** — las claves `sb_publishable_...` no
son JWT, y mandarlas además en `Authorization: Bearer` hace que PostgREST
rechace la petición con `Invalid JWT`.

```http
### 1. Las vistas responden
GET {{url}}/rest/v1/v_today_habits?select=*
apikey: {{key}}

GET {{url}}/rest/v1/v_log_habits?select=*
apikey: {{key}}

### 2. La tabla NO responde  (debe dar 401/403 o lista vacía)
GET {{url}}/rest/v1/habits?select=*
apikey: {{key}}

### 3. La escritura directa NO funciona  (debe fallar)
POST {{url}}/rest/v1/habit_checkins
apikey: {{key}}
Content-Type: application/json

{ "habit_id": "<id>", "checkin_date": "2026-07-27", "value": 1 }

### 4. Las funciones del contrato SÍ funcionan
POST {{url}}/rest/v1/rpc/habit_step
apikey: {{key}}
Content-Type: application/json

{ "p_habit_id": "<id>" }

### 5. Las funciones INTERNAS no  (debe dar 404/401, nunca 200)
POST {{url}}/rest/v1/rpc/chain_next_occurrence
apikey: {{key}}
Content-Type: application/json

{ "p_template_id": "<id>" }
```

Si la 2 o la 3 tienen éxito, el contrato no está cerrado: revisa los `revoke`
de `20260724120600_rls_contract.sql`. Si la 5 responde 200, lo que falta es el
`revoke execute on all functions … from public` — Postgres concede `EXECUTE` a
`PUBLIC` en cada función nueva, y `anon` hereda de `PUBLIC`, así que revocar
solo de `anon` deja **toda** función de `public` publicada como endpoint RPC.

Si la 1 da **404**, no es un error de SQL: desde 2026-04-28 Supabase ya no
expone sola una tabla o vista nueva en el Data API. Lo que la da de alta es
precisamente su `grant select … to anon`, así que comprueba que la vista tiene
el suyo en el bloque 3 de `20260724120600_rls_contract.sql`.

## Estructura del repositorio

```
.
├── docs/
│   └── contrato.md              # el contrato de lectura/escritura para los clientes
└── supabase/
    ├── seed.sql                 # datos de prueba (NO ejecutar en producción)
    └── migrations/
        ├── 20260724115900_init.sql               # funciones base, las 11 tablas, índices y triggers
        ├── 20260724120000_view_today_habits.sql  # v_today_habits
        ├── 20260724120100_view_log_habits.sql    # v_log_habits
        ├── 20260724120200_view_today_tasks.sql   # v_today_tasks
        ├── 20260724120300_view_templates.sql     # v_templates
        ├── 20260724120400_rpc_habits.sql         # habit_step / habit_set / habit_undo
        ├── 20260724120500_rpc_tasks.sql          # instantiate_task, (un)complete_task, (un)skip_task
        ├── 20260724120600_rls_contract.sql       # RLS + grants mínimos a anon
        └── 20260724120700_rls_auto_enable.sql    # event trigger: RLS en tablas futuras
```

Las migraciones se aplican en orden por su timestamp. No son deltas históricos:
cada fichero describe el **estado final** de una pieza del esquema, así que
levantar la base en otro proyecto es lanzarlas una vez, de arriba abajo, sobre
una base vacía. No son idempotentes a propósito — si una falla porque el objeto
ya existe, es que el proyecto no estaba vacío.

Dos reglas de orden que no se pueden romper:

- `init.sql` crea `task_templates` **antes** que `tasks`, porque
  `tasks.template_id` la referencia.
- `rls_contract.sql` va **después de todo lo que concede permisos**: revoca
  sobre *all tables / all functions in schema public*, así que todo tiene que
  existir ya. Si añades una vista o una función nueva, hay que añadirle su
  `grant` ahí o quedará cerrada — y para las funciones eso es una feature: el
  revoke desde `PUBLIC` es lo único que impide que cada función de `public` sea
  un endpoint `/rest/v1/rpc/` abierto.
- `rls_auto_enable.sql` va aparte y el último a propósito: `create event
  trigger` exige superusuario y puede fallar según el proyecto. Aislado, ese
  fallo no se lleva por delante los `grant` del fichero anterior. Si falla, solo
  pierdes el automatismo — las tablas de hoy ya tienen RLS.

`supabase/config.toml` no se versiona aquí: cada entorno lo genera con
`supabase init` y lo enlaza a su propio proyecto con `supabase link`.

## Estado

Implementado:

- `app_today()` — el único dueño de la fecha
- `v_today_habits` — hábitos con objetivo que tocan hoy según su `schedule_type`
- `v_log_habits` — hábitos de solo registro (purpose=log)
- `v_today_tasks` — ocurrencias pendientes (ni hechas ni omitidas) con vencimiento hoy o antes
- `habit_step`, `habit_set`, `habit_undo`
- `instantiate_task`, `complete_task`, `uncomplete_task`
- `skip_task`, `unskip_task` — omitir encadena la siguiente ocurrencia igual que completar
- Enganche deslizante (`interval_completion`) en `chain_next_occurrence()`, común a completar y omitir
- `task_templates` — definición reutilizable de tareas
- Tipos de programación de hábitos: `interval_calendar`, `weekly_days`, `weekly_quota`, `monthly_day`
- Tipos de programación de plantillas: `interval_calendar`, `interval_completion`, `monthly_day`, `none`
- RLS cerrado + permisos mínimos a `anon`

Pendiente (sesiones futuras):

- Materialización automática de ocurrencias fijas con `pg_cron` (tareas `interval_calendar` y `times_of_day`)
- `deleted_at` (tombstones) en todas las tablas
- Vistas de análisis (`v_habit_stats`) para Grafana y PWA
- `v_inbox_tasks` (tareas sin fecha)

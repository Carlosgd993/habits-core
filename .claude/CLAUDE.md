# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Qué es esto

La base de datos (Supabase/Postgres) de un ecosistema personal de hábitos y tareas. **No hay código de aplicación**: solo SQL y documentación. Aquí vive toda la lógica de negocio del ecosistema; los clientes (el daemon del repo hermano `../streamdeck-habits`, y en el futuro una PWA, una app NFC, un bot de Telegram) son renderizadores tontos.

Mono-usuario: no hay `user_id` ni multi-tenancy. El modelo está inspirado en la Open API de TickTick (nombres y campos), pero no hay migración ni sincronización con TickTick.

## Orientación rápida

El repo es pequeño; esto es todo lo que hay:

```
supabase/migrations/     7 ficheros SQL — el repo en la práctica
docs/contrato.md         Qué consumen los clientes.  Léelo entero antes de tocar nada
docs/estructura-bd.md    Esquema completo: decisiones, ER y DDL de las tablas
docs/supabase.http       Peticiones PostgREST de ejemplo y verificación
```

| Si vas a… | Mira |
|---|---|
| Cambiar qué ven los clientes | `docs/contrato.md` **primero**, luego `20260727120100_schedule_views_rpc.sql` |
| Cambiar cómo se registra un hábito o se cierra una tarea | `20260727120100_schedule_views_rpc.sql` |
| Añadir/cambiar columnas de hábitos o programación | `20260727120000_schedule_columns.sql` |
| Consultar columnas/tipos de una tabla | `docs/estructura-bd.md` → `## Tablas` (una subsección por tabla, con DDL) |
| Depurar un 401/403 desde un cliente | `20260724120300_rls_contract.sql` (el bloque de `grant`) |
| Tocar zona horaria o el estado "hecho" | `20260724120000_time_and_status.sql` |

**Antes de tocar nada, lee `docs/contrato.md`.** Es lo que define qué se puede romper.

## El contrato

La superficie pública es exactamente esta, y nada más. Todo lo demás está cerrado.

### Dos ejes ortogonales (hábitos)

No confundir `type` con `schedule_type`:

| Eje | Campo | Controla | Valores |
|---|---|---|---|
| **QUÉ** mides | `type` | Cómo avanza el valor | `Boolean` (salta a goal) · `Real` (suma step) |
| **CUÁNDO** toca | `schedule_type` | Qué días aparece | `interval_calendar` · `weekly_days` · `weekly_quota` · `monthly_day` |

Son independientes. Un hábito Boolean puede ser semanal; un Real puede ser diario.

### Lectura — tres vistas

- `v_today_habits` → `id, name, icon_res, color, type, goal, step, unit, sort_order, section_id, current_value, done, day`
  Solo hábitos `purpose='goal'` cuyo `schedule_type` indica que hoy toca. Un hábito no arrastra deuda (2/8 ayer → 0/8 hoy). `current_value` puede superar `goal` (10/8 válido). Para `weekly_quota`, `current_value` = nº de días con checkin en la semana ISO actual, no el valor del día de hoy. `done = current_value >= goal`.

  | `schedule_type` | Toca hoy si… |
  |---|---|
  | `interval_calendar` | `(hoy − anchor_date) % interval_n = 0`; con n=1 es diario |
  | `weekly_days` | `isodow(hoy)` está en `byday` (1=lun…7=dom) |
  | `weekly_quota` | siempre (cualquier día cuenta) |
  | `monthly_day` | `day(hoy) = bymonthday` |

- `v_log_habits` → `id, name, icon_res, color, type, unit, sort_order, section_id, current_value, day`
  Hábitos `purpose='log'`: solo registro, nunca pendientes. No tienen objetivo ni programación. Se llama a `habit_step` sobre ellos igual que sobre los goal.

- `v_today_tasks` → `id, title, priority, project_id, sort_order, due_date, template_id, due_day, overdue, day`
  Ocurrencias de `tasks` con `completed_time is null`, `skipped_time is null` y vencimiento hoy o antes. Las vencidas arrastran con `overdue = true`. Sin fecha, no salen (inbox aparte).

### task_templates vs tasks

`task_templates` = definición reutilizable (título, prioridad, subtareas, schedule_type de la plantilla). `tasks` = ocurrencias concretas con `due_date`, `completed_time`, `skipped_time` y `template_id` (null si tarea única). Las ocurrencias nunca se borran: siempre se marcan.

Ciclo de vida de una ocurrencia:
- `completed_time is null` y `skipped_time is null` → pendiente (aparece en vista)
- `completed_time is not null` → hecha (desaparece)
- `skipped_time is not null` → omitida (desaparece, pero queda registrada)

### Escritura — ocho funciones RPC (todas `security definer` con `set search_path = public`)

| Función | Qué hace |
|---|---|
| `habit_step(p_habit_id)` → `float` | La operación de "pulsar la tecla". `weekly_quota` → fija 1 en el día (idempotente); `Boolean` → salta a `goal`; `Real` → suma `step` sin tope. Upsert atómico. Falla con `no_data_found` si el hábito no existe o está archivado. |
| `habit_set(p_habit_id, p_value)` → `float` | Fija el total exacto de hoy (`greatest(p_value, 0)`). Para correcciones desde la PWA. |
| `habit_undo(p_habit_id)` → `float` | Retrocede un paso. Boolean → 0; Real → `greatest(value - step, 0)`. Devuelve 0 si hoy no había checkin. |
| `instantiate_task(p_template_id, p_due)` → `uuid` | Crea una ocurrencia en `tasks` desde una plantilla, copiando subtareas. Devuelve el id de la nueva ocurrencia. |
| `complete_task(p_task_id)` | Cierra la ocurrencia. **Idempotente**. Si la plantilla es `interval_completion`, crea la siguiente ocurrencia a `interval_n` días desde ahora (deslizante). |
| `uncomplete_task(p_task_id)` | Reabre: limpia `completed_time` y `status_id`. |
| `skip_task(p_task_id)` | Marca la ocurrencia como omitida (`skipped_time = now()`). Sale de la vista pero queda en la historia. |
| `unskip_task(p_task_id)` | Limpia `skipped_time`. |

Más `app_today()`, la única fuente de verdad sobre la fecha.

### Reglas de evolución

Romper una de estas rompe clientes ya desplegados, normalmente en silencio:

1. **A una vista solo se le añaden columnas.** Nunca quitar ni renombrar.
2. **El cuerpo de una vista o función se puede reescribir entero.** Es justo para eso que existe la indirección.
3. **Ningún cliente envía fechas** — las decide `app_today()`.
4. **Ningún cliente conoce UUIDs de catálogo** (`statuses`, `projects`).

## Cosas que no se deducen leyendo el SQL

- **Las tablas base no están en `supabase/migrations/`.** La migración más antigua hace `alter table` sobre tablas que ya existían (creadas fuera de banda). Su DDL solo está **documentado** en `docs/estructura-bd.md`. Si necesitas la verdad sobre una tabla, consúltala en la base (MCP `list_tables` / `execute_sql`), no asumas que el doc está sincronizado.
- **Las vistas se crean deliberadamente SIN `security_invoker = true`.** Al ejecutarse con los permisos de su propietario, atraviesan el RLS de las tablas subyacentes y devuelven filas que `anon` no podría leer directamente. Si alguien añade `security_invoker`, las vistas se quedan vacías sin ningún error visible.
- **`app_timezone()` está hardcodeada a `Europe/Madrid`.** Es lo que evita que el servidor UTC cambie de día a las 02:00 hora local en verano. Cambiar de huso = cambiar esa función, y se entera todo el ecosistema a la vez.
- **La cabecera de `docs/supabase.http` está desactualizada**: afirma que las tablas tienen política permisiva para `anon`. Dejó de ser cierto con `rls_contract`. Los ejemplos CRUD directos sobre tablas solo funcionan con la service key.
- **`.env` incluye `TICKTICK_ACCESS_TOKEN` y `TICKTICK_BASE_URL`, pero nada en este repo las consume.** Son residuo de la etapa TickTick.
- **`habit_step` en `weekly_quota` fija `value = 1` en el checkin del día** (idempotente en el día). El contador semanal que muestra `v_today_habits` se calcula contando los días de la semana con `value > 0`, no sumando los valores.
- **Las tareas de materialización fija (`interval_calendar`, `times_of_day`) NO se auto-crean todavía**: solo la deslizante (`interval_completion`) crea la siguiente ocurrencia vía `complete_task`. El materializador `pg_cron` está pendiente.

## Comandos

No hay build, ni tests, ni `package.json`. Todo pasa por el CLI de Supabase:

```bash
npm install -g supabase          # o brew install supabase/tap/supabase
supabase init                    # genera supabase/config.toml (gitignored)
supabase link --project-ref <ref>
supabase db push                 # aplica supabase/migrations/ al proyecto cloud
```

### Integración GitHub ↔ Supabase

Conectada y verificada. Configuración actual (dashboard de Supabase → *Integrations*):

- Repo enlazado: `Carlosgd993/habits-core`, working directory `.` (busca `supabase/` en la raíz del repo).
- **"Deploy to production" activado**, rama de producción `main`: cualquier merge/push a `main` aplica `supabase/migrations/` directamente al proyecto cloud. Ya no hace falta `supabase db push` manual para llegar a producción.
- **Branching (preview databases por PR) desactivado** — es una función del plan Pro y no está contratado. Consecuencia importante: **no hay red de seguridad de un preview DB por PR**; un push a `main` va directo a producción sin pasar antes por una base de datos de prueba aislada. Verificar migraciones antes de mergear (con `supabase db push` a un proyecto local/staging, o revisión manual) sigue siendo responsabilidad de quien hace el cambio, no de la integración.

### Verificación tras aplicar migraciones

Es el único "test" que existe, y es manual. Usa la **clave anon**, nunca la service key: la service key salta RLS y daría falsos positivos en los checks 2 y 3. Hay peticiones listas en `docs/supabase.http`.

| # | Petición | Resultado esperado |
|---|---|---|
| 1 | `GET /rest/v1/v_today_habits?select=*` | 200 con filas |
| 1b | `GET /rest/v1/v_log_habits?select=*` | 200 con filas |
| 2 | `GET /rest/v1/habits?select=*` | **falla** (401/403 o vacío) |
| 3 | `POST /rest/v1/habit_checkins` | **falla** |
| 4 | `POST /rest/v1/rpc/habit_step` | funciona |

Si 2 o 3 tienen éxito, hay un `revoke` roto en `20260724120300_rls_contract.sql`.

## Convenciones del esquema

- **UUID nativo** como PK (`gen_random_uuid()`); no se importan IDs de TickTick.
- **snake_case**; el mapeo desde el camelCase de TickTick está tabla a tabla en `docs/estructura-bd.md`.
- **Enumeraciones vía `CHECK`**, no `enum` nativo: más fácil de ampliar y más simple para PostgREST. Valores en `docs/estructura-bd.md` → `## Referencia de enumeraciones`.
- **Tipos nativos** (`timestamptz`, `date`, `text[]`) en vez de los formatos de transporte de la API de TickTick.
- `created_at`/`updated_at` los pone el trigger `set_updated_at()`, nunca el cliente.
- En cualquier función `security definer`, `set search_path = public` es **obligatorio** o el `search_path` del llamante puede secuestrar la resolución de nombres.
- Documentación, comentarios SQL y mensajes de commit en español.

## Roadmap

Implementado:
- Tipos de programación de hábitos: `interval_calendar`, `weekly_days`, `weekly_quota`, `monthly_day`
- `task_templates` + ocurrencias `tasks` con `skipped_time`
- `instantiate_task`, `skip_task`, `unskip_task`
- `complete_task` con enganche deslizante (`interval_completion`)

Pendiente:
- Materialización automática de ocurrencias fijas con `pg_cron` (tareas `interval_calendar` y `times_of_day`)
- Tombstones (`deleted_at`) en todas las tablas
- Vistas de análisis (`v_habit_stats`) para Grafana y PWA
- `v_inbox_tasks` (tareas sin fecha)

## Mantén este fichero al día

Si al trabajar descubres que algo descrito aquí ya no coincide con la realidad (una columna que cambió, un comando que no funciona como se documenta), corrígelo en el mismo turno. Este documento solo sirve si las próximas sesiones pueden confiar en él sin verificarlo todo.

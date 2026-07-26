# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Qué es esto

La base de datos (Supabase/Postgres) de un ecosistema personal de hábitos y tareas. **No hay código de aplicación**: solo SQL y documentación. Aquí vive toda la lógica de negocio del ecosistema; los clientes (el daemon del repo hermano `../streamdeck-habits`, y en el futuro una PWA, una app NFC, un bot de Telegram) son renderizadores tontos.

Mono-usuario: no hay `user_id` ni multi-tenancy. El modelo está inspirado en la Open API de TickTick (nombres y campos), pero no hay migración ni sincronización con TickTick.

## Orientación rápida

El repo es pequeño; esto es todo lo que hay:

```
supabase/migrations/     4 ficheros SQL — el repo en la práctica
docs/contrato.md         Qué consumen los clientes.  ~70 líneas, léelo entero
docs/estructura-bd.md    Esquema completo: decisiones, ER y DDL de las 10 tablas
docs/supabase.http       Peticiones PostgREST de ejemplo y verificación
```

| Si vas a… | Mira |
|---|---|
| Cambiar qué ven los clientes | `docs/contrato.md` **primero**, luego `20260724120100_views_today.sql` |
| Cambiar cómo se registra un hábito o se cierra una tarea | `20260724120200_rpc_write.sql` |
| Consultar columnas/tipos de una tabla | `docs/estructura-bd.md` → `## Tablas` (una subsección por tabla, con DDL) |
| Depurar un 401/403 desde un cliente | `20260724120300_rls_contract.sql` (el bloque de `grant`) |
| Tocar zona horaria o el estado "hecho" | `20260724120000_time_and_status.sql` |

**Antes de tocar nada, lee `docs/contrato.md`.** Es lo que define qué se puede romper.

## El contrato

La superficie pública es exactamente esta, y nada más. Todo lo demás está cerrado.

**Lectura — dos vistas:**

- `v_today_habits` → `id, name, icon_res, color, type, goal, step, unit, sort_order, section_id, current_value, done, day`
  Hábitos activos (`habits.status = 0`) con el progreso de hoy ya calculado. Un hábito **siempre es de hoy**: no arrastra deuda ni vence (si ayer quedó 2/8, hoy empieza en 0/8) — por eso no hay filtro de fecha ni de recurrencia. `current_value` **puede superar `goal`** (10/8 es válido y deliberado); `done` solo indica si se alcanzó el objetivo, no si se puede seguir sumando.
- `v_today_tasks` → `id, title, priority, project_id, sort_order, due_date, due_day, overdue, day`
  Tareas pendientes con vencimiento hoy o antes. A diferencia de los hábitos, **sí arrastran**: una vencida el lunes sigue apareciendo el jueves con `overdue = true`. Las tareas **sin fecha se excluyen** (con 12 teclas útiles en el deck, el inbox inundaría la pantalla); cuando hagan falta irán en una `v_inbox_tasks` aparte.

**Escritura — cinco funciones RPC** (todas `security definer` con `set search_path = public`):

| Función | Qué hace |
|---|---|
| `habit_step(p_habit_id)` → `float` | La operación de "pulsar la tecla". Boolean → salta a `goal`; Real → suma `step` **sin tope**. Upsert atómico con `on conflict (habit_id, checkin_date)`: sin carreras entre deck y móvil. Devuelve el nuevo total. Falla con `no_data_found` si el hábito no existe o está archivado. |
| `habit_set(p_habit_id, p_value)` → `float` | Fija el total exacto de hoy (`greatest(p_value, 0)`). Para correcciones desde la PWA. |
| `habit_undo(p_habit_id)` → `float` | Retrocede un paso. Boolean → 0; Real → `greatest(value - step, 0)`. Devuelve 0 si hoy no había checkin. |
| `complete_task(p_task_id)` | Fija `completed_time` y mueve `status_id` al estado con `is_done`. **Idempotente** (`where completed_time is null`). Punto de enganche futuro para recurrencias deslizantes. |
| `uncomplete_task(p_task_id)` | Reabre: limpia `completed_time` y `status_id`. |

Más `app_today()`, la única fuente de verdad sobre la fecha.

### Reglas de evolución

Romper una de estas rompe clientes ya desplegados, normalmente en silencio:

1. **A una vista solo se le añaden columnas.** Nunca quitar ni renombrar.
2. **El cuerpo de una vista o función se puede reescribir entero.** Es justo para eso que existe la indirección.
3. **Ningún cliente envía fechas** — las decide `app_today()`.
4. **Ningún cliente conoce UUIDs de catálogo** (`statuses`, `projects`).

## Cosas que no se deducen leyendo el SQL

- **Las tablas base no están en `supabase/migrations/`.** Ninguna migración tiene un `create table`: la primera hace `alter table statuses add column…` sobre tablas que ya existían. Se crearon fuera de banda (dashboard de Supabase o MCP). Su DDL solo está **documentado** en `docs/estructura-bd.md` — que es documentación, no la fuente aplicada. Si necesitas la verdad sobre una tabla, consúltala en la base (MCP `list_tables` / `execute_sql`), no asumas que el doc está sincronizado.
- **Las vistas se crean deliberadamente SIN `security_invoker = true`.** Al ejecutarse con los permisos de su propietario, atraviesan el RLS de las tablas subyacentes y devuelven filas que `anon` no podría leer directamente. Si alguien añade `security_invoker`, las vistas se quedan vacías y todos los clientes dejan de mostrar datos sin ningún error visible.
- **`app_timezone()` está hardcodeada a `Europe/Madrid`.** Es lo que evita que el servidor UTC cambie de día a las 02:00 hora local en verano (un checkin a la 01:30 caería en "ayer"). Cambiar de huso = cambiar esa función, y se entera todo el ecosistema a la vez.
- **La cabecera de `docs/supabase.http` está desactualizada**: afirma que las tablas tienen una política permisiva de acceso total para `anon`. Dejó de ser cierto con la migración `rls_contract`. Los ejemplos CRUD directos sobre tablas de ese fichero solo funcionan con la service key.
- **`.env` incluye `TICKTICK_ACCESS_TOKEN` y `TICKTICK_BASE_URL`, pero nada en este repo las consume.** Son residuo de la etapa TickTick.

## Comandos

No hay build, ni tests, ni `package.json`. Todo pasa por el CLI de Supabase:

```bash
npm install -g supabase          # o brew install supabase/tap/supabase
supabase init                    # genera supabase/config.toml (gitignored)
supabase link --project-ref <ref>
supabase db push                 # aplica supabase/migrations/ al proyecto cloud
```

### Verificación tras aplicar migraciones

Es el único "test" que existe, y es manual. Usa la **clave anon**, nunca la service key: la service key salta RLS y daría falsos positivos en los checks 2 y 3. Hay peticiones listas en `docs/supabase.http`.

| # | Petición | Resultado esperado |
|---|---|---|
| 1 | `GET /rest/v1/v_today_habits?select=*` | 200 con filas |
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

## Roadmap (sección "Estado" del README)

Hábitos y tareas con programación fija vs. deslizante · `task_templates` + materialización de ocurrencias con `pg_cron` · tombstones (`deleted_at`) · vistas de análisis (`v_habit_stats`) para Grafana y la PWA · `v_inbox_tasks`.

## Mantén este fichero al día

Si al trabajar descubres que algo descrito aquí ya no coincide con la realidad (una columna que cambió, un comando que no funciona como se documenta), corrígelo en el mismo turno. Este documento solo sirve si las próximas sesiones pueden confiar en él sin verificarlo todo.

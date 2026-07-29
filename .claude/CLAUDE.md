# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Qué es esto

La base de datos (Supabase/Postgres) de un ecosistema personal de hábitos y tareas. **No hay código de aplicación**: solo SQL y documentación. Aquí vive toda la lógica de negocio del ecosistema; los clientes (el daemon del repo hermano `../streamdeck-habits`, y en el futuro una PWA, una app NFC, un bot de Telegram) son renderizadores tontos.

Mono-usuario: no hay `user_id` ni multi-tenancy. El modelo está inspirado en la Open API de TickTick (nombres y campos), pero no hay migración ni sincronización con TickTick.

## Orientación rápida

El repo es pequeño; esto es todo lo que hay:

```
supabase/migrations/     9 ficheros SQL — el repo en la práctica (init + 4 vistas + 2 rpc + 2 rls)
supabase/seed.sql        datos de prueba, uno de cada tipo. NO ejecutar en producción
docs/contrato.md         Qué consumen los clientes.  Léelo entero antes de tocar nada
docs/estructura-bd.md    Esquema completo: decisiones, ER y DDL de las tablas
tools/supabase.http      Peticiones PostgREST de ejemplo y verificación
```

Las migraciones **no son deltas históricos**: cada fichero describe el estado
final de una pieza del esquema, así que el sitio donde se cambia algo es el
mismo sitio donde está definido. No hay que ir encadenando `alter table`.

| Si vas a… | Mira |
|---|---|
| Cambiar qué ven los clientes | `docs/contrato.md` **primero**, luego el `*_view_*.sql` correspondiente |
| Cambiar cómo se registra un hábito | `20260724120400_rpc_habits.sql` |
| Cambiar cómo se cierra/omite una tarea | `20260724120500_rpc_tasks.sql` |
| Añadir/cambiar columnas de cualquier tabla | `20260724115900_init.sql` (es la única que crea tablas) |
| Cambiar qué plantillas ve la PWA | `docs/contrato.md`, `20260724120300_view_templates.sql` |
| Consultar columnas/tipos de una tabla | `docs/estructura-bd.md` → `## Tablas` (una subsección por tabla, con DDL) |
| Depurar un 401/403 desde un cliente | `20260724120600_rls_contract.sql` (los bloques de `grant`/`revoke`) |
| Añadir una tabla nueva y saber si queda cerrada por defecto | `rls_auto_enable()` en `20260724120700_rls_auto_enable.sql` — activa RLS sola, pero los grants siguen siendo manuales |
| Tocar zona horaria o el estado "hecho" | `20260724115900_init.sql` (`app_timezone()`, semilla de `statuses`) |

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

### Lectura — cuatro vistas

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

- `v_templates` → `id, title, project_id, priority, schedule_type, interval_n, bymonthday, subtask_count, created_at`
  Plantillas activas (`task_templates.active = true`) para que la PWA las liste y llame a `instantiate_task(id)`. No expone `anchor_date` ni el `subtasks` jsonb crudo — `subtask_count` basta para pintar "3 subtareas"; `instantiate_task` se encarga del jsonb por dentro. Es la única vía de lectura sobre `task_templates`: la tabla en sí está cerrada (ver más abajo).

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
| `skip_task(p_task_id)` | Marca la ocurrencia como omitida (`skipped_time = now()`). **Idempotente.** Encadena la siguiente exactamente igual que `complete_task`. No toca `status_id`. |
| `unskip_task(p_task_id)` | Limpia `skipped_time`. No borra la ocurrencia encadenada. |

Más `app_today()`, la única fuente de verdad sobre la fecha.

### Reglas de evolución

Romper una de estas rompe clientes ya desplegados, normalmente en silencio:

1. **A una vista solo se le añaden columnas.** Nunca quitar ni renombrar.
2. **El cuerpo de una vista o función se puede reescribir entero.** Es justo para eso que existe la indirección.
3. **Ningún cliente envía fechas** — las decide `app_today()`.
4. **Ningún cliente conoce UUIDs de catálogo** (`statuses`, `projects`).

## Cosas que no se deducen leyendo el SQL

- **Las migraciones se aplican sobre una base VACÍA y no son idempotentes.** No hay `if not exists` ni guardas `do $$ … pg_constraint`: si una falla porque el objeto ya existe, el proyecto no estaba vacío y hay que averiguar por qué, no relanzarla. El esquema entero se recrea lanzando los 9 ficheros en orden.
- **Para crear una migración nueva, `supabase migration new <nombre>`.** No inventes el nombre del fichero a mano: el formato del timestamp lo decide el CLI y equivocarse altera el orden de aplicación, que aquí es load-bearing (ver los dos puntos siguientes).
- **`docs/estructura-bd.md` va por detrás del SQL.** No documenta `task_templates` ni las columnas de programación de `habits` (`purpose`, `schedule_type`, `interval_n`, `byday`, `bymonthday`, `anchor_date`). La verdad está en `20260724115900_init.sql`, o en la base misma (MCP `list_tables` / `execute_sql`).
- **`init.sql` crea `task_templates` antes que `tasks`**, porque `tasks.template_id` la referencia. Si reordenas el fichero, esto es lo que rompe.
- **`rls_contract.sql` tiene que ir el último.** Revoca sobre *all tables in schema public*, así que todo debe existir ya. Una vista o función nueva sin su `grant` ahí queda cerrada a `anon` — que es el fallo seguro, pero se manifiesta como un 401 desconcertante.
- **Las vistas se crean deliberadamente SIN `security_invoker = true`.** Al ejecutarse con los permisos de su propietario, atraviesan el RLS de las tablas subyacentes y devuelven filas que `anon` no podría leer directamente. Si alguien añade `security_invoker`, las vistas se quedan vacías sin ningún error visible.
- **`app_timezone()` está hardcodeada a `Europe/Madrid`.** Es lo que evita que el servidor UTC cambie de día a las 02:00 hora local en verano. Cambiar de huso = cambiar esa función, y se entera todo el ecosistema a la vez.
- **`.env` incluye `TICKTICK_ACCESS_TOKEN` y `TICKTICK_BASE_URL`, pero nada en este repo las consume.** Son residuo de la etapa TickTick.
- **`habit_step` en `weekly_quota` fija `value = 1` en el checkin del día** (idempotente en el día). El contador semanal que muestra `v_today_habits` se calcula contando los días de la semana con `value > 0`, no sumando los valores.
- **Las tareas de materialización fija (`interval_calendar`, `times_of_day`) NO se auto-crean todavía**: solo la deslizante (`interval_completion`) encadena la siguiente. El materializador `pg_cron` está pendiente.
- **Omitir encadena igual que completar.** `skip_task` y `complete_task` llaman ambas a `chain_next_occurrence()`, donde vive la regla deslizante en un único sitio. Omitir no es lo contrario de completar: en los dos casos la ocurrencia deja de estar pendiente y la recurrencia sigue. Lo que cambia es el rastro histórico (`skipped_time` vs `completed_time`) y que omitir no toca `status_id`. Si tocas la regla, tócala en `chain_next_occurrence` — no la dupliques.
- **`chain_next_occurrence()` filtra por `active`, y eso es load-bearing.** Sin ese filtro, `instantiate_task` lanzaría excepción sobre una plantilla desactivada, la transacción haría rollback y la última ocurrencia abierta de esa plantilla sería **imposible de cerrar**. Desactivar una plantilla es cómo se para una recurrencia; tiene que dejar cerrar lo que quedaba abierto.
- **`interval_calendar` exige `app_today() >= anchor_date`.** El `%` de Postgres devuelve resto negativo (`-6 % 3 = 0`), así que sin esa guarda un hábito anclado en el futuro empezaría a aparecer hoy. El ancla es el arranque de la serie, no solo su punto de referencia.
- **Toda tabla nueva del esquema `public` activa RLS sola**, vía el event trigger `trg_rls_auto_enable` (función `rls_auto_enable()`, en `20260724120700_rls_auto_enable.sql`, en fichero aparte porque `create event trigger` exige superusuario y su fallo no debe arrastrar los grants del anterior). Existe porque ya pasó una vez: `task_templates` se creó en su día después del fichero de RLS y quedó abierta a `anon`. Una tabla creada sin más queda ahora con RLS activado y sin políticas → cerrada por defecto. Los `grant` siguen siendo manuales — RLS activo no basta si luego se hace `grant all` a `anon`.
- **Hay que revocar de `PUBLIC`, no solo de `anon`.** Postgres concede `EXECUTE` a `PUBLIC` en cada función nueva y `anon` hereda de `PUBLIC`, así que `revoke all on all functions … from anon` **no cierra nada**: toda función de `public` sigue siendo un endpoint `/rest/v1/rpc/<nombre>` llamable con la clave publishable. Lo que lo cierra es el `revoke execute on all functions in schema public from public` de `20260724120600_rls_contract.sql`, más el `alter default privileges … revoke execute on functions from public` para las futuras. Consecuencia: **una función nueva nace cerrada y necesita su `grant execute … to anon` explícito**; si una RPC da 404, es esto. `service_role` se restituye entero justo después (lo necesita para disparar `set_updated_at()` al escribir).
- **`chain_next_occurrence` es interna de verdad, no por convención.** Antes del revoke desde `PUBLIC` era llamable desde fuera y creaba ocurrencias a petición de cualquiera con la clave pública. Hay un check en `tools/supabase.http` que lo comprueba: si responde 200, el revoke se ha caído.
- **El linter de Supabase da tres tipos de aviso asumidos, y hay que distinguirlos de uno real.** `security_definer_view` en las 4 vistas (es el mecanismo: sin él, `anon` no puede leer nada — "arreglarlo" con `security_invoker = true` las deja devolviendo cero filas y sin error), `function_search_path_mutable` en `app_today()`/`app_timezone()` (son `security invoker`, no escalan privilegios, y la cláusula `SET` les quitaría el inlining en los predicados de las vistas), y `anon_security_definer_function_executable` en las 8 funciones del contrato (`habit_step`, `habit_set`, `habit_undo`, `instantiate_task`, `complete_task`, `uncomplete_task`, `skip_task`, `unskip_task`) — es literalmente el contrato funcionando, `anon` debe poder llamarlas. Si ese aviso apareciera en una función que NO está en la tabla de "Escritura" de `docs/contrato.md` (p.ej. `chain_next_occurrence`), eso sí es una fuga real: significa que su `grant` se coló donde no debía. Cualquier otro aviso hay que mirarlo.
- **`app_timezone()` necesita su propio `grant execute ... to anon`, aunque ningún cliente la llame directamente.** Es `security invoker` (igual que `app_today()`, que la llama por dentro) y una función invoker llamada desde dentro de una vista comprueba el `EXECUTE` contra el rol que hace la consulta (`anon`), no contra el dueño de la vista. Sin ese grant, `v_today_habits`, `v_log_habits` y `v_today_tasks` — las tres vistas que usan la fecha — fallan con `permission denied for function app_timezone`, un 401 que no delata cuál es la función culpable. `v_templates` no la usa y por eso es la única que no lo nota. Se descubrió aplicando las migraciones de verdad contra un proyecto de test; no se ve leyendo el SQL.
- **El Data API ya no expone nada solo.** Desde el cambio de Supabase de 2026-04-28, una tabla o vista nueva de `public` no aparece en `/rest/v1` por existir: lo que la da de alta es su `GRANT`. Los grants de `rls_contract.sql` son a la vez el mínimo privilegio y el alta en la API. Una vista que responde 404 casi siempre es un `grant` que falta, no SQL roto.
- **Las claves nuevas (`sb_publishable_…`) no son JWT.** Van **solo** en la cabecera `apikey`. Si además viajan en `Authorization: Bearer`, PostgREST intenta parsearlas como JWT y devuelve `Invalid JWT`. Con las claves legacy `anon` sí colaba, así que es un fallo típico al migrar — y estuvo en `tools/supabase.http` hasta que se quitó.

## Comandos

No hay build, ni tests, ni `package.json`. Todo pasa por el CLI de Supabase:

```bash
npm install -g supabase          # o brew install supabase/tap/supabase
supabase init                    # genera supabase/config.toml (gitignored)
supabase link --project-ref <ref>
supabase db push                 # aplica supabase/migrations/ al proyecto cloud
```

### Dos proyectos Supabase, uno por rama

| Proyecto | ref | Rama que lo despliega |
|---|---|---|
| `habits-core` (producción) | `ufyzpixnhrsltoxdqihn` | `main` |
| `habits-core-test` | `dkomeqbvhobkaulogibw` | `develop` |

Cada uno tiene su propia integración GitHub↔Supabase, independiente. La rama
`test` no despliega a ningún proyecto por sí sola: es la rama de trabajo que
se mergea a `develop` (para probar en `habits-core-test`) y, cuando está
verificado, `develop` se mergea a `main` (para llegar a producción). El
disparo es el **merge**, no el push directo a la rama — un `git push` sin
merge no llega al proyecto.

El daemon `../streamdeck-habits` puede apuntar a cualquiera de los dos
proyectos cambiando una variable en su `.env` — ver
`../streamdeck-habits/CLAUDE.md#cambiar-de-proyecto-supabase-main--test`.

**Un proyecto recién creado (o recreado) está completamente vacío** —
`list_migrations`/`list_tables` devuelven `[]` hasta que se mergea algo a la
rama que lo despliega. Un cliente apuntando ahí no da un error de
configuración: PostgREST responde 404 `PGRST205` ("Could not find the table
... in the schema cache") en cualquier vista o función. Antes de sospechar de
las credenciales, comprueba `list_migrations` del proyecto en cuestión.

### Integración GitHub ↔ Supabase

Conectada y verificada en ambos proyectos. Configuración actual (dashboard de Supabase → *Integrations*):

- Repo enlazado: `Carlosgd993/habits-core`, working directory `.` (busca `supabase/` en la raíz del repo).
- **"Deploy to production" activado**, una rama distinta por proyecto (ver tabla arriba): cualquier merge a esa rama aplica `supabase/migrations/` directamente al proyecto cloud correspondiente. Ya no hace falta `supabase db push` manual para llegar a producción.
- **Branching (preview databases por PR) desactivado** — es una función del plan Pro y no está contratado. Consecuencia importante: **no hay red de seguridad de un preview DB por PR**; un merge a `main` o `develop` va directo a su proyecto sin pasar antes por una base de datos de prueba aislada. Verificar migraciones antes de mergear (con `supabase db push` a un proyecto local/staging, o revisión manual) sigue siendo responsabilidad de quien hace el cambio, no de la integración.

### Verificación tras aplicar migraciones

Empieza por el linter, que es gratis: `supabase db advisors --level warn` (CLI v2.81.3+) o MCP `get_advisors`. Los dos falsos positivos esperados están arriba; cualquier otro aviso hay que mirarlo.

Luego, el único "test" que existe, y es manual. Usa la **clave publishable**, nunca la service key: la service key salta RLS y daría falsos positivos en los checks 2, 3 y 5. Va **solo** en la cabecera `apikey`. Hay peticiones listas en `tools/supabase.http`.

| # | Petición | Resultado esperado |
|---|---|---|
| 1 | `GET /rest/v1/v_today_habits?select=*` | 200 con filas |
| 1b | `GET /rest/v1/v_log_habits?select=*` | 200 con filas |
| 2 | `GET /rest/v1/habits?select=*` | **falla** (401/403 o vacío) |
| 3 | `POST /rest/v1/habit_checkins` | **falla** |
| 4 | `POST /rest/v1/rpc/habit_step` | funciona |
| 5 | `POST /rest/v1/rpc/chain_next_occurrence` | **falla** (404/401) |

Si 2 o 3 tienen éxito, hay un `revoke` roto en `20260724120600_rls_contract.sql`. Si 5 tiene éxito, el que falta es el `revoke … from public` de las funciones. Si 1 da 404, es un `grant select` que falta (el Data API ya no expone vistas solo).

## Convenciones del esquema

- **UUID nativo** como PK (`gen_random_uuid()`); no se importan IDs de TickTick.
- **snake_case**; el mapeo desde el camelCase de TickTick está tabla a tabla en `docs/estructura-bd.md`.
- **Enumeraciones vía `CHECK`**, no `enum` nativo: más fácil de ampliar y más simple para PostgREST. Valores en `docs/estructura-bd.md` → `## Referencia de enumeraciones`.
- **Tipos nativos** (`timestamptz`, `date`, `text[]`) en vez de los formatos de transporte de la API de TickTick.
- `created_at`/`updated_at` los pone el trigger `set_updated_at()`, nunca el cliente.
- En cualquier función `security definer`, `set search_path = public` es **obligatorio** o el `search_path` del llamante puede secuestrar la resolución de nombres. Las únicas sin cláusula `SET` son `app_today()` y `app_timezone()`, que son `security invoker` y se dejan así a propósito para no perder el inlining (razonado en `init.sql`).
- **Toda función nueva necesita su `grant execute … to anon` explícito** si va a formar parte del contrato, y no llevarlo es lo correcto si no. Ver el punto sobre `PUBLIC` más arriba.
- Documentación, comentarios SQL y mensajes de commit en español.

## Roadmap

Implementado:
- Tipos de programación de hábitos: `interval_calendar`, `weekly_days`, `weekly_quota`, `monthly_day`
- `task_templates` + ocurrencias `tasks` con `skipped_time`
- `instantiate_task`, `skip_task`, `unskip_task`
- `complete_task` con enganche deslizante (`interval_completion`)
- `task_templates` cerrada con RLS + vista `v_templates` para que la PWA liste plantillas
- RLS automático en tablas nuevas de `public` (event trigger `rls_auto_enable`)

Pendiente:
- Materialización automática de ocurrencias fijas con `pg_cron` (tareas `interval_calendar` y `times_of_day`)
- Tombstones (`deleted_at`) en todas las tablas
- Vistas de análisis (`v_habit_stats`) para Grafana y PWA
- `v_inbox_tasks` (tareas sin fecha)

## Mantén este fichero al día

Si al trabajar descubres que algo descrito aquí ya no coincide con la realidad (una columna que cambió, un comando que no funciona como se documenta), corrígelo en el mismo turno. Este documento solo sirve si las próximas sesiones pueden confiar en él sin verificarlo todo.

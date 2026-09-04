# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Qué es esto

La base de datos (Supabase/Postgres) de un ecosistema personal de hábitos y tareas. **No hay código de aplicación**: solo SQL y documentación. Aquí vive toda la lógica de negocio del ecosistema; los clientes (el daemon del repo hermano `../streamdeck-habits`, y en el futuro una PWA, una app NFC, un bot de Telegram) son renderizadores tontos.

Mono-usuario: no hay `user_id` ni multi-tenancy. El modelo está inspirado en la Open API de TickTick (nombres y campos), pero no hay migración ni sincronización con TickTick.

## El proceso de todo cambio de base de datos

> **Léelo antes de tocar SQL, en cualquier sesión y en cualquier máquina.** Este
> proyecto se lleva desde varios PCs: esto vive aquí, en el repo, precisamente
> para que no dependa de lo que recuerde una sesión concreta.

Esto no es una recomendación ni depende del tamaño del cambio: **cualquier
modificación de la base de datos sigue estos seis pasos, siempre y en este
orden.**

1. El cambio se hace en la rama **`develop`** (migration nueva +
   `supabase/schemas/` + docs, todo en el mismo commit).
2. **PR de `develop` → `test`.** El merge despliega a `habits-core-test`.
3. Se prueba **en la Stream Deck apuntando al proyecto de test**
   (`SUPABASE_ENV=test` en el `.env` de la Pi — ver
   `../streamdeck-habits/CLAUDE.md#cambiar-de-proyecto-supabase-main--test`).
4. Se confirma que funciona de verdad, en el hardware.
5. **PR de `test` → `main`.** El merge despliega a producción.
6. Se despliega la Pi en modo normal (`deploy/deploy.sh` sin `--test`) y se
   devuelve `SUPABASE_ENV` a `main`.

| Rama | Papel | Qué despliega |
|---|---|---|
| `develop` | Rama de trabajo | **Nada** |
| `test` | Validación | `habits-core-test` (`dkomeqbvhobkaulogibw`) |
| `main` | Producción | `habits-core` (`ufyzpixnhrsltoxdqihn`) |

El disparo es el **merge**, no el push: un `git push` a la rama sin merge no
llega al proyecto.

Saltarse los pasos 2-3 es lo único que separa un error de esquema de un deck
inservible: **no hay preview databases por PR** (es función del plan Pro y no
está contratado), así que el proyecto de test *es* la red de seguridad.

**Antes de empezar, comprueba que las tres ramas están niveladas:**

```bash
git log --oneline -1 develop && git log --oneline -1 test && git log --oneline -1 main
```

Los tres deben coincidir. Si `develop` va por detrás de `main`, el PR del paso 2
intentaría **revertir producción** — nivélalas primero con
`git merge --ff-only main` en cada una. Ya pasó una vez: `develop` se quedó con
el layout viejo de migrations mientras `main` tenía la versión consolidada.

Commits, pushes y merges de estos pasos **los autoriza el usuario en el momento**.
Que un plan aprobado los liste no cuenta como permiso.

## Orientación rápida

El repo es pequeño; esto es todo lo que hay:

```
supabase/migrations/     10 ficheros SQL — el repo en la práctica (init + 4 vistas + 2 rpc + 2 rls + deltas)
supabase/schemas/        Definición del ESTADO ACTUAL (tablas/vistas/RPC), mantenida a mano
supabase/seed.sql        datos de prueba, uno de cada tipo. NO ejecutar en producción
docs/contrato.md         Qué consumen los clientes.  Léelo entero antes de tocar nada
docs/estructura-bd.md    Esquema completo: decisiones, ER y DDL de las tablas
tools/supabase.http      Peticiones PostgREST de ejemplo y verificación
```

Los **9 primeros** ficheros de `migrations/` no son deltas históricos: cada uno
describe el estado final de una pieza del esquema, y se escribieron contra una
base vacía. Pero una vez desplegados **ya no se editan**: la integración
GitHub↔Supabase salta las migrations ya aplicadas, así que tocar `init.sql` hoy
no llegaría a ningún proyecto. Desde `20260805120000_plantillas_deck.sql` en
adelante, **todo cambio estructural es un delta en una migration nueva** (con su
`alter table` / `create or replace`), y el estado actual legible vive en
`supabase/schemas/`, que sí se edita en el sitio.

| Si vas a… | Mira |
|---|---|
| **Cualquier cambio de BD: el proceso de ramas** | [El proceso de todo cambio de base de datos](#el-proceso-de-todo-cambio-de-base-de-datos), arriba. **Es obligatorio, no orientativo** |
| Cambiar qué ven los clientes | `docs/contrato.md` **primero**, luego `supabase/schemas/0N_view_*.sql` + migration nueva |
| Cambiar cómo se registra un hábito | `supabase/schemas/07_rpc_habits.sql` + migration nueva |
| Cambiar cómo se cierra/omite una tarea | `supabase/schemas/08_rpc_tasks.sql` + migration nueva |
| Añadir/cambiar columnas de cualquier tabla | `supabase/schemas/02_tables.sql` **y** una migration nueva con el `alter table`. **No** edites `init.sql`: ya está aplicado en los dos proyectos |
| Cambiar qué plantillas ve un cliente | `docs/contrato.md`, `supabase/schemas/06_view_templates.sql` |
| Cambiar qué plantillas ofrece el deck como botón "Crear" | `task_templates.show_in_deck` (columna, no código): `update task_templates set show_in_deck = true where …` |
| Cambiar qué etiquetas rápidas ofrece el deck en "Cronómetros" | `timer_labels.show_in_deck` (columna, no código); crear/archivar etiquetas es `insert`/`update timer_labels set archived_at = now()`, a mano por SQL — no hay cliente que las gestione |
| Consultar columnas/tipos de una tabla | `docs/estructura-bd.md` → `## Tablas` (una subsección por tabla, con DDL) |
| Depurar un 401/403 desde un cliente | `20260724120600_rls_contract.sql` (los bloques de `grant`/`revoke`) |
| Añadir una tabla nueva y saber si queda cerrada por defecto | `rls_auto_enable()` en `20260724120700_rls_auto_enable.sql` — activa RLS sola, pero los grants siguen siendo manuales |
| Ver el estado actual del esquema sin reconstruirlo mentalmente leyendo las migrations en orden | `supabase/schemas/` — ver sección siguiente |
| Tocar zona horaria o el estado "hecho" | `supabase/schemas/01_functions.sql` (`app_timezone()`) y la semilla de `statuses` en `20260724115900_init.sql` |

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

Tercer eje, solo con sentido si `type = 'Real'`: `manual_entry` (boolean,
`default false`, opt-in por hábito igual que `show_in_deck` lo es por
plantilla). Si es `true`, el cliente pide el valor exacto de hoy y lo fija con
`habit_set` en vez de sumar `step` con `habit_step` — es el caso de un hábito
como "Peso", donde no tiene sentido ir sumando de 1 en 1.

### Lectura — cuatro vistas

- `v_today_habits` → `id, name, icon_res, color, type, goal, step, unit, sort_order, section_id, current_value, done, day, manual_entry`
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

- `v_templates` → `id, title, project_id, priority, schedule_type, interval_n, bymonthday, subtask_count, created_at, show_in_deck`
  Plantillas activas (`task_templates.active = true`) para que un cliente las liste y llame a `instantiate_task(id)`. No expone `anchor_date` ni el `subtasks` jsonb crudo — `subtask_count` basta para pintar "3 subtareas"; `instantiate_task` se encarga del jsonb por dentro. Es la única vía de lectura sobre `task_templates`: la tabla en sí está cerrada (ver más abajo).
  `show_in_deck` marca las plantillas de **creación rápida** (tareas que se repiten sin momento fijo: "Cita peluquero"), las que la pantalla "Crear" del deck ofrece como botón. Eje independiente de `active` y `schedule_type`, opt-in (`default false`). El filtrado es del cliente (`?show_in_deck=eq.true`): no hay vista aparte, así la PWA sigue viendo todas.

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
| `habit_set(p_habit_id, p_value)` → `float` | Fija el total exacto de hoy (`greatest(p_value, 0)`). Para correcciones desde la PWA y para los hábitos `manual_entry`. |
| `habit_undo(p_habit_id)` → `float` | Retrocede un paso. Boolean → 0; Real → `greatest(value - step, 0)`. Devuelve 0 si hoy no había checkin. |
| `instantiate_task(p_template_id, p_due)` → `uuid` | Crea una ocurrencia en `tasks` desde una plantilla, copiando subtareas. **Sin `p_due` vence ahora** (con `due_date` null no saldría en `v_today_tasks`). **No es idempotente**: dos llamadas, dos ocurrencias. Devuelve el id de la nueva. |
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

## `supabase/schemas/` — definición del estado actual

Las migrations son deltas históricos (aunque cada una describa un estado
final, como se explica arriba); `supabase/schemas/` es otra cosa: una copia
del estado actual de tablas, vistas y funciones RPC, partida en los mismos
ocho conceptos que las migrations correspondientes (`01_functions.sql` ..
`08_rpc_tasks.sql`), pensada para que un humano o un LLM vea el esquema de
un vistazo sin reconstruirlo mentalmente leyendo 9 ficheros en orden.

**No se despliega.** La integración GitHub↔Supabase sigue aplicando
`supabase/migrations/`, no `supabase/schemas/`. Este directorio no es un
mecanismo de CI ni de arranque: es documentación ejecutable y la base para
reconstruir la BD en otro sitio (ver más abajo).

**Se mantiene a mano, no se genera.** Supabase tiene una feature nativa
("declarative schemas") que genera migrations automáticamente comparando
`schemas/` contra el historial (`supabase db diff`) — pero requiere el CLI
instalado (y Docker), que este repo no tiene instalado por
ahora. Mientras tanto, **todo cambio estructural edita el fichero de
`schemas/` correspondiente Y la migration nueva, en el mismo commit.** Si
algún día se instala el CLI, esto se puede automatizar; hasta entonces es
sincronización manual, igual de mecánica que escribir hoy una migration.
Investigado también: `db diff` no captura de forma fiable `grant`/`revoke`,
`security_invoker` en vistas, ni DML — por eso, aunque se automatizara,
`rls_contract.sql` y `rls_auto_enable.sql` seguirían fuera de `schemas/`
(ver siguiente punto).

**Qué queda fuera, a propósito:** `rls_contract.sql` (grants + `enable row
level security`) y `rls_auto_enable.sql` (el event trigger). No son
"estructura" en el sentido de CREATE TABLE/VIEW/FUNCTION — son una barrida
de revoke/grant y un trigger de infraestructura, y este repo ya trata los
grants como un paso manual y deliberado por diseño (ver "El contrato" más
arriba: "una función nueva nace cerrada y necesita su grant explícito").
Fusionarlos con la definición estructural no aportaría nada y sí un lugar
más donde una automatización futura podría fallar en silencio justo en la
pieza que más importa proteger.

**Reconstruir la base desde cero en otro sitio**, sin tocar
`supabase/migrations/` ni depender del CLI:

1. Aplicar `supabase/schemas/*.sql` en orden (`01` → `08`) — con `psql`, el
   SQL Editor del dashboard, o MCP `execute_sql`.
2. Aplicar la semilla mínima (vive solo en `init.sql`, no en `schemas/`,
   porque es DML):
   ```sql
   insert into statuses (name, sort_order, is_done) values ('Hecho', 100, true);
   ```
3. Aplicar `rls_contract.sql` y luego `rls_auto_enable.sql`, en ese orden
   (el segundo va después porque `create event trigger` puede fallar según
   el rol, y no debe arrastrar los grants del primero — misma razón por la
   que están en ficheros separados en `migrations/`).

## Cosas que no se deducen leyendo el SQL

- **Las migraciones se aplican sobre una base VACÍA y no son idempotentes.** No hay `if not exists` ni guardas `do $$ … pg_constraint`: si una falla porque el objeto ya existe, el proyecto no estaba vacío y hay que averiguar por qué, no relanzarla. El esquema entero se recrea lanzando los ficheros en orden.
- **Para crear una migración nueva, `supabase migration new <nombre>`.** No inventes el nombre del fichero a mano: el formato del timestamp lo decide el CLI y equivocarse altera el orden de aplicación, que aquí es load-bearing (ver los dos puntos siguientes). Si el CLI no está disponible (hoy no lo está), el formato es `YYYYMMDDHHMMSS_nombre.sql` y el timestamp tiene que ser estrictamente mayor que el de la última migration existente.
- **Una migration ya desplegada no se edita nunca.** La integración GitHub↔Supabase lleva su propio registro de versiones aplicadas y salta las que ya corrieron: cambiar `init.sql` hoy no modifica ni `habits-core` ni `habits-core-test`, solo desincroniza el repo de la realidad. Los cambios estructurales van en una migration **nueva** (delta) y en `supabase/schemas/` (estado actual).
- **`docs/estructura-bd.md` va por detrás del SQL.** No documenta `task_templates` ni las columnas de programación de `habits` (`purpose`, `schedule_type`, `interval_n`, `byday`, `bymonthday`, `anchor_date`). La verdad está en `supabase/schemas/02_tables.sql`, o en la base misma (MCP `list_tables` / `execute_sql`).
- **`init.sql` crea `task_templates` antes que `tasks`**, porque `tasks.template_id` la referencia. Si reordenas el fichero, esto es lo que rompe.
- **`rls_contract.sql` tiene que ir el último.** Revoca sobre *all tables in schema public*, así que todo debe existir ya. Una vista o función nueva sin su `grant` ahí queda cerrada a `anon` — que es el fallo seguro, pero se manifiesta como un 401 desconcertante.
- **Las vistas se crean deliberadamente SIN `security_invoker = true`.** Al ejecutarse con los permisos de su propietario, atraviesan el RLS de las tablas subyacentes y devuelven filas que `anon` no podría leer directamente. Si alguien añade `security_invoker`, las vistas se quedan vacías sin ningún error visible.
- **`app_timezone()` está hardcodeada a `Europe/Madrid`.** Es lo que evita que el servidor UTC cambie de día a las 02:00 hora local en verano. Cambiar de huso = cambiar esa función, y se entera todo el ecosistema a la vez.
- **`.env` incluye `TICKTICK_ACCESS_TOKEN` y `TICKTICK_BASE_URL`, pero nada en este repo las consume.** Son residuo de la etapa TickTick.
- **`habit_step` en `weekly_quota` fija `value = 1` en el checkin del día** (idempotente en el día). El contador semanal que muestra `v_today_habits` se calcula contando los días de la semana con `value > 0`, no sumando los valores.
- **Las tareas de materialización fija (`interval_calendar`, `times_of_day`) NO se auto-crean todavía**: solo la deslizante (`interval_completion`) encadena la siguiente. El materializador `pg_cron` está pendiente.
- **`instantiate_task` sin `p_due` vence AHORA, y eso es load-bearing.** Antes insertaba `p_due` tal cual, o sea `null`, y `v_today_tasks` excluye las tareas sin `due_date`: la ocurrencia se creaba de verdad pero no la veía ningún cliente, así que el botón "Crear" parecía no hacer nada. El `coalesce(p_due, now())` es lo que respeta la regla 3 del contrato (la fecha la pone la base) sin dejar la tarea en un limbo. Cuando exista `v_inbox_tasks`, esto se puede replantear — hasta entonces, no.
- **`instantiate_task` deja como mucho una ocurrencia pendiente por plantilla.** Antes dos llamadas creaban dos ocurrencias (documentado como "no idempotente"); ahora, si ya hay una pendiente (ni completada ni omitida), no inserta otra — adelanta su `due_date` a `coalesce(p_due, now())` y devuelve su `id`. Existe porque `chain_next_occurrence` encadena la siguiente ocurrencia **por adelantado** (vencimiento a `interval_n` días vista), y esa fila queda fuera de `v_today_tasks` — invisible para cualquier cliente — hasta que llega su fecha: un botón de creación rápida pulsado antes de esa fecha creaba una segunda ocurrencia sin que nada lo impidiera. Se descubrió en producción con la plantilla "Dyson" (`interval_completion`, `interval_n=3`): completarla el día 3 encadenó la siguiente para el día 6, y pulsar el botón el día 5 creó una duplicada — ambas visibles a la vez el día 6.
- **`show_in_deck` es un tercer eje, independiente de `active` y `schedule_type`.** Una plantilla puede estar activa, ser `interval_calendar`, y no ofrecerse como botón (la materializará `pg_cron`). Y una `none` puede estar activa sin ser de creación rápida. Es `default false`: opt-in explícito, para que una plantilla nueva no aparezca sola en el deck.
- **Omitir encadena igual que completar.** `skip_task` y `complete_task` llaman ambas a `chain_next_occurrence()`, donde vive la regla deslizante en un único sitio. Omitir no es lo contrario de completar: en los dos casos la ocurrencia deja de estar pendiente y la recurrencia sigue. Lo que cambia es el rastro histórico (`skipped_time` vs `completed_time`) y que omitir no toca `status_id`. Si tocas la regla, tócala en `chain_next_occurrence` — no la dupliques.
- **`chain_next_occurrence()` filtra por `active`, y eso es load-bearing.** Sin ese filtro, `instantiate_task` lanzaría excepción sobre una plantilla desactivada, la transacción haría rollback y la última ocurrencia abierta de esa plantilla sería **imposible de cerrar**. Desactivar una plantilla es cómo se para una recurrencia; tiene que dejar cerrar lo que quedaba abierto.
- **`interval_calendar` exige `app_today() >= anchor_date`.** El `%` de Postgres devuelve resto negativo (`-6 % 3 = 0`), así que sin esa guarda un hábito anclado en el futuro empezaría a aparecer hoy. El ancla es el arranque de la serie, no solo su punto de referencia.
- **Toda tabla nueva del esquema `public` activa RLS sola**, vía el event trigger `trg_rls_auto_enable` (función `rls_auto_enable()`, en `20260724120700_rls_auto_enable.sql`, en fichero aparte porque `create event trigger` exige superusuario y su fallo no debe arrastrar los grants del anterior). Existe porque ya pasó una vez: `task_templates` se creó en su día después del fichero de RLS y quedó abierta a `anon`. Una tabla creada sin más queda ahora con RLS activado y sin políticas → cerrada por defecto. Los `grant` siguen siendo manuales — RLS activo no basta si luego se hace `grant all` a `anon`.
- **Hay que revocar de `PUBLIC`, no solo de `anon`.** Postgres concede `EXECUTE` a `PUBLIC` en cada función nueva y `anon` hereda de `PUBLIC`, así que `revoke all on all functions … from anon` **no cierra nada**: toda función de `public` sigue siendo un endpoint `/rest/v1/rpc/<nombre>` llamable con la clave publishable. Lo que lo cierra es el `revoke execute on all functions in schema public from public` de `20260724120600_rls_contract.sql`, más el `alter default privileges … revoke execute on functions from public` para las futuras. Consecuencia: **una función nueva nace cerrada y necesita su `grant execute … to anon` explícito**; si una RPC da 404, es esto. `service_role` se restituye entero justo después (lo necesita para disparar `set_updated_at()` al escribir).
- **`chain_next_occurrence` es interna de verdad, no por convención.** Antes del revoke desde `PUBLIC` era llamable desde fuera y creaba ocurrencias a petición de cualquiera con la clave pública. Hay un check en `tools/supabase.http` que lo comprueba: si responde 200, el revoke se ha caído.
- **El linter de Supabase da cuatro tipos de aviso asumidos, y hay que distinguirlos de uno real.** `rls_enabled_no_policy` (INFO) en las 11 tablas — es literalmente el diseño: RLS activo y sin políticas es lo que las deja cerradas, y los clientes entran por vistas y RPC `security definer`; si a una tabla le apareciera una política, eso sí habría que mirarlo—, `security_definer_view` en las 4 vistas (es el mecanismo: sin él, `anon` no puede leer nada — "arreglarlo" con `security_invoker = true` las deja devolviendo cero filas y sin error), `function_search_path_mutable` en `app_today()`/`app_timezone()` (son `security invoker`, no escalan privilegios, y la cláusula `SET` les quitaría el inlining en los predicados de las vistas), y `anon_security_definer_function_executable` en las 8 funciones del contrato (`habit_step`, `habit_set`, `habit_undo`, `instantiate_task`, `complete_task`, `uncomplete_task`, `skip_task`, `unskip_task`) — es literalmente el contrato funcionando, `anon` debe poder llamarlas. Si ese aviso apareciera en una función que NO está en la tabla de "Escritura" de `docs/contrato.md` (p.ej. `chain_next_occurrence`), eso sí es una fuga real: significa que su `grant` se coló donde no debía. Cualquier otro aviso hay que mirarlo.
- **`app_timezone()` necesita su propio `grant execute ... to anon`, aunque ningún cliente la llame directamente.** Es `security invoker` (igual que `app_today()`, que la llama por dentro) y una función invoker llamada desde dentro de una vista comprueba el `EXECUTE` contra el rol que hace la consulta (`anon`), no contra el dueño de la vista. Sin ese grant, `v_today_habits`, `v_log_habits` y `v_today_tasks` — las tres vistas que usan la fecha — fallan con `permission denied for function app_timezone`, un 401 que no delata cuál es la función culpable. `v_templates` no la usa y por eso es la única que no lo nota. Se descubrió aplicando las migraciones de verdad contra un proyecto de test; no se ve leyendo el SQL.
- **El Data API ya no expone nada solo.** Desde el cambio de Supabase de 2026-04-28, una tabla o vista nueva de `public` no aparece en `/rest/v1` por existir: lo que la da de alta es su `GRANT`. Los grants de `rls_contract.sql` son a la vez el mínimo privilegio y el alta en la API. Una vista que responde 404 casi siempre es un `grant` que falta, no SQL roto.
- **`create or replace view` no admite insertar una columna nueva en medio de la lista, solo al final.** Postgres lo trata como "renombrar" la columna existente que ocupe esa posición y falla (`cannot change name of view column "x" to "y"`). Se descubrió añadiendo `manual_entry` a `v_today_habits`: hubo que ponerla la última del `select`, después de `day`, en vez de junto a sus columnas relacionadas (`unit`). Si una columna nueva "tiene que" ir en medio por legibilidad, no se puede — va al final y punto.
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
| `habits-core-test` | `dkomeqbvhobkaulogibw` | `test` |

Cada uno tiene su propia integración GitHub↔Supabase, independiente. El disparo
es el **merge**, no el push directo a la rama — un `git push` sin merge no llega
al proyecto. La rama `develop` es la de trabajo y **no despliega a ningún
proyecto por sí sola**.

El proceso obligatorio para llevar un cambio de una rama a otra está arriba, en
[El proceso de todo cambio de base de datos](#el-proceso-de-todo-cambio-de-base-de-datos).

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

Empieza por el linter, que es gratis: `supabase db advisors --level warn` (CLI v2.81.3+) o MCP `get_advisors`. Los cuatro tipos de aviso esperados están arriba; cualquier otro hay que mirarlo.

**Antes de mergear, valida la migration en seco contra el proyecto de test.** El
DDL de Postgres es transaccional, así que se puede aplicar entera dentro de un
`begin; … rollback;` vía MCP `execute_sql`: si hay un error de sintaxis, un
`create or replace view` que intenta reordenar columnas, o un `grant` que se
pierde, salta ahí y no deja rastro. Es lo más parecido a un test de migration
que hay sin CLI ni Docker. Comprobado así: **`create or replace` conserva los
grants** tanto en vistas como en funciones, de modo que reescribir el cuerpo de
una pieza del contrato no obliga a volver a tocar `rls_contract.sql`.

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
- `task_templates` cerrada con RLS + vista `v_templates` para que los clientes listen plantillas
- RLS automático en tablas nuevas de `public` (event trigger `rls_auto_enable`)
- Creación rápida desde plantilla (`show_in_deck` + `instantiate_task` con vencimiento por defecto), consumida por la pantalla "Crear" de `../streamdeck-habits`
- Cronómetros tipo Toggl Track (`timer_labels`, `time_entries`, `timer_toggle`, `v_timer_labels`, `v_running_timer`), consumidos por la pantalla "Cronómetros" de `../streamdeck-habits`
- `v_timer_daily_totals` (segundos acumulados hoy por tarea/etiqueta), consumida por el deck para mostrar el total del día en la tecla de un cronómetro parado

Pendiente:
- Materialización automática de ocurrencias fijas con `pg_cron` (tareas `interval_calendar` y `times_of_day`)
- Tombstones (`deleted_at`) en todas las tablas
- Vistas de análisis (`v_habit_stats`) para Grafana y PWA
- `v_inbox_tasks` (tareas sin fecha)

## Mantén este fichero al día

Si al trabajar descubres que algo descrito aquí ya no coincide con la realidad (una columna que cambió, un comando que no funciona como se documenta), corrígelo en el mismo turno. Este documento solo sirve si las próximas sesiones pueden confiar en él sin verificarlo todo.

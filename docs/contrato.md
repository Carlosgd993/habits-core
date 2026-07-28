# El contrato

Lo único que los clientes pueden usar. Todo lo demás es interno y puede cambiar
sin aviso.

## Por qué existe

Cuatro clientes distintos escriben en la misma base. Si cada uno decide por su
cuenta qué es "hoy", cuál es el siguiente valor de un hábito, o qué UUID de
`statuses` significa "hecho", esa lógica acaba escrita cuatro veces y diverge.
El día que diverja, la Stream Deck y el móvil te enseñarán cosas distintas y no
sabrás cuál miente.

El contrato mueve esas decisiones a un solo sitio.

## Dos ejes ortogonales (hábitos)

Antes de leer las vistas conviene no confundir:

| Eje | Campo | Qué controla | Valores |
| --- | --- | --- | --- |
| **QUÉ** mides | `type` | Cómo avanza el valor | `Boolean` (salta a goal) · `Real` (suma step) |
| **CUÁNDO** toca | `schedule_type` | Qué días aparece el hábito | `interval_calendar` · `weekly_days` · `weekly_quota` · `monthly_day` |

Son independientes: un hábito Boolean puede ser semanal; un Real puede ser diario.

### schedule_type de hábitos

| Valor | Toca hoy si… | `current_value` devuelve |
| --- | --- | --- |
| `interval_calendar` | `(hoy − anchor_date) % interval_n = 0`. Con `n=1` es diario | valor del checkin de hoy |
| `weekly_days` | `isodow(hoy)` está en `byday` (1=lun … 7=dom) | valor del checkin de hoy |
| `weekly_quota` | **siempre** (cualquier día cuenta) | nº de días con checkin en la semana ISO actual |
| `monthly_day` | `day(hoy) = bymonthday` | valor del checkin de hoy |

## Lectura

| Vista | Devuelve |
| --- | --- |
| `v_today_habits` | Hábitos con objetivo que **tocan hoy** según su programación |
| `v_log_habits` | Hábitos de solo registro (nunca pendientes) |
| `v_today_tasks` | Ocurrencias de tarea pendientes con vencimiento hoy o antes |
| `v_templates` | Plantillas activas, para crear tareas a partir de ellas |

### `v_today_habits`

`id`, `name`, `icon_res`, `color`, `type`, `goal`, `step`, `unit`,
`sort_order`, `section_id`, `current_value`, `done`, `day`

Solo salen hábitos con `purpose = 'goal'` **y** cuyo `schedule_type` indica que
hoy es un día que toca (ver tabla arriba). Un hábito sin programación nunca
aparece aquí.

Un hábito **no arrastra deuda**: si ayer quedó en 2/8, hoy empieza en 0/8.
`current_value` **puede superar** a `goal` — 10/8 es válido y deliberado.
`done` solo dice si se alcanzó el objetivo, no bloquea más incrementos.

Para `weekly_quota`, `current_value` es el número de días distintos de la semana
ISO actual en que hubo checkin con `value > 0` — no el valor del día de hoy.
Pulsar el hábito un segundo día de la misma semana sube el contador de 1 a 2.

### `v_log_habits`

`id`, `name`, `icon_res`, `color`, `type`, `unit`, `sort_order`, `section_id`,
`current_value`, `day`

Hábitos con `purpose = 'log'`: nunca tienen objetivo ni programación, nunca son
"pendientes". Sirven para registrar eventos ("bebí cocacola hoy") y consultarlos
luego en analítica. Se puede llamar a `habit_step` sobre ellos igual que en
cualquier hábito.

### `v_today_tasks`

`id`, `title`, `priority`, `project_id`, `sort_order`, `due_date`,
`template_id`, `due_day`, `overdue`, `day`

Muestra **ocurrencias** (filas de `tasks`) que cumplen:

- `completed_time is null` — no completada
- `skipped_time is null` — no omitida
- `due_date` con vencimiento hoy o antes (en la zona horaria local)

Una tarea **sí arrastra**: si venció el lunes y no se hizo, sigue apareciendo
con `overdue = true`. Las tareas **sin fecha no salen aquí**.

#### Ciclo de vida de una ocurrencia

| Estado | Indicador | Aparece en vista |
| --- | --- | --- |
| Pendiente | `completed_time is null` y `skipped_time is null` | Sí |
| Hecha | `completed_time is not null` | No |
| Omitida | `skipped_time is not null` | No |

Las ocurrencias **nunca se borran**: siempre se marcan. Esto preserva la
historia y permite deshacerlos.

#### task_templates vs tasks

`task_templates` contiene la definición reutilizable (título, prioridad,
proyecto, subtareas, schedule_type de la plantilla). `tasks` contiene las
ocurrencias concretas, cada una con su `due_date`, `completed_time`,
`skipped_time` y un `template_id` que apunta a la plantilla (o `null` si es
una tarea única).

La tabla `task_templates` en sí está cerrada (RLS, sin `grant` a `anon`): los
clientes no la tocan directamente. Se lee vía `v_templates` y se instancia vía
`instantiate_task`.

### `v_templates`

`id`, `title`, `project_id`, `priority`, `schedule_type`, `interval_n`,
`bymonthday`, `subtask_count`, `created_at`

Plantillas con `active = true`, ordenadas por `title`. Es justo lo necesario
para que la PWA pinte una fila y llame a `instantiate_task(id)`: no expone
`anchor_date` ni el jsonb crudo de `subtasks` — de eso se encarga
`instantiate_task` por dentro. `subtask_count` evita mandar el jsonb entero al
cliente solo para mostrar "3 subtareas".

## Escritura

| Función | Efecto |
| --- | --- |
| `habit_step(p_habit_id)` → `float` | Avanza un paso. Devuelve el nuevo total |
| `habit_set(p_habit_id, p_value)` → `float` | Fija el total exacto de hoy |
| `habit_undo(p_habit_id)` → `float` | Retrocede un paso |
| `instantiate_task(p_template_id, p_due)` → `uuid` | Crea una ocurrencia a partir de una plantilla |
| `complete_task(p_task_id)` | Cierra una ocurrencia. Idempotente. Encadena la siguiente si es deslizante |
| `uncomplete_task(p_task_id)` | Reabre una ocurrencia |
| `skip_task(p_task_id)` | Marca la ocurrencia como omitida (sale de la vista, queda registrada). Idempotente. Encadena la siguiente igual que `complete_task` |
| `unskip_task(p_task_id)` | Deshace el omitido |

Más `app_today()`. **Esta tabla es exhaustiva**: cualquier otra función que
exista en la base es interna y no es llamable con la clave pública, aunque
aparezca en el SQL. `chain_next_occurrence` es el ejemplo — vive en el mismo
fichero que `complete_task` pero no tiene `grant`, así que `/rest/v1/rpc/` la
rechaza.

### habit_step — comportamiento por tipo y schedule

`habit_step` es atómico (upsert con `on conflict`): pulsar en el deck y en el
móvil a la vez no pierde un incremento.

| Combinación | Qué hace |
| --- | --- |
| `weekly_quota` (cualquier type) | Fija `value = 1` el día actual (idempotente en el día). El contador semanal sube porque hay un día más con checkin |
| `type = Boolean` (no weekly_quota) | Salta directo a `goal` |
| `type = Real` (no weekly_quota) | Suma `step`, sin tope |

### instantiate_task

Crea una fila en `tasks` copiando `project_id`, `title` y `priority` de la
plantilla, e inserta en `checklist_items` las subtareas definidas en el JSON de
`task_templates.subtasks`. Devuelve el `id` de la ocurrencia nueva.

### El enganche deslizante — común a `complete_task` y `skip_task`

Si la ocurrencia viene de una plantilla con
`schedule_type = 'interval_completion'`, al dejar de estar pendiente se crea
automáticamente la siguiente con `due_date = now() + interval_n days`. Así la
tarea deslizante reaparece a los N días desde que la resolviste, no desde el
calendario.

**Completar y omitir encadenan igual.** Omitir no es lo contrario de completar,
es su hermano: en ambos casos la ocurrencia deja de estar pendiente y la
recurrencia sigue su curso. Lo único que cambia es el rastro que queda en la
historia — `completed_time` frente a `skipped_time` —, y que omitir no toca
`status_id` (omitida no es "hecha"). Es lo que permite mirar atrás y distinguir
los días que te tomaste la pastilla de los que no.

Dos casos en los que **no** se encadena, por diseño:

- La ocurrencia no tiene plantilla (`template_id is null`): es una tarea única.
- La plantilla está `active = false`. Desactivarla es cómo se para una
  recurrencia, así que la cadena termina ahí — y la ocurrencia que quedara
  abierta se cierra con normalidad.

### skip_task / unskip_task

`skip_task` pone `skipped_time = now()` si la ocurrencia no está ya cerrada u
omitida, y encadena la siguiente (ver arriba). Es idempotente: omitir dos veces
no reescribe la hora ni duplica la siguiente ocurrencia. La ocurrencia
desaparece de `v_today_tasks` pero queda en `tasks` con su historia.

`unskip_task` limpia `skipped_time`, pero **no borra la ocurrencia que se
encadenó**: si la reabres, tendrás dos abiertas. Mismo comportamiento que
`uncomplete_task`.

## Reglas de evolución

1. **A una vista se le añaden columnas. Nunca se le quitan ni se renombran.**
   Quitar una columna rompe la Raspberry Pi en silencio y te enteras tres días
   después mirando teclas rojas.
2. **Ningún cliente envía nunca una fecha.** La decide `app_today()`.
3. **Ningún cliente conoce un UUID de catálogo.** Ni de `statuses`, ni de
   `projects`. Si hace falta uno, es que falta una función.
4. **El cuerpo de una vista puede reescribirse entero.** Es para eso que existe
   la indirección.

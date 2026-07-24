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

## Lectura

| Vista | Devuelve |
| --- | --- |
| `v_today_habits` | Hábitos activos con su progreso de hoy |
| `v_today_tasks` | Tareas pendientes que vencen hoy o antes |

### `v_today_habits`

`id`, `name`, `icon_res`, `color`, `type`, `goal`, `step`, `unit`,
`sort_order`, `section_id`, `current_value`, `done`, `day`

Un hábito **siempre es de hoy**. No vence, no arrastra deuda: si ayer se quedó
en 2/8, hoy empieza en 0/8. `current_value` **puede superar** a `goal` — 10/8 es
un estado válido. `done` solo dice si se alcanzó el objetivo, no si está
cerrado.

### `v_today_tasks`

`id`, `title`, `priority`, `project_id`, `sort_order`, `due_date`, `due_day`,
`overdue`, `day`

Una tarea **sí arrastra**: si venció el lunes y no se hizo, sigue apareciendo
con `overdue = true`. Al completarse desaparece de la vista (aunque una
recurrencia pueda hacerla reaparecer en otra fecha).

Las tareas **sin fecha no salen aquí**. Con 12 teclas útiles en la Stream Deck,
el inbox entero inundaría la pantalla.

## Escritura

| Función | Efecto |
| --- | --- |
| `habit_step(p_habit_id)` | Avanza un paso. Devuelve el nuevo total |
| `habit_set(p_habit_id, p_value)` | Fija el total exacto de hoy |
| `habit_undo(p_habit_id)` | Retrocede un paso |
| `complete_task(p_task_id)` | Cierra la tarea. Idempotente |
| `uncomplete_task(p_task_id)` | La reabre |

`habit_step` sustituye al patrón leer → calcular → escribir que hacía el daemon.
Es atómico: pulsar en el deck y en el móvil a la vez no pierde un incremento.

Comportamiento por tipo:

- **Boolean** — salta directo a `goal`. Es binario.
- **Real** — suma `step`, **sin tope**.

## Reglas de evolución

1. **A una vista se le añaden columnas. Nunca se le quitan ni se renombran.**
   Quitar una columna rompe la Raspberry Pi en silencio y te enteras tres días
   después mirando teclas rojas.
2. **Ningún cliente envía nunca una fecha.** La decide `app_today()`.
3. **Ningún cliente conoce un UUID de catálogo.** Ni de `statuses`, ni de
   `projects`. Si hace falta uno, es que falta una función.
4. **El cuerpo de una vista puede reescribirse entero.** Cuando lleguen las
   plantillas y las ocurrencias, `v_today_tasks` cambiará por dentro y ningún
   cliente se enterará. Ese es todo el motivo de que exista.

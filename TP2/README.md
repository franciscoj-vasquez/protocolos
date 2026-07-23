# TP2 — Generador LFSR

## Estructura del proyecto

```
TP2/
├── primer_archivo.v
├── rtl/
│   ├── lfsr_generator.v
│   └── lfsr_checker.v
└── tb/
    ├── tb_lfsr_generator.v
    └── tb_lfsr_system.v
```

---

## Estado de verificación

Ambos testbenches fueron compilados y simulados con **Icarus Verilog 12.0** (`iverilog -g2012` + `vvp`):

| Testbench | Tests | Resultado |
|---|---|---|
| `tb_lfsr_generator.v` | TEST 0a, 0b, 0c, 1, 2 (×5 seeds), 3, 4 | 15/15 PASS |
| `tb_lfsr_system.v` | TEST 0, 1, 2, 3, 4 (×5 iter), 5 (×5 iter) | 12/12 PASS |

Para reproducir:

```bash
iverilog -g2012 -o sim_gen.vvp tb/tb_lfsr_generator.v rtl/lfsr_generator.v && vvp sim_gen.vvp
iverilog -g2012 -o sim_sys.vvp tb/tb_lfsr_system.v rtl/lfsr_generator.v rtl/lfsr_checker.v && vvp sim_sys.vvp
```

La primera corrida de `tb_lfsr_system.v` encontró y corrigió una condición de carrera real en `send_valid`/`send_invalid` (ver sección de esa testbench) que hacía perder el último ciclo de cada ráfaga, impidiendo que el checker llegara a lockear.

Al agregar `o_valid` como salida registrada del generador y usarla para alimentar al checker (en vez del `i_valid` del testbench compartido entre ambos DUTs), apareció una variante del mismo problema: `gen_o_valid` queda un ciclo por detrás de `i_valid`, así que `send_valid`/`send_invalid` necesitaron un flanco de drenaje adicional al final de cada ráfaga para que el checker alcance a procesar el último dato antes de que la tarea retorne.

---

## `primer_archivo.v`

Código de referencia extraído del ejecutable provisto por la cátedra. Implementa un LFSR Galois de 16 bits con el polinomio x¹⁶ + x¹⁴ + x¹³ + x¹¹ + 1 (taps en bits 11, 13 y 14), sin resets ni control de valid. Se usa como golden reference para confirmar la topología correcta antes de construir el generador parametrizado.

---

## `rtl/lfsr_generator.v`

**Actividad 1** — Módulo RTL principal (sintetizable).

Implementa el generador LFSR Galois de 16 bits con todas las señales de control requeridas:

| Puerto | Dirección | Descripción |
|---|---|---|
| `i_clk` | in | Clock del sistema |
| `i_rst` | in | Reset **asíncrono** — carga `DEFAULT_SEED` (parámetro fijo) |
| `i_soft_reset` | in | Reset **sincrónico** — carga el valor presente en `i_seed` |
| `i_valid` | in | Habilitación de secuencia — el LFSR solo avanza cuando está en alto |
| `i_seed` | in | Seed configurable en runtime (usada por `i_soft_reset`) |
| `o_data` | out | Salida del LFSR (estado actual del registro) |
| `o_valid` | out | Compañera registrada de `o_data` — en 1 solo en los ciclos donde `o_data` es un avance PRBS genuino |

La lógica de próximo estado es combinacional (`lfsr_next`), separada del bloque secuencial. La prioridad de control es: `i_rst` > `i_soft_reset` > `i_valid` > hold.

`o_valid` se agregó porque la señal de valid debe viajar siempre junto con el dato que califica, en vez de ser reconstruida por cada consumidor a partir de una señal de habilitación compartida por separado. Se implementa como un flip-flop que sigue exactamente la misma cadena de prioridad que `lfsr`: quedará en 0 después de `i_rst` o `i_soft_reset` (el dato resultante es un reset/reseed, no un paso nuevo de la secuencia) y en 1 únicamente cuando la rama de `i_valid` fue la que ganó ese ciclo. Esto importa incluso si `i_valid` está en alto a la vez que `i_soft_reset`: como `i_soft_reset` tiene prioridad y el LFSR no avanza ese ciclo, `o_valid` debe reportar 0 (ver TEST 0c en `tb_lfsr_generator.v`).

---

## `rtl/lfsr_checker.v`

**Actividad 4** — Módulo RTL de verificación (sintetizable).

Conectado a la salida del generador, verifica en cada ciclo válido que el valor recibido corresponde a la secuencia PRBS esperada. Internamente mantiene su propio LFSR de referencia (mismo polinomio) y lo compara contra `i_data`.

| Puerto | Dirección | Descripción |
|---|---|---|
| `i_clk` | in | Clock del sistema |
| `i_rst` | in | Reset asíncrono — vuelve a estado UNLOCKED |
| `i_valid` | in | Indica que hay un dato nuevo disponible para verificar |
| `i_data` | in | Dato proveniente del generador |
| `o_lock` | out | HIGH cuando la secuencia está verificada y el checker está bloqueado |

El módulo en sí es agnóstico de quién genere `i_valid`; en `tb_lfsr_system.v` (Actividad 5) se conecta directamente a `o_valid` de `lfsr_generator`, para que el par valid/dato viaje completo desde el generador hasta el checker en vez de derivarse por separado en el testbench.

Máquina de estados de **dos** estados (sin `ACQUIRE` separado):

- **UNLOCKED**: compara `i_data` contra el valor predicho. Acierto → acumula aciertos consecutivos, al alcanzar 5 → `o_lock = 1` y pasa a LOCKED. Error → no hay estado especial para esto: simplemente no hay (todavía) con qué comparar, así que toma `i_data` como nueva referencia y reinicia el contador de aciertos. Esa misma rama cubre tanto la resincronización inicial (lo que antes hacía `ACQUIRE`) como cualquier pérdida de sincronía posterior, sin gastar un estado ni un ciclo aparte.
- **LOCKED**: acumula errores consecutivos. Al alcanzar 3 → `o_lock = 0` y vuelve a UNLOCKED. Un acierto resetea el contador de errores.

La referencia interna (`lfsr_ref`) se inicializa en `0` — un valor que la secuencia PRBS nunca produce (no pertenece al ciclo maximal de 2¹⁶−1 estados no nulos) — tanto en el reset como al desbloquear. Ese "centinela" garantiza que la primera comparación después de cualquiera de esos dos eventos falle a propósito y dispare la resincronización de UNLOCKED, en vez de arriesgarse a que coincida por casualidad con el dato real (como pasaría si se sembrara con `DEFAULT_SEED`, el valor con el que suele arrancar el generador: la comparación acertaría de pura casualidad y el checker lockearía un ciclo antes de lo esperado, rompiendo los tests de frontera). Gracias al centinela, el tiempo exacto para lockear/relockear no cambió respecto del diseño de tres estados, así que `tb_lfsr_system.v` no necesitó ningún ajuste de conteos de ciclos.

---

## `tb/tb_lfsr_generator.v`

**Actividades 2 y 3** — Testbench del generador aislado.

Verifica el módulo `lfsr_generator` de forma independiente. Incluye:

**Infraestructura (Actividad 2):**
- Clock de 10 MHz (periodo = 100 ns).
- `task_set_seed`: cambia `i_seed` en tiempo de simulación.
- `task_async_reset`: pulsa `i_rst` por una duración aleatoria en [1 µs, 250 µs].
- `task_soft_reset`: pulsa `i_soft_reset` por una duración aleatoria en [1 µs, 250 µs].
- Proceso de valid aleatorio: `rand_valid` se randomiza cada posedge cuando `rand_valid_en = 1`. La señal `i_valid` es un wire mux entre `forced_valid` (tests determinísticos) y `rand_valid` (modo aleatorio), evitando conflictos de driver. Ejercitado por TEST 4.

**Tests (Actividad 3):**
- **TEST 0a**: verifica que `o_data == DEFAULT_SEED` inmediatamente después de `i_rst`, y que `o_valid == 0` (el dato es producto de un reset, no un avance).
- **TEST 0b**: verifica que `o_data == i_seed` inmediatamente después de `i_soft_reset`, y que `o_valid == 0`.
- **TEST 0c**: verifica prioridad — `i_soft_reset` e `i_valid` asertados simultáneamente; el reset debe ganar y `o_valid` debe quedar en 0 (prueba clave de que `o_valid` no es un simple eco de `i_valid`).
- **TEST 1**: mide el período del LFSR con `DEFAULT_SEED`; debe ser exactamente 65 535.
- **TEST 2**: repite la medición de período con 5 seeds aleatorias distintas; todas deben dar 65 535.
- **TEST 3**: verifica que la salida no avanza durante 50 ciclos con `i_valid = 0`, y que `o_valid` se mantiene en 0 durante ese lapso.
- **TEST 4**: activa `rand_valid_en` y compara `o_data`, ciclo a ciclo durante 3000 ciclos, contra un modelo de referencia (`lfsr_step`) que solo avanza en los ciclos donde el `i_valid` muestreado fue 1 — verifica el gating bajo valid genuinamente intermitente. En el mismo lazo compara `o_valid` contra el `i_valid` muestreado un ciclo antes, confirmando que viaja correctamente junto con `o_data` bajo valid intermitente.

---

## `tb/tb_lfsr_system.v`

**Actividad 5** — Testbench del sistema completo (generador + checker integrados).

Instancia ambos módulos RTL y los conecta. Incluye un mux de inyección de errores (`inject_error`) que permite forzar datos incorrectos al checker sin alterar el generador. `u_chk.i_valid` se conecta a `gen_o_valid` (salida del generador), no al `i_valid` del testbench — el par valid/dato viaja completo entre los dos módulos en vez de que el testbench se lo entregue a cada uno por separado.

**Monitor de `o_lock`:** proceso `always @(o_lock)` que imprime un mensaje en consola cada vez que el estado de bloqueo cambia, indicando el valor anterior y el nuevo.

**Tasks auxiliares:**
- `reset_generator` / `reset_checker`: reset asíncrono aleatorio [1 µs, 250 µs] de cada módulo por separado.
- `send_valid(n)` / `send_invalid(n)`: envían `n` ciclos de datos correctos / erróneos (inversión bit a bit) al checker. La desaserción de `i_valid` espera a `@(negedge i_clk)` para no competir con los `always @(posedge i_clk)` del generador/checker en el mismo flanco — sin esto, Icarus resolvía la carrera a favor del testbench y se perdía el último ciclo de cada ráfaga. Como `gen_o_valid` está un ciclo detrás de `i_valid`, además esperan un flanco de drenaje adicional (`@(posedge i_clk)`) tras la desaserción, para que el checker alcance a procesar el último dato de la ráfaga antes de que la tarea retorne. Gracias a ese drenaje, `n` sigue significando "`n` ciclos que el checker efectivamente procesa" y ninguno de los conteos de los tests (`CYCLES_TO_LOCK`, los patrones 4+1, 2+1, 5+3, etc.) tuvo que cambiar.
- `lock_checker`: resetea el checker y le envía los ciclos necesarios para alcanzar estado LOCKED.

**Tests:**
- **TEST 0**: aplica `gen_soft_rst` con seed 0xCAFE, verifica que el generador la carga y que el checker logra lockear desde esa nueva seed.
- **TEST 1**: tráfico válido continuo — verifica que el checker lockea y no se desbloquea durante un período completo (65 535 ciclos).
- **TEST 2**: condición frontera de lock — 4 datos válidos + 1 inválido; verifica que nunca lockea.
- **TEST 3**: condición frontera de unlock — patrón (2 inválidos + 1 válido) × 10 mientras locked; verifica que nunca desbloquea.
- **TEST 4**: transiciones — patrón (5 válidos + 3 inválidos) × 5; verifica que siempre alterna entre LOCKED y UNLOCKED.
- **TEST 5**: reset aleatorio del checker × 5; verifica que siempre vuelve a lockear tras cada reset.

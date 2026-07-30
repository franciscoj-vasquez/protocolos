# TP2 — Generador LFSR

## Estructura del proyecto

```
TP2/
├── primer_archivo.v
├── rtl/
│   ├── lfsr_generator.v
│   ├── lfsr_checker.v
│   └── fsm_style/                  # misma func., otro estilo de codificación
│       ├── lfsr_generator.v
│       └── lfsr_checker.v
└── tb/
    ├── tb_lfsr_generator.v
    ├── tb_lfsr_system.v
    ├── channel_delay.v             # modelo de canal (delay de N ciclos)
    └── tb_lfsr_system_channel.v
```

---

## Estado de verificación

Todos los testbenches fueron compilados y simulados con **Icarus Verilog 12.0** (`iverilog -g2012` + `vvp`):

| Testbench | Tests | Resultado |
|---|---|---|
| `tb_lfsr_generator.v` | TEST 0a, 0b, 0c, 1, 2 (×5 seeds), 3, 4 | 15/15 PASS |
| `tb_lfsr_system.v` | TEST 0, 1, 2, 3, 4 (×5 iter), 5 (×5 iter) | 12/12 PASS |
| `tb_lfsr_system_channel.v` | TEST C0, C1 (×5 delays), C2, C3, C4 (×8 iter) | 11/11 PASS |

Para reproducir:

```bash
iverilog -g2012 -o sim_gen.vvp tb/tb_lfsr_generator.v rtl/lfsr_generator.v && vvp sim_gen.vvp
iverilog -g2012 -o sim_sys.vvp tb/tb_lfsr_system.v rtl/lfsr_generator.v rtl/lfsr_checker.v && vvp sim_sys.vvp
iverilog -g2012 -o sim_chan.vvp tb/tb_lfsr_system_channel.v tb/channel_delay.v rtl/lfsr_generator.v rtl/lfsr_checker.v && vvp sim_chan.vvp
```

`rtl/fsm_style/` y `tb/channel_delay.v` + `tb/tb_lfsr_system_channel.v` son extensiones no pedidas por la consigna — ver sus propias secciones más abajo para el detalle de qué son y cómo se verificaron.

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

## `rtl/fsm_style/` (extensión — no pedida por la consigna)

Reescritura de `lfsr_generator.v` y `lfsr_checker.v` con el patrón de dos `always` separados: uno combinacional (`always @*`) con `case` para la lógica de próximo estado, y otro secuencial (`always @(posedge i_clk or posedge i_rst)`) que solo registra lo que decidió el combinacional. Mismo nombre de módulo y misma interfaz que los originales — pensado para poder recompilarse contra los testbenches existentes sin tocar ni una línea de esos testbenches. `rtl/lfsr_generator.v` y `rtl/lfsr_checker.v` (ya verificados) quedan intactos; esta es una versión paralela, no un reemplazo.

**Por qué `i_rst` no entra al `case` combinacional:** es asíncrono, y para que eso sea real en hardware (no un reset sincrónico disfrazado) tiene que resolverse en la sensitivity list del propio `always` secuencial (`posedge i_clk or posedge i_rst`). El combinacional solo resuelve la prioridad `i_soft_reset` > `i_valid` > hold (generador) o el `case` sobre `state` (checker); `i_rst` gana por fuera de ese case, en el secuencial.

**Defaults contra latches:** ambos combinacionales asignan valores de "hold" a todas sus señales `next_*` antes del `case`, y el `case` tiene además rama `default` explícita — doble cobertura para que ninguna señal quede sin definir en ningún camino del bloque.

- Selector del generador: `ctrl_sel = {i_soft_reset, i_valid}` (`fsm_style/lfsr_generator.v:82`) — las señales de control encendidas/apagadas se usan directamente como entrada del `case` que arma `next_lfsr`/`next_o_valid`.
- Selector del checker: `case (state)` (`fsm_style/lfsr_checker.v:112`) — encaja naturalmente porque el checker ya tenía una FSM de 2 estados explícita.

**Verificación de equivalencia:** se recompilaron `tb_lfsr_generator.v` y `tb_lfsr_system.v`, **sin modificarlos**, apuntando a estos archivos en vez de a los originales:

```bash
iverilog -g2012 -o sim_gen_fsm.vvp tb/tb_lfsr_generator.v rtl/fsm_style/lfsr_generator.v && vvp sim_gen_fsm.vvp
iverilog -g2012 -o sim_sys_fsm.vvp tb/tb_lfsr_system.v rtl/fsm_style/lfsr_generator.v rtl/fsm_style/lfsr_checker.v && vvp sim_sys_fsm.vvp
```

Resultado: mismos 27/27 PASS que las versiones originales. Adicionalmente, por fuera de estos testbenches (stress test exploratorio, no versionado), se compararon ambas versiones ciclo a ciclo durante 20 000 ciclos con `i_rst`/`i_soft_reset`/`i_valid` aleatorios y simultáneos — 0 diferencias, incluyendo (para el checker) el estado interno completo (`state`, `lfsr_ref`, `valid_cnt`, `invalid_cnt`), no solo `o_lock`.

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

---

## `tb/channel_delay.v` y `tb/tb_lfsr_system_channel.v` (extensión — no pedida por la consigna)

Modelo de canal de comunicación insertado entre generador y checker, para simular latencia de transmisión (mayor o menor "distancia") en vez de la conexión directa `gen_o_valid`/`gen_o_data` → checker que usa `tb_lfsr_system.v`.

**`channel_delay.v`:** shift register de `MAX_DELAY` etapas que desplaza **siempre**, ciclo a ciclo, sin importar el valor de `i_delay` — `i_delay` solo selecciona de qué etapa se lee, nunca detiene ni salta el desplazamiento. `data` y `valid` avanzan siempre juntos, etapa por etapa (mismo principio que `o_valid`/`o_data` en `lfsr_generator.v`, aplicado ahora a cada etapa del canal en vez de a un único flip-flop). `i_delay = 0` es un passthrough combinacional, equivalente a la conexión directa que usa `tb_lfsr_system.v`.

Cambiar `i_delay` mientras hay datos en tránsito haría que la lectura "salte" a otra edad del buffer (dato repetido si N sube, salteado si N baja) — no es un bug del módulo, es lo que pasaría en la vida real si se cambiara la longitud de un cable en caliente. La responsabilidad de cambiar `i_delay` en un momento seguro es del testbench, no del módulo:

- `set_channel_delay(n)` (`tb_lfsr_system_channel.v:169`): pulsa `i_rst` del canal junto con el cambio de `chan_delay`, para que arranque "vacío" en la nueva distancia — como reconectar el cable.
- `randomize_channel_delay()` (`tb_lfsr_system_channel.v:183`): elige `n` con `$urandom_range(0, MAX_DELAY)` y llama a `set_channel_delay` — simula reconectar a una distancia aleatoria entre ráfagas.

La inyección de errores (`inject_error`) se aplica **antes** del canal (`tx_data = inject_error ? ~gen_o_data : gen_o_data`, alimentando al canal): el canal transporta fielmente lo que se le entrega, sea el dato correcto o uno corrompido a propósito, igual que un canal real no "arregla" los bits que le llegan mal.

**Drenaje generalizado:** con canal, el último dato de una ráfaga tarda 1 ciclo (registro propio del generador) + `chan_delay` ciclos (propagación por el canal) en llegar al checker. `send_valid`/`send_invalid` generalizan el drenaje fijo de `tb_lfsr_system.v` (un solo `@(posedge i_clk)`) a `repeat (chan_delay + 1) @(posedge i_clk)` — con `chan_delay = 0` coincide exactamente con el drenaje original, así que ambos testbenches concuerdan en ese caso límite.

**Tests:**
- **TEST C0**: `delay = 0` — regresión, debe comportarse igual que `tb_lfsr_system.v` sin canal.
- **TEST C1**: lock a través de 5 distancias fijas (0, 4, 8, 12, 16 ciclos).
- **TEST C2**: tráfico válido continuo con `delay = MAX_DELAY` (31, el máximo que entra en los 5 bits de `i_delay`) — no debe desbloquear en un período completo (65 535 ciclos).
- **TEST C3**: fronteras de lock/unlock (mismos patrones que TEST 2/3 de `tb_lfsr_system.v`) con `delay = 7`.
- **TEST C4**: 8 iteraciones de lock→unlock, cada una con una distancia aleatoria distinta entre ráfagas (vía `randomize_channel_delay`).

Resultado: 11/11 PASS (C0=1, C1=5 individuales + 1 agregado, C2=1, C3=2, C4=1 agregado sobre 8 iteraciones — mismo criterio de conteo que las tablas de arriba: líneas que contienen la palabra PASS en una corrida limpia). Se verificó además, por fuera de este testbench (probe exploratorio, no versionado), que el canal reproduce dato y valid bit-exacto con el retardo esperado: 2447 muestras comparadas contra una cola de referencia para delay ∈ {0, 1, 5, 20, 31}, 0 mismatches (31 = `MAX_DELAY`, el límite real del canal).

Para reproducir:

```bash
iverilog -g2012 -o sim_chan.vvp tb/tb_lfsr_system_channel.v tb/channel_delay.v rtl/lfsr_generator.v rtl/lfsr_checker.v && vvp sim_chan.vvp
```

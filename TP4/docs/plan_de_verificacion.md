# Plan de verificación — PCS 10GBASE-R de *taxi* (fase 1: XGMII ↔ PCS)

Versión 1 (octubre 2026). Estado de ejecución: tests escritos, pendientes de correr con Verilator
(ver [Estado](#10-estado-y-registro-de-resultados)).

## 1. Objetivo y alcance

**Objetivo**: decidir, con evidencia de simulación, si los bloques 10G de `fpganinja/taxi` cumplen
IEEE 802.3 en lo que respecta a la interfaz XGMII (cláusula 46) y a la PCS 64B/66B de 10GBASE-R
(cláusula 49). El veredicto se da **por requisito**: *cumple*, *no cumple* (con evidencia),
*no aplica* o *no verificado*.

**Diseños bajo prueba** (repo `fpganinja/taxi`, commit `cc70b27`, 2026-08-28):

| Nivel | DUT | Bloques internos (solo para ubicar ondas) |
|---|---|---|
| Unidad | `taxi_xgmii_baser_enc` | codificador XGMII → 64B/66B |
| Unidad | `taxi_xgmii_baser_dec` | decodificador 64B/66B → XGMII |
| Top | `taxi_eth_phy_10g` | `_tx`: codificador, scrambler, PRBS31; `_rx`: block lock, monitor de BER, *watchdog*, descrambler, decodificador |
| Integración | 2 × `taxi_eth_phy_10g` (A ↔ B) | *wrapper* `tb_eth_phy_10g_duplex.sv` |

`taxi_eth_phy_10g_tx` y `taxi_eth_phy_10g_rx` son envoltorios delgados del top: se verifican a través
de él (configuración *split*, en la que el camino TX y el RX se estimulan por separado).

**Fuera de alcance en esta fase**: MAC (`taxi_eth_mac_10g`), MAC+PCS (`taxi_eth_mac_phy_10g`),
interfaz de *gearbox* del transceptor (`GBX_IF_EN = 1`), USXGMII, PTP, FEC (cláusula 74) y el
comportamiento EEE/LPI más allá de la codificación de /LI/.

**Configuración bajo prueba** (valores por defecto del RTL salvo indicación):

| Parámetro | Valor | Comentario |
|---|---|---|
| `DATA_W` / `CTRL_W` / `HDR_W` | 64 / 8 / 2 | XGMII de 64 bits a 156,25 MHz (6,4 ns) |
| `TX_GBX_IF_EN` / `RX_GBX_IF_EN` | 0 | sin *gearbox* |
| `BIT_REVERSE` | 0 | `hdr[0]` es el primer bit transmitido |
| `SCRAMBLER_DISABLE` | 0 | scrambler activo |
| `PRBS31_EN` | 1 | lógica de patrón de prueba presente (deshabilitada por `cfg_*`) |
| `TX/RX_SERDES_PIPELINE` | 0 | se puede variar (`make PARAM_TX_SERDES_PIPELINE=2`) |
| `BITSLIP_HIGH/LOW_CYCLES` | 1 / 7 | |
| `COUNT_125US` | 195 | timer de 125 µs escalado 1:100 para simular rápido; valor real 19531,25 |

Configuraciones secundarias previstas (fase 1b): `SERDES_PIPELINE = 2`, `BIT_REVERSE = 1`,
`SCRAMBLER_DISABLE = 1`, `DATA_W = 32` (requiere agentes de 32 bits).

## 2. Referencias

| Ref. | Documento | Uso |
|---|---|---|
| [802.3] | IEEE Std 802.3-2022, cláusulas 44.3, 46, 49 | requisitos (accesible gratis por el programa IEEE GET) |
| [UNH] | UNH-IOL, *Introduction to 10 Gigabit 64b/66b (Clause 49)*, 2001 | diagramas de lock, BER, TX y RX (de P802.3ae/D3.2); ejemplos de codificación |
| [DF] | E. Opsasnick, *Stateless 64B/66B Encode/Decode for 800GbE and 1.6TbE*, IEEE P802.3df, oct. 2022 | diagramas TX/RX vigentes y **tabla de secuencias de ejemplo** con la salida esperada |
| [TP3] | Informe TP3 (labs 2 y 3) | vectores de codificación ya verificados en el curso |
| [taxi] | `fpganinja/taxi`, `src/eth/rtl`, `src/eth/tb` | puertos, parámetros y convenciones de bits |
| [cocotb] | cocotb 2.0.1, Verilator 5.050 | entorno |

> La numeración de figuras de la cláusula 49 cambió entre ediciones (los diagramas de lock, BER, TX y
> RX son 49-12…49-15 en 802.3-2008 y 49-14…49-17 desde que se agregó EEE). Este plan cita subcláusulas;
> conviene confirmar números contra la edición que use la cátedra.

## 3. Estrategia

1. **Caja negra ("como IP")**: se estimula y observa solo por los puertos. Del RTL se tomaron únicamente
   puertos, parámetros y convenciones de bits (sección 5).
2. **Modelo de referencia independiente** (`verif/vip/baser.py`), escrito desde la norma: tablas de
   códigos y formatos, funciones `T_TYPE`/`R_TYPE`, `ENCODE`/`DECODE`, diagramas de estados TX y RX
   (incluido el *look-ahead* `R_TYPE_NEXT`), scrambler/descrambler y diagrama de block lock.
   No se usan los modelos del autor del DUT (`cocotbext-eth`, `baser.py` de *taxi*).
3. **Verificar al verificador**: antes de juzgar al DUT, el modelo se prueba contra vectores externos
   ([TP3], [UNH], tabla de [DF]) e implementaciones bit a bit (`verif/selftest`, 53 pruebas).
4. **Agentes reutilizables** (los del boceto de clase): Agente 1 (PRBS → MII), Agente 2
   (MII → MAC → PRBS), agente PCS (driver y monitor de bloques de 66 bits) y canal (loopback /
   full duplex, retardo, errores de bit, desalineación y *bit-slip*). Los mismos agentes se usan en
   unidad, top e integración.
5. **Niveles**: unidad (enc, dec) → top (PHY en *split* y en *loopback*) → integración (full duplex).
6. **Estímulos**: dirigidos (los 15 formatos, vectores inválidos exhaustivos, secuencias de [DF]) y
   aleatorios con restricciones y semilla reproducible (largos 1–9600 octetos, IPG 1–12 con y sin DIC,
   carril de inicio 0/4, errores de línea).
7. **Chequeos**:
   - *scoreboard* de flujo, ciclo a ciclo: la salida del DUT se alinea con la del modelo en el primer
     ítem no-idle (latencia desconocida, caja negra) y desde ahí debe coincidir 1 a 1; una latencia
     que varíe también es un error;
   - propiedades temporales con cotas (umbrales de lock y de BER, cuya temporización exacta depende
     de la implementación);
   - nivel trama (Agente 2): preámbulo, SFD, FCS, /E/, *payload* y PRBS.
8. **Cobertura funcional** con puntos y *bins* explícitos (sección 8) y criterio de cierre (sección 9).

## 4. Arquitectura del testbench

```text
Unidad encoder:   Agente1 --xgmii_txd/txc--> [enc] --encoded_tx_hdr/data--> PcsMonitor --+
                  (palabras registradas) --> modelo: diagrama TX + ENCODE --> scoreboard <-+

Unidad decoder:   PcsDriver --encoded_rx_hdr/data--> [dec] --xgmii_rxd/rxc--> Agente2 --+
                  (bloques registrados) --> modelo: diagrama RX + DECODE --> scoreboard <-+

Top "split":      Agente1 --> [PHY TX] --serdes_tx--> PcsMonitor (descrambler de referencia)
                  PcsDriver (scrambler de ref., errores, bit-slip) --serdes_rx--> [PHY RX] --> Agente2

Top "loopback":   Agente1 --> [PHY TX] --serdes_tx--> Canal --serdes_rx--> [PHY RX] --> Agente2

Full duplex:      Agente1A --> [A TX] --> Canal A->B --> [B RX] --> Agente2B
                  Agente2A <-- [A RX] <-- Canal B->A <-- [B TX] <-- Agente1B
                  (el RX de cada PHY usa el reloj de TX del otro, como un reloj recuperado)
```

## 5. Interfaces y convenciones (supuestos sobre el IP)

| Tema | Convención | Origen |
|---|---|---|
| Reloj | 156,25 MHz (6,4 ns); 1 ciclo = 64 BT a 10 Gb/s | 10GBASE-R con bus de 64 bits |
| XGMII | 64 bits SDR (dos columnas de la XGMII de 32 bits); carril 0 = `txd[7:0]` / `txc[0]` = primer octeto | [taxi] + cl. 46 |
| Bloque de 66 bits | `hdr[0]` = bit 0 en la línea; `data[i]` = bit i+2. Cabecera de datos "01" = `2'b10`; de control "10" = `2'b01` | [taxi], `BIT_REVERSE = 0` |
| Validez | `xgmii_tx_valid`, `serdes_rx_*_valid` = 1; salidas `*_valid` = 1 sin *gearbox* | [taxi] |
| *Bit-slip* | cada pulso de `serdes_rx_bitslip` pide correr la ventana de 66 bits una posición (el canal lo emula por flanco) | [taxi], SLIP de 49.2.9 |
| Estado propio de *taxi* | `tx_bad_block`, `rx_bad_block`, `rx_sequence_error`, `rx_error_count`, `rx_status` (*watchdog*), `serdes_rx_reset_req` | extensiones, sin requisito normativo directo: se registran como informativas |

## 6. Requisitos

Prioridad: **P1** = conformidad central, **P2** = manejo de errores/condiciones de borde,
**P3** = opcional o informativo.

### 6.1 XGMII (cláusula 46)

| ID | Requisito | Ref. | P |
|---|---|---|---|
| XG-01 | Caracteres de control: /I/ 0x07, /S/ 0xFB, /T/ 0xFD, /E/ 0xFE, /Q/ 0x9C, /Fsig/ 0x5C, /LI/ 0x06 y reservados 0x1C, 0x3C, 0x7C, 0xBC, 0xDC, 0xF7 | 46.3, Tabla 49-1 | P1 |
| XG-02 | /S/ solo en el carril 0 de una columna (carril 0 o 4 del bus de 64 bits) | 46.3.1 | P1 |
| XG-03 | *Local Fault* = /Q/ 0x00 0x00 0x01 | 46.3.4 | P1 |

### 6.2 Codificación 64B/66B (49.2.4)

| ID | Requisito | Ref. | P |
|---|---|---|---|
| ENC-01 | Bloque de datos: cabecera 01 y los 8 octetos sin cambios, en orden de transmisión | 49.2.4.3 | P1 |
| ENC-02 | Bloque de control: cabecera 10, *block type* y códigos de 7 bits de la Tabla 49-1 (/I/→0x00, /LI/→0x06, /E/→0x1E, reservados→0x2D…0x78) | 49.2.4.4, Tabla 49-1 | P1 |
| ENC-03 | Los 15 formatos de control de la Figura 49-7 (0x1E, 0x2D, 0x33, 0x66, 0x55, 0x78, 0x4B, 0x87, 0x99, 0xAA, 0xB4, 0xCC, 0xD2, 0xE1, 0xFF), relleno en 0 | Figura 49-7 | P1 |
| ENC-04 | *Ordered sets*: código O 0x0 para /Q/ y 0xF para /Fsig/, con sus 3 octetos de datos | 49.2.4.9 | P1 |
| ENC-05 | /T/ en cualquiera de los 8 carriles; /S/ en carril 0 (0x78) o 4 (0x33 / 0x66) | Figura 49-7 | P1 |
| ENC-06 | Tráfico válido arbitrario se codifica 1 bloque por palabra, sin pérdidas ni inserciones (latencia constante) | 49.2.4 (la inserción/borrado de idles solo aplica con WIS) | P1 |

### 6.3 Diagrama de estados de transmisión (49.2.13)

| ID | Requisito | Ref. | P |
|---|---|---|---|
| TXSM-01 | Una palabra con `T_TYPE = E` (carácter inválido o mal ubicado) se transmite como EBLOCK_T (ocho /E/) | 49.2.13, TX_E | P2 |
| TXSM-02 | Secuencias inválidas (D o T sin S previo, S dentro de trama, C sin /T/) producen EBLOCK_T según el diagrama | 49.2.13, TX_E | P2 |
| TXSM-03 | Las secuencias de ejemplo de [DF] producen la columna "TX state machine output" | [DF] | P2 |
| TXSM-04 | Mientras `reset` está activo se transmite LBLOCK_T (TX_INIT) | 49.2.13, TX_INIT | P3 |

### 6.4 Scrambler (49.2.6)

| ID | Requisito | Ref. | P |
|---|---|---|---|
| SCR-01 | Scrambler autosincronizante G(x) = 1 + x³⁹ + x⁵⁸ sobre los 64 bits de carga, en orden de transmisión | 49.2.6, Figura 49-8 | P1 |
| SCR-02 | La cabecera de sincronismo no se aleatoriza (siempre 01/10 en la línea) | 49.2.6 | P1 |
| SCR-03 | El descrambler recupera los datos al sincronizarse (sin semilla compartida) | 49.2.10 | P1 |

### 6.5 Decodificación (49.2.4, 49.2.11)

| ID | Requisito | Ref. | P |
|---|---|---|---|
| DEC-01 | Bloques válidos → caracteres XGMII correctos (inverso de ENC-01…05) | 49.2.11 | P1 |
| DEC-02 | Los 15 formatos de control decodificados | Figura 49-7 | P1 |
| DEC-03 | Cabecera inválida (00 u 11) → `R_TYPE = E` → ocho /E/ | 49.2.13 (R_TYPE) | P1 |
| DEC-04 | *Block type* no definido (241 valores) → ocho /E/ | 49.2.13 (R_TYPE) | P1 |
| DEC-05 | Código de control de 7 bits o código O inválido → ocho /E/ | 49.2.13 (R_TYPE) | P2 |
| DEC-06 | Tráfico válido arbitrario se decodifica sin pérdidas (transparencia) | 49.2.11 | P1 |

### 6.6 Diagrama de estados de recepción (49.2.13)

| ID | Requisito | Ref. | P |
|---|---|---|---|
| RXSM-01 | Bloque tipo E → EBLOCK_R (ocho /E/) | RX_E | P1 |
| RXSM-02 | Secuencias inválidas (D fuera de trama, S dentro de trama, C sin /T/) → EBLOCK_R | RX_E | P2 |
| RXSM-03 | /T/ se acepta solo si el bloque siguiente es S, C o LI (`R_TYPE_NEXT`); tabla de [DF], columna RX | RX_D / RX_T | P2 |
| RXSM-04 | Con `reset`, `hi_ber` o `!block_lock` el receptor está en RX_INIT y entrega LBLOCK_R (*Local Fault*) a la XGMII | RX_INIT | P1 |
| RXSM-05 | Con errores de línea, la salida XGMII es la del diagrama RX aplicado al flujo recibido (incluye la multiplicación ×3 del descrambler) | 49.2.10, 49.2.13 | P2 |

### 6.7 Sincronismo de bloque (49.2.9, diagrama de lock)

| ID | Requisito | Ref. | P |
|---|---|---|---|
| LOCK-01 | `block_lock` se declara tras 64 cabeceras válidas consecutivas, nunca antes | lock: 64_GOOD | P1 |
| LOCK-02 | Sin lock, cada cabecera inválida provoca un SLIP de una posición; desde un corrimiento de k bits se alinea con exactamente 66−k *slips* | lock: SLIP | P1 |
| LOCK-03 | Con lock, menos de 16 cabeceras inválidas en una ventana de 64 no lo hacen perder | lock: INVALID_SH | P1 |
| LOCK-04 | 16 cabeceras inválidas en una ventana de 64 → `block_lock = 0` | lock: SLIP | P1 |
| LOCK-05 | Tras perder el lock, se recupera con 64 cabeceras válidas | lock | P1 |

### 6.8 Monitor de BER (diagrama BER monitor)

| ID | Requisito | Ref. | P |
|---|---|---|---|
| BER-01 | Menos de 16 cabeceras inválidas en 125 µs → `hi_ber = 0` | BER monitor | P1 |
| BER-02 | 16 o más en 125 µs → `hi_ber = 1` | BER monitor | P1 |
| BER-03 | `hi_ber` se libera tras una ventana completa de 125 µs con menos de 16 errores (alto ≥ 1 ventana; libre ≤ 2 ventanas después del último error) | BER monitor: GOOD_BER | P1 |
| BER-04 | Con `!block_lock` el monitor queda en BER_MT_INIT (`hi_ber = 0`) — *a confirmar con la edición vigente* | BER monitor | P2 |
| BER-05 | Temporizador de 125 µs (+1 % / −25 %) con el reloj de 156,25 MHz | 49.2.13 (timers) | P3 |

### 6.9 Retardo, patrones de prueba, extremo a extremo

| ID | Requisito | Ref. | P |
|---|---|---|---|
| LAT-01 | Retardo de la PCS, TX + RX, ≤ 3584 BT (= 56 ciclos de 6,4 ns); constante | 49.2.15, Tabla 44-2 | P1 |
| TP-01 | Modo PRBS31 en TX: la línea (66 bits) sigue x³¹ + x²⁸ + 1 | 49.2.8 (opcional) | P2 |
| TP-02 | Chequeador PRBS31 en RX: 0 errores en loopback limpio; cuenta errores inyectados | 49.2.12 (opcional) | P2 |
| TP-03 | Patrones *square wave* y *pseudo-random* (semillas A/B) y su chequeador, usados en los ensayos del PMD. El IP no expone control para ellos (no tiene MDIO): se verifica por inspección de interfaz — *a confirmar si la edición vigente los exige* | 49.2.8, 49.2.12 | P3 |
| E2E-01 | En loopback, toda trama llega igual (payload y FCS), con lock desde cualquier desalineación | — | P1 |
| E2E-02 | Sin errores de línea, el flujo XGMII de RX es idéntico al de TX | — | P1 |
| E2E-03 | El *payload* PRBS llega sin errores de bit | — | P1 |
| E2E-04 | Con errores de línea, ninguna trama corrupta se entrega como buena (la detecta la FCS o una /E/) | — | P1 |
| FD-01 | Tráfico simultáneo e independiente en ambos sentidos, sin errores | — | P1 |
| FD-02 | La caída de un sentido no afecta al otro; el sentido caído se recupera | — | P2 |

## 7. Casos de prueba

Directorio `verif/tb/<testbench>/`; comando `make COCOTB_TEST_FILTER=<test>`.

| Test | Nivel | Tipo | Qué hace / criterio de aprobación | Requisitos | P |
|---|---|---|---|---|---|
| `test_enc_idle` | enc | dir. | idles → bloques 0x1E con códigos 0x00 | ENC-02 | P1 |
| `test_enc_block_formats` | enc | dir. | secuencia legal con los 15 formatos, /T/ en 8 carriles, /Q/ y /Fsig/, reservados, tramas pegadas; igual al modelo y cobertura de formatos 100 % | ENC-01…05, XG-01 | P1 |
| `test_enc_random_frames` ×8 | enc | aleat. | 150 tramas PRBS por variante (IPG 12/1, DIC sí/no, carril 0/aleatorio); igual al modelo; cobertura de carril de /T/ 100 % | ENC-06, XG-02 | P1 |
| `test_enc_invalid_xgmii` | enc | dir. | 10 palabras inválidas en reposo y dentro de trama; tabla por vector; igual al diagrama TX | TXSM-01, TXSM-02 | P2 |
| `test_enc_ieee_sequences` | enc | dir. | 9 secuencias de [DF]; tipos observados = columna TX | TXSM-02, TXSM-03 | P2 |
| `test_dec_idle` | dec | dir. | bloques idle → 8 × /I/ | DEC-01 | P1 |
| `test_dec_block_formats` | dec | dir. | los 15 formatos; igual al modelo | DEC-01, DEC-02 | P1 |
| `test_dec_random_frames` ×4 | dec | aleat. | 150 tramas; palabra a palabra + Agente 2 (FCS, payload, PRBS) | DEC-06 | P1 |
| `test_dec_invalid_blocks` | dec | dir. | 11 bloques inválidos (cabeceras, códigos, códigos O) en reposo y en trama; tabla por vector | DEC-03, DEC-05, RXSM-01 | P1 |
| `test_dec_invalid_block_types` | dec | dir. exh. | los 241 *block types* no definidos → 8 × /E/ | DEC-04 | P1 |
| `test_dec_ieee_sequences` | dec | dir. | 9 secuencias de [DF]; tipos observados = columna RX | RXSM-02, RXSM-03 | P2 |
| `test_phy_tx_frames` ×2 | top split | aleat. | TX descrambleado = modelo; cabeceras siempre 01/10; latencia TX | ENC-06, SCR-01, SCR-02 | P1 |
| `test_phy_tx_lblock_in_reset` | top | dir. | con `tx_rst = 1` la línea lleva LBLOCK_T | TXSM-04 | P3 |
| `test_phy_rx_frames` | top split | aleat. | tráfico de referencia aleatorizado → XGMII = diagrama RX; tramas y PRBS OK; latencia RX | DEC-06, SCR-03 | P1 |
| `test_phy_rx_lock_offsets` | top split | dir. | 19 corrimientos (1…65 bits): *slips* = 66−k; lock ≥ 64 ciclos después de alinear; tráfico OK luego | LOCK-01, LOCK-02, LOCK-05 | P1 |
| `test_phy_rx_lock_hold_and_loss` | top split | dir. | 15 cabeceras malas seguidas: no pierde lock; 31 seguidas: lo pierde (≤ 47 ciclos) y vuelve ≥ 64 ciclos después | LOCK-03, LOCK-04, LOCK-05 | P1 |
| `test_phy_rx_hi_ber` | top split | dir. | 15 errores espaciados: `hi_ber` = 0; 31 espaciados (sin perder lock): `hi_ber` = 1; se libera entre 1 y 2 ventanas | BER-01…03 | P1 |
| `test_phy_rx_hi_ber_reset_on_unlock` | top split | dir. | línea desalineada (sin lock): `hi_ber` debe quedar en 0 | BER-04 | P2 |
| `test_phy_rx_local_fault` | top split | dir. | sin lock y con `hi_ber`: todas las palabras XGMII son *Local Fault* | RXSM-04, XG-03 | P1 |
| `test_phy_rx_error_handling` | top split | aleat. | errores de bit en la carga + bloques inválidos; XGMII = diagrama RX sobre el flujo recibido | RXSM-05 | P2 |
| `test_phy_loopback` ×4 | top loop | aleat. | retardo 0/5, corrimiento 0/17 bits; 200 tramas; tramas, flujo XGMII TX = RX, PRBS, TX y retardo ≤ 3584 BT | E2E-01…03, LAT-01 | P1 |
| `test_phy_loopback_bit_errors` | top loop | aleat. | ~1 error cada 300 bloques: ninguna trama corrupta "buena"; lock estable; errores visibles en PRBS | E2E-04 | P1 |
| `test_phy_prbs31` | top loop | dir. | `cfg_*_prbs31_enable`: línea = PRBS31; 0 errores; errores inyectados contados (×1…×3) | TP-01, TP-02 | P2 |
| `test_duplex_traffic` | integración | aleat. | A↔B simultáneo, corrimientos distintos por sentido; tramas, flujos y PRBS en ambos sentidos | FD-01, E2E-01…03 | P1 |
| `test_duplex_link_down_one_direction` | integración | dir. | se corta A→B: B pierde lock, A no; B→A sin errores; A→B se recupera | FD-02, LOCK-04, LOCK-05 | P2 |

Pendientes / próximos: BER-05 (correr `test_phy_rx_hi_ber` con `COUNT_125US=19531.25`), configuraciones
secundarias (sección 1), LPI (EEE, P3).

## 8. Cobertura funcional

| Punto | *Bins* | Meta | Dónde se mide |
|---|---|---|---|
| Formato de bloque (TX y RX) | D + 15 *block types* | 100 % | `test_enc_block_formats`, `test_dec_*` |
| Carril de /T/ | 0…7 | 100 % | tests aleatorios y de formatos |
| Carril de /S/ | 0, 4 | 100 % | tests aleatorios (`start_lane=random`) |
| Largo de trama | 1–59, 60, 61–127, 128–511, 512–1514, 1515–9600 | 100 % | tests aleatorios |
| IPG | 1, ≥ 9 con DIC, ≥ 12 sin DIC | todos | parametrización |
| Entradas TX inválidas | 10 categorías × {reposo, en trama} | 100 % | `test_enc_invalid_xgmii` |
| Entradas RX inválidas | cabecera 00/11, 241 *block types*, códigos 7 bits, códigos O | 100 % | `test_dec_invalid_*` |
| Corrimientos de bit para lock | 19 valores en 1…65 | 100 % | `test_phy_rx_lock_offsets` |
| Errores de línea | cabecera / carga | ambos | `test_phy_loopback_bit_errors` |

Cada test escribe `reports/cov_<test>.json` y muestra los *bins* no cubiertos en el log.

## 9. Criterios de finalización

1. Self-tests del VIP: 100 % pasan.
2. Tests P1: pasan, o fallan con una **desviación documentada** (requisito, ref. a la norma, vector,
   tiempo de simulación, captura de GTKWave y análisis de impacto).
3. Ante cada discrepancia se revisan ambos lados (DUT y modelo) antes de declarar un hallazgo.
4. Cobertura de la sección 8 al 100 %.
5. Regresión completa con al menos 3 semillas sin fallas no explicadas.
6. Tabla de veredictos por requisito completa (sección 10).

## 10. Estado y registro de resultados

| Ítem | Estado |
|---|---|
| Self-tests del VIP (`make selftest`) | 53/53 pasan (Python 3.12, sin simulador) |
| Testbenches | escritos; importan con cocotb 2.0.1; **sin ejecutar con Verilator** |

Veredicto por requisito (completar tras la ejecución):

| Requisito | Resultado | Evidencia |
|---|---|---|
| XG-01…03, ENC-01…06, SCR-01…03, DEC-01…06 | pendiente | |
| TXSM-01…04, RXSM-01…05 | pendiente | |
| LOCK-01…05, BER-01…05 | pendiente | |
| LAT-01, TP-01…03, E2E-01…04, FD-01…02 | pendiente | |

## 11. Riesgos, supuestos y limitaciones

- **Texto de la norma**: los requisitos se tomaron de la cláusula 49 y de documentos públicos del IEEE
  ([UNH], [DF]); los números de figura dependen de la edición. BER-04 en particular debe confirmarse.
- **Verilator es de 2 estados**: no hay X, así que no se pueden verificar valores indefinidos ni
  propagación de X después del reset.
- **Velocidad**: los agentes corren en Python ciclo a ciclo; por eso el timer de 125 µs está escalado
  (`COUNT_125US = 195`). Los umbrales (16 errores, 64 cabeceras) no dependen de ese valor.
- **Convenciones de interfaz** (sección 5): son supuestos sobre el IP; si fueran otras, los primeros
  tests de unidad lo mostrarían de inmediato (todas las palabras desalineadas).
- **Relojes**: en loopback `tx_clk` y `rx_clk` tienen la misma frecuencia; en full duplex el RX usa
  el reloj de TX del otro PHY (no hay compensación de ppm en esta PCS).
- **Modelo de referencia**: puede tener errores; se mitiga con vectores externos y con la regla 3 de
  la sección 9.

## 12. Observaciones previas (hipótesis a confirmar)

Al leer los puertos y parámetros del RTL para armar los agentes se vieron indicios que orientaron la
prioridad de algunos tests. **No son resultados**: se confirman o descartan al ejecutar.

| Hipótesis | Tests que la confirman o descartan |
|---|---|
| El encoder y el decoder trabajan bloque a bloque: no se ven los estados TX_E / RX_E ni el *look-ahead* de `R_TYPE_NEXT`; el encoder no usa `rst` con `DATA_W = 64` | `test_enc_invalid_xgmii`, `test_enc_ieee_sequences`, `test_dec_ieee_sequences`, `test_dec_invalid_blocks`, `test_phy_tx_lblock_in_reset` |
| No se encontró la generación de LBLOCK_R (*Local Fault*) cuando falta block lock o hay `hi_ber` | `test_phy_rx_local_fault` |
| El monitor de BER solo se reinicia con `rst`, no con `!block_lock` (el test original de *taxi* incluso espera `hi_ber = 1` tras perder el lock) | `test_phy_rx_hi_ber_reset_on_unlock` |
| `rx_status` es una señal propia (*watchdog*), distinta de `PCS_status` (= block_lock ∧ ¬hi_ber) | informativo |
| Solo hay modo de prueba PRBS31: no se ven los patrones *square wave* / *pseudo-random* ni registros de gestión (MDIO, contadores de BER y de bloques errados de 49.2.14) | TP-03, inspección de interfaz |

Si se confirman, conviene acompañar cada hallazgo con su **impacto**: por ejemplo, un error de
secuencia que la PCS no convierte en /E/ puede igual ser detectado por la FCS de la MAC del otro
extremo, mientras que la ausencia de *Local Fault* impide que la capa de reconciliación (RS) informe
la caída del enlace (*link fault signaling*, 46.3.4).

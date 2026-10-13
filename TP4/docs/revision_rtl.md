# Revisión del RTL de *taxi* contra la cláusula 49 (análisis estático)

Fecha: 2026-10-12. DUT: `fpganinja/taxi`, commit `cc70b27`, configuración por defecto del plan
(`DATA_W = 64`, sin *gearbox*). Alcance: XGMII ↔ PCS (fase 1).

> **Estado: preliminar.** Estos veredictos salen de **leer el RTL** y compararlo con la norma, no de
> simular. Según el plan (sección 9), un requisito se da por "no cumple" recién con evidencia de
> simulación: log, tiempo de simulación y captura de GTKWave. Cada hallazgo indica qué test lo
> confirma. En la laptop, **que esos tests fallen es el resultado esperado** y no un error del
> testbench.

## Por qué se abrió la caja

El plan trata al DUT como caja negra, y los tests lo siguen haciendo: solo estimulan y observan
por los puertos. Esta revisión lo complementa por dos motivos:

1. **Anticipar los resultados.** Así, cuando un test falle en Verilator, ya se sabe si la causa
   está en el DUT o hay que revisar el testbench o el modelo (regla 3 de la sección 9 del plan).
2. **Ubicar cada desviación en el código** (archivo y línea), para el informe.

## Resumen

| # | Hallazgo | Requisitos | Severidad | Veredicto preliminar | Test que lo confirma |
|---|---|---|---|---|---|
| H1 | No se envía *Local Fault* (LBLOCK_R) a la XGMII cuando falta *block lock* o hay `hi_ber` | RXSM-04, XG-03 | **alta** | no cumple | `test_phy_rx_local_fault` |
| H2 | El decodificador no implementa el diagrama de estados de recepción | RXSM-02, RXSM-03, DEC-05 | media | no cumple | `test_dec_ieee_sequences`, `test_dec_invalid_blocks`, `test_phy_rx_error_handling` |
| H3 | El codificador no implementa el diagrama de estados de transmisión | TXSM-01…04 | media-baja | no cumple | `test_enc_invalid_xgmii`, `test_enc_ieee_sequences`, `test_phy_tx_lblock_in_reset` |
| H4 | El monitor de BER no se reinicia cuando se pierde el *block lock* | BER-04 | baja | no cumple *(falta confirmar el texto de la norma)* | `test_phy_rx_hi_ber_reset_on_unlock` |
| H5 | `hi_ber` se libera solo si hubo ≤ 14 errores en la ventana; la norma pide < 16 | BER-03 | baja | no cumple (caso de borde) | `test_phy_rx_hi_ber_release_15` (nuevo) |
| H6 | Interfaz y gestión incompletas: no hay `signal_ok` ni patrones *square wave* / *pseudo-random*, ni contadores de 49.2.14 | TP-03 | baja | no implementado *(a confirmar si es obligatorio)* | inspección |

Por inspección, **cumplen**: las tablas de códigos, los 15 formatos de bloque, la detección de
cabeceras y *block types* inválidos, el scrambler, el *block lock*, el umbral para activar `hi_ber`,
el timer de 125 µs y el retardo (ver [Lo que cumple](#lo-que-cumple-por-inspección)).

Un patrón común explica H1, H2 y H3: el codificador y el decodificador de *taxi* trabajan **bloque a
bloque, sin estado**. Las máquinas de estados TX y RX de 49.2.13 no están, y el decodificador no
recibe `block_lock` ni `hi_ber`. Es una simplificación conocida: el grupo IEEE P802.3df discutió
justamente codificadores y decodificadores *stateless* para 800G ([DF] del plan). Pero en la
cláusula 49 los diagramas de estados son normativos.

---

## H1 — No se envía *Local Fault* sin *block lock* ni con `hi_ber`

**Norma** (49.2.13, diagrama de recepción). Con `reset + hi_ber + !block_lock` el receptor pasa a
RX_INIT y entrega **LBLOCK_R** a la XGMII: dos *ordered sets* de Local Fault,
`/Q/ 00 00 01 /Q/ 00 00 01`. La subcapa de reconciliación (RS) usa esa señal para el *link fault
signaling* (46.3.4): deja de pasar tramas a la MAC y le avisa al otro extremo con Remote Fault.

**RTL.**
- `taxi_xgmii_baser_dec` no tiene entradas de *lock* ni de BER ([dec, puertos][dec-ports]).
- `taxi_eth_phy_10g_rx` lo instancia conectándole solo `clk` y `rst` ([rx, decodificador][rx-dec]).
- `rx_block_lock` y `rx_high_ber` existen, pero solo salen como puertos de estado: nunca intervienen
  en el camino de datos.

**Contraejemplo.** Línea desalineada 33 bits que nunca engancha.
- Norma: todas las palabras de `xgmii_rxd/rxc` valen LBLOCK_R.
- RTL: cerca de la mitad de los bloques tienen cabecera inválida y salen como 8 × /E/. El resto se
  decodifica como datos o control aleatorio, lo que puede incluir /S/ y /T/ espurios.
- Con `hi_ber = 1` y *lock*, el RTL sigue decodificando la línea con errores en lugar de entregar
  Local Fault.

**Impacto.** Una RS que cumpla la norma, conectada a este IP, **nunca detecta la caída del enlace en
banda**: no envía Remote Fault y sigue recibiendo basura. La FCS descarta las tramas espurias (pasa
una falsa con probabilidad ≈ 2⁻³² por trama), pero la señalización de fallas no funciona. En *taxi*
esto queda oculto porque su MAC tampoco implementa *link fault signaling*: en todo `src/eth/rtl` la
palabra "fault" solo aparece dentro de `default`. El diseño confía en señales fuera de banda
(`rx_block_lock`, `rx_status`) que tiene que leer el usuario.

## H2 — El decodificador no tiene el diagrama de estados RX

**Norma** (49.2.13, diagrama de recepción). Cada bloque se juzga según el estado y, para /T/,
también según el bloque siguiente (`R_TYPE_NEXT`). Pasan a EBLOCK_R (8 × /E/):
- datos fuera de trama (D en RX_C);
- control o /S/ dentro de trama (C o S en RX_D);
- /T/ seguido de algo que no sea S, C ni LI;
- cualquier bloque con `R_TYPE = E`, incluido un control con **un solo** código de 7 bits inválido.

**RTL.** Decodifica cada bloque por separado ([dec, decodificación][dec-body]). Tiene un registro
`frame_reg` que detecta /S/ dentro de trama y /T/ fuera de trama, pero solo lo usa para la señal de
estado `rx_sequence_error`; los datos salen igual ([dec, `frame_reg`][dec-frame]). Un código de
control inválido pone /E/ **solo en ese carril** ([dec, códigos][dec-codes]).

**Contraejemplo.** Las 9 secuencias de ejemplo del IEEE ([DF], `vip/sequences.py`). Como el RTL no
tiene estado, su salida es igual a la entrada. **En 6 de las 9, la norma pide otra cosa:**

| Entrada | Salida RX según la norma | RTL (sin estado) |
|---|---|---|
| `SDDECS` | `SDDECS` | = |
| `SDDTESD` | `SDDEEED` | `SDDTESD` |
| `SDETCSD` | `SDETCSD` | = |
| `SEDTCSD` | `SEDTCSD` | = |
| `SDDTTCC` | `SDDETCC` | `SDDTTCC` |
| `SDDTTSD` | `SDDETSD` | `SDDTTSD` |
| `SDDCCD` | `SDDECE` | `SDDCCD` |
| `SDDCSD` | `SDDEED` | `SDDCSD` |
| `SDDESD` | `SDDEED` | `SDDESD` |

La columna de la norma sale del modelo de referencia, que reproduce la tabla de [DF] (53/53
self-tests pasan). Otro caso: un bloque 0x1E con el código 0x7F en el carril 0. La norma da 8 × /E/;
el RTL da `/E/ /I/ /I/ /I/ /I/ /I/ /I/ /I/`.

**Impacto: medio-bajo.** Casi todas las tramas corruptas las sigue descartando la FCS de la MAC. Lo
que se pierde es la garantía de que un error de línea dentro de una trama llegue a la RS como /E/.
Por ejemplo, en `SDDCCD` la trama termina sin /T/ y sin /E/, y cómo se interpreta depende de la MAC.

## H3 — El codificador no tiene el diagrama de estados TX

**Norma** (49.2.13, diagrama de transmisión).
- Pasan a EBLOCK_T: datos sin /S/ previo, idle o /S/ dentro de trama, /T/ fuera de trama y toda
  palabra con `T_TYPE = E`.
- Durante el reset (TX_INIT) se transmite LBLOCK_T.

**RTL.**
- Codifica cada palabra por separado. Una palabra con `txc = 0` siempre sale como bloque de datos
  ([enc, datos][enc-data]).
- Un carácter inválido dentro de una palabra de control pone /E/ solo en ese carril
  ([enc, códigos][enc-codes]). Solo las combinaciones sin formato de bloque posible dan EBLOCK_T
  ([enc, sin formato][enc-noformat]).
- Con `DATA_W = 64`, el codificador no usa `rst` (solo lo usa la rama de 32 bits:
  [enc, reset][enc-rst]). `taxi_eth_phy_10g_tx_if` tampoco usa `rst`, así que en reset la línea no
  lleva LBLOCK_T.

**Contraejemplo.** La columna TX de la misma tabla: en 6 de las 9 secuencias difiere. Por ejemplo,
para `SDDCCD` la norma pide `SDDECE` y el RTL transmite `SDDCCD`. Otros dos casos:
- una palabra de datos después de idles sin /S/: la norma pide EBLOCK_T y el RTL manda un bloque de
  datos;
- una palabra de idles con /E/ en el carril 3: la norma pide EBLOCK_T y el RTL manda el bloque 0x1E
  con /E/ solo en ese carril.

**Impacto: bajo con una MAC correcta.** La MAC de *taxi* genera secuencias legales. Pero el contrato
del IP con la norma es proteger la línea de una fuente XGMII defectuosa: con este RTL, una trama
truncada en TX llega al otro extremo sin /E/.

## H4 — El monitor de BER no se reinicia cuando se pierde el *lock*

**Norma.** Todo indica que el diagrama del monitor de BER entra a BER_MT_INIT (`hi_ber = false`) con
`reset + !block_lock`, como el monitor equivalente de la cláusula 82 con `!align_status`. La
documentación de Intel de su PCS 10GBASE-R dice que el monitor cuenta cabeceras inválidas "después
de alcanzado el *block lock*". **Falta confirmarlo con el texto de 802.3**: es el punto abierto
BER-04 del plan.

**RTL.** `taxi_eth_phy_10g_rx_ber_mon` solo tiene `rst` y la cabecera ([ber, puertos][ber-ports]), y
se instancia con `.rst(rst)` ([rx_if, BER][rxif-ber]). Mientras no hay *lock*, cuenta las cabeceras
inválidas de la línea desalineada y activa `hi_ber`. Es intencional: el test del propio autor exige
`rx_high_ber = 1` después de perder el *lock* ([test de taxi][taxi-test]).

**Impacto: bajo.** Afecta solo al estado reportado. `PCS_status` (= `block_lock ∧ ¬hi_ber`) es falso
de todas formas. Sí importa si el usuario interpreta `hi_ber` como "hay enlace pero con muchos
errores".

## H5 — `hi_ber` necesita ≤ 14 errores para liberarse

**Norma** (diagrama del monitor de BER). Con `hi_ber` activo, una ventana de 125 µs que termina con
`ber_cnt < 16` pasa por GOOD_BER y libera `hi_ber`. Es decir, una ventana con hasta 15 cabeceras
inválidas lo libera.

**RTL.** El contador es de 4 bits y satura en 15. La liberación se condiciona con
`ber_count_reg != 4'd15` ([ber, liberación][ber-release]). Una ventana con **exactamente 15** errores
deja `hi_ber` activo hasta el final de la ventana siguiente: el umbral de liberación quedó corrido en
uno. El umbral para *activar* sí es correcto: el error número 16 pone `hi_ber = 1`.

Hay otro detalle menor. Si la última cabecera de la ventana es inválida (con menos de 15 errores), el
RTL libera `hi_ber` ([ber, cabecera inválida][ber-invalid]). La norma en ese caso pasa de
BER_BAD_SH a START_TIMER sin liberar.

**Contraejemplo.** Se activa `hi_ber` y la ventana siguiente tiene 15 cabeceras inválidas. La norma
libera al final de esa ventana; el RTL, una ventana (125 µs) después. Lo mide el test nuevo
`test_phy_rx_hi_ber_release_15`.

**Impacto: bajo.** En condiciones de borde, `hi_ber` dura 125 µs de más.

## H6 — Interfaz y gestión

- **`signal_ok`.** El diagrama de *lock* vuelve a LOCK_INIT con `!signal_ok` (indicación del PMA).
  El IP no tiene esa entrada: sin señal, pierde el *lock* recién cuando acumula 16 cabeceras
  inválidas.
- **Patrones de prueba (49.2.8 y 49.2.12).** Solo está PRBS31, que es opcional. No hay *square wave*
  ni *pseudo-random* con semillas A/B, ni chequeador para ellos (TP-03).
- **Gestión (49.2.14).** No hay contador de BER ni de bloques errados. El IP expone pulsos
  (`rx_bad_block`, `rx_sequence_error`) con los que el usuario podría armarlos.

Hay que confirmar qué exige como "*shall*" la edición que usa la cátedra. Parte de esto depende de
la interfaz de gestión (MDIO, cláusula 45), que el IP no tiene.

## Lo que cumple (por inspección)

| Requisito | Evidencia en el RTL |
|---|---|
| XG-01, ENC-02, ENC-04 | caracteres XGMII, códigos de 7 bits y códigos O iguales a la Tabla 49-1 ([enc, tablas][enc-tables]) |
| ENC-01, ENC-03, ENC-05, DEC-01, DEC-02 | los 15 *block types* de la Figura 49-7, con cabeceras 01/10 |
| DEC-03, DEC-04 | cabecera 00/11 y los 241 *block types* no definidos → 8 × /E/ (chequeo de 8 bits en [dec, *block types*][dec-types]) |
| SCR-01…03 | scrambler `x⁵⁸ + x³⁹ + 1` sobre la carga (no sobre la cabecera); descrambler *feed-forward* (autosincronizante) |
| LOCK-01…05 | *lock* tras 64 cabeceras válidas, *slip* con cada cabecera inválida sin *lock*, pérdida con 16 inválidas en 64 ([frame_sync][fs-body]) |
| BER-01, BER-02 | `hi_ber` se activa con la 16.ª cabecera inválida de la ventana |
| BER-05 | timer de `$rtoi(19531.25) + 1 = 19532` ciclos = 125,005 µs (+0,004 %, tolerancia +1 % / −25 %) |
| LAT-01 | 2 registros en TX (codificador + salida) y 2 en RX (entrada + decodificador): 4 ciclos = 256 BT ≤ 3584 BT |

Todo esto también se confirma con la regresión: son los tests que **deberían pasar**.

## Próximos pasos (laptop con Ubuntu)

```bash
cd TP4/verif && make selftest
cd tb/xgmii_baser_enc && make WAVES=1      # se esperan fallas en test_enc_invalid_xgmii y test_enc_ieee_sequences
cd ../xgmii_baser_dec && make WAVES=1      # fallas esperadas: test_dec_ieee_sequences, test_dec_invalid_blocks
cd ../eth_phy_10g && make WAVES=1          # fallas esperadas: local_fault, hi_ber_reset_on_unlock, hi_ber_release_15, tx_lblock_in_reset, rx_error_handling
```

Por cada test que falle:
1. Verificar que el mensaje coincida con el hallazgo.
2. Guardar el log y una captura de GTKWave en el instante del primer error.
3. Pasar el veredicto a la sección 10 del plan.

Si un test que debería pasar falla, primero se revisan el testbench y el modelo.

[dec-ports]: https://github.com/fpganinja/taxi/blob/cc70b270b910d369ab1ad7b3855e76399fd461f1/src/eth/rtl/taxi_xgmii_baser_dec.sv#L26-L61
[dec-body]: https://github.com/fpganinja/taxi/blob/cc70b270b910d369ab1ad7b3855e76399fd461f1/src/eth/rtl/taxi_xgmii_baser_dec.sv#L273-L526
[dec-frame]: https://github.com/fpganinja/taxi/blob/cc70b270b910d369ab1ad7b3855e76399fd461f1/src/eth/rtl/taxi_xgmii_baser_dec.sv#L328-L335
[dec-codes]: https://github.com/fpganinja/taxi/blob/cc70b270b910d369ab1ad7b3855e76399fd461f1/src/eth/rtl/taxi_xgmii_baser_dec.sv#L216-L259
[dec-types]: https://github.com/fpganinja/taxi/blob/cc70b270b910d369ab1ad7b3855e76399fd461f1/src/eth/rtl/taxi_xgmii_baser_dec.sv#L528-L563
[rx-dec]: https://github.com/fpganinja/taxi/blob/cc70b270b910d369ab1ad7b3855e76399fd461f1/src/eth/rtl/taxi_eth_phy_10g_rx.sv#L130-L171
[enc-tables]: https://github.com/fpganinja/taxi/blob/cc70b270b910d369ab1ad7b3855e76399fd461f1/src/eth/rtl/taxi_xgmii_baser_enc.sv#L78-L132
[enc-codes]: https://github.com/fpganinja/taxi/blob/cc70b270b910d369ab1ad7b3855e76399fd461f1/src/eth/rtl/taxi_xgmii_baser_enc.sv#L206-L256
[enc-data]: https://github.com/fpganinja/taxi/blob/cc70b270b910d369ab1ad7b3855e76399fd461f1/src/eth/rtl/taxi_xgmii_baser_enc.sv#L273-L278
[enc-noformat]: https://github.com/fpganinja/taxi/blob/cc70b270b910d369ab1ad7b3855e76399fd461f1/src/eth/rtl/taxi_xgmii_baser_enc.sv#L370-L374
[enc-rst]: https://github.com/fpganinja/taxi/blob/cc70b270b910d369ab1ad7b3855e76399fd461f1/src/eth/rtl/taxi_xgmii_baser_enc.sv#L161-L193
[ber-ports]: https://github.com/fpganinja/taxi/blob/cc70b270b910d369ab1ad7b3855e76399fd461f1/src/eth/rtl/taxi_eth_phy_10g_rx_ber_mon.sv#L18-L37
[ber-release]: https://github.com/fpganinja/taxi/blob/cc70b270b910d369ab1ad7b3855e76399fd461f1/src/eth/rtl/taxi_eth_phy_10g_rx_ber_mon.sv#L69-L75
[ber-invalid]: https://github.com/fpganinja/taxi/blob/cc70b270b910d369ab1ad7b3855e76399fd461f1/src/eth/rtl/taxi_eth_phy_10g_rx_ber_mon.sv#L76-L86
[rxif-ber]: https://github.com/fpganinja/taxi/blob/cc70b270b910d369ab1ad7b3855e76399fd461f1/src/eth/rtl/taxi_eth_phy_10g_rx_if.sv#L258-L268
[fs-body]: https://github.com/fpganinja/taxi/blob/cc70b270b910d369ab1ad7b3855e76399fd461f1/src/eth/rtl/taxi_eth_phy_10g_rx_frame_sync.sv#L63-L109
[taxi-test]: https://github.com/fpganinja/taxi/blob/cc70b270b910d369ab1ad7b3855e76399fd461f1/src/eth/tb/taxi_eth_mac_phy_10g/test_taxi_eth_mac_phy_10g.py#L650-L652

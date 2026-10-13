# Protocolos de Comunicación (UNC, 2026)

Repo de trabajos prácticos: TP1–TP3 terminados (informes en `docs/` y `TP3/informe/`), TP4 en curso.

## Convenciones

- Conversación en español. Informes en Markdown → PDF con pandoc (ver `TP3/informe/build.sh`), en
  español (`Informe_*.md`) e inglés (`Report_*.md`). Código y comentarios en inglés.
- Las herramientas HDL (Verilator, GTKWave, cocotb) corren en la laptop con Ubuntu. La PC con Windows
  tiene Python 3.12, pero no pytest, cocotb, Verilator ni WSL: ahí solo corre el modelo puro de
  `vip/`.
- Cuando el usuario traiga comentarios de clase, sumarlos a "Notas de clase" de `TP4/README.md` y
  reflejarlos en el plan.

## TP4 (en curso): verificación de la PCS 10GBASE-R de fpganinja/taxi

Leer primero `TP4/README.md` (notas de clase, arquitectura, estado), `TP4/docs/plan_de_verificacion.md`
y `TP4/docs/entorno.md`.

- Objetivo: decidir si los IPs 10G de taxi cumplen IEEE 802.3 (cláusulas 46 y 49). Fase 1: XGMII ↔ PCS
  (`taxi_xgmii_baser_enc`/`_dec`, `taxi_eth_phy_10g`, dos PHY en full duplex). La MAC es la fase 2.
- Indicaciones de la cátedra: Verilator (no Icarus), `dump.fst` + GTKWave, tratar los diseños como IPs
  (caja negra contra la norma), verificación por módulo e integrada, agentes PRBS → MII y
  MII → MAC → PRBS, primero loopback y después full duplex.
- DUT: taxi en el commit `cc70b27`, se clona con `TP4/scripts/get_taxi.sh` en `TP4/repo_taxi/taxi`
  (ignorado por git; en Windows el symlink `src/eth/lib/taxi` queda roto).
- Entorno en `TP4/verif`, con cocotb 2.0.1 y Verilator ≥ 5.036:
  - `vip/`: agentes y modelo de referencia escrito desde la norma (no usar como juez los modelos de
    `cocotbext-eth` ni el `baser.py` de taxi);
  - `selftest/`: pytest sin simulador;
  - `tb/<testbench>/`: Makefile + `test_*.py`.

## Estado al 2026-10-12

- Escrito: plan v1.1, documentación, scripts de instalación, VIP y cuatro testbenches (encoder,
  decoder, PHY y full duplex).
- Verificado sin simulador: 53/53 self-tests; los módulos de test importan con cocotb 2.0.1.
- Revisión estática del RTL contra la cláusula 49 en `TP4/docs/revision_rtl.md`: 6 hallazgos
  preliminares, que pasan a "no cumple" recién con evidencia de simulación.
  - H1: no se envía Local Fault (LBLOCK_R) con `!block_lock` o con `hi_ber`.
  - H2 y H3: decoder y encoder sin las máquinas de estado RX/TX; en 6 de las 9 secuencias de [DF] la
    salida difiere de la norma.
  - H4: el monitor de BER no se reinicia con `!block_lock` (falta confirmar el texto de la norma).
  - H5: `hi_ber` se libera con ≤ 14 errores por ventana en vez de < 16 (test nuevo
    `test_phy_rx_hi_ber_release_15`).
  - H6: no hay `signal_ok`, patrones de prueba ni contadores de gestión.
- **Nunca se corrió con Verilator**: la primera ejecución en Ubuntu probablemente pida ajustes. Los
  tests asociados a H1–H5 *deberían fallar*.
- Próximo paso, en este orden:
  1. `bash TP4/scripts/setup_ubuntu.sh`;
  2. `make selftest`;
  3. `tb/xgmii_baser_enc`, después decoder, PHY (loopback) y full duplex;
  4. completar la tabla de veredictos (sección 10 del plan) con evidencia (log + GTKWave).
- No se tiene el texto de 802.3; se usaron fuentes públicas: diagramas de UNH-IOL (cláusula 49) y la
  tabla de secuencias de ejemplo de IEEE P802.3df (Opsasnick, 2022). Ver la sección 2 del plan.

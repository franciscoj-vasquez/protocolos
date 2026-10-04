# Protocolos de Comunicación (UNC, 2026)

Repo de trabajos prácticos: TP1–TP3 terminados (informes en `docs/` y `TP3/informe/`), TP4 en curso.

## Convenciones

- Conversación en español. Informes en Markdown → PDF con pandoc (ver `TP3/informe/build.sh`), en
  español (`Informe_*.md`) e inglés (`Report_*.md`). Código y comentarios en inglés.
- Las herramientas HDL (Verilator, GTKWave, cocotb) corren en la laptop con Ubuntu. La PC con Windows
  no tiene Python ni Verilator.
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

## Estado al 2026-10-04

- Escrito: plan v1, documentación, scripts de instalación, VIP y cuatro testbenches (encoder, decoder,
  PHY y full duplex).
- Verificado sin simulador: 53/53 self-tests; los módulos de test importan con cocotb 2.0.1.
- **Nunca se corrió con Verilator**: la primera ejecución en Ubuntu probablemente pida ajustes.
- Próximo paso, en este orden:
  1. `bash TP4/scripts/setup_ubuntu.sh`;
  2. `make selftest`;
  3. `tb/xgmii_baser_enc`, después decoder, PHY (loopback) y full duplex;
  4. completar la tabla de veredictos (sección 10 del plan).
- Hipótesis a confirmar (no son resultados):
  - encoder y decoder sin las máquinas de estado TX/RX de la cláusula 49;
  - no se envía Local Fault (LBLOCK_R) con `!block_lock` o con `hi_ber`;
  - el monitor de BER no se reinicia con `!block_lock`.
- No se tiene el texto de 802.3; se usaron fuentes públicas: diagramas de UNH-IOL (cláusula 49) y la
  tabla de secuencias de ejemplo de IEEE P802.3df (Opsasnick, 2022). Ver la sección 2 del plan.

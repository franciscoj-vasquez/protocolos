# Entorno de verificación (Ubuntu)

Todo el flujo corre en Linux (la laptop con Ubuntu 22.04/24.04; WSL2 también sirve). En Windows
no se puede: el repo *taxi* usa un *symlink* (`src/eth/lib/taxi`) que en un checkout de Windows queda
roto, y cocotb + Verilator no están soportados ahí.

## Versiones

| Herramienta | Versión | Motivo |
|---|---|---|
| Verilator | **≥ 5.036** (se instala v5.050, la del CI de *taxi*) | cocotb 2.0.1 corta con *"cocotb requires Verilator 5.036 or later"*. Ubuntu 24.04 trae 5.020, así que se compila desde la fuente. |
| Python | ≥ 3.9 (22.04 trae 3.10, 24.04 trae 3.12) | |
| cocotb | 2.0.1 | misma que el CI de *taxi*; los tests usan `@cocotb.parametrize` (nuevo en 2.0) |
| cocotb-test, cocotbext-eth, cocotbext-axi, pytest, scapy | ver [`verif/requirements.txt`](../verif/requirements.txt) | los dos `cocotbext` solo hacen falta para correr los tests originales de *taxi* |
| GTKWave | la de `apt` | lectura de `dump.fst` |

## Instalación automática

```bash
bash TP4/scripts/setup_ubuntu.sh
```

Instala paquetes, compila e instala Verilator si falta (≈10–20 min la primera vez), crea el
entorno virtual `TP4/verif/.venv`, clona *taxi* en el commit fijado y corre los self-tests del VIP.

## Instalación paso a paso

1. Paquetes del sistema y GTKWave:

   ```bash
   sudo apt-get update
   sudo apt-get install -y git make autoconf g++ flex bison help2man perl perl-doc \
       python3 python3-venv python3-pip python3-dev libfl2 libfl-dev zlib1g zlib1g-dev \
       ccache numactl libgoogle-perftools-dev gtkwave
   ```

2. Verilator desde la fuente:

   ```bash
   git clone https://github.com/verilator/verilator ~/tools/verilator-src
   cd ~/tools/verilator-src
   git checkout v5.050
   unset VERILATOR_ROOT
   autoconf && ./configure && make -j"$(nproc)" && sudo make install
   verilator --version          # Verilator 5.050 ...
   ```

   Alternativa sin compilar: [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build)
   (binarios con Verilator, GTKWave, Yosys). Conviene agregar solo su `bin/` al `PATH` en lugar de
   hacer `source environment`, porque ese script cambia también el Python.

3. Entorno de Python:

   ```bash
   python3 -m venv TP4/verif/.venv
   source TP4/verif/.venv/bin/activate          # en cada terminal nueva
   pip install -r TP4/verif/requirements.txt
   cocotb-config --version                      # 2.0.1
   ```

4. Diseño bajo prueba (commit fijado, para que los resultados sean reproducibles):

   ```bash
   bash TP4/scripts/get_taxi.sh                 # -> TP4/repo_taxi/taxi @ cc70b27
   ```

5. Chequeo del entorno con un test original de *taxi* (si pasa, la cadena de herramientas está bien):

   ```bash
   cd TP4/repo_taxi/taxi/src/eth/tb/taxi_eth_phy_10g && make
   ```

## Uso

Cada testbench es un directorio con un `Makefile` y un `test_*.py`, igual que en el tutorial de la
cátedra:

```bash
cd TP4/verif/tb/eth_phy_10g
make                                   # todos los tests; ondas en dump.fst
make WAVES=0                           # más rápido, sin ondas
make COCOTB_TEST_FILTER=test_phy_rx_hi_ber        # un test (regex)
make COCOTB_RANDOM_SEED=1234           # repetir una corrida (la semilla se imprime al inicio)
make COUNT_125US=19531.25              # BER monitor con el timer real de 125 us
make waves                             # abre dump.fst en GTKWave
```

Regresión completa desde `TP4/verif`:

```bash
make selftest      # pruebas del VIP, sin simulador (segundos)
make               # selftest + los 4 testbenches (sin ondas) + reports/summary.md
make tb_eth_phy_10g                    # un testbench con ondas
```

Salidas de cada testbench:

| Archivo | Contenido |
|---|---|
| `results.xml` | resultado por test (formato JUnit) |
| `dump.fst` | ondas (si `WAVES=1`) |
| `reports/cov_*.json` | cobertura funcional de cada test |
| salida de consola | resumen del scoreboard, tablas por vector, latencias, cobertura |

> **Recompilación**: cocotb por sí solo recompila el modelo únicamente cuando cambian las fuentes.
> `verif/tb/common.mk` guarda además los argumentos de compilación en `sim_build/compile_args.txt`,
> así que cambiar un parámetro (`COUNT_125US=...`) o `WAVES` también fuerza la recompilación.

## Ondas con GTKWave

- `make waves` (o `gtkwave dump.fst`). La jerarquía arranca en el DUT (o en el *wrapper* del full
  duplex: `phy_a`, `phy_b`).
- Los mensajes de error del scoreboard indican el **tiempo de simulación en ns** del desajuste; con ese
  valor se ubica el ciclo en GTKWave.
- Orden de bytes, igual que en el TP3: el carril 0 (primer octeto en la línea) es `[7:0]`; GTKWave
  muestra el bus en hexadecimal con el MSB a la izquierda, así que la palabra se lee de derecha a
  izquierda. La cabecera de sincronismo `serdes_*_hdr` vale `2` para datos (`01` en la notación de
  la norma, bit 0 primero) y `1` para control (`10`).
- Señales útiles del top: `xgmii_txd/txc`, `serdes_tx_hdr/data`, `serdes_rx_hdr/data`,
  `serdes_rx_bitslip`, `rx_block_lock`, `rx_high_ber`, `xgmii_rxd/rxc`, y dentro de
  `eth_phy_10g_tx_inst.xgmii_baser_enc_inst` las salidas `encoded_tx_*` (bloque antes del scrambler).
- Guardar la vista (`File > Write Save File`) como `*.gtkw` en el directorio del testbench: `make waves`
  la carga sola.
- Con ondas activas, los tests largos generan archivos de cientos de MB: para regresiones usar
  `WAVES=0`.

## Diferencias con el tutorial de la cátedra

| Tutorial (TP con verilog-ethernet) | TP4 (taxi) |
|---|---|
| Verilog-2001, Icarus | SystemVerilog, Verilator |
| `WAVES=1` genera `.vcd` (modificando `iverilog_dump.v`) | `WAVES=1` agrega `--trace-fst` y genera `dump.fst` directamente |
| cocotb 1.x: `MODULE`, `TOPLEVEL`, `TESTCASE`, `RANDOM_SEED` | cocotb 2.0: `COCOTB_TEST_MODULES`, `COCOTB_TOPLEVEL`, `COCOTB_TEST_FILTER`, `COCOTB_RANDOM_SEED` (los nombres viejos siguen andando, con aviso) |

## Problemas frecuentes

| Síntoma | Causa / solución |
|---|---|
| `cocotb requires Verilator 5.036 or later` | Verilator de `apt`: compilar desde la fuente (paso 2) |
| `cocotb-config: command not found` | falta `source TP4/verif/.venv/bin/activate` |
| `taxi RTL not found in ...` | correr `scripts/get_taxi.sh` o pasar `TAXI_DIR=/ruta/a/taxi` |
| errores con `lib/taxi/src/...` al expandir los `.f` | *taxi* clonado en Windows (symlink roto): clonar en Linux |
| la primera corrida tarda | Verilator compila el modelo C++; las siguientes reutilizan `sim_build/` |
| `make` falla en `$(file ...)` | GNU make < 4.2 (Ubuntu 22.04/24.04 traen 4.3) |

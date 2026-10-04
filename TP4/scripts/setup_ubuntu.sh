#!/usr/bin/env bash
# One-time TP4 setup on Ubuntu 22.04 / 24.04:
#   system packages + GTKWave, Verilator built from source (cocotb 2.0 needs
#   >= 5.036; Ubuntu ships 5.020 at most), Python venv with cocotb, DUT clone,
#   and a smoke test.
#
#   ./setup_ubuntu.sh                       (asks for sudo for apt / make install)
#   VERILATOR_VERSION=v5.052 ./setup_ubuntu.sh
set -euo pipefail

VERILATOR_VERSION="${VERILATOR_VERSION:-v5.050}"     # same as taxi CI
VERILATOR_MIN="5.036"
TP4_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENV="$TP4_DIR/verif/.venv"

echo "== system packages"
sudo apt-get update
sudo apt-get install -y git make autoconf g++ flex bison help2man perl perl-doc \
    python3 python3-venv python3-pip python3-dev libfl2 libfl-dev zlib1g zlib1g-dev \
    ccache numactl libgoogle-perftools-dev gtkwave

version_ok() {   # version_ok <have> <min>
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

have=""
if command -v verilator >/dev/null 2>&1; then
    have="$(verilator --version | awk '{print $2}')"
fi
if [ -n "$have" ] && version_ok "$have" "$VERILATOR_MIN"; then
    echo "== Verilator $have already installed"
else
    echo "== building Verilator $VERILATOR_VERSION (found: ${have:-none})"
    SRC="$HOME/tools/verilator-src"
    [ -d "$SRC/.git" ] || git clone https://github.com/verilator/verilator "$SRC"
    git -C "$SRC" fetch --tags --quiet
    git -C "$SRC" -c advice.detachedHead=false checkout --quiet "$VERILATOR_VERSION"
    (
        cd "$SRC"
        unset VERILATOR_ROOT
        autoconf
        ./configure
        make -j"$(nproc)"
        sudo make install
    )
fi
verilator --version

echo "== Python venv ($VENV)"
python3 -m venv "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
pip install --upgrade pip
pip install -r "$TP4_DIR/verif/requirements.txt"
echo "cocotb $(cocotb-config --version)"

echo "== DUT"
bash "$TP4_DIR/scripts/get_taxi.sh"

echo "== smoke test: VIP self-tests (no simulator)"
( cd "$TP4_DIR/verif" && python -m pytest -q selftest )

cat <<EOF

Environment ready. In every new terminal:
    source $VENV/bin/activate
Then, for example:
    cd $TP4_DIR/verif/tb/eth_phy_10g && make          # waves in dump.fst
    cd $TP4_DIR/verif && make                         # full regression + summary
Upstream taxi tests (environment sanity check):
    cd $TP4_DIR/repo_taxi/taxi/src/eth/tb/taxi_eth_phy_10g && make
EOF

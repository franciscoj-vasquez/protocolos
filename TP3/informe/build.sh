#!/usr/bin/env bash
# Builds the TP3 report PDFs with pandoc + a XeTeX-based LaTeX engine.
#   ./build.sh          -> Informe_TP3.pdf (es) and Report_TP3.pdf (en)
#   ./build.sh es|en    -> only one language
# Engine: xelatex by default; override with PDF_ENGINE=tectonic ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

ENGINE="${PDF_ENGINE:-xelatex}"

build() {  # $1 = markdown source, $2 = language-specific preamble
    local src="$1" out="${1%.md}.pdf"
    pandoc "$src" -o "$out" \
        --pdf-engine="$ENGINE" \
        -H tex/preamble.tex -H "$2" \
        --highlight-style=tango
    echo "OK -> $out"
}

case "${1:-all}" in
    es)  build Informe_TP3.md tex/preamble-es.tex ;;
    en)  build Report_TP3.md tex/preamble-en.tex ;;
    all) build Informe_TP3.md tex/preamble-es.tex
         build Report_TP3.md tex/preamble-en.tex ;;
    *)   echo "usage: $0 [es|en|all]" >&2; exit 1 ;;
esac

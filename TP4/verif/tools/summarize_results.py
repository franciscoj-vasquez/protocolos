#!/usr/bin/env python3
"""
Summarize cocotb results.xml files (one per testbench directory) into a
Markdown table, printed and written to reports/summary.md.

usage: summarize_results.py tb/xgmii_baser_enc tb/eth_phy_10g ...
"""

import os
import sys
import xml.etree.ElementTree as ET


def main(dirs):
    rows, totals = [], {"PASS": 0, "FAIL": 0, "SKIP": 0}
    for d in dirs:
        path = os.path.join(d, "results.xml")
        if not os.path.exists(path):
            rows.append((os.path.basename(d), "-", "NOT RUN", "", ""))
            continue
        for tc in ET.parse(path).getroot().iter("testcase"):
            if tc.find("skipped") is not None:
                status = "SKIP"
            elif tc.find("failure") is not None or tc.find("error") is not None:
                status = "FAIL"
            else:
                status = "PASS"
            totals[status] += 1
            msg = ""
            node = tc.find("failure") if tc.find("failure") is not None else tc.find("error")
            if node is not None:
                msg = (node.get("message") or "").splitlines()[0][:90] if node.get("message") else ""
            rows.append((os.path.basename(d), tc.get("name"), status,
                         f"{float(tc.get('sim_time_ns', 0) or 0) / 1000:.1f}", msg))
    lines = ["| Testbench | Test | Result | Sim time (us) | Message |",
             "|---|---|---|---|---|"]
    lines += [f"| {a} | `{b}` | {c} | {d} | {e} |" for a, b, c, d, e in rows]
    lines.append("")
    lines.append(f"PASS {totals['PASS']} | FAIL {totals['FAIL']} | SKIP {totals['SKIP']}")
    text = "\n".join(lines)
    print(text)
    os.makedirs("reports", exist_ok=True)
    with open(os.path.join("reports", "summary.md"), "w") as f:
        f.write(text + "\n")


if __name__ == "__main__":
    main(sys.argv[1:])

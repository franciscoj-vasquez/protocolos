import os
import sys

# make `import vip` work when running `pytest selftest` from verif/
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

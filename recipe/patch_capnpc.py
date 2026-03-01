"""Patch rgpot rpc/meson.build to use 'capnp compile' instead of 'capnpc'.

The Windows capnpc.EXE shipped by conda-forge does not support the -o flag.
The portable alternative is 'capnp compile -oc++:dir'.

Usage: python patch_capnpc.py <path-to-meson.build>
"""
import sys

path = sys.argv[1]
text = open(path).read()
text = text.replace("capnpc = find_program('capnpc')", "capnp = find_program('capnp')")
text = text.replace("capnpc,\n", "capnp,\n        'compile',\n")
text = text.replace("'-o',\n        'c++:@OUTDIR@'", "'-oc++:@OUTDIR@'")
open(path, "w").write(text)

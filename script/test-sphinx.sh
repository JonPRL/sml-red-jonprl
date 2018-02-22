#!/bin/bash

set -o pipefail

echo "Building the documentation of RedPRL with Sphinx..."
cd doc;
if [ -n "${TRAVIS}" ]; then
  pip install sphinx-rtd-theme || exit 1;
  make SPHINXOPTS="-n -W" html || exit 1;
else
  make html || exit 1;
fi
echo "Done!"

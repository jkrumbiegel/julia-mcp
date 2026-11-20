#!/bin/sh
set -eu

cd "$(dirname "$0")"
julia_cmd=${JULIA:-julia +1.13}

$julia_cmd --project=build-env -e 'import Pkg; Pkg.instantiate()'
$julia_cmd --project=. -e 'import Pkg; Pkg.instantiate()'
rm -rf dist
$julia_cmd --project=build-env -m JuliaC \
    --output-exe julia-mcp \
    --bundle dist \
    --trim=safe \
    --experimental \
    .

echo "Built $(pwd)/dist/bin/julia-mcp"

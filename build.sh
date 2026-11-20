#!/bin/sh
set -eu

cd "$(dirname "$0")"
julia_cmd=${JULIA:-julia +1.13}

$julia_cmd --project=build-env -e 'import Pkg; Pkg.instantiate()'
$julia_cmd --project=. -e 'import Pkg; Pkg.instantiate()'
rm -rf dist.new
$julia_cmd --project=build-env -m JuliaC \
    --output-exe julia-mcp \
    --bundle dist.new \
    --trim=safe \
    --experimental \
    .

# Swap in the new bundle only once it is complete, so running servers and new launches never see a partial one.
rm -rf dist.old
[ -d dist ] && mv dist dist.old
mv dist.new dist
rm -rf dist.old

echo "Built $(pwd)/dist/bin/julia-mcp"

# comfy-i2v-env

A reproducible ComfyUI image-to-video runtime, built once and pulled onto rented
GPUs. Public so that pulls are anonymous.

```
docker pull ghcr.io/emu-commits/comfy-i2v-env:latest
```

## Why an image and not just a lockfile

Mostly it isn't about bandwidth. The bytes cross the wire either way — a pulled
layer is the same download as a `pip install`, just from a different host. What
a baked image removes is CPU work on a metered GPU: wheel unpacking, dependency
resolution, and above all `nvcc`, which can spend ten minutes of rent compiling
instead of rendering.

A hash-pinned lockfile plus submodules at fixed SHAs gets you most of the
reproducibility for none of the registry overhead. **The image only earns its
keep once something in the stack has to be compiled.** That is why the compile
stage here is an explicit, currently-empty extension point rather than a
pretence — see `EXTENSIONS` in the Dockerfile.

## Weights are not in the image

Model weights are fetched at boot, pinned by revision, onto the instance's own
disk. Baking them in would force every pull to carry every precision variant
(`fp8_scaled` for Ada and newer, GGUF for Ampere) when a given host can only use
one of them.

## Architecture coverage

Compiled CUDA extensions are architecture-specific, and a spot market hands you
whatever it has that hour. Everything we are willing to rent is in the fat
binary:

```
TORCH_CUDA_ARCH_LIST="8.0 8.6 8.9 9.0 12.0+PTX"
```

Getting this wrong does not raise an error. It falls back to a PTX JIT on first
use, which reads as a disappointing benchmark rather than as a bug.

## Pins

Everything in `pins.env` is a digest or a commit SHA — nothing that can move
underneath a rebuild. Re-resolve with:

```
tools/resolve-pins.sh > pins.env.new && diff -u pins.env pins.env.new
```

Review that diff. It is the moment a supply chain changes.

## Publishing hygiene

A public image cannot be un-published, so the check runs before the push and a
finding fails the build:

```
tools/scan-image.sh IMAGE[:TAG]
```

It inspects the image config, the build history, every path in the filesystem,
and the contents of the directories where a build leaks identity, looking for
credentials, VCS metadata, shell history, and a list of strings that must never
become public.

That list lives **outside this repository**, at
`~/.config/comfy-i2v-env/private-strings` — putting it in the repo would publish
exactly what it exists to catch. See `tools/private-strings.example`. Findings
are reported by index and by path; the matched string is never printed back.

## Build

CI builds and publishes on every change to `Dockerfile` or `pins.env`. It runs
on GitHub Actions rather than a workstation or a rented host because Actions is
free on a public repository, GHCR egress from Actions is unmetered, and the
multi-architecture compile needs `nvcc` but no GPU.

Locally, if you want to:

```
set -a; . ./pins.env; set +a
docker build \
  --build-arg BASE_DEVEL --build-arg BASE_RUNTIME \
  --build-arg TORCH_CHANNEL --build-arg TORCH_VERSION \
  --build-arg COMFYUI_REPO --build-arg COMFYUI_SHA \
  -t comfy-i2v-env:local .
```

## Licence

ComfyUI is GPL-3.0; this image ships it, so the image inherits that. The build
definition here is trivial and carries no additional restriction.

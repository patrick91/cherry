FROM rust:1.94-bookworm
RUN apt-get update -qq && apt-get install -y --no-install-recommends openssh-server \
    && rm -rf /var/lib/apt/lists/* && mkdir -p /run/sshd
# Debian's Neovim (0.7) predates the terminal queries current Neovim sends at
# startup. Install a pinned official release instead; keep the version and
# digests in sync with .github/workflows/host.yml.
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) arch=x86_64; digest=bce0f56eda1f1b1db6eee8f4133d7a38813ea07933837dd1777411ca384c6875 ;; \
      arm64) arch=arm64; digest=1aa5ca085249580ae0f91eb14f27ec0919773ff2d99a163d03f3d6c21ac29725 ;; \
      *) echo "No pinned Neovim build for $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 3 -o /tmp/nvim.tar.gz \
      "https://github.com/neovim/neovim/releases/download/v0.12.5/nvim-linux-$arch.tar.gz"; \
    echo "$digest  /tmp/nvim.tar.gz" | sha256sum -c -; \
    mkdir -p /opt/nvim; \
    tar -xzf /tmp/nvim.tar.gz -C /opt/nvim --strip-components=1; \
    rm /tmp/nvim.tar.gz; \
    ln -s /opt/nvim/bin/nvim /usr/local/bin/nvim; \
    nvim --version | head -n 1
RUN rustup component add rustfmt clippy
WORKDIR /work

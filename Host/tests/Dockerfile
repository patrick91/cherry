FROM rust:1.99-bookworm
RUN apt-get update -qq && apt-get install -y --no-install-recommends openssh-server \
    && rm -rf /var/lib/apt/lists/* && mkdir -p /run/sshd
# Debian's Neovim (0.7) predates the terminal queries current Neovim sends at
# startup. Install a pinned official release instead; keep the version and
# digests in sync with .github/workflows/host.yml.
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) arch=x86_64; digest=474430d53e6264f6d6dd18db42d6dc9df3a1b56ca9e88a325bbf860e1a811d87 ;; \
      arm64) arch=arm64; digest=8f1f64a0bdb97247034038c3823c6cbad5bdf9ecd5751b85494b71c3ee04c815 ;; \
      *) echo "No pinned Neovim build for $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 3 -o /tmp/nvim.tar.gz \
      "https://github.com/neovim/neovim/releases/download/v0.12.6/nvim-linux-$arch.tar.gz"; \
    echo "$digest  /tmp/nvim.tar.gz" | sha256sum -c -; \
    mkdir -p /opt/nvim; \
    tar -xzf /tmp/nvim.tar.gz -C /opt/nvim --strip-components=1; \
    rm /tmp/nvim.tar.gz; \
    ln -s /opt/nvim/bin/nvim /usr/local/bin/nvim; \
    nvim --version | head -n 1
RUN rustup component add rustfmt clippy
WORKDIR /work

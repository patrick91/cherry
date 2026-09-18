FROM rust:1.94-bookworm
RUN apt-get update -qq && apt-get install -y --no-install-recommends neovim openssh-server \
    && rm -rf /var/lib/apt/lists/* && mkdir -p /run/sshd
RUN rustup component add rustfmt clippy
WORKDIR /work

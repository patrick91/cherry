use std::{env, path::PathBuf};

fn main() {
    let target = env::var("TARGET").unwrap();
    let prefix = env::var_os("CHERRY_GHOSTTY_VT_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap())
                .join("../../vendor/ghostty-vt")
                .join(&target)
        });
    assert!(prefix.join("lib/libghostty-vt.a").is_file(),
        "Missing pinned libghostty-vt at {}. Run Scripts/build-host-vt first (or set CHERRY_GHOSTTY_VT_DIR).", prefix.display());
    // Stamps written by Scripts/build-host-vt after a successful build.
    let stamp = |name: &str| {
        std::fs::read_to_string(prefix.join(name))
            .unwrap_or_default()
            .trim()
            .to_owned()
    };
    assert_eq!(
        stamp("SOURCE_REVISION"),
        "a4aacd918ba9e79929ff608034c60a4341773ef0",
        "VT archive must match Cherry's pinned C ABI; run Scripts/build-host-vt"
    );
    // The daemon parses untrusted output from every session with this
    // library, so Zig's runtime safety checks must be compiled in.
    let optimize = stamp("OPTIMIZE");
    assert!(
        optimize == "ReleaseSafe",
        "libghostty-vt at {} is not a ReleaseSafe build (OPTIMIZE stamp: {optimize:?}); run Scripts/build-host-vt",
        prefix.display()
    );
    println!("cargo:rerun-if-env-changed=CHERRY_GHOSTTY_VT_DIR");
    for stamp in ["SOURCE_REVISION", "OPTIMIZE"] {
        println!("cargo:rerun-if-changed={}", prefix.join(stamp).display());
    }
    println!("cargo:rerun-if-changed=src/shim.c");
    println!(
        "cargo:rerun-if-changed={}",
        prefix.join("include").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        prefix.join("lib/libghostty-vt.a").display()
    );
    cc::Build::new()
        .file("src/shim.c")
        .include(prefix.join("include"))
        .define("GHOSTTY_STATIC", None)
        .flag_if_supported("-std=c11")
        .warnings(true)
        .compile("cherry-vt-shim");
    // Keep the link name separate from upstream's colocated dynamic library:
    // Apple ld otherwise prefers that dylib on some Rust toolchains.
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    std::fs::copy(
        prefix.join("lib/libghostty-vt.a"),
        out.join("libcherry_ghostty_vt.a"),
    )
    .unwrap();
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=cherry_ghostty_vt");
    println!(
        "cargo:rustc-link-lib={}",
        if target.contains("apple") {
            "c++"
        } else {
            "stdc++"
        }
    );
}

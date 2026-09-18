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
    assert_eq!(
        std::fs::read_to_string(prefix.join("SOURCE_REVISION"))
            .unwrap_or_default()
            .trim(),
        "7aab0a0392369613472bd5dcfd66bef58e78c3ec",
        "VT archive must match Cherry's pinned C ABI; run Scripts/build-host-vt"
    );
    println!("cargo:rerun-if-env-changed=CHERRY_GHOSTTY_VT_DIR");
    println!(
        "cargo:rerun-if-changed={}",
        prefix.join("SOURCE_REVISION").display()
    );
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

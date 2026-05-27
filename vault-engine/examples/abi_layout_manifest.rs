fn main() {
    println!(
        "{}",
        vault_engine::diagnostics::abi_manifest::generate_abi_manifest_json()
            .expect("serialize ABI manifest")
    );
}

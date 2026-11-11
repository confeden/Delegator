use security_framework::passwords::{get_generic_password, set_generic_password};
use std::io::Read;

const SERVICE: &str = "org.delegator.macos.api-keys";
const PREFIX: &str = "keychain:";

pub fn encrypt_string(plain_text: &str) -> Result<String, String> {
    if plain_text.is_empty() {
        return Ok(String::new());
    }
    let mut random = [0u8; 16];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut random))
        .map_err(|e| format!("Keychain identifier: {e}"))?;
    let account: String = random.iter().map(|b| format!("{b:02x}")).collect();
    set_generic_password(SERVICE, &account, plain_text.as_bytes())
        .map_err(|e| format!("Cannot save API key in macOS Keychain: {e}"))?;
    Ok(format!("{PREFIX}{account}"))
}

pub fn decrypt_string(reference: &str) -> Result<String, String> {
    if reference.is_empty() {
        return Ok(String::new());
    }
    let account = reference
        .strip_prefix(PREFIX)
        .filter(|id| id.len() == 32 && id.bytes().all(|b| b.is_ascii_hexdigit()))
        .ok_or("Invalid macOS Keychain reference (Windows keys must be entered again)")?;
    let secret = get_generic_password(SERVICE, account)
        .map_err(|e| format!("Cannot read API key from macOS Keychain: {e}"))?;
    String::from_utf8(secret).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_foreign_references_without_accessing_keychain() {
        assert!(decrypt_string("DPAPI-blob").is_err());
        assert!(decrypt_string("keychain:../../anything").is_err());
        assert_eq!(decrypt_string("").unwrap(), "");
    }
    #[test]
    #[ignore = "requires an unlocked login Keychain; creates and removes one test key"]
    fn keychain_roundtrip() {
        let reference = encrypt_string("delegator test secret").unwrap();
        let result = decrypt_string(&reference);
        let _ = security_framework::passwords::delete_generic_password(
            SERVICE,
            reference.strip_prefix(PREFIX).unwrap(),
        );
        assert_eq!(result.unwrap(), "delegator test secret");
    }
}

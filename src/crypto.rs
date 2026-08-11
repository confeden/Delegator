use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use std::ptr;
use windows_sys::Win32::Security::Cryptography::{
    CryptProtectData, CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN,
};

#[repr(C)]
pub struct DATA_BLOB {
    pub cbData: u32,
    pub pbData: *mut u8,
}

extern "system" {
    fn LocalFree(hmem: *mut std::ffi::c_void) -> *mut std::ffi::c_void;
}

/// Encrypts a plaintext string using Windows Data Protection API (DPAPI).
/// The encrypted output is base64 encoded and tied strictly to the current user & machine.
pub fn encrypt_string(plain_text: &str) -> Result<String, String> {
    if plain_text.is_empty() {
        return Ok(String::new());
    }

    let mut input_bytes = plain_text.as_bytes().to_vec();
    let mut data_in = DATA_BLOB {
        cbData: input_bytes.len() as u32,
        pbData: input_bytes.as_mut_ptr(),
    };
    let mut data_out = DATA_BLOB {
        cbData: 0,
        pbData: ptr::null_mut(),
    };

    let res = unsafe {
        CryptProtectData(
            &mut data_in as *mut _ as _,
            ptr::null(),
            ptr::null(),
            ptr::null_mut(),
            ptr::null(),
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut data_out as *mut _ as _,
        )
    };

    if res == 0 {
        return Err("Failed to encrypt data using Windows DPAPI".to_string());
    }

    let encrypted_slice =
        unsafe { std::slice::from_raw_parts(data_out.pbData, data_out.cbData as usize) };
    let encoded = BASE64.encode(encrypted_slice);

    unsafe {
        LocalFree(data_out.pbData as _);
    }

    Ok(encoded)
}

/// Decrypts a base64-encoded DPAPI encrypted blob.
/// Returns an error if the file was copied to another machine or user account.
pub fn decrypt_string(encrypted_base64: &str) -> Result<String, String> {
    if encrypted_base64.is_empty() {
        return Ok(String::new());
    }

    let mut decoded = BASE64
        .decode(encrypted_base64)
        .map_err(|e| format!("Base64 decode error: {}", e))?;

    let mut data_in = DATA_BLOB {
        cbData: decoded.len() as u32,
        pbData: decoded.as_mut_ptr(),
    };
    let mut data_out = DATA_BLOB {
        cbData: 0,
        pbData: ptr::null_mut(),
    };

    let res = unsafe {
        CryptUnprotectData(
            &mut data_in as *mut _ as _,
            ptr::null_mut(),
            ptr::null(),
            ptr::null_mut(),
            ptr::null(),
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut data_out as *mut _ as _,
        )
    };

    if res == 0 {
        return Err(
            "DPAPI decryption failed: Data is bound to another user/machine or corrupted"
                .to_string(),
        );
    }

    let decrypted_slice =
        unsafe { std::slice::from_raw_parts(data_out.pbData, data_out.cbData as usize) };
    let result = String::from_utf8(decrypted_slice.to_vec())
        .map_err(|e| format!("Invalid UTF-8 after DPAPI decryption: {}", e))?;

    unsafe {
        LocalFree(data_out.pbData as _);
    }

    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_dpapi_roundtrip() {
        let secret = "delegator-dpapi-roundtrip-test-value";
        let encrypted = encrypt_string(secret).expect("Encryption failed");
        assert_ne!(secret, encrypted);
        let decrypted = decrypt_string(&encrypted).expect("Decryption failed");
        assert_eq!(secret, decrypted);
    }
}

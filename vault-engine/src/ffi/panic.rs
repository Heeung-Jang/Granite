use std::panic::{self, AssertUnwindSafe, catch_unwind};
use std::sync::Mutex;

static FFI_PANIC_HOOK_LOCK: Mutex<()> = Mutex::new(());

pub(super) fn catch_ffi_unwind<T, F>(call: F) -> std::thread::Result<T>
where
    F: FnOnce() -> T,
{
    let _guard = FFI_PANIC_HOOK_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let previous_hook = panic::take_hook();
    panic::set_hook(Box::new(|_| {}));
    let result = catch_unwind(AssertUnwindSafe(call));
    panic::set_hook(previous_hook);
    result
}

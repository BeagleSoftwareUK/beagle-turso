// Runs blocking Rust work with Ruby's GVL released, so other Ruby threads keep
// running and a fiber scheduler that implements `blocking_operation_wait` can
// move the call to a worker thread (keeping its reactor live).
//
// The closure must not touch any Ruby object: convert arguments before calling
// and build Ruby results after it returns. No unblocking function is passed,
// so Thread#raise/kill (and Timeout) are delivered only once the call returns:
// rb_nogvl then raises the pending interrupt by longjmp. That is caught with
// rb_protect (magnus::rb_sys::protect), so it never unwinds through Rust
// frames; any value the native call produced is dropped normally (for `open`,
// the Database is closed) and the exception comes back as `Err`.

use std::ffi::c_void;
use std::panic::{self, AssertUnwindSafe};
use std::ptr;

use magnus::Error;

// From ruby/thread.h. Rubies that predate it test only the INTR_FAIL (0x1) and
// UBF_ASYNC_SAFE (0x2) bits and ignore this one (Task 1, F2).
const RB_NOGVL_OFFLOAD_SAFE: i32 = 0x4;

struct Call<F, R> {
    f: Option<F>,
    out: Option<std::thread::Result<R>>,
}

unsafe extern "C" fn trampoline<F, R>(data: *mut c_void) -> *mut c_void
where
    F: FnOnce() -> R,
{
    let call = &mut *(data as *mut Call<F, R>);
    let f = call.f.take().expect("nogvl closure run twice");
    // Never unwind across the C frame.
    call.out = Some(panic::catch_unwind(AssertUnwindSafe(f)));
    ptr::null_mut()
}

pub fn without_gvl<F, R>(f: F) -> Result<R, Error>
where
    F: FnOnce() -> R + Send,
    R: Send,
{
    let mut call = Call { f: Some(f), out: None };
    let protected = magnus::rb_sys::protect(|| {
        unsafe {
            rb_sys::rb_nogvl(
                Some(trampoline::<F, R>),
                &mut call as *mut Call<F, R> as *mut c_void,
                None,
                ptr::null_mut(),
                RB_NOGVL_OFFLOAD_SAFE,
            );
        }
        0 // Qfalse; the value is unused
    });
    // On Err, `call` (and anything the closure produced) drops here normally.
    protected?;
    match call.out.expect("rb_nogvl returned without running the closure") {
        Ok(r) => Ok(r),
        Err(payload) => panic::resume_unwind(payload),
    }
}

use std::collections::VecDeque;
use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::SystemTime;

use crate::adapters::fs::path_resolver::VaultRoot;

pub const WATCHER_FLAG_MUST_SCAN_SUBDIRS: u32 = 0x0000_0001;
pub const WATCHER_FLAG_USER_DROPPED: u32 = 0x0000_0002;
pub const WATCHER_FLAG_KERNEL_DROPPED: u32 = 0x0000_0004;
pub const WATCHER_FLAG_EVENT_IDS_WRAPPED: u32 = 0x0000_0008;
pub const WATCHER_FLAG_ROOT_CHANGED: u32 = 0x0000_0020;
pub const WATCHER_FLAG_ITEM_CREATED: u32 = 0x0000_0100;
pub const WATCHER_FLAG_ITEM_REMOVED: u32 = 0x0000_0200;
pub const WATCHER_FLAG_ITEM_RENAMED: u32 = 0x0000_0800;
pub const WATCHER_FLAG_ITEM_MODIFIED: u32 = 0x0000_1000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WatcherEvent {
    pub relative_path: Option<PathBuf>,
    pub kind: WatcherEventKind,
    pub flags: u32,
    pub event_id: Option<u64>,
    pub requires_full_rescan: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WatcherEventKind {
    Created,
    Modified,
    Removed,
    Renamed,
    RootChanged,
    Ambiguous,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InitialScanState {
    Complete,
    Stale,
    Ambiguous,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InitialScanReconciliation {
    pub state: InitialScanState,
    pub events: Vec<WatcherEvent>,
    pub stream_started_at: SystemTime,
    pub scan_started_at: SystemTime,
    pub stream_started_event_id: Option<u64>,
    pub overflowed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WatchedInitialScan<T> {
    pub scan: T,
    pub reconciliation: InitialScanReconciliation,
}

pub struct InitialScanWatcher {
    root: PathBuf,
    buffer: Arc<Mutex<WatcherEventBuffer>>,
    stream_started_at: SystemTime,
    scan_started_at: SystemTime,
    stream_started_event_id: Option<u64>,
    #[cfg(target_os = "macos")]
    _platform_stream: Option<macos_fsevents::MacFseventsStream>,
}

#[derive(Debug)]
pub enum WatcherError {
    BufferPoisoned,
    #[allow(dead_code)]
    Platform(String),
}

impl InitialScanWatcher {
    #[allow(dead_code)]
    pub fn start(root: &VaultRoot, capacity: usize) -> Result<Self, WatcherError> {
        let canonical_root = root.canonical_root().to_path_buf();
        let stream_started_at = SystemTime::now();
        let buffer = Arc::new(Mutex::new(WatcherEventBuffer::new(
            canonical_root.clone(),
            capacity,
        )));

        #[cfg(target_os = "macos")]
        let (platform_stream, stream_started_event_id) = {
            let event_id = macos_fsevents::current_event_id();
            let stream =
                macos_fsevents::MacFseventsStream::start(&canonical_root, Arc::clone(&buffer))?;
            (Some(stream), event_id)
        };

        #[cfg(not(target_os = "macos"))]
        let (platform_stream, stream_started_event_id): (Option<()>, Option<u64>) = (None, None);

        let scan_started_at = SystemTime::now();
        Ok(Self {
            root: canonical_root,
            buffer,
            stream_started_at,
            scan_started_at,
            stream_started_event_id,
            #[cfg(target_os = "macos")]
            _platform_stream: platform_stream,
        })
    }

    pub fn start_for_test(root: &VaultRoot, capacity: usize, event_id: Option<u64>) -> Self {
        let canonical_root = root.canonical_root().to_path_buf();
        let stream_started_at = SystemTime::now();
        let scan_started_at = SystemTime::now();
        Self {
            root: canonical_root.clone(),
            buffer: Arc::new(Mutex::new(WatcherEventBuffer::new(
                canonical_root,
                capacity,
            ))),
            stream_started_at,
            scan_started_at,
            stream_started_event_id: event_id,
            #[cfg(target_os = "macos")]
            _platform_stream: None,
        }
    }

    pub fn scan_started_at(&self) -> SystemTime {
        self.scan_started_at
    }

    pub fn stream_started_at(&self) -> SystemTime {
        self.stream_started_at
    }

    pub fn stream_started_event_id(&self) -> Option<u64> {
        self.stream_started_event_id
    }

    pub fn record_event_for_test(
        &self,
        path: impl AsRef<Path>,
        flags: u32,
        event_id: Option<u64>,
    ) -> Result<(), WatcherError> {
        let absolute_path = self.root.join(path.as_ref());
        self.record_absolute_event(absolute_path, flags, event_id)
    }

    pub fn record_absolute_event(
        &self,
        path: impl AsRef<Path>,
        flags: u32,
        event_id: Option<u64>,
    ) -> Result<(), WatcherError> {
        self.buffer
            .lock()
            .map_err(|_| WatcherError::BufferPoisoned)?
            .push_event(path.as_ref(), flags, event_id);
        Ok(())
    }

    pub fn finish<T>(self, scan: T) -> Result<WatchedInitialScan<T>, WatcherError> {
        let mut buffer = self
            .buffer
            .lock()
            .map_err(|_| WatcherError::BufferPoisoned)?;
        let events = buffer.drain();
        let overflowed = buffer.overflowed;
        let state = if overflowed || events.iter().any(|event| event.requires_full_rescan) {
            InitialScanState::Ambiguous
        } else if events.is_empty() {
            InitialScanState::Complete
        } else {
            InitialScanState::Stale
        };

        Ok(WatchedInitialScan {
            scan,
            reconciliation: InitialScanReconciliation {
                state,
                events,
                stream_started_at: self.stream_started_at,
                scan_started_at: self.scan_started_at,
                stream_started_event_id: self.stream_started_event_id,
                overflowed,
            },
        })
    }
}

impl fmt::Display for WatcherError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::BufferPoisoned => write!(formatter, "watcher event buffer is poisoned"),
            Self::Platform(message) => write!(formatter, "watcher platform error: {message}"),
        }
    }
}

impl std::error::Error for WatcherError {}

#[derive(Debug)]
struct WatcherEventBuffer {
    root: PathBuf,
    capacity: usize,
    events: VecDeque<WatcherEvent>,
    overflowed: bool,
}

impl WatcherEventBuffer {
    fn new(root: PathBuf, capacity: usize) -> Self {
        Self {
            root,
            capacity,
            events: VecDeque::new(),
            overflowed: false,
        }
    }

    fn push_event(&mut self, path: &Path, flags: u32, event_id: Option<u64>) {
        if self.capacity == 0 || self.events.len() >= self.capacity {
            self.overflowed = true;
            return;
        }

        let relative_path = path.strip_prefix(&self.root).ok().map(Path::to_path_buf);
        self.events.push_back(WatcherEvent {
            relative_path,
            kind: event_kind_from_flags(flags),
            flags,
            event_id,
            requires_full_rescan: flags_require_full_rescan(flags),
        });
    }

    fn drain(&mut self) -> Vec<WatcherEvent> {
        self.events.drain(..).collect()
    }
}

fn event_kind_from_flags(flags: u32) -> WatcherEventKind {
    if flags_require_full_rescan(flags) {
        return WatcherEventKind::Ambiguous;
    }
    if flags & WATCHER_FLAG_ROOT_CHANGED != 0 {
        return WatcherEventKind::RootChanged;
    }
    if flags & WATCHER_FLAG_ITEM_RENAMED != 0 {
        return WatcherEventKind::Renamed;
    }
    if flags & WATCHER_FLAG_ITEM_REMOVED != 0 {
        return WatcherEventKind::Removed;
    }
    if flags & WATCHER_FLAG_ITEM_CREATED != 0 {
        return WatcherEventKind::Created;
    }
    if flags & WATCHER_FLAG_ITEM_MODIFIED != 0 {
        return WatcherEventKind::Modified;
    }
    WatcherEventKind::Unknown
}

fn flags_require_full_rescan(flags: u32) -> bool {
    flags
        & (WATCHER_FLAG_MUST_SCAN_SUBDIRS
            | WATCHER_FLAG_USER_DROPPED
            | WATCHER_FLAG_KERNEL_DROPPED
            | WATCHER_FLAG_EVENT_IDS_WRAPPED)
        != 0
}

#[cfg(target_os = "macos")]
#[allow(dead_code)]
mod macos_fsevents {
    use super::*;
    use std::ffi::{CStr, CString, c_char, c_void};
    use std::ptr;

    type CFAllocatorRef = *const c_void;
    type CFArrayRef = *const c_void;
    type CFRunLoopRef = *mut c_void;
    type CFStringRef = *const c_void;
    type FSEventStreamRef = *mut c_void;
    type ConstFSEventStreamRef = *const c_void;
    type FSEventStreamEventFlags = u32;
    type FSEventStreamEventId = u64;
    type CFTimeInterval = f64;
    type Boolean = u8;

    const K_CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;
    const K_FS_EVENT_STREAM_EVENT_ID_SINCE_NOW: FSEventStreamEventId = u64::MAX;
    const K_FS_EVENT_STREAM_CREATE_FLAG_NO_DEFER: u32 = 0x0000_0002;
    const K_FS_EVENT_STREAM_CREATE_FLAG_FILE_EVENTS: u32 = 0x0000_0010;

    #[repr(C)]
    struct FSEventStreamContext {
        version: isize,
        info: *mut c_void,
        retain: Option<unsafe extern "C" fn(*const c_void) -> *const c_void>,
        release: Option<unsafe extern "C" fn(*const c_void)>,
        copy_description: Option<unsafe extern "C" fn(*const c_void) -> CFStringRef>,
    }

    pub struct MacFseventsStream {
        stream: FSEventStreamRef,
        callback_context: *mut CallbackContext,
        path_string: CFStringRef,
        path_array: CFArrayRef,
    }

    struct CallbackContext {
        root: PathBuf,
        buffer: Arc<Mutex<WatcherEventBuffer>>,
    }

    impl MacFseventsStream {
        pub fn start(
            root: &Path,
            buffer: Arc<Mutex<WatcherEventBuffer>>,
        ) -> Result<Self, WatcherError> {
            let root_string = root
                .to_str()
                .ok_or_else(|| WatcherError::Platform("watch root is not valid UTF-8".into()))?;
            let c_root = CString::new(root_string)
                .map_err(|_| WatcherError::Platform("watch root contains NUL".into()))?;
            let path_string = unsafe {
                CFStringCreateWithCString(ptr::null(), c_root.as_ptr(), K_CF_STRING_ENCODING_UTF8)
            };
            if path_string.is_null() {
                return Err(WatcherError::Platform(
                    "failed to create FSEvents path".into(),
                ));
            }

            let values = [path_string];
            let path_array = unsafe {
                CFArrayCreate(
                    ptr::null(),
                    values.as_ptr(),
                    values.len() as isize,
                    ptr::null(),
                )
            };
            if path_array.is_null() {
                unsafe { CFRelease(path_string) };
                return Err(WatcherError::Platform(
                    "failed to create FSEvents path array".into(),
                ));
            }

            let callback_context = Box::into_raw(Box::new(CallbackContext {
                root: root.to_path_buf(),
                buffer,
            }));
            let mut context = FSEventStreamContext {
                version: 0,
                info: callback_context.cast(),
                retain: None,
                release: None,
                copy_description: None,
            };
            let stream = unsafe {
                FSEventStreamCreate(
                    ptr::null(),
                    fsevents_callback,
                    &mut context,
                    path_array,
                    K_FS_EVENT_STREAM_EVENT_ID_SINCE_NOW,
                    0.05,
                    K_FS_EVENT_STREAM_CREATE_FLAG_NO_DEFER
                        | K_FS_EVENT_STREAM_CREATE_FLAG_FILE_EVENTS,
                )
            };
            if stream.is_null() {
                unsafe {
                    drop(Box::from_raw(callback_context));
                    CFRelease(path_array);
                    CFRelease(path_string);
                }
                return Err(WatcherError::Platform(
                    "failed to create FSEvents stream".into(),
                ));
            }

            unsafe {
                FSEventStreamScheduleWithRunLoop(
                    stream,
                    CFRunLoopGetCurrent(),
                    kCFRunLoopDefaultMode,
                );
            }

            let started = unsafe { FSEventStreamStart(stream) };
            if started == 0 {
                unsafe {
                    FSEventStreamInvalidate(stream);
                    FSEventStreamRelease(stream);
                    drop(Box::from_raw(callback_context));
                    CFRelease(path_array);
                    CFRelease(path_string);
                }
                return Err(WatcherError::Platform(
                    "failed to start FSEvents stream".into(),
                ));
            }

            Ok(Self {
                stream,
                callback_context,
                path_string,
                path_array,
            })
        }
    }

    impl Drop for MacFseventsStream {
        fn drop(&mut self) {
            unsafe {
                FSEventStreamStop(self.stream);
                FSEventStreamInvalidate(self.stream);
                FSEventStreamRelease(self.stream);
                drop(Box::from_raw(self.callback_context));
                CFRelease(self.path_array);
                CFRelease(self.path_string);
            }
        }
    }

    pub fn current_event_id() -> Option<u64> {
        Some(unsafe { FSEventsGetCurrentEventId() })
    }

    unsafe extern "C" fn fsevents_callback(
        _stream_ref: ConstFSEventStreamRef,
        client_callback_info: *mut c_void,
        num_events: usize,
        event_paths: *mut c_void,
        event_flags: *const FSEventStreamEventFlags,
        event_ids: *const FSEventStreamEventId,
    ) {
        if client_callback_info.is_null() || event_paths.is_null() {
            return;
        }

        let context = unsafe { &*(client_callback_info.cast::<CallbackContext>()) };
        let paths = event_paths.cast::<*const c_char>();
        let mut buffer = match context.buffer.lock() {
            Ok(buffer) => buffer,
            Err(_) => return,
        };

        for index in 0..num_events {
            let path_pointer = unsafe { *paths.add(index) };
            if path_pointer.is_null() {
                continue;
            }
            let path = unsafe { CStr::from_ptr(path_pointer) };
            let Ok(path) = path.to_str() else {
                buffer.push_event(&context.root, WATCHER_FLAG_MUST_SCAN_SUBDIRS, None);
                continue;
            };
            let flags = unsafe { *event_flags.add(index) };
            let event_id = unsafe { *event_ids.add(index) };
            buffer.push_event(Path::new(path), flags, Some(event_id));
        }
    }

    #[link(name = "CoreServices", kind = "framework")]
    unsafe extern "C" {
        fn FSEventStreamCreate(
            allocator: CFAllocatorRef,
            callback: unsafe extern "C" fn(
                ConstFSEventStreamRef,
                *mut c_void,
                usize,
                *mut c_void,
                *const FSEventStreamEventFlags,
                *const FSEventStreamEventId,
            ),
            context: *mut FSEventStreamContext,
            paths_to_watch: CFArrayRef,
            since_when: FSEventStreamEventId,
            latency: CFTimeInterval,
            flags: u32,
        ) -> FSEventStreamRef;
        fn FSEventStreamScheduleWithRunLoop(
            stream_ref: FSEventStreamRef,
            run_loop: CFRunLoopRef,
            run_loop_mode: CFStringRef,
        );
        fn FSEventStreamStart(stream_ref: FSEventStreamRef) -> Boolean;
        fn FSEventStreamStop(stream_ref: FSEventStreamRef);
        fn FSEventStreamInvalidate(stream_ref: FSEventStreamRef);
        fn FSEventStreamRelease(stream_ref: FSEventStreamRef);
        fn FSEventsGetCurrentEventId() -> FSEventStreamEventId;
    }

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        static kCFRunLoopDefaultMode: CFStringRef;
        fn CFStringCreateWithCString(
            allocator: CFAllocatorRef,
            c_str: *const c_char,
            encoding: u32,
        ) -> CFStringRef;
        fn CFArrayCreate(
            allocator: CFAllocatorRef,
            values: *const *const c_void,
            num_values: isize,
            callbacks: *const c_void,
        ) -> CFArrayRef;
        fn CFRunLoopGetCurrent() -> CFRunLoopRef;
        fn CFRelease(cf: *const c_void);
    }
}
